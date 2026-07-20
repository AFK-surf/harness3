import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import harness3/llm
import harness3/plugin
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol
import harness3/plugin/mcp/runtime

const plugin_name = "mcp"

pub type Error {
  MissingManifest(configuration_id: String)
}

type State {
  State(configuration_id: String, manifest_revision: Int)
}

pub fn new(
  mcp_runtime: runtime.Runtime,
  snapshot: runtime.Snapshot,
) -> Result(plugin.Plugin, Error) {
  let runtime.Snapshot(catalog_revision:, configuration:) = snapshot
  use manifest <- result.try(case configuration.manifest {
    Some(manifest) -> Ok(manifest)
    None -> Error(MissingManifest(configuration.id))
  })
  let initial_state = encode_state(State(configuration.id, catalog_revision))
  let value =
    plugin.new(plugin_name, initial_state)
    |> plugin.with_system_prompt(plugin.SystemPromptSection(
      "MCP specialist",
      "You have access to every discovered tool in the global MCP configuration `"
        <> configuration.id
        <> "` ("
        <> configuration.label
        <> "). MCP tools may access external systems. Use them deliberately and report concrete sources and results to your teammates.",
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
        Ok(plugin.hook_result(
          encode_state(State(configuration.id, catalog_revision)),
          context,
          Nil,
        ))
      }),
    )
  Ok(
    list.fold(manifest.tools, value, fn(value, tool) {
      plugin.with_tool(value, mcp_tool(mcp_runtime, configuration.id, tool))
    }),
  )
}

fn mcp_tool(
  mcp_runtime: runtime.Runtime,
  configuration_id: String,
  tool: configuration.Tool,
) -> plugin.Tool {
  let description = case tool.description {
    Some(description) -> "MCP `" <> tool.server_id <> "`: " <> description
    None -> "MCP tool `" <> tool.name <> "` from `" <> tool.server_id <> "`."
  }
  plugin.tool(
    llm.Tool(tool.exposed_name, Some(description), tool.input_schema),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case
        runtime.call(
          mcp_runtime,
          configuration_id,
          tool.exposed_name,
          arguments,
        )
      {
        Ok(result) -> call_output(result)
        Error(error) -> plugin.ToolOutput([llm.Text(error)], True)
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
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
    #("schema_version", json.int(1)),
    #("configuration_id", json.string(state.configuration_id)),
    #("manifest_revision", json.int(state.manifest_revision)),
  ])
  |> json.to_string
}

fn state_decoder() -> decode.Decoder(State) {
  use schema <- decode.field("schema_version", decode.int)
  use configuration_id <- decode.field("configuration_id", decode.string)
  use manifest_revision <- decode.field("manifest_revision", decode.int)
  case schema {
    1 -> decode.success(State(configuration_id, manifest_revision))
    _ -> decode.failure(State("", 0), "unsupported MCP plugin state schema")
  }
}
