import exception
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import harness3/agent_group_registry
import harness3/cluster/core
import harness3/storage
import harness3/storage/local

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

pub fn multiple_cluster_nodes_rpc_test() {
  let root = "/tmp/harness3-cluster-test-" <> int.to_string(unique_integer())
  let backend = local.new(local.config(root))
  use <- exception.defer(fn() {
    let _ = remove_directory(root)
    Nil
  })

  let echo_method =
    core.method("echo", decode.string, fn(message) { Ok("node-a:" <> message) })
  let assert Ok(node_a) =
    core.config(backend, "127.0.0.1", 0)
    |> core.with_rpc_plugin(core.rpc_plugin([echo_method]))
    |> core.start
  use <- exception.defer(fn() { core.stop(node_a) })

  let #(node_a_ip, node_a_port) = core.node(node_a)
  let forward =
    core.method("forward", decode.string, fn(message) {
      core.call(
        node_a_ip,
        node_a_port,
        core.token(node_a),
        "echo",
        message,
        decode.string,
      )
      |> result.map_error(fn(error) {
        core.HandlerError("forward_failed", string.inspect(error))
      })
    })
  let assert Ok(node_b) =
    core.config(backend, "127.0.0.1", 0)
    |> core.with_rpc_plugin(core.rpc_plugin([forward]))
    |> core.start
  use <- exception.defer(fn() {
    core.stop(node_b)
    process.sleep(50)
  })

  let assert Ok(members) = storage.list(backend, "cluster/membership/")
  assert list.length(members) == 2

  let #(node_b_ip, node_b_port) = core.node(node_b)
  let assert Ok(response) =
    core.call(
      node_b_ip,
      node_b_port,
      core.token(node_b),
      "forward",
      "hello",
      decode.string,
    )
  assert response == "node-a:hello"
}

pub fn membership_refresh_publishes_only_live_registered_agent_groups_test() {
  let root = "/tmp/harness3-membership-test-" <> int.to_string(unique_integer())
  let backend = local.new(local.config(root))
  use <- exception.defer(fn() {
    let _ = remove_directory(root)
    Nil
  })
  let live_id = "live-" <> int.to_string(unique_integer())
  let dead_id = "dead-" <> int.to_string(unique_integer())
  let live = process.spawn_unlinked(fn() { process.sleep_forever() })
  let dead = process.spawn_unlinked(fn() { Nil })
  process.sleep(10)
  agent_group_registry.register(live_id, live, fn() { Ok(Nil) }, fn(_, _) {
    Ok(Nil)
  })
  agent_group_registry.register(dead_id, dead, fn() { Ok(Nil) }, fn(_, _) {
    Ok(Nil)
  })
  use <- exception.defer(fn() {
    agent_group_registry.unregister(live_id, live)
    process.kill(live)
  })

  let assert Ok(node) = core.start(core.config(backend, "127.0.0.1", 0))
  use <- exception.defer(fn() { core.stop(node) })
  core.refresh(node)
  let assert Ok(object) = storage.get(backend, core.membership_key(node))
  let assert Ok(body) = bit_array.to_string(object.body)
  let assert Ok(agent_groups) =
    json.parse(body, {
      use agent_groups <- decode.field(
        "agent_groups",
        decode.list(of: decode.string),
      )
      decode.success(agent_groups)
    })
  assert list.contains(agent_groups, live_id)
  assert !list.contains(agent_groups, dead_id)
}
