import filepath
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

pub fn new(
  group_id: String,
  agent_id: String,
  role: String,
  workspace: String,
  teammates: List(String),
) -> plugin.Plugin {
  plugin.new(plugin_name, "{}")
  |> plugin.with_system_prompt(plugin.SystemPromptSection(
    "Coding agent",
    system_prompt(agent_id, role, workspace, teammates),
  ))
  |> plugin.with_tool(read_tool(workspace))
  |> plugin.with_tool(write_tool(workspace))
  |> plugin.with_tool(exec_tool(workspace))
  |> plugin.with_tool(message_tool(group_id, agent_id, teammates))
}

fn system_prompt(
  agent_id: String,
  role: String,
  workspace: String,
  teammates: List(String),
) -> String {
  "You are agent `"
  <> agent_id
  <> "` in a persistent harness3 coding team. Your role is: "
  <> role
  <> ".\n\nThe shared workspace root is `"
  <> workspace
  <> "`. Use Read, Write, and Exec to inspect, change, and verify it. Paths are relative to the workspace. "
  <> "Your teammates are: "
  <> string.join(teammates, ", ")
  <> ". Use MessageAgent when another agent can help or needs your findings. "
  <> "Messages are durable and wake the target agent. Coordinate explicitly, avoid overlapping edits, and report concrete results."
}

fn read_tool(workspace: String) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "Read",
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
      case json.parse(arguments, read_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid Read arguments: " <> string.inspect(error),
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

fn write_tool(workspace: String) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "Write",
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
      case json.parse(arguments, write_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid Write arguments: " <> string.inspect(error),
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

fn exec_tool(workspace: String) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "Exec",
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
      case json.parse(arguments, exec_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid Exec arguments: " <> string.inspect(error),
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

fn message_tool(
  group_id: String,
  own_id: String,
  teammates: List(String),
) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "MessageAgent",
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
      case json.parse(arguments, message_arguments_decoder()) {
        Error(error) ->
          Ok(tool_result(
            state,
            context,
            "Invalid MessageAgent arguments: " <> string.inspect(error),
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
                agent_group_registry.send_message(group_id, target, message)
              {
                Ok(Nil) ->
                  Ok(tool_result(
                    state,
                    context,
                    "Message delivered to `" <> target <> "`",
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
