import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm
import harness3/plugin
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/json_document
import harness3/plugin/mcp/pool
import harness3/plugin/mcp/protocol
import harness3/plugin/mcp/runtime

const plugin_name = "mcp"

type State {
  State(configuration_id: String)
}

type BrokerCall {
  BrokerCall(tool: String, arguments: json.Json)
}

pub fn new(
  mcp_runtime: runtime.Runtime,
  configuration: configuration.Configuration,
) -> plugin.Plugin {
  plugin.new(plugin_name, encode_state(State(configuration.id)))
  |> plugin.with_system_prompt(plugin.SystemPromptSection(
    "MCP specialist",
    "You have brokered access to the external resources in global MCP configuration `"
      <> configuration.id
      <> "` ("
      <> configuration.label
      <> "). Use `mcp.list` to inspect the tools currently available from reachable MCP servers, then use `mcp.call` with one of the returned identifiers. Unreachable servers are excluded. You have no filesystem or shell access. External tools may read or change remote systems, so use them deliberately and report concrete sources and results to the lead agent.",
  ))
  |> plugin.on_activate(
    plugin.activation_hook(fn(state, context) {
      use decoded <- result.try(
        json.parse(state, state_decoder())
        |> result.map_error(fn(error) {
          plugin.InvalidState(plugin_name, string.inspect(error))
        }),
      )
      use _ <- result.try(case decoded.configuration_id == configuration.id {
        True -> Ok(Nil)
        False ->
          Error(plugin.InvalidState(
            plugin_name,
            "persisted configuration ID does not match the installed profile",
          ))
      })
      // Activation runs inside the group coordinator, which also services its
      // own lease renewal, so it must never touch MCP servers. Only the
      // configuration is validated here; connections are opened lazily by the
      // tools below, which run in this agent's own plugin host.
      use _ <- result.try(
        runtime.configuration(mcp_runtime, configuration.id)
        |> result.map_error(fn(error) {
          plugin.HookFailed(plugin_name, "activation", error)
        }),
      )
      Ok(plugin.hook_result(encode_state(State(configuration.id)), context, Nil))
    }),
  )
  |> plugin.with_tool(list_tool(mcp_runtime, configuration.id))
  |> plugin.with_tool(call_tool(mcp_runtime, configuration.id))
}

fn list_tool(
  mcp_runtime: runtime.Runtime,
  configuration_id: String,
) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "mcp.list",
      Some(
        "List tools currently available through reachable servers in this agent's MCP configuration. Returns stable tool identifiers, descriptions, and typed input/output schemas, plus unavailable servers.",
      ),
      json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
        #("additionalProperties", json.bool(False)),
      ]),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      case json_document.parse_object(arguments) {
        Error(error) ->
          Ok(plugin.hook_result(
            state,
            context,
            plugin.ToolOutput([llm.Text(error)], True),
          ))
        Ok(_) -> {
          // Opening connections here — inside this agent's plugin host — is
          // what makes them the agent's own: the pool is linked to the host
          // and dies with it.
          let #(context, opened) =
            ensure_pool(mcp_runtime, configuration_id, context)
          let output = case opened {
            Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
            Ok(connections) ->
              case pool.list(connections, listing_timeout_milliseconds) {
                Ok(listing) ->
                  plugin.ToolOutput(
                    [llm.Text(listing |> encode_listing |> json.to_string)],
                    False,
                  )
                Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
              }
          }
          Ok(plugin.hook_result(state, context, output))
        }
      }
    },
  )
}

fn call_tool(
  mcp_runtime: runtime.Runtime,
  configuration_id: String,
) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "mcp.call",
      Some(
        "Call one currently available MCP tool. Obtain the tool identifier and its argument schema from `mcp.list` first.",
      ),
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([
            #(
              "tool",
              json.object([
                #("type", json.string("string")),
                #(
                  "description",
                  json.string("Stable tool identifier returned by mcp.list"),
                ),
              ]),
            ),
            #(
              "arguments",
              json.object([
                #("type", json.string("object")),
                #(
                  "description",
                  json.string("Arguments matching the tool's input schema"),
                ),
              ]),
            ),
          ]),
        ),
        #("required", json.array(["tool", "arguments"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let #(context, output) = case
        json.parse(arguments, broker_call_decoder())
      {
        Error(error) -> #(
          context,
          plugin.ToolOutput(
            [llm.Text("invalid mcp.call arguments: " <> string.inspect(error))],
            True,
          ),
        )
        Ok(call) -> {
          let #(context, opened) =
            ensure_pool(mcp_runtime, configuration_id, context)
          let output = case opened {
            Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
            Ok(connections) ->
              case
                pool.call(
                  connections,
                  call.tool,
                  json.to_string(call.arguments),
                  call_timeout_milliseconds,
                )
              {
                Ok(result) -> call_output(result)
                Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
              }
          }
          #(context, output)
        }
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

/// Returns this agent's connection pool, starting it on first use.
///
/// The pool is started from here, which runs inside the agent's plugin host,
/// so it is linked to that host and dies with the agent. Its handle lives in
/// the plugin's ephemeral resource — never in the durable state and never in
/// node-wide state — so no other agent can reach or invalidate it.
fn ensure_pool(
  mcp_runtime: runtime.Runtime,
  configuration_id: String,
  context: plugin.Context,
) -> #(plugin.Context, Result(pool.Pool, String)) {
  case existing_pool(context) {
    Some(connections) -> #(context, Ok(connections))
    None ->
      case runtime.pool_spec(mcp_runtime, configuration_id) {
        Error(error) -> #(context, Error(error))
        Ok(spec) ->
          case pool.start(spec) {
            Error(error) -> #(context, Error(error))
            Ok(connections) -> #(
              plugin.set_resource(context, to_dynamic(connections)),
              Ok(connections),
            )
          }
      }
  }
}

fn existing_pool(context: plugin.Context) -> Option(pool.Pool) {
  case plugin.resource(context) {
    Error(_) -> None
    Ok(value) -> {
      let connections = from_dynamic(value)
      // A pool whose process is gone (its agent's host was restarted) must be
      // replaced rather than reused.
      case pool.alive(connections) {
        True -> Some(connections)
        False -> None
      }
    }
  }
}

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: pool.Pool) -> dynamic.Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: dynamic.Dynamic) -> pool.Pool

/// Bounds how long a tool call may occupy this agent's plugin host. Only this
/// agent is affected, but the host also serves cross-agent callbacks.
const call_timeout_milliseconds = 301_000

const listing_timeout_milliseconds = 120_000

fn encode_listing(listing: pool.Listing) -> json.Json {
  let pool.Listing(configuration:, tools:, failures:) = listing
  json.object([
    #("configuration_id", json.string(configuration.id)),
    #("configuration_label", json.string(configuration.label)),
    #("tools", json.array(tools, encode_tool)),
    #("unavailable_servers", json.array(failures, encode_failure)),
  ])
}

fn encode_tool(tool: configuration.Tool) -> json.Json {
  json.object([
    #("tool", json.string(tool.exposed_name)),
    #("server_id", json.string(tool.server_id)),
    #("name", json.string(tool.name)),
    #("description", json.nullable(tool.description, json.string)),
    #("input_schema", tool.input_schema),
    #("output_schema", json.nullable(tool.output_schema, fn(value) { value })),
  ])
}

fn encode_failure(failure: pool.ServerFailure) -> json.Json {
  let pool.ServerFailure(server_id:, reason:) = failure
  json.object([
    #("server_id", json.string(server_id)),
    #("reason", json.string(reason)),
  ])
}

fn call_output(result: protocol.CallResult) -> plugin.ToolOutput {
  let content =
    list.map(result.content, fn(content) {
      case content {
        protocol.Text(text) -> llm.Text(text)
        protocol.Image(data, media_type) ->
          llm.Image(llm.Base64(media_type, data), llm.Auto)
        protocol.Other(document) -> llm.Text(document)
      }
    })
  let content = case result.structured_content, content {
    Some(structured), [] -> [llm.Text(structured)]
    Some(structured), content -> list.append(content, [llm.Text(structured)])
    None, content -> content
  }
  let content = case content {
    [] -> [llm.Text("MCP tool completed without content")]
    content -> content
  }
  plugin.ToolOutput(content, result.is_error)
}

fn encode_state(state: State) -> String {
  json.object([
    #("schema_version", json.int(2)),
    #("configuration_id", json.string(state.configuration_id)),
  ])
  |> json.to_string
}

fn state_decoder() -> decode.Decoder(State) {
  use schema <- decode.field("schema_version", decode.int)
  use configuration_id <- decode.field("configuration_id", decode.string)
  case schema {
    2 -> decode.success(State(configuration_id))
    _ -> decode.failure(State(""), "unsupported MCP plugin state schema")
  }
}

fn broker_call_decoder() -> decode.Decoder(BrokerCall) {
  use tool <- decode.field("tool", decode.string)
  use arguments <- decode.field("arguments", json_document.object_decoder())
  decode.success(BrokerCall(tool, arguments))
}
