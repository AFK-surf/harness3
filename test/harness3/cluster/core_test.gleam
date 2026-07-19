import exception
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
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
    |> core.with_plugin(core.plugin([echo_method]))
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
    |> core.with_plugin(core.plugin([forward]))
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
