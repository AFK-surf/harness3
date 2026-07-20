import exception
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/string
import harness3/agent_group_registry
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
  let coding = coding_plugin.workspace(root)
  let assert Ok(registry) = plugin.registry([coding])
  let assert Ok(runtime) = plugin.activate(registry, plugin.empty_states())

  let assert Ok(#(runtime, plugin.ToolOutput(is_error: False, ..))) =
    plugin.invoke_tool(
      runtime,
      "coding.write",
      invocation("write", [
        #("path", json.string("nested/proof.txt")),
        #("content", json.string("hello\n")),
      ]),
    )
  let assert Ok(#(runtime, read_output)) =
    plugin.invoke_tool(
      runtime,
      "coding.read",
      invocation("read", [
        #("path", json.string("nested/proof.txt")),
      ]),
    )
  assert output_text(read_output) == "1 | hello\n2 | "

  let assert Ok(#(runtime, exec_output)) =
    plugin.invoke_tool(
      runtime,
      "coding.exec",
      invocation("exec", [
        #("command", json.string("cat nested/proof.txt")),
      ]),
    )
  assert output_text(exec_output) == "hello\n"

  let assert Ok(#(_, escaped)) =
    plugin.invoke_tool(
      runtime,
      "coding.write",
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

pub fn message_agent_says_replies_arrive_without_polling_test() {
  let group_id = temporary_root()
  let delivered = process.new_subject()
  let coordinator = process.spawn_unlinked(fn() { process.sleep_forever() })
  agent_group_registry.register(
    group_id,
    coordinator,
    fn() { Ok(Nil) },
    fn(agent_id, message) {
      process.send(delivered, #(agent_id, message))
      Ok(Nil)
    },
    fn(_) { Ok(1) },
  )
  use <- exception.defer(fn() {
    agent_group_registry.unregister(group_id, coordinator)
    process.kill(coordinator)
  })

  let team =
    coding_plugin.collaboration(
      group_id,
      "lead",
      "Lead",
      ["researcher"],
      "Workspace access.",
    )
  let assert Ok(registry) = plugin.registry([team])
  let assert Ok(runtime) = plugin.activate(registry, plugin.empty_states())
  let assert Ok(#(
    _,
    plugin.ToolOutput(content: [llm.Text(message)], is_error: False),
  )) =
    plugin.invoke_tool(
      runtime,
      "team.message_agent",
      invocation("message", [
        #("agent_id", json.string("researcher")),
        #("message", json.string("Investigate the failure")),
      ]),
    )
  assert message
    == "Message delivered to `researcher`. Any reply will be delivered automatically; there is no need to poll or wait."
  let assert Ok(#("researcher", "Investigate the failure")) =
    process.receive(delivered, within: 1000)
}
