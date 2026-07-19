import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/string
import harness3/llm
import harness3/plugin
import harness3_server/coding_plugin
import simplifile

fn temporary_root() -> String {
  "/tmp/harness3-coding-plugin-test-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn invocation(
  id: String,
  fields: List(#(String, json.Json)),
) -> plugin.ToolInvocation {
  plugin.ToolInvocation(id, json.object(fields) |> json.to_string)
}

fn output_text(output: plugin.ToolOutput) -> String {
  let plugin.ToolOutput(content:, ..) = output
  let assert [llm.Text(text)] = content
  text
}

pub fn coding_tools_write_read_exec_and_reject_escape_test() {
  let root = temporary_root()
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let coding = coding_plugin.new("group", "lead", "Lead", root, [])
  let assert Ok(registry) = plugin.registry([coding])
  let assert Ok(runtime) = plugin.activate(registry, plugin.empty_states())

  let assert Ok(#(runtime, plugin.ToolOutput(is_error: False, ..))) =
    plugin.invoke_tool(
      runtime,
      "Write",
      invocation("write", [
        #("path", json.string("nested/proof.txt")),
        #("content", json.string("hello\n")),
      ]),
    )
  let assert Ok(#(runtime, read_output)) =
    plugin.invoke_tool(
      runtime,
      "Read",
      invocation("read", [
        #("path", json.string("nested/proof.txt")),
      ]),
    )
  assert output_text(read_output) == "1 | hello\n2 | "

  let assert Ok(#(runtime, exec_output)) =
    plugin.invoke_tool(
      runtime,
      "Exec",
      invocation("exec", [
        #("command", json.string("cat nested/proof.txt")),
      ]),
    )
  assert output_text(exec_output) == "hello\n"

  let assert Ok(#(_, escaped)) =
    plugin.invoke_tool(
      runtime,
      "Write",
      invocation("escape", [
        #("path", json.string("../outside.txt")),
        #("content", json.string("no")),
      ]),
    )
  let plugin.ToolOutput(is_error:, ..) = escaped
  assert is_error
  assert string.contains(output_text(escaped), "path escapes")
  let assert Ok(Nil) = simplifile.delete(root)
}
