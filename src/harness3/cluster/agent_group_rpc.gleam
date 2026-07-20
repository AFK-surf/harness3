import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import harness3/agent_group
import harness3/agent_group_registry
import harness3/cluster/core
import harness3/storage.{type Storage}

const membership_alive_seconds = 30

type Endpoint {
  Endpoint(
    token: String,
    ip: String,
    port: Int,
    refreshed_at: Int,
    agent_groups: List(String),
  )
}

type LeaderRecord {
  LeaderRecord(owner: String, expires_at: Int)
}

/// RPC methods installed on every node capable of running agent groups.
pub fn plugin(storage: Storage, lease_duration_seconds: Int) -> core.RpcPlugin {
  core.rpc_plugin([
    core.contextual_method(method_name(), decode.string, fn(context, group_key) {
      use loaded <- result.try(load_group(
        storage,
        group_key,
        lease_duration_seconds,
      ))
      let group = agent_group.loaded_state(loaded)
      case list.contains(agent_group_registry.alive_ids(), group.id) {
        True -> {
          core.context_refresh_membership(context)
          Ok("ok")
        }
        False -> {
          use _ <- result.try(
            // Detached: this handler is a transient request process; waking
            // directly would link the group's process tree to it.
            agent_group.wake_detached(loaded, core.context_token(context), fn() {
              core.context_refresh_membership(context)
            })
            |> result.map_error(fn(error) {
              core.HandlerError("wake_failed", string.inspect(error))
            }),
          )
          Ok("ok")
        }
      }
    }),
    core.contextual_method(
      wake_method_name(),
      wake_decoder(),
      fn(context, request) {
        let #(group_id, group_key, visited) = request
        route_wake(storage, context, group_id, group_key, visited)
      },
    ),
    core.contextual_method(
      message_method_name(),
      message_decoder(),
      fn(context, request) {
        let #(group_id, agent_id, message, visited) = request
        route_message(storage, context, group_id, agent_id, message, visited)
      },
    ),
    core.contextual_method(
      compaction_method_name(),
      compaction_decoder(),
      fn(context, request) {
        let #(group_id, agent_id, visited) = request
        route_compaction(storage, context, group_id, agent_id, visited)
      },
    ),
    core.method(force_stop_method_name(), decode.string, fn(group_id) {
      agent_group_registry.force_stop(group_id)
      |> result.map(fn(_) { "ok" })
      |> result.map_error(fn(error) {
        core.HandlerError("force_stop_failed", string.inspect(error))
      })
    }),
  ])
}

pub fn wake_request(
  group_id: String,
  group_key: String,
) -> #(String, String, List(String)) {
  #(group_id, group_key, [])
}

pub fn message_request(
  group_id: String,
  agent_id: String,
  message: String,
) -> #(String, String, String, List(String)) {
  #(group_id, agent_id, message, [])
}

/// Builds an awake-only, host-routed per-agent compaction request.
pub fn compaction_request(
  group_id: String,
  agent_id: String,
) -> #(String, String, List(String)) {
  #(group_id, agent_id, [])
}

fn load_group(
  backend: Storage,
  group_key: String,
  lease_duration_seconds: Int,
) -> Result(agent_group.LoadedGroup, core.RpcError) {
  agent_group.resume_registered(backend, group_key, lease_duration_seconds)
  |> result.map_error(fn(error) {
    core.HandlerError("resume_failed", string.inspect(error))
  })
}

fn route_wake(
  backend: Storage,
  context: core.RpcContext,
  group_id: String,
  group_key: String,
  visited: List(String),
) -> Result(String, core.RpcError) {
  let current = core.context_token(context)
  use _ <- result.try(check_loop(current, visited))
  use nodes <- result.try(alive_memberships(backend))
  use leader <- result.try(recovery_leader(backend, nodes))
  case leader.token == current {
    False -> redirect_wake(leader, current, group_id, group_key, visited)
    True -> {
      let running = running_owner(backend, group_id)
      case running {
        Ok(owner) ->
          case
            list.any(nodes, fn(node) {
              node.token == owner && list.contains(node.agent_groups, group_id)
            })
          {
            True -> Ok("ok")
            False -> dispatch_wake(nodes |> list.shuffle, group_key)
          }
        Error(_) -> dispatch_wake(nodes |> list.shuffle, group_key)
      }
    }
  }
}

fn redirect_wake(
  leader: Endpoint,
  current: String,
  group_id: String,
  group_key: String,
  visited: List(String),
) -> Result(String, core.RpcError) {
  use _ <- result.try(check_redirect(leader.token, visited))
  core.call(
    leader.ip,
    leader.port,
    leader.token,
    wake_method_name(),
    #(group_id, group_key, [current, ..visited]),
    decode.string,
  )
  |> result.map_error(fn(error) {
    core.HandlerError("wake_redirect_failed", string.inspect(error))
  })
}

fn dispatch_wake(
  nodes: List(Endpoint),
  group_key: String,
) -> Result(String, core.RpcError) {
  case nodes {
    [] -> Error(core.HandlerError("no_nodes", "no alive agent nodes"))
    [node, ..rest] ->
      case
        core.call(
          node.ip,
          node.port,
          node.token,
          method_name(),
          group_key,
          decode.string,
        )
      {
        Ok(response) -> Ok(response)
        Error(_) -> dispatch_wake(rest, group_key)
      }
  }
}

fn route_message(
  backend: Storage,
  context: core.RpcContext,
  group_id: String,
  agent_id: String,
  message: String,
  visited: List(String),
) -> Result(String, core.RpcError) {
  let current = core.context_token(context)
  use _ <- result.try(check_loop(current, visited))
  case agent_group_registry.send_message(group_id, agent_id, message) {
    Ok(Nil) -> Ok("ok")
    Error(agent_group_registry.NotFound(_)) -> {
      use nodes <- result.try(alive_memberships(backend))
      use host <- result.try(group_host(backend, group_id, nodes))
      use _ <- result.try(case host.token == current {
        True ->
          Error(core.HandlerError(
            "not_running",
            "agent group is not running on its indexed node",
          ))
        False -> check_redirect(host.token, visited)
      })
      core.call(
        host.ip,
        host.port,
        host.token,
        message_method_name(),
        #(group_id, agent_id, message, [current, ..visited]),
        decode.string,
      )
      |> result.map_error(fn(error) {
        core.HandlerError("message_redirect_failed", string.inspect(error))
      })
    }
    Error(error) ->
      Error(core.HandlerError("message_failed", string.inspect(error)))
  }
}

fn route_compaction(
  backend: Storage,
  context: core.RpcContext,
  group_id: String,
  agent_id: String,
  visited: List(String),
) -> Result(Int, core.RpcError) {
  let current = core.context_token(context)
  use _ <- result.try(check_loop(current, visited))
  case agent_group_registry.request_compaction(group_id, agent_id) {
    Ok(generation) -> Ok(generation)
    Error(agent_group_registry.NotFound(_)) -> {
      use nodes <- result.try(alive_memberships(backend))
      use host <- result.try(
        group_host(backend, group_id, nodes)
        |> result.map_error(fn(error) {
          case error {
            core.HandlerError("not_running", _) ->
              core.HandlerError("not_awake", "agent group is not awake")
            error -> error
          }
        }),
      )
      use _ <- result.try(case host.token == current {
        True ->
          Error(core.HandlerError(
            "not_awake",
            "agent group is not awake on its indexed node",
          ))
        False -> check_redirect(host.token, visited)
      })
      core.call(
        host.ip,
        host.port,
        host.token,
        compaction_method_name(),
        #(group_id, agent_id, [current, ..visited]),
        decode.int,
      )
      |> result.map_error(fn(error) {
        core.HandlerError("compaction_redirect_failed", string.inspect(error))
      })
    }
    Error(error) ->
      Error(core.HandlerError("compaction_failed", string.inspect(error)))
  }
}

fn group_host(
  backend: Storage,
  group_id: String,
  nodes: List(Endpoint),
) -> Result(Endpoint, core.RpcError) {
  let indexed = case running_owner(backend, group_id) {
    Ok(owner) -> list.find(nodes, fn(node) { node.token == owner })
    Error(_) -> Error(Nil)
  }
  case indexed {
    Ok(node) -> Ok(node)
    Error(_) ->
      nodes
      |> list.find(fn(node) { list.contains(node.agent_groups, group_id) })
      |> result.map_error(fn(_) {
        core.HandlerError("not_running", "agent group is not running anywhere")
      })
  }
}

fn running_owner(
  backend: Storage,
  group_id: String,
) -> Result(String, core.RpcError) {
  use metadata <- result.try(
    storage.list(backend, agent_group.running_index_prefix())
    |> result.map_error(storage_rpc_error),
  )
  use entries <- result.try(
    list.try_fold(metadata, [], fn(entries, item) {
      case storage.get(backend, item.key) {
        Error(storage.NotFound(_)) -> Ok(entries)
        Error(error) -> Error(storage_rpc_error(error))
        Ok(object) ->
          case agent_group.decode_running_index(item.key, object.body) {
            Ok(entry) if entry.group_id == group_id -> Ok([entry, ..entries])
            _ -> Ok(entries)
          }
      }
    }),
  )
  entries
  |> list.sort(fn(a, b) { int.compare(b.epoch, a.epoch) })
  |> list.first
  |> result.map(fn(entry) { entry.owner })
  |> result.map_error(fn(_) {
    core.HandlerError("not_running", "agent group is not running anywhere")
  })
}

fn recovery_leader(
  backend: Storage,
  nodes: List(Endpoint),
) -> Result(Endpoint, core.RpcError) {
  use object <- result.try(
    storage.get(backend, "cluster/locks/recovery-leader")
    |> result.map_error(storage_rpc_error),
  )
  use body <- result.try(
    bit_array.to_string(object.body)
    |> result.map_error(fn(_) {
      core.HandlerError("no_recovery_leader", "recovery lock is invalid")
    }),
  )
  use record <- result.try(
    json.parse(body, {
      use owner <- decode.field("owner", decode.string)
      use expires_at <- decode.field("expires_at", decode.int)
      decode.success(LeaderRecord(owner, expires_at))
    })
    |> result.map_error(fn(_) {
      core.HandlerError("no_recovery_leader", "recovery lock is invalid")
    }),
  )
  use _ <- result.try(case record.expires_at > system_time(Second) {
    True -> Ok(Nil)
    False ->
      Error(core.HandlerError("no_recovery_leader", "recovery lease expired"))
  })
  nodes
  |> list.find(fn(node) { node.token == record.owner })
  |> result.map_error(fn(_) {
    core.HandlerError("no_recovery_leader", "recovery leader is not alive")
  })
}

fn alive_memberships(
  backend: Storage,
) -> Result(List(Endpoint), core.RpcError) {
  use metadata <- result.try(
    storage.list(backend, "cluster/membership/")
    |> result.map_error(storage_rpc_error),
  )
  use nodes <- result.try(
    list.try_fold(metadata, [], fn(nodes, item) {
      case storage.get(backend, item.key) {
        Error(storage.NotFound(_)) -> Ok(nodes)
        Error(error) -> Error(storage_rpc_error(error))
        Ok(object) ->
          case decode_membership(object.body) {
            Ok(node) -> Ok([node, ..nodes])
            Error(_) -> Ok(nodes)
          }
      }
    }),
  )
  let alive_after = system_time(Second) - membership_alive_seconds
  Ok(list.filter(nodes, fn(node) { node.refreshed_at >= alive_after }))
}

fn decode_membership(body: BitArray) -> Result(Endpoint, Nil) {
  use body <- result.try(bit_array.to_string(body))
  json.parse(body, {
    use token <- decode.field("token", decode.string)
    use ip <- decode.field("ip", decode.string)
    use port <- decode.field("port", decode.int)
    use refreshed_at <- decode.field("refreshed_at", decode.int)
    use agent_groups <- decode.field(
      "agent_groups",
      decode.list(of: decode.string),
    )
    decode.success(Endpoint(token, ip, port, refreshed_at, agent_groups))
  })
  |> result.map_error(fn(_) { Nil })
}

fn check_loop(
  current: String,
  visited: List(String),
) -> Result(Nil, core.RpcError) {
  case list.contains(visited, current) {
    True ->
      Error(core.HandlerError("routing_loop", "RPC routing loop detected"))
    False -> Ok(Nil)
  }
}

fn check_redirect(
  target: String,
  visited: List(String),
) -> Result(Nil, core.RpcError) {
  case list.contains(visited, target) {
    True ->
      Error(core.HandlerError("routing_loop", "RPC routing loop detected"))
    False -> Ok(Nil)
  }
}

fn storage_rpc_error(error: storage.Error) -> core.RpcError {
  core.HandlerError("storage_failed", string.inspect(error))
}

fn wake_decoder() -> decode.Decoder(#(String, String, List(String))) {
  decode.at([0], decode.string)
  |> decode.then(fn(group_id) {
    decode.at([1], decode.string)
    |> decode.then(fn(group_key) {
      decode.at([2], decode.list(of: decode.string))
      |> decode.map(fn(visited) { #(group_id, group_key, visited) })
    })
  })
}

fn message_decoder() -> decode.Decoder(#(String, String, String, List(String))) {
  decode.at([0], decode.string)
  |> decode.then(fn(group_id) {
    decode.at([1], decode.string)
    |> decode.then(fn(agent_id) {
      decode.at([2], decode.string)
      |> decode.then(fn(message) {
        decode.at([3], decode.list(of: decode.string))
        |> decode.map(fn(visited) { #(group_id, agent_id, message, visited) })
      })
    })
  })
}

fn compaction_decoder() -> decode.Decoder(#(String, String, List(String))) {
  decode.at([0], decode.string)
  |> decode.then(fn(group_id) {
    decode.at([1], decode.string)
    |> decode.then(fn(agent_id) {
      decode.at([2], decode.list(of: decode.string))
      |> decode.map(fn(visited) { #(group_id, agent_id, visited) })
    })
  })
}

pub fn force_stop_method_name() -> String {
  "force_stop_agent_group"
}

/// Internal RPC used by the recovery leader to place a group on a node.
pub fn method_name() -> String {
  "resume_agent_group"
}

pub fn wake_method_name() -> String {
  "wake_agent_group"
}

pub fn message_method_name() -> String {
  "message_agent_group"
}

/// RPC that records compaction on the current host or forwards to it. It never
/// wakes or resumes a dormant group.
pub fn compaction_method_name() -> String {
  "compact_agent_group"
}

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int
