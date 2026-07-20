import exception
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import harness3/agent
import harness3/agent_group
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/cluster/agent_group_rpc
import harness3/cluster/core
import harness3/llm
import harness3/model_catalog
import harness3/plugin
import harness3/storage
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

fn temporary_root() -> String {
  let suffix =
    crypto.strong_random_bytes(10) |> bit_array.base64_url_encode(False)
  "/tmp/harness3-agent-group-rpc-test-" <> suffix
}

pub fn wake_rpc_is_idempotent_and_precedes_routed_compaction_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  use <- exception.defer(fn() {
    let _ = remove_directory(root)
    Nil
  })
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let started = process.new_subject()
  let transport =
    agent.model_transport(fn(_, _, _) {
      let blocked = process.new_subject()
      process.send(started, blocked)
      let assert Ok(Nil) = process.receive(blocked, within: 60_000)
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "profile",
      registry,
      transport,
      None,
      None,
      fn(_) { Ok(Nil) },
    )
  let state =
    agent.State(
      ..agent.state("agent", "model"),
      profile_id: "profile",
      messages: [llm.Message(llm.User, [llm.Text("historic task")])],
    )
  let config = agent_group.Config(backend, "groups/rpc", [profile], 10, 100)
  let assert Ok(_) =
    agent_group.create(config, agent_group.new("rpc-group", "catalog", [state]))

  let assert Ok(host) =
    core.config(backend, "127.0.0.1", 0)
    |> core.with_rpc_plugin(agent_group_rpc.plugin(backend, 10))
    |> core.start
  use <- exception.defer(fn() { core.stop(host) })
  let assert Ok(entry) =
    core.config(backend, "127.0.0.1", 0)
    |> core.with_rpc_plugin(agent_group_rpc.plugin(backend, 10))
    |> core.start
  use <- exception.defer(fn() { core.stop(entry) })
  let #(host_ip, host_port) = core.node(host)
  let #(entry_ip, entry_port) = core.node(entry)
  let assert Ok("ok") =
    core.call(
      host_ip,
      host_port,
      core.token(host),
      agent_group_rpc.method_name(),
      "groups/rpc",
      decode.string,
    )
  let assert Ok(_blocked) = process.receive(started, within: 2000)
  assert list.contains(agent_group_registry.alive_ids(), "rpc-group")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1

  // Waking an already-active group is idempotent: the leader observes its
  // live owner and returns without reclaiming or moving it.
  let assert Ok("ok") =
    core.call(
      entry_ip,
      entry_port,
      core.token(entry),
      agent_group_rpc.wake_method_name(),
      agent_group_rpc.wake_request("rpc-group", "groups/rpc"),
      decode.string,
    )
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1

  // The request enters through a different node and is forwarded to the
  // registry entry on the group owner without waking or moving the group.
  let assert Ok(1) =
    core.call(
      entry_ip,
      entry_port,
      core.token(entry),
      agent_group_rpc.compaction_method_name(),
      agent_group_rpc.compaction_request("rpc-group", "agent"),
      decode.int,
    )

  let assert Ok("ok") =
    core.call(
      host_ip,
      host_port,
      core.token(host),
      agent_group_rpc.force_stop_method_name(),
      "rpc-group",
      decode.string,
    )
  assert !list.contains(agent_group_registry.alive_ids(), "rpc-group")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.is_empty(index)

  // The same wake-first sequence revives an inactive group before the routed
  // compaction request. The original generation remains pending, so the
  // duplicate request returns it rather than creating another generation.
  let assert Ok("ok") =
    core.call(
      entry_ip,
      entry_port,
      core.token(entry),
      agent_group_rpc.wake_method_name(),
      agent_group_rpc.wake_request("rpc-group", "groups/rpc"),
      decode.string,
    )
  let assert Ok(_compaction_blocked) = process.receive(started, within: 2000)
  let assert Ok(1) =
    core.call(
      entry_ip,
      entry_port,
      core.token(entry),
      agent_group_rpc.compaction_method_name(),
      agent_group_rpc.compaction_request("rpc-group", "agent"),
      decode.int,
    )
  let assert Ok("ok") =
    core.call(
      entry_ip,
      entry_port,
      core.token(entry),
      agent_group_rpc.force_stop_method_name(),
      "rpc-group",
      decode.string,
    )
  let assert Ok(snapshot) = agent_group.load(config)
  let assert agent_group.Idle(released_epoch) = snapshot.execution
  assert released_epoch > 0
  let assert [preserved] = snapshot.agents
  assert preserved.round == 0
  assert preserved.status == agent.Ready
  assert preserved.compaction_requested == 1
  assert preserved.compaction_completed == 0
}
