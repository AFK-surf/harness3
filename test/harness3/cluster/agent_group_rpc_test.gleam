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

pub fn resume_and_force_stop_agent_group_rpc_test() {
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
    agent.State(..agent.state("agent", "model"), profile_id: "profile")
  let config = agent_group.Config(backend, "groups/rpc", [profile], 10)
  let assert Ok(_) =
    agent_group.create(config, agent_group.new("rpc-group", "catalog", [state]))

  let assert Ok(node) =
    core.config(backend, "127.0.0.1", 0)
    |> core.with_rpc_plugin(agent_group_rpc.plugin(backend, 10))
    |> core.start
  use <- exception.defer(fn() { core.stop(node) })
  let #(ip, port) = core.node(node)
  let assert Ok("ok") =
    core.call(
      ip,
      port,
      core.token(node),
      agent_group_rpc.method_name(),
      "groups/rpc",
      decode.string,
    )
  let assert Ok(_blocked) = process.receive(started, within: 2000)
  assert list.contains(agent_group_registry.alive_ids(), "rpc-group")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1

  let assert Ok("ok") =
    core.call(
      ip,
      port,
      core.token(node),
      agent_group_rpc.force_stop_method_name(),
      "rpc-group",
      decode.string,
    )
  assert !list.contains(agent_group_registry.alive_ids(), "rpc-group")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.is_empty(index)
  let assert Ok(snapshot) = agent_group.load(config)
  assert snapshot.execution == agent_group.Idle
  let assert [preserved] = snapshot.agents
  assert preserved.round == 0
  assert preserved.status == agent.Ready
}
