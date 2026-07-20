import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/agent_group
import harness3/cluster/distributed_lock
import harness3/storage.{type Storage}

const election_interval_ms = 10_000

const leader_lease_seconds = 30

const membership_alive_seconds = 30

pub type Error {
  StartFailed(reason: String)
}

pub opaque type Handle {
  Handle(subject: Subject(Message))
}

type State {
  State(
    storage: Storage,
    owner: String,
    dispatch: fn(String, Int, String, String) -> Result(Nil, String),
    lock: Option(distributed_lock.Lock),
    candidates: List(agent_group.RunningIndexEntry),
  )
}

type Message {
  Elect(subject: Subject(Message))
  Candidates(reply: Subject(List(agent_group.RunningIndexEntry)))
  Shutdown
}

type Membership {
  Membership(
    token: String,
    ip: String,
    port: Int,
    refreshed_at: Int,
    agent_groups: List(String),
  )
}

type Scan {
  Scan(candidates: List(agent_group.RunningIndexEntry), nodes: List(Membership))
}

pub fn start(
  storage: Storage,
  owner: String,
  dispatch: fn(String, Int, String, String) -> Result(Nil, String),
) -> Result(Handle, Error) {
  use started <- result.try(
    actor.new(State(storage, owner, dispatch, None, []))
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) { StartFailed(string.inspect(error)) }),
  )
  process.send(started.data, Elect(started.data))
  Ok(Handle(started.data))
}

pub fn candidates(handle: Handle) -> List(agent_group.RunningIndexEntry) {
  let Handle(subject) = handle
  process.call_forever(subject, Candidates)
}

pub fn stop(handle: Handle) -> Nil {
  let Handle(subject) = handle
  process.send(subject, Shutdown)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Elect(subject) -> {
      let state = elect_and_scan(state)
      let _ = process.send_after(subject, election_interval_ms, Elect(subject))
      actor.continue(state)
    }
    Candidates(reply) -> {
      process.send(reply, state.candidates)
      actor.continue(state)
    }
    Shutdown -> {
      case state.lock {
        Some(lock) -> {
          let _ = distributed_lock.release(lock)
          Nil
        }
        None -> Nil
      }
      actor.stop()
    }
  }
}

fn elect_and_scan(state: State) -> State {
  case state.lock {
    Some(lock) ->
      case distributed_lock.renew(lock) {
        Ok(renewed) -> scan_as_leader(state, renewed)
        // Only a confirmed replacement forfeits leadership. Dropping the lock
        // on a transient storage error would leave the cluster with no
        // recovery leader for a full lease even though nobody took over.
        Error(distributed_lock.Lost) ->
          State(..state, lock: None, candidates: [])
        // Keep the (possibly version-stale) lock but skip this cycle: the
        // lease was not extended, so scanning now could overlap a successor.
        // The next renew settles the version via read-back or comes back
        // `Lost`.
        Error(_) -> State(..state, lock: Some(lock), candidates: [])
      }
    None ->
      case
        distributed_lock.try_acquire(
          state.storage,
          "recovery-leader",
          state.owner,
          leader_lease_seconds,
        )
      {
        Ok(Some(lock)) -> scan_as_leader(state, lock)
        Ok(None) | Error(_) -> State(..state, lock: None, candidates: [])
      }
  }
}

fn scan_as_leader(state: State, lock: distributed_lock.Lock) -> State {
  case scan(state.storage) {
    Ok(Scan(candidates:, nodes:)) -> {
      dispatch_candidates(state.storage, state.dispatch, candidates, nodes)
      State(..state, lock: Some(lock), candidates:)
    }
    Error(_) -> State(..state, lock: Some(lock), candidates: [])
  }
}

/// Reads the running index first, then reads membership to avoid missing a
/// group that is moving from an old node to a newly advertising node.
///
/// Claim publication must pair with this ordering by registering locally and
/// completing an acknowledged membership refresh before writing its running
/// index entry. See `agent_group.start_coordinator`.
fn scan(backend: Storage) -> Result(Scan, storage.Error) {
  use running_metadata <- result.try(storage.list(
    backend,
    agent_group.running_index_prefix(),
  ))
  use running <- result.try(
    list.try_fold(running_metadata, [], fn(entries, metadata) {
      case storage.get(backend, metadata.key) {
        Error(storage.NotFound(_)) -> Ok(entries)
        Error(error) -> Error(error)
        Ok(object) ->
          case agent_group.decode_running_index(metadata.key, object.body) {
            Ok(entry) -> Ok([entry, ..entries])
            Error(_) -> Ok(entries)
          }
      }
    }),
  )

  // This membership list and all its objects are deliberately read only after
  // the running-index snapshot above has been collected.
  use membership_metadata <- result.try(storage.list(
    backend,
    "cluster/membership/",
  ))
  use memberships <- result.try(
    list.try_fold(membership_metadata, [], fn(memberships, metadata) {
      case storage.get(backend, metadata.key) {
        Error(storage.NotFound(_)) -> Ok(memberships)
        Error(error) -> Error(error)
        Ok(object) ->
          case decode_membership(object.body) {
            Ok(membership) -> Ok([membership, ..memberships])
            Error(_) -> Ok(memberships)
          }
      }
    }),
  )
  let alive_after = system_time(Second) - membership_alive_seconds
  let alive_nodes =
    memberships
    |> list.filter(fn(membership) { membership.refreshed_at >= alive_after })
    |> list.sort(fn(a, b) {
      string.compare(
        a.ip <> ":" <> int.to_string(a.port),
        b.ip <> ":" <> int.to_string(b.port),
      )
    })
  let claimed =
    alive_nodes
    |> list.flat_map(fn(membership) { membership.agent_groups })
  let candidates =
    running
    |> list.filter(fn(entry) { !list.contains(claimed, entry.group_id) })
    |> newest_claims
    |> list.sort(fn(a, b) { string.compare(a.group_id, b.group_id) })
  Ok(Scan(candidates, alive_nodes))
}

fn dispatch_candidates(
  backend: Storage,
  dispatch: fn(String, Int, String, String) -> Result(Nil, String),
  candidates: List(agent_group.RunningIndexEntry),
  nodes: List(Membership),
) -> Nil {
  case nodes {
    [] -> Nil
    _ ->
      dispatch_round_robin(backend, dispatch, candidates, list.shuffle(nodes))
  }
}

fn dispatch_round_robin(
  backend: Storage,
  dispatch: fn(String, Int, String, String) -> Result(Nil, String),
  candidates: List(agent_group.RunningIndexEntry),
  nodes: List(Membership),
) -> Nil {
  case candidates, nodes {
    [], _ | _, [] -> Nil
    [candidate, ..rest], [node, ..remaining_nodes] -> {
      // A group that stopped cleanly after this scan's index snapshot was
      // taken has already released its claim; dispatching from the stale
      // snapshot would resurrect it. Re-check the entry immediately before
      // dispatching, and skip conservatively when the check itself fails.
      //
      // Advisory, not airtight: shutdown releases the claim *before* deleting
      // the index (see `agent_group.finish` — the opposite order can leave a
      // claimed group with no entry, invisible here). So a group can be
      // released while its entry still exists. Waking it then is harmless:
      // it claims a fresh epoch, finds its agents terminal, and finishes,
      // after which `clean_stale_entries` reaps the old entry.
      case storage.get(backend, candidate.index_key) {
        Ok(_) -> {
          case dispatch_candidate(dispatch, candidate, nodes) {
            False -> Nil
            True -> clean_stale_entries(backend, candidate.group_id)
          }
          dispatch_round_robin(
            backend,
            dispatch,
            rest,
            list.append(remaining_nodes, [node]),
          )
        }
        Error(_) ->
          dispatch_round_robin(backend, dispatch, rest, [
            node,
            ..remaining_nodes
          ])
      }
    }
  }
}

/// Removes the dispatched group's superseded index entries. The entries are
/// re-listed after the dispatch, and only epochs strictly below the newest
/// are deleted: after a fresh wake the newest is the new claim's entry, and
/// after an "already running" response it is the live claim itself — which a
/// snapshot-based delete would erase, leaving a running group invisible to
/// recovery when its node later crashes. On any read failure nothing is
/// deleted; stale entries cost only a spurious wake later.
fn clean_stale_entries(backend: Storage, group_id: String) -> Nil {
  case group_entries(backend, group_id) {
    Error(_) -> Nil
    Ok(entries) -> {
      let newest =
        list.fold(entries, 0, fn(max, entry) { int.max(max, entry.epoch) })
      entries
      |> list.filter(fn(entry) { entry.epoch < newest })
      |> list.each(fn(entry) {
        let _ = storage.delete(backend, entry.index_key)
        Nil
      })
    }
  }
}

fn group_entries(
  backend: Storage,
  group_id: String,
) -> Result(List(agent_group.RunningIndexEntry), storage.Error) {
  use metadata <- result.try(storage.list(
    backend,
    agent_group.running_index_prefix(),
  ))
  list.try_fold(metadata, [], fn(entries, item) {
    case storage.get(backend, item.key) {
      Error(storage.NotFound(_)) -> Ok(entries)
      Error(error) -> Error(error)
      Ok(object) ->
        case agent_group.decode_running_index(item.key, object.body) {
          Ok(entry) if entry.group_id == group_id -> Ok([entry, ..entries])
          _ -> Ok(entries)
        }
    }
  })
}

fn dispatch_candidate(
  dispatch: fn(String, Int, String, String) -> Result(Nil, String),
  candidate: agent_group.RunningIndexEntry,
  nodes: List(Membership),
) -> Bool {
  case nodes {
    [] -> False
    [node, ..rest] ->
      case dispatch(node.ip, node.port, node.token, candidate.group_key) {
        Ok(_) -> True
        Error(_) -> dispatch_candidate(dispatch, candidate, rest)
      }
  }
}

fn newest_claims(
  entries: List(agent_group.RunningIndexEntry),
) -> List(agent_group.RunningIndexEntry) {
  let indexed: Dict(String, agent_group.RunningIndexEntry) =
    entries
    |> list.fold(dict.new(), fn(index, entry) {
      case dict.get(index, entry.group_id) {
        Ok(existing) ->
          case newer_or_equal(existing, entry) {
            True -> index
            False -> dict.insert(index, entry.group_id, entry)
          }
        Error(_) -> dict.insert(index, entry.group_id, entry)
      }
    })
  dict.values(indexed)
}

fn newer_or_equal(
  existing: agent_group.RunningIndexEntry,
  candidate: agent_group.RunningIndexEntry,
) -> Bool {
  existing.epoch >= candidate.epoch
}

fn decode_membership(body: BitArray) -> Result(Membership, Nil) {
  use body <- result.try(bit_array.to_string(body))
  json.parse(body, {
    use token <- decode.field("token", decode.string)
    use ip <- decode.field("ip", decode.string)
    use port <- decode.field("port", decode.int)
    use refreshed_at <- decode.field("refreshed_at", decode.int)
    use agent_groups <- decode.optional_field(
      "agent_groups",
      [],
      decode.list(of: decode.string),
    )
    decode.success(Membership(token, ip, port, refreshed_at, agent_groups))
  })
  |> result.map_error(fn(_) { Nil })
}

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int
