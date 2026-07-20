import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/list
import harness3/agent_group_registry

fn unique_id(label: String) -> String {
  let suffix =
    crypto.strong_random_bytes(8) |> bit_array.base64_url_encode(False)
  label <> "-" <> suffix
}

pub fn live_entries_force_stop_and_dead_entries_are_swept_test() {
  let live_id = unique_id("registry-live")
  let dead_id = unique_id("registry-dead")
  let stopped = process.new_subject()
  let live = process.spawn_unlinked(fn() { process.sleep_forever() })
  agent_group_registry.register(
    live_id,
    live,
    fn() {
      process.send(stopped, Nil)
      process.kill(live)
      Ok(Nil)
    },
    fn(_, _) { Ok(Nil) },
    fn(_) { Ok(1) },
  )
  assert list.contains(agent_group_registry.alive_ids(), live_id)
  assert agent_group_registry.force_stop(live_id) == Ok(Nil)
  let assert Ok(Nil) = process.receive(stopped, within: 1000)

  let dead = process.spawn_unlinked(fn() { Nil })
  let monitor = process.monitor(dead)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(message) { message })
    |> process.selector_receive(1000)
  agent_group_registry.register(
    dead_id,
    dead,
    fn() { Ok(Nil) },
    fn(_, _) { Ok(Nil) },
    fn(_) { Ok(1) },
  )

  let alive = agent_group_registry.alive_ids()
  assert !list.contains(alive, live_id)
  assert !list.contains(alive, dead_id)
  assert agent_group_registry.force_stop(dead_id)
    == Error(agent_group_registry.NotFound(dead_id))
}
