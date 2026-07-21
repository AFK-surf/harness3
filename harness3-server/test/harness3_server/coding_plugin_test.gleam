import exception
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
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

fn workspace_host(root: String) -> plugin.Host {
  plugin.Host(
    group_id: "group",
    agent_id: "lead",
    agent_attributes: dict.new(),
    group_attributes: dict.from_list([
      #(coding_plugin.workspace_attribute, root),
    ]),
    peers: [],
  )
}

fn team_host(group_id: String) -> plugin.Host {
  plugin.Host(
    group_id:,
    agent_id: "lead",
    agent_attributes: dict.from_list([
      #(coding_plugin.role_attribute, "Lead"),
      #(coding_plugin.kind_attribute, "coding"),
    ]),
    group_attributes: dict.new(),
    peers: [#("researcher", dict.new())],
  )
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
  let coding = coding_plugin.workspace()
  let assert Ok(registry) = plugin.registry([coding])
  let assert Ok(runtime) =
    plugin.activate_hosted(
      registry,
      plugin.empty_states(),
      workspace_host(root),
    )

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

pub fn message_agent_injects_synthetic_tool_call_test() {
  let group_id =
    "group-"
    <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
  let delivered = process.new_subject()
  let fake_group = process.spawn_unlinked(fn() { process.sleep_forever() })
  agent_group_registry.register(
    group_id,
    fake_group,
    fn() { Ok(Nil) },
    // Inter-agent messaging must not arrive as user messages.
    fn(_, _) { Error("user messages are not used") },
    fn(agent_id, tool_name, arguments, response) {
      process.send(delivered, #(agent_id, tool_name, arguments, response))
      Ok(Nil)
    },
    fn(_) { Ok(0) },
    fn(_, _) { Ok(Nil) },
  )
  use <- exception.defer(fn() {
    agent_group_registry.unregister(group_id, fake_group)
    process.kill(fake_group)
  })
  let team = coding_plugin.collaboration()
  let assert Ok(registry) = plugin.registry([team])
  let assert Ok(runtime) =
    plugin.activate_hosted(registry, plugin.empty_states(), team_host(group_id))

  let assert Ok(#(runtime, sent)) =
    plugin.invoke_tool(
      runtime,
      "team.message_agent",
      invocation("message", [
        #("agent_id", json.string("researcher")),
        #("message", json.string("look at src/")),
      ]),
    )
  let plugin.ToolOutput(is_error: sent_error, ..) = sent
  assert !sent_error
  assert output_text(sent)
    == "Message delivered to `researcher`. Any reply will be delivered automatically; there is no need to poll or wait."
  let assert Ok(#(target, tool_name, arguments, response)) =
    process.receive(delivered, within: 1000)
  assert target == "researcher"
  assert tool_name == "team.receive_message"
  let assert Ok(from) =
    json.parse(arguments, {
      use from <- decode.field("from", decode.string)
      decode.success(from)
    })
  assert from == "lead"
  assert response == "look at src/"

  let assert Ok(#(_, rejected)) =
    plugin.invoke_tool(
      runtime,
      "team.message_agent",
      invocation("reject", [
        #("agent_id", json.string("ghost")),
        #("message", json.string("hello")),
      ]),
    )
  let plugin.ToolOutput(is_error: rejected_error, ..) = rejected
  assert rejected_error
  assert string.contains(output_text(rejected), "Unknown teammate")
}

pub fn message_agent_reports_inject_failure_test() {
  let group_id =
    "group-"
    <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
  let fake_group = process.spawn_unlinked(fn() { process.sleep_forever() })
  agent_group_registry.register(
    group_id,
    fake_group,
    fn() { Ok(Nil) },
    fn(_, _) { Error("unused") },
    fn(_, _, _, _) { Error("target agent is wedged") },
    fn(_) { Ok(0) },
    fn(_, _) { Ok(Nil) },
  )
  use <- exception.defer(fn() {
    agent_group_registry.unregister(group_id, fake_group)
    process.kill(fake_group)
  })
  let team = coding_plugin.collaboration()
  let assert Ok(registry) = plugin.registry([team])
  let assert Ok(runtime) =
    plugin.activate_hosted(registry, plugin.empty_states(), team_host(group_id))

  let assert Ok(#(_, failed)) =
    plugin.invoke_tool(
      runtime,
      "team.message_agent",
      invocation("inject-failure", [
        #("agent_id", json.string("researcher")),
        #("message", json.string("hello")),
      ]),
    )
  let plugin.ToolOutput(is_error: failed_error, ..) = failed
  assert failed_error
  assert string.contains(output_text(failed), "Could not message teammate")
  assert string.contains(output_text(failed), "target agent is wedged")

  // A group that is not registered locally at all fails the same way.
  let assert Ok(registry) = plugin.registry([coding_plugin.collaboration()])
  let assert Ok(runtime) =
    plugin.activate_hosted(
      registry,
      plugin.empty_states(),
      team_host("no-such-group"),
    )
  let assert Ok(#(_, not_found)) =
    plugin.invoke_tool(
      runtime,
      "team.message_agent",
      invocation("inject-not-found", [
        #("agent_id", json.string("researcher")),
        #("message", json.string("hello")),
      ]),
    )
  let plugin.ToolOutput(is_error: not_found_error, ..) = not_found
  assert not_found_error
  assert string.contains(output_text(not_found), "Could not message teammate")
}
