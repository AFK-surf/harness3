import filepath
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import harness3/agent_group_registry
import harness3/llm
import harness3/plugin
import shellout
import simplifile

const plugin_name = "coding"

/// Synthetic tool call used to deliver incoming teammate messages. It is
/// injected into the recipient's history and never appears in a tool list.
const receive_tool_name = "team.receive_message"

/// Group attribute holding the session's shared workspace root. Written by
/// the application when the session is created; read here at activation and
/// on every tool invocation.
pub const workspace_attribute = "workspace"

/// Agent attribute holding the agent's free-text role description.
pub const role_attribute = "role"

/// Agent attribute holding the agent kind (`coding`, `researcher`, or `mcp`)
/// that selects the capability instructions in the role prompt.
pub const kind_attribute = "kind"

/// Filesystem and shell capabilities for agents that are allowed to modify
/// the selected workspace. The workspace root is read from the group's
/// durable attributes on every use, so one plugin instance serves every
/// session. Team coordination is installed separately so other agent kinds do
/// not inherit these capabilities.
pub fn workspace() -> plugin.Plugin {
  plugin.new(plugin_name, "{}")
  |> plugin.with_dynamic_system_prompt(fn(_state, context) {
    plugin.SystemPromptSection("Workspace tools", case workspace_root(context) {
      Ok(root) ->
        "The shared workspace root is `"
        <> root
        <> "`. Use `coding.read`, `coding.write`, and `coding.exec` to inspect, change, and verify it. Tool paths are relative to this workspace."
      Error(error) -> error
    })
  })
  |> plugin.with_tool(read_tool())
  |> plugin.with_tool(write_tool())
  |> plugin.with_tool(exec_tool())
}

fn workspace_root(context: plugin.Context) -> Result(String, String) {
  let plugin.Host(group_attributes:, ..) = plugin.host(context)
  case dict.get(group_attributes, workspace_attribute) {
    Ok(root) if root != "" -> Ok(root)
    _ ->
      Error(
        "This session has no durable workspace attribute; the workspace tools are unavailable.",
      )
  }
}

/// Durable teammate messaging and the role prompt shared by heterogeneous
/// agent profiles. Identity, role, kind, and permitted recipients are read
/// from the durable agent/group attributes at activation, so one plugin
/// instance serves every session.
pub fn collaboration() -> plugin.Plugin {
  plugin.new("team", "{}")
  |> plugin.with_dynamic_system_prompt(fn(_state, context) {
    let host = plugin.host(context)
    let plugin.Host(agent_id:, agent_attributes:, ..) = host
    let role = dict.get(agent_attributes, role_attribute) |> result.unwrap("")
    let kind = dict.get(agent_attributes, kind_attribute) |> result.unwrap("")
    plugin.SystemPromptSection(
      "Team role",
      "You are agent `"
        <> agent_id
        <> "` in a persistent harness3 team. Your role is: "
        <> role
        <> ".\n\n"
        <> capability_instructions(kind)
        <> " Your permitted `team.message_agent` recipients are: "
        <> string.join(message_targets(host), ", ")
        <> ". `team.message_agent` rejects every other recipient. Subagents communicate only with the lead; the lead may communicate with every subagent. Messages are durable and wake the target agent; incoming messages arrive as `"
        <> receive_tool_name
        <> "` synthetic tool results naming the sender. Replies are delivered automatically. Coordinate explicitly and report concrete results.",
    )
  })
  |> plugin.with_tool(message_tool())
}

/// Subagents communicate only with the lead; the lead may communicate with
/// every subagent.
fn message_targets(host: plugin.Host) -> List(String) {
  let plugin.Host(agent_id:, peers:, ..) = host
  let peer_ids = list.map(peers, fn(peer) { peer.0 })
  case agent_id {
    "lead" -> peer_ids
    _ ->
      case list.contains(peer_ids, "lead") {
        True -> ["lead"]
        False -> []
      }
  }
}

fn capability_instructions(kind: String) -> String {
  case kind {
    "coding" ->
      "You can inspect and modify the shared workspace, run commands with the installed coding tools, and read, write, list, delete, or create transfer URLs for durable objects in the session's cloud storage workspace."
    "researcher" ->
      "You have no filesystem, workspace, shell, or MCP tools. You can use `team.message_agent` only to report to the lead, and you can use the `cloud_storage.*` tools to read, write, list, delete, or create transfer URLs for durable objects in the session's cloud storage workspace."
    "mcp" ->
      "You are the MCP research specialist with access to all enabled global MCP servers. You have `team.message_agent` (to report to the lead), `mcp.list` (to inspect tools from currently reachable external servers), `mcp.call` (to invoke a listed tool), and the `cloud_storage.*` tools for durable objects in the session's cloud storage workspace. You have no direct filesystem or shell access."
    _ -> ""
  }
}

fn read_tool() -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "coding.read",
      Some("Read a UTF-8 file from the shared workspace with line numbers."),
      object_schema(
        [
          property("path", "string", "Workspace-relative file path"),
          property("offset", "integer", "Zero-based first line (default 0)"),
          property("limit", "integer", "Maximum lines (default 400, max 2000)"),
        ],
        ["path"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      use workspace <- with_workspace(state, context)
      case json.parse(arguments, read_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid coding.read arguments: " <> string.inspect(error),
            True,
          ))
        Ok(ReadArguments(path, offset, limit)) ->
          case workspace_path(workspace, path) {
            Error(error) -> Ok(tool_result(state, context, error, True))
            Ok(path) ->
              case simplifile.read(path) {
                Error(error) ->
                  Ok(tool_result(
                    state,
                    context,
                    simplifile.describe_error(error),
                    True,
                  ))
                Ok(body) -> {
                  let lines =
                    body
                    |> string.split("\n")
                    |> list.drop(offset |> int.max(0))
                    |> list.take(limit |> int.clamp(1, 2000))
                    |> list.index_map(fn(line, index) {
                      int.to_string(index + int.max(offset, 0) + 1)
                      <> " | "
                      <> line
                    })
                  Ok(tool_result(
                    state,
                    context,
                    string.join(lines, "\n"),
                    False,
                  ))
                }
              }
          }
      }
    },
  )
}

fn write_tool() -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "coding.write",
      Some("Create or replace a UTF-8 file in the shared workspace."),
      object_schema(
        [
          property("path", "string", "Workspace-relative file path"),
          property("content", "string", "Complete new file contents"),
        ],
        ["path", "content"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      use workspace <- with_workspace(state, context)
      case json.parse(arguments, write_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid coding.write arguments: " <> string.inspect(error),
            True,
          ))
        Ok(WriteArguments(path, content)) ->
          case workspace_path(workspace, path) {
            Error(error) -> Ok(tool_result(state, context, error, True))
            Ok(path) -> {
              let directory = filepath.directory_name(path)
              case simplifile.create_directory_all(directory) {
                Error(error) ->
                  Ok(tool_result(
                    state,
                    context,
                    simplifile.describe_error(error),
                    True,
                  ))
                Ok(Nil) ->
                  case simplifile.write(to: path, contents: content) {
                    Ok(Nil) ->
                      Ok(tool_result(
                        state,
                        context,
                        "Wrote "
                          <> int.to_string(string.length(content))
                          <> " characters to "
                          <> path,
                        False,
                      ))
                    Error(error) ->
                      Ok(tool_result(
                        state,
                        context,
                        simplifile.describe_error(error),
                        True,
                      ))
                  }
              }
            }
          }
      }
    },
  )
}

fn exec_tool() -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "coding.exec",
      Some("Run a shell command in the shared workspace."),
      object_schema(
        [
          property("command", "string", "Shell command to execute"),
          property(
            "timeout_seconds",
            "integer",
            "Timeout (default 30, max 300)",
          ),
        ],
        ["command"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      use workspace <- with_workspace(state, context)
      case json.parse(arguments, exec_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid coding.exec arguments: " <> string.inspect(error),
            True,
          ))
        Ok(ExecArguments(command, timeout_seconds)) -> {
          let timeout = int.clamp(timeout_seconds, 1, 300)
          case
            shellout.command(
              run: "timeout",
              with: [int.to_string(timeout) <> "s", "sh", "-lc", command],
              in: workspace,
              opt: [],
            )
          {
            Ok(output) ->
              Ok(tool_result(state, context, trim_output(output), False))
            Error(#(status, output)) ->
              Ok(tool_result(
                state,
                context,
                trim_output(output)
                  <> "\n[command exited with status "
                  <> int.to_string(status)
                  <> "]",
                True,
              ))
          }
        }
      }
    },
  )
}

fn with_workspace(
  state: String,
  context: plugin.Context,
  run: fn(String) -> Result(plugin.HookResult(plugin.ToolOutput), plugin.Error),
) -> Result(plugin.HookResult(plugin.ToolOutput), plugin.Error) {
  case workspace_root(context) {
    Ok(root) -> run(root)
    Error(error) -> Ok(tool_result(state, context, error, True))
  }
}

fn message_tool() -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "team.message_agent",
      Some("Send a durable message to a teammate and wake that agent."),
      object_schema(
        [
          property("agent_id", "string", "Target teammate ID"),
          property("message", "string", "Task, question, or finding to send"),
        ],
        ["agent_id", "message"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let host = plugin.host(context)
      let plugin.Host(group_id:, agent_id: own_id, ..) = host
      let teammates = message_targets(host)
      case json.parse(arguments, message_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid team.message_agent arguments: " <> string.inspect(error),
            True,
          ))
        Ok(MessageArguments(target, message)) ->
          case target == own_id || !list.contains(teammates, target) {
            True ->
              Ok(tool_result(
                state,
                context,
                "Unknown teammate `" <> target <> "`",
                True,
              ))
            False ->
              case
                agent_group_registry.inject_tool_call(
                  group_id,
                  target,
                  receive_tool_name,
                  json.object([#("from", json.string(own_id))])
                    |> json.to_string,
                  message,
                )
              {
                Ok(Nil) ->
                  Ok(tool_result(
                    state,
                    context,
                    "Message delivered to `"
                      <> target
                      <> "`. Any reply will be delivered automatically; there is no need to poll or wait.",
                    False,
                  ))
                Error(error) ->
                  Ok(tool_result(
                    state,
                    context,
                    "Could not message teammate: " <> string.inspect(error),
                    True,
                  ))
              }
          }
      }
    },
  )
}

type ReadArguments {
  ReadArguments(path: String, offset: Int, limit: Int)
}

fn read_arguments_decoder() -> decode.Decoder(ReadArguments) {
  use path <- decode.field("path", decode.string)
  use offset <- decode.optional_field("offset", 0, decode.int)
  use limit <- decode.optional_field("limit", 400, decode.int)
  decode.success(ReadArguments(path, offset, limit))
}

type WriteArguments {
  WriteArguments(path: String, content: String)
}

fn write_arguments_decoder() -> decode.Decoder(WriteArguments) {
  use path <- decode.field("path", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(WriteArguments(path, content))
}

type ExecArguments {
  ExecArguments(command: String, timeout_seconds: Int)
}

fn exec_arguments_decoder() -> decode.Decoder(ExecArguments) {
  use command <- decode.field("command", decode.string)
  use timeout <- decode.optional_field("timeout_seconds", 30, decode.int)
  decode.success(ExecArguments(command, timeout))
}

type MessageArguments {
  MessageArguments(agent_id: String, message: String)
}

fn message_arguments_decoder() -> decode.Decoder(MessageArguments) {
  use agent_id <- decode.field("agent_id", decode.string)
  use message <- decode.field("message", decode.string)
  decode.success(MessageArguments(agent_id, message))
}

fn workspace_path(root: String, path: String) -> Result(String, String) {
  use root <- result.try(
    simplifile.resolve(root)
    |> result.map_error(fn(error) { simplifile.describe_error(error) }),
  )
  use candidate <- result.try(
    filepath.join(root, path)
    |> simplifile.resolve
    |> result.map_error(fn(error) { simplifile.describe_error(error) }),
  )
  case candidate == root || string.starts_with(candidate, root <> "/") {
    True -> Ok(candidate)
    False -> Error("path escapes the configured workspace")
  }
}

fn trim_output(output: String) -> String {
  case string.length(output) > 100_000 {
    True -> string.slice(output, 0, 100_000) <> "\n[output truncated]"
    False -> output
  }
}

fn tool_result(
  state: String,
  context: plugin.Context,
  output: String,
  is_error: Bool,
) -> plugin.HookResult(plugin.ToolOutput) {
  plugin.hook_result(
    state,
    context,
    plugin.ToolOutput([llm.Text(output)], is_error),
  )
}

fn property(
  name: String,
  kind: String,
  description: String,
) -> #(String, json.Json) {
  #(
    name,
    json.object([
      #("type", json.string(kind)),
      #("description", json.string(description)),
    ]),
  )
}

fn object_schema(
  properties: List(#(String, json.Json)),
  required: List(String),
) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
    #("additionalProperties", json.bool(False)),
  ])
}
