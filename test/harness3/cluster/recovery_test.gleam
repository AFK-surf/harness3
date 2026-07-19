import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json
import gleam/list
import harness3/agent_group
import harness3/cluster/recovery
import harness3/storage
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

fn temporary_root() -> String {
  let suffix =
    crypto.strong_random_bytes(10) |> bit_array.base64_url_encode(False)
  "/tmp/harness3-recovery-test-" <> suffix
}

fn index_body(epoch: Int, group_key: String) -> BitArray {
  json.object([
    #("schema_version", json.int(1)),
    #("group_id", json.string("recover-me")),
    #("group_key", json.string(group_key)),
    #("owner", json.string("dead-node")),
    #("epoch", json.int(epoch)),
    #("lease_expires_at", json.int(0)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn membership_body() -> BitArray {
  json.object([
    #("token", json.string("node-token")),
    #("ip", json.string("127.0.0.1")),
    #("port", json.int(4321)),
    #("refreshed_at", json.int(system_time(Second))),
    #("agent_groups", json.array([], json.string)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

pub fn recovery_leader_dispatches_newest_unclaimed_group_and_cleans_index_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let prefix = agent_group.running_index_prefix()
  let assert Ok(_) =
    storage.put(
      backend,
      prefix <> "recover-me/1_old",
      index_body(1, "groups/old"),
      storage.IfAbsent,
    )
  let assert Ok(_) =
    storage.put(
      backend,
      prefix <> "recover-me/2_new",
      index_body(2, "groups/new"),
      storage.IfAbsent,
    )
  let assert Ok(_) =
    storage.put(
      backend,
      "cluster/membership/node",
      membership_body(),
      storage.IfAbsent,
    )

  let dispatched = process.new_subject()
  let assert Ok(handle) =
    recovery.start(backend, "leader", fn(ip, port, token, group_key) {
      process.send(dispatched, #(ip, port, token, group_key))
      Ok(Nil)
    })
  let assert Ok(#("127.0.0.1", 4321, "node-token", "groups/new")) =
    process.receive(dispatched, within: 2000)
  let candidates = recovery.candidates(handle)
  let assert [candidate] = candidates
  assert candidate.group_id == "recover-me"
  assert candidate.epoch == 2
  let assert Ok(index) = storage.list(backend, prefix)
  assert list.is_empty(index)

  recovery.stop(handle)
  remove_directory(root)
}

pub fn recovery_does_not_dispatch_groups_claimed_by_alive_membership_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let prefix = agent_group.running_index_prefix()
  let assert Ok(_) =
    storage.put(
      backend,
      prefix <> "recover-me/1_old",
      index_body(1, "groups/current"),
      storage.IfAbsent,
    )
  let claimed_membership =
    json.object([
      #("token", json.string("node-token")),
      #("ip", json.string("127.0.0.1")),
      #("port", json.int(4321)),
      #("refreshed_at", json.int(system_time(Second))),
      #("agent_groups", json.array(["recover-me"], json.string)),
    ])
    |> json.to_string
    |> bit_array.from_string
  let assert Ok(_) =
    storage.put(
      backend,
      "cluster/membership/node",
      claimed_membership,
      storage.IfAbsent,
    )
  let dispatched = process.new_subject()
  let assert Ok(handle) =
    recovery.start(backend, "leader", fn(ip, port, token, group_key) {
      process.send(dispatched, #(ip, port, token, group_key))
      Ok(Nil)
    })
  process.sleep(100)
  assert recovery.candidates(handle) == []
  assert process.receive(dispatched, within: 25) == Error(Nil)
  let assert Ok(index) = storage.list(backend, prefix)
  assert list.length(index) == 1

  recovery.stop(handle)
  remove_directory(root)
}
