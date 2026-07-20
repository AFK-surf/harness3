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
import harness3/plugin/mcp/connections
import harness3/plugin/mcp/json_document
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
  |> plugin.on_release(
    plugin.release_hook(fn(_state, context) {
      // Transports survive the plugin host's normal exit (a normal exit signal
      // does not take down linked processes), so they are closed explicitly
      // here. `close` only sends, so the host is not held up.
      case existing_connections(context) {
        Some(open) -> {
          let _ = connections.close(open)
          Nil
        }
        None -> Nil
      }
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
          // Connecting here — inside this agent's plugin host — is what
          // makes the transports the agent's own: they are linked to the host
          // and die with it.
          let #(context, output) =
            with_connections(
              mcp_runtime,
              configuration_id,
              context,
              fn(connections) {
                let #(connections, listing) = connections.list(connections)
                let output = case listing {
                  Ok(listing) ->
                    plugin.ToolOutput(
                      [llm.Text(listing |> encode_listing |> json.to_string)],
                      False,
                    )
                  Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
                }
                #(connections, output)
              },
            )
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
        Ok(call) ->
          with_connections(
            mcp_runtime,
            configuration_id,
            context,
            fn(connections) {
              let #(connections, outcome) =
                connections.call(
                  connections,
                  call.tool,
                  json.to_string(call.arguments),
                )
              let output = case outcome {
                Ok(result) -> call_output(result)
                Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
              }
              #(connections, output)
            },
          )
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

/// Runs `use_connections` against this agent's connections, creating them on
/// first use and storing the updated value back in the plugin's ephemeral
/// resource.
///
/// The resource is per-agent and never persisted, so the transports opened
/// here — linked to this plugin host — are reachable only by this agent and
/// die with it.
fn with_connections(
  mcp_runtime: runtime.Runtime,
  configuration_id: String,
  context: plugin.Context,
  use_connections: fn(connections.Connections) ->
    #(connections.Connections, plugin.ToolOutput),
) -> #(plugin.Context, plugin.ToolOutput) {
  case existing_connections(context) {
    Some(connections) -> {
      let #(connections, output) = use_connections(connections)
      #(plugin.set_resource(context, to_dynamic(connections)), output)
    }
    None ->
      case runtime.connection_spec(mcp_runtime, configuration_id) {
        Error(error) -> #(context, plugin.ToolOutput([llm.Text(error)], True))
        Ok(spec) -> {
          let #(connections, output) = use_connections(connections.new(spec))
          #(plugin.set_resource(context, to_dynamic(connections)), output)
        }
      }
  }
}

fn existing_connections(
  context: plugin.Context,
) -> Option(connections.Connections) {
  case plugin.resource(context) {
    Error(_) -> None
    Ok(value) -> Some(from_dynamic(value))
  }
}

@external(erlang, "gleam_stdlib", "identity")
fn to_dynamic(value: connections.Connections) -> dynamic.Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn from_dynamic(value: dynamic.Dynamic) -> connections.Connections

fn encode_listing(listing: connections.Listing) -> json.Json {
  let connections.Listing(configuration:, tools:, failures:) = listing
  json.object([
    #("configuration_id", json.string(configuration.id)),
    #("configuration_label", json.string(configuration.label)),
    #("tools", json.array(tools, encode_tool)),
    #("unavailable_servers", json.array(failures, encode_failure)),
  ])
}

fn encode_tool(tool: configuration.Tool) -> json.Json {
  json.object([
    #("tool", json.string(tool.broker_name)),
    #("server_id", json.string(tool.server_id)),
    #("name", json.string(tool.name)),
    #("description", json.nullable(tool.description, json.string)),
    #("input_schema", tool.input_schema),
    #("output_schema", json.nullable(tool.output_schema, fn(value) { value })),
  ])
}

fn encode_failure(failure: connections.ServerFailure) -> json.Json {
  let connections.ServerFailure(server_id:, reason:) = failure
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
