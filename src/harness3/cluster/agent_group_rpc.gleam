import gleam/dynamic/decode
import gleam/result
import gleam/string
import harness3/agent_group
import harness3/agent_group_registry
import harness3/cluster/core
import harness3/storage.{type Storage}

/// RPC method installed on nodes that can execute recovered agent groups.
pub fn plugin(storage: Storage, lease_duration_seconds: Int) -> core.RpcPlugin {
  core.rpc_plugin([
    core.method(method_name(), decode.string, fn(group_key) {
      use loaded <- result.try(
        agent_group.resume_registered(
          storage,
          group_key,
          lease_duration_seconds,
        )
        |> result.map_error(fn(error) {
          core.HandlerError("resume_failed", string.inspect(error))
        }),
      )
      agent_group.wake(loaded)
      |> result.map(fn(_) { "ok" })
      |> result.map_error(fn(error) {
        core.HandlerError("wake_failed", string.inspect(error))
      })
    }),
    core.method(force_stop_method_name(), decode.string, fn(group_id) {
      agent_group_registry.force_stop(group_id)
      |> result.map(fn(_) { "ok" })
      |> result.map_error(fn(error) {
        core.HandlerError("force_stop_failed", string.inspect(error))
      })
    }),
  ])
}

pub fn force_stop_method_name() -> String {
  "force_stop_agent_group"
}

pub fn method_name() -> String {
  "resume_agent_group"
}
