import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import harness3/agent
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/llm
import harness3/model_catalog
import harness3/storage.{type Metadata, type Storage, type VersionToken}

const default_minimum_lifetime_milliseconds = 10_000

pub type ExecutionState {
  Idle
  /// `nonce` is unique per claim attempt. Claim bodies must differ between
  /// two concurrent wakes even when they share an owner and a wall-clock
  /// second, otherwise the ambiguous-CAS read-back confirmation could accept
  /// a twin's claim as its own and run two coordinators for one group.
  Claimed(owner: String, epoch: Int, lease_expires_at: Int, nonce: String)
  Completed
}

pub type AgentGroup {
  AgentGroup(
    id: String,
    model_catalog_key: String,
    revision: Int,
    agents: List(agent.State),
    execution: ExecutionState,
  )
}

pub type RunningIndexEntry {
  RunningIndexEntry(
    index_key: String,
    group_id: String,
    group_key: String,
    owner: String,
    epoch: Int,
    lease_expires_at: Int,
  )
}

pub fn new(
  id: String,
  model_catalog_key: String,
  agents: List(agent.State),
) -> AgentGroup {
  AgentGroup(id, model_catalog_key, 0, agents, Idle)
}

pub type Config {
  Config(
    storage: Storage,
    object_key: String,
    profiles: List(agent_profile.AgentProfile),
    lease_duration_seconds: Int,
    minimum_lifetime_milliseconds: Int,
  )
}

pub type Error {
  InvalidGroup(reason: String)
  InvalidMessage(reason: String)
  MissingAgent(id: String)
  MissingProfile(id: String)
  DuplicateAgent(id: String)
  UnknownModel(agent_id: String, model_id: String)
  AlreadyClaimed(owner: String, lease_expires_at: Int)
  StaleAgentCommit(id: String, expected: Int, actual: Int)
  ConcurrentGroupUpdate
  LostGroupOwnership
  StorageFailed(error: storage.Error)
  DecodeFailed(reason: String)
  AgentActivationFailed(id: String, error: agent.Error)
  AgentCallbackUnavailable(id: String)
  AgentCallbackFailed(id: String, error: agent.Error)
  ProcessStartFailed(reason: String)
  ProfileUnavailable(reason: String)
  ModelCatalogFailed(error: model_catalog.Error)
}

pub type CommitReceipt {
  CommitReceipt(state: agent.State, group_revision: Int)
}

pub opaque type Group {
  Group(subject: Subject(Message))
}

pub opaque type LoadedGroup {
  LoadedGroup(config: Config, group: AgentGroup, version: VersionToken)
}

type CoordinatorState {
  CoordinatorState(
    storage: Storage,
    key: String,
    index_key: String,
    group: AgentGroup,
    metadata: Metadata,
    owner: String,
    lease_duration_seconds: Int,
    owned: Bool,
    children: List(#(String, agent.Handle)),
    helpers: List(Pid),
    profiles: List(agent_profile.AgentProfile),
    minimum_lifetime_milliseconds: Int,
    minimum_lifetime_elapsed: Bool,
  )
}

type Message {
  CommitAgent(
    id: String,
    expected_revision: Int,
    state: agent.State,
    reply: Subject(Result(CommitReceipt, Error)),
  )
  Snapshot(reply: Subject(Result(AgentGroup, Error)))
  AgentPids(reply: Subject(List(#(String, Pid))))
  RegisterChild(id: String, handle: agent.Handle, reply: Subject(Nil))
  AgentExited(id: String, pid: Pid, coordinator: Subject(Message))
  CallbackHelperExited(pid: Pid, coordinator: Subject(Message))
  StopIfEmpty(coordinator: Subject(Message))
  CallAgentCallback(
    source_id: String,
    target_id: String,
    plugin_name: String,
    callback: String,
    input: String,
    coordinator: Subject(Message),
    reply: Subject(Result(String, Error)),
  )
  PersistCallbackStates(
    target_id: String,
    plugin_states: Dict(String, String),
    plugin_generation: Int,
    reply: Subject(Result(Nil, Error)),
  )
  SendGroupMessage(
    agent_id: String,
    content: String,
    coordinator: Subject(Message),
    reply: Subject(Result(Nil, Error)),
  )
  RequestCompaction(
    agent_id: String,
    coordinator: Subject(Message),
    reply: Subject(Result(Int, Error)),
  )
  Renew(subject: Subject(Message))
  Stop(reply: Subject(Result(Nil, Error)))
}

type PreparedAgent {
  PreparedAgent(
    id: String,
    active: agent.Active,
    profile: agent_profile.AgentProfile,
  )
}

pub fn create(config: Config, group: AgentGroup) -> Result(LoadedGroup, Error) {
  use _ <- result.try(validate(config, group))
  agent_profile.install(config.profiles)
  let body = encode_group(group) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case
      storage.put(config.storage, config.object_key, body, storage.IfAbsent)
    {
      Ok(metadata) -> Ok(metadata)
      // An ambiguous IfAbsent success (applied, response lost, retry saw the
      // object) must not fail creation of a group that now durably exists.
      Error(storage.PreconditionFailed(_)) ->
        confirm_group_write(config.storage, config.object_key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(LoadedGroup(config, group, metadata.version))
}

pub fn resume(config: Config) -> Result(LoadedGroup, Error) {
  use object <- result.try(
    storage.get(config.storage, config.object_key)
    |> result.map_error(StorageFailed),
  )
  use group <- result.try(decode_group_body(object.body))
  use _ <- result.try(validate(config, group))
  agent_profile.install(config.profiles)
  Ok(LoadedGroup(config, group, object.metadata.version))
}

/// Loads a group using agent profiles installed on the current node.
pub fn resume_registered(
  storage: Storage,
  object_key: String,
  lease_duration_seconds: Int,
) -> Result(LoadedGroup, Error) {
  use object <- result.try(
    storage.get(storage, object_key)
    |> result.map_error(StorageFailed),
  )
  use group <- result.try(decode_group_body(object.body))
  let ready_ids =
    group.agents
    |> list.filter(fn(state) { state.status == agent.Ready })
    |> list.map(fn(state) { state.profile_id })
    |> list.unique
  use ready_profiles <- result.try(
    agent_profile.profiles(ready_ids)
    |> result.map_error(fn(error) { ProfileUnavailable(string.inspect(error)) }),
  )
  // Profiles for dormant agents are picked up when installed so that messages
  // can revive them, but a terminal agent whose profile is no longer
  // installed must not block resuming (and recovering) the whole group.
  // Messaging such an agent fails with MissingProfile only when attempted.
  let dormant_profiles =
    group.agents
    |> list.filter(fn(state) { state.status != agent.Ready })
    |> list.map(fn(state) { state.profile_id })
    |> list.unique
    |> list.filter(fn(id) { !list.contains(ready_ids, id) })
    |> list.filter_map(fn(id) {
      case agent_profile.profiles([id]) {
        Ok([profile]) -> Ok(profile)
        _ -> Error(Nil)
      }
    })
  let profiles = list.append(ready_profiles, dormant_profiles)
  let config =
    Config(
      storage,
      object_key,
      profiles,
      lease_duration_seconds,
      default_minimum_lifetime_milliseconds,
    )
  use _ <- result.try(validate(config, group))
  Ok(LoadedGroup(config, group, object.metadata.version))
}

pub fn loaded_state(loaded: LoadedGroup) -> AgentGroup {
  let LoadedGroup(group:, ..) = loaded
  group
}

/// Claims a loaded group and starts its coordinator and agent processes.
pub fn wake(loaded: LoadedGroup) -> Result(Group, Error) {
  wake_as(loaded, owner_token())
}

/// Claims and runs a group using a stable node owner token.
pub fn wake_as(loaded: LoadedGroup, owner: String) -> Result(Group, Error) {
  wake_as_with_membership_refresh(loaded, owner, fn() { Nil })
}

/// Like `wake_as_with_membership_refresh`, but runs the wake in a short-lived
/// process so the coordinator's fate is not tied to a transient caller.
///
/// `wake` links the started process tree to the waking process — deliberate
/// for embedders that supervise the group with their own lifetime. For an RPC
/// or web request handler that link is a hazard: an abnormal handler exit
/// (client disconnect, listener shutdown) would kill the whole group with no
/// cleanup, leaving the lease claimed until expiry. The spawned waker exits
/// normally after the group starts, which dissolves its links harmlessly.
pub fn wake_detached(
  loaded: LoadedGroup,
  owner: String,
  refresh_membership: fn() -> Nil,
) -> Result(Group, Error) {
  let reply = process.new_subject()
  let waker =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        wake_as_with_membership_refresh(loaded, owner, refresh_membership),
      )
    })
  let monitor = process.monitor(waker)
  let outcome =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(down) {
      Error(ProcessStartFailed(string.inspect(down)))
    })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
}

/// Claims and runs a group, synchronously publishing membership after local
/// registration and before creating the durable running index.
pub fn wake_as_with_membership_refresh(
  loaded: LoadedGroup,
  owner: String,
  refresh_membership: fn() -> Nil,
) -> Result(Group, Error) {
  let LoadedGroup(config:, group:, version:) = loaded
  use catalog_session <- result.try(
    model_catalog.resume(config.storage, group.model_catalog_key)
    |> result.map_error(ModelCatalogFailed),
  )
  let catalog = model_catalog.catalog(catalog_session)
  use _ <- result.try(validate_models(group, catalog))
  use _ <- result.try(ensure_claimable(group.execution))
  let claimed = claim(group, owner, config.lease_duration_seconds)
  let claimed_body =
    encode_group(claimed) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case
      storage.put(
        config.storage,
        config.object_key,
        claimed_body,
        storage.IfUnchanged(version),
      )
    {
      Ok(metadata) -> Ok(metadata)
      // The claim is the single most important CAS: an ambiguous success here
      // (write applied, response lost, retry observed 412) would leave the
      // group durably claimed by an owner that believes the wake failed — no
      // coordinator, no running-index entry, invisible to recovery until the
      // lease expires. Confirm by read-back exactly like write_group does.
      Error(storage.PreconditionFailed(_)) ->
        confirm_group_write(config.storage, config.object_key, claimed_body)
      Error(error) -> Error(storage_error(error))
    },
  )
  let index_key = running_index_key(claimed, owner)
  start_coordinator(
    config,
    claimed,
    metadata,
    owner,
    index_key,
    catalog,
    refresh_membership,
  )
}

/// Loads the durable group state without claiming it or starting processes.
pub fn load(config: Config) -> Result(AgentGroup, Error) {
  use object <- result.try(
    storage.get(config.storage, config.object_key)
    |> result.map_error(StorageFailed),
  )
  use group <- result.try(decode_group_body(object.body))
  use _ <- result.try(validate(config, group))
  Ok(group)
}

fn decode_group_body(body: BitArray) -> Result(AgentGroup, Error) {
  use body <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) { DecodeFailed("agent group is not UTF-8 JSON") }),
  )
  json.parse(body, group_decoder())
  |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) })
}

fn start_coordinator(
  config: Config,
  group: AgentGroup,
  metadata: Metadata,
  owner: String,
  index_key: String,
  catalog: model_catalog.Catalog,
  refresh_membership: fn() -> Nil,
) -> Result(Group, Error) {
  use prepared <- result.try(prepare_agents(config, group, catalog))
  let state =
    CoordinatorState(
      config.storage,
      config.object_key,
      index_key,
      group,
      metadata,
      owner,
      config.lease_duration_seconds,
      True,
      [],
      [],
      config.profiles,
      config.minimum_lifetime_milliseconds,
      False,
    )
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) {
      discard_prepared(prepared)
      ProcessStartFailed(string.inspect(error))
    }),
  )
  let handle = Group(started.data)
  agent_group_registry.register(
    group.id,
    started.pid,
    fn() { stop(handle) |> result.map_error(string.inspect) },
    fn(agent_id, message) {
      send_message(handle, agent_id, message)
      |> result.map_error(string.inspect)
    },
    fn(agent_id) {
      request_compaction(handle, agent_id)
      |> result.map_error(string.inspect)
    },
  )

  // RECOVERY ORDERING INVARIANT: recovery deliberately snapshots the running
  // index before it reads membership. A new claim must therefore become
  // visible in this exact order:
  //
  //   local registry -> attempted membership refresh -> running index
  //
  // Never move write_running_index above this refresh. Doing so creates a
  // window where recovery sees an indexed group but cannot see its live owner,
  // and may dispatch a second claimant. The refresh is synchronous but
  // best-effort: it returns even when its storage write fails, so this
  // ordering only minimizes spurious dispatches — the group lease is what
  // actually fences out a second claimant, and the periodic refresher closes
  // the membership gap within one interval.
  refresh_membership()
  case
    write_running_index(
      config.storage,
      index_key,
      config.object_key,
      group,
      owner,
    )
  {
    Error(error) -> {
      agent_group_registry.unregister(group.id, started.pid)
      // The index was not published, so remove the now-stale membership claim
      // promptly instead of waiting for the periodic registry sweep.
      refresh_membership()
      process.unlink(started.pid)
      process.kill(started.pid)
      discard_prepared(prepared)
      Error(StorageFailed(error))
    }
    Ok(_) -> start_agents(config, prepared, handle, started.data)
  }
}

fn start_agents(
  config: Config,
  prepared: List(PreparedAgent),
  handle: Group,
  subject: Subject(Message),
) -> Result(Group, Error) {
  schedule_renewal(subject, config.lease_duration_seconds)
  let children = list.map(prepared, fn(item) { launch_agent(handle, item) })
  list.each(children, agent.release)
  let _ =
    process.send_after(
      subject,
      config.minimum_lifetime_milliseconds,
      StopIfEmpty(subject),
    )
  Ok(handle)
}

fn prepare_agents(
  config: Config,
  group: AgentGroup,
  catalog: model_catalog.Catalog,
) -> Result(List(PreparedAgent), Error) {
  group.agents
  |> list.filter(fn(state) { state.status == agent.Ready })
  |> list.try_fold([], fn(prepared, state) {
    case prepare_agent(config, state, catalog) {
      Ok(item) -> Ok([item, ..prepared])
      Error(error) -> {
        // Plugin hosts already started for earlier agents must not outlive a
        // failed group start.
        discard_prepared(prepared)
        Error(error)
      }
    }
  })
  |> result.map(list.reverse)
}

fn discard_prepared(prepared: List(PreparedAgent)) -> Nil {
  list.each(prepared, fn(item) {
    let PreparedAgent(active:, ..) = item
    agent.discard(active)
  })
}

fn prepare_agent(
  config: Config,
  state: agent.State,
  catalog: model_catalog.Catalog,
) -> Result(PreparedAgent, Error) {
  use profile <- result.try(find_profile(config.profiles, state.profile_id))
  use model <- result.try(
    model_catalog.lookup(catalog, state.model_id)
    |> result.map_error(fn(_) { UnknownModel(state.id, state.model_id) }),
  )
  let agent_config =
    agent.Config(
      provider: model_catalog.provider(model),
      model_name: model.name,
      catalog_revision: model_catalog.revision(catalog),
      registry: profile.registry,
      transport: profile.transport,
      max_output_tokens: profile.max_output_tokens,
      reasoning_effort: profile.reasoning_effort,
      context_window_tokens: model.context_window_tokens,
    )
  use active <- result.try(
    agent.activate(state, agent_config)
    |> result.map_error(fn(error) { AgentActivationFailed(state.id, error) }),
  )
  Ok(PreparedAgent(state.id, active, profile))
}

fn launch_agent(group: Group, prepared: PreparedAgent) -> agent.Handle {
  let child = make_agent(group, prepared)
  let PreparedAgent(id:, ..) = prepared
  let Group(subject) = group
  process.call_forever(subject, fn(reply) { RegisterChild(id, child, reply) })
  child
}

fn make_agent(group: Group, prepared: PreparedAgent) -> agent.Handle {
  let PreparedAgent(id:, active:, profile:) = prepared
  let checkpoint =
    agent.checkpointer(fn(expected, state) {
      commit_agent(group, id, expected, state)
      |> result.map(fn(receipt) {
        let CommitReceipt(state:, group_revision:) = receipt
        agent.CommitReceipt(state, group_revision)
      })
      |> result.map_error(fn(error) {
        agent.CommitFailed(string.inspect(error))
      })
    })
  let router =
    agent.callback_router(fn(target, plugin_name, callback, input) {
      call_agent_callback(group, id, target, plugin_name, callback, input)
      |> result.map_error(fn(error) {
        agent.CommitFailed(string.inspect(error))
      })
    })
  let child =
    agent.start(active, checkpoint, router, profile.observe, fn() {
      let Group(subject) = group
      process.send(subject, AgentExited(id, process.self(), subject))
    })
  child
}

pub fn call_agent_callback(
  group: Group,
  source_id: String,
  target_id: String,
  plugin_name: String,
  callback: String,
  input: String,
) -> Result(String, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    CallAgentCallback(
      source_id,
      target_id,
      plugin_name,
      callback,
      input,
      subject,
      reply,
    )
  })
}

pub fn commit_agent(
  group: Group,
  id: String,
  expected_revision: Int,
  state: agent.State,
) -> Result(CommitReceipt, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    CommitAgent(id, expected_revision, state, reply)
  })
}

pub fn snapshot(group: Group) -> Result(AgentGroup, Error) {
  let Group(subject) = group
  process.call_forever(subject, Snapshot)
}

pub fn pid(group: Group) -> Pid {
  let Group(subject) = group
  let assert Ok(pid) = process.subject_owner(subject)
  pid
}

pub fn agent_pids(group: Group) -> List(#(String, Pid)) {
  let Group(subject) = group
  process.call_forever(subject, AgentPids)
}

pub fn stop(group: Group) -> Result(Nil, Error) {
  let Group(subject) = group
  process.call_forever(subject, Stop)
}

/// Durably queues a user message and starts a new parallel agent round when
/// the group has no agents currently executing.
pub fn send_message(
  group: Group,
  agent_id: String,
  content: String,
) -> Result(Nil, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    SendGroupMessage(agent_id, content, subject, reply)
  })
}

/// Durably requests context compaction for one agent in an awake group.
pub fn request_compaction(
  group: Group,
  agent_id: String,
) -> Result(Int, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    RequestCompaction(agent_id, subject, reply)
  })
}

fn handle_message(
  state: CoordinatorState,
  message: Message,
) -> actor.Next(CoordinatorState, Message) {
  case message {
    CommitAgent(id, expected, agent_state, reply) -> {
      let outcome = do_commit_agent(state, id, expected, agent_state)
      case outcome {
        Ok(#(state, receipt)) -> {
          process.send(reply, Ok(receipt))
          actor.continue(state)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          case error {
            ConcurrentGroupUpdate | LostGroupOwnership -> {
              abandon(state)
              actor.stop()
            }
            _ -> actor.continue(state)
          }
        }
      }
    }
    Snapshot(reply) -> {
      process.send(reply, case state.owned {
        True -> Ok(state.group)
        False -> Error(LostGroupOwnership)
      })
      actor.continue(state)
    }
    AgentPids(reply) -> {
      process.send(
        reply,
        list.map(state.children, fn(child) { #(child.0, agent.pid(child.1)) }),
      )
      actor.continue(state)
    }
    RegisterChild(id, handle, reply) -> {
      let assert True = process.link(agent.pid(handle))
      process.send(reply, Nil)
      actor.continue(
        CoordinatorState(..state, children: [#(id, handle), ..state.children]),
      )
    }
    AgentExited(id, pid, coordinator) -> {
      let children =
        list.filter(state.children, fn(child) {
          child.0 != id || agent.pid(child.1) != pid
        })
      let state = CoordinatorState(..state, children:)
      // This exit notice may be stale: a message delivery or compaction
      // request processed ahead of it can already have started a replacement
      // worker. Restarting again would run a duplicate worker and drop the
      // live replacement from `children`, orphaning it from stop/abandon
      // cleanup. The replacement's own commits consume the inbox and any
      // pending compaction, so a live replacement means nothing to do here.
      let replacement_running =
        state.children
        |> list.find(fn(child) { child.0 == id })
        |> result.map(fn(child) { process.is_alive(agent.pid(child.1)) })
        |> result.unwrap(False)
      case replacement_running {
        True -> settle_idle(state)
        False ->
          case find_agent(state.group.agents, id) {
            Ok(current) ->
              case current.pending_messages {
                [] ->
                  // A compaction request accepted while this worker was
                  // already exiting is durable but was never executed;
                  // nothing else would ever pick it up (wakes only start
                  // Ready agents). Restart a worker for it — unless the last
                  // attempt failed, in which case restarting would retry a
                  // failing compaction forever.
                  case
                    current.compaction_requested > current.compaction_completed
                    && current.last_compaction_error == None
                  {
                    False -> settle_idle(state)
                    True ->
                      case start_agent_worker(state, current, coordinator) {
                        Ok(next) -> actor.continue(next)
                        Error(_) -> {
                          abandon(state)
                          actor.stop()
                        }
                      }
                  }
                [_, ..] ->
                  case inject_and_start(state, current, [], coordinator) {
                    Ok(next) -> actor.continue(next)
                    Error(_) -> {
                      abandon(state)
                      actor.stop()
                    }
                  }
              }
            _ -> settle_idle(state)
          }
      }
    }
    CallbackHelperExited(pid, _coordinator) -> {
      let helpers = list.filter(state.helpers, fn(helper) { helper != pid })
      settle_idle(CoordinatorState(..state, helpers:))
    }
    StopIfEmpty(_coordinator) ->
      settle_idle(CoordinatorState(..state, minimum_lifetime_elapsed: True))
    CallAgentCallback(
      source,
      target_id,
      plugin_name,
      callback,
      input,
      coordinator,
      reply,
    ) -> {
      let target = find_child(state.children, target_id)
      let source_exists =
        list.any(state.children, fn(child) { child.0 == source })
      let next = case source == target_id, source_exists, target {
        True, _, _ -> {
          process.send(reply, Error(AgentCallbackUnavailable(target_id)))
          state
        }
        _, False, _ -> {
          process.send(reply, Error(AgentCallbackUnavailable(source)))
          state
        }
        _, _, Error(_) -> {
          process.send(reply, Error(AgentCallbackUnavailable(target_id)))
          state
        }
        False, True, Ok(handle) -> {
          let helper =
            process.spawn(fn() {
              let response = case
                agent.call_callback(handle, plugin_name, callback, input)
              {
                Error(error) -> Error(AgentCallbackFailed(target_id, error))
                Ok(callback_result) -> {
                  let agent.CallbackResult(
                    output:,
                    plugin_states:,
                    plugin_generation:,
                  ) = callback_result
                  process.call_forever(coordinator, fn(persist_reply) {
                    PersistCallbackStates(
                      target_id,
                      plugin_states,
                      plugin_generation,
                      persist_reply,
                    )
                  })
                  |> result.map(fn(_) { output })
                }
              }
              process.send(reply, response)
              process.send(
                coordinator,
                CallbackHelperExited(process.self(), coordinator),
              )
            })
          CoordinatorState(..state, helpers: [helper, ..state.helpers])
        }
      }
      actor.continue(next)
    }
    PersistCallbackStates(target_id, plugin_states, plugin_generation, reply) -> {
      case
        do_commit_callback_states(
          state,
          target_id,
          plugin_states,
          plugin_generation,
        )
      {
        Ok(state) -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          case error {
            ConcurrentGroupUpdate | LostGroupOwnership -> {
              abandon(state)
              actor.stop()
            }
            _ -> actor.continue(state)
          }
        }
      }
    }
    SendGroupMessage(agent_id, content, coordinator, reply) -> {
      case deliver_message(state, agent_id, content, coordinator) {
        Error(error) -> {
          process.send(reply, Error(error))
          case error {
            ConcurrentGroupUpdate | LostGroupOwnership -> {
              abandon(state)
              actor.stop()
            }
            _ -> actor.continue(state)
          }
        }
        Ok(next) -> {
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
      }
    }
    RequestCompaction(agent_id, coordinator, reply) -> {
      case request_agent_compaction(state, agent_id, coordinator) {
        Error(error) -> {
          process.send(reply, Error(error))
          case error {
            ConcurrentGroupUpdate | LostGroupOwnership -> {
              abandon(state)
              actor.stop()
            }
            _ -> actor.continue(state)
          }
        }
        Ok(#(next, generation)) -> {
          process.send(reply, Ok(generation))
          actor.continue(next)
        }
      }
    }
    Renew(subject) -> {
      case renew(state) {
        Ok(next) -> {
          case next.group.execution {
            Claimed(..) ->
              schedule_renewal(subject, next.lease_duration_seconds)
            _ -> Nil
          }
          actor.continue(next)
        }
        Error(_) -> {
          abandon(state)
          actor.stop()
        }
      }
    }
    Stop(reply) -> {
      list.each(state.children, fn(child) { agent.stop(child.1) })
      list.each(state.helpers, stop_helper)
      let finished = finish(state)
      process.send(reply, finished |> result.map(fn(_) { Nil }))
      agent_group_registry.unregister(state.group.id, process.self())
      actor.stop()
    }
  }
}

fn abandon(state: CoordinatorState) -> Nil {
  list.each(state.children, fn(child) { agent.stop(child.1) })
  list.each(state.helpers, stop_helper)
  agent_group_registry.unregister(state.group.id, process.self())
}

fn settle_idle(
  state: CoordinatorState,
) -> actor.Next(CoordinatorState, Message) {
  case state.children, state.helpers {
    [], [] if state.minimum_lifetime_elapsed -> {
      let _ = finish(state)
      agent_group_registry.unregister(state.group.id, process.self())
      actor.stop()
    }
    _, _ -> actor.continue(state)
  }
}

fn deliver_message(
  state: CoordinatorState,
  target_id: String,
  content: String,
  coordinator: Subject(Message),
) -> Result(CoordinatorState, Error) {
  use _ <- result.try(case string.trim(content) {
    "" -> Error(InvalidMessage("message cannot be empty"))
    _ -> Ok(Nil)
  })
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use current <- result.try(find_agent(state.group.agents, target_id))
  let incoming = llm.Message(llm.User, [llm.Text(content)])
  let running =
    state.children
    |> list.find(fn(child) { child.0 == target_id })
    |> result.map(fn(child) { process.is_alive(agent.pid(child.1)) })
    |> result.unwrap(False)
  case running {
    True -> queue_pending_message(state, current, incoming)
    False -> inject_and_start(state, current, [incoming], coordinator)
  }
}

/// Starts a worker for an agent's current durable state without persisting
/// any change — used to resume a durably recorded but never-executed
/// compaction request after its worker exited.
fn start_agent_worker(
  state: CoordinatorState,
  current: agent.State,
  coordinator: Subject(Message),
) -> Result(CoordinatorState, Error) {
  use catalog_session <- result.try(
    model_catalog.resume(state.storage, state.group.model_catalog_key)
    |> result.map_error(ModelCatalogFailed),
  )
  let catalog = model_catalog.catalog(catalog_session)
  use prepared <- result.try(prepare_agent(
    Config(
      state.storage,
      state.key,
      state.profiles,
      state.lease_duration_seconds,
      state.minimum_lifetime_milliseconds,
    ),
    current,
    catalog,
  ))
  let child = make_agent(Group(coordinator), prepared)
  let assert True = process.link(agent.pid(child))
  agent.release(child)
  let children = [
    #(current.id, child),
    ..list.filter(state.children, fn(child) { child.0 != current.id })
  ]
  Ok(CoordinatorState(..state, children:))
}

fn request_agent_compaction(
  state: CoordinatorState,
  agent_id: String,
  coordinator: Subject(Message),
) -> Result(#(CoordinatorState, Int), Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use current <- result.try(find_agent(state.group.agents, agent_id))
  use _ <- result.try(case current.messages {
    [] -> Error(InvalidMessage("agent session has no messages to compact"))
    _ -> Ok(Nil)
  })
  let pending =
    current.compaction_requested > current.compaction_completed
    && current.last_compaction_error == None
  let generation = case pending {
    True -> current.compaction_requested
    False ->
      int.max(current.compaction_requested, current.compaction_completed) + 1
  }
  // A new explicit request clears any recorded failure: the error is what
  // pauses retries of a failing compaction, and re-requesting is the caller's
  // way to try again.
  let replacement =
    agent.State(
      ..current,
      compaction_requested: generation,
      last_compaction_error: option.None,
    )
  let running =
    state.children
    |> list.find(fn(child) { child.0 == agent_id })
    |> result.map(fn(child) { process.is_alive(agent.pid(child.1)) })
    |> result.unwrap(False)
  case pending, running {
    True, True -> Ok(#(state, generation))
    _, True -> {
      use state <- result.try(persist_agents(
        state,
        replace_agent(state.group.agents, replacement),
      ))
      Ok(#(state, generation))
    }
    _, False -> {
      use catalog_session <- result.try(
        model_catalog.resume(state.storage, state.group.model_catalog_key)
        |> result.map_error(ModelCatalogFailed),
      )
      let catalog = model_catalog.catalog(catalog_session)
      use prepared <- result.try(prepare_agent(
        Config(
          state.storage,
          state.key,
          state.profiles,
          state.lease_duration_seconds,
          state.minimum_lifetime_milliseconds,
        ),
        replacement,
        catalog,
      ))
      use state <- result.try(
        persist_agents(state, replace_agent(state.group.agents, replacement))
        |> result.map_error(fn(error) {
          let PreparedAgent(active:, ..) = prepared
          agent.discard(active)
          error
        }),
      )
      let child = make_agent(Group(coordinator), prepared)
      let assert True = process.link(agent.pid(child))
      agent.release(child)
      let children = [
        #(agent_id, child),
        ..list.filter(state.children, fn(child) { child.0 != agent_id })
      ]
      Ok(#(CoordinatorState(..state, children:), generation))
    }
  }
}

fn queue_pending_message(
  state: CoordinatorState,
  current: agent.State,
  incoming: llm.Message,
) -> Result(CoordinatorState, Error) {
  // The active worker still commits against this same agent revision. Persist
  // the inbox without advancing that revision; its next commit atomically
  // consumes the pending messages into the conversation.
  let replacement =
    agent.State(
      ..current,
      pending_messages: list.append(current.pending_messages, [incoming]),
    )
  persist_agents(state, replace_agent(state.group.agents, replacement))
}

fn inject_and_start(
  state: CoordinatorState,
  current: agent.State,
  incoming: List(llm.Message),
  coordinator: Subject(Message),
) -> Result(CoordinatorState, Error) {
  // No worker owns this state, so move both the durable inbox and the new
  // message into `messages` in one CAS write. A message is never persisted in
  // both collections, nor absent from both collections, across this handoff.
  let next_agent =
    agent.State(
      ..current,
      revision: current.revision + 1,
      messages: list.append(
        current.messages,
        list.append(current.pending_messages, incoming),
      ),
      context_messages: append_context(
        current.context_messages,
        list.append(current.pending_messages, incoming),
      ),
      pending_messages: [],
      status: agent.Ready,
    )
  use catalog_session <- result.try(
    model_catalog.resume(state.storage, state.group.model_catalog_key)
    |> result.map_error(ModelCatalogFailed),
  )
  let catalog = model_catalog.catalog(catalog_session)
  let single = AgentGroup(..state.group, agents: [next_agent])
  use _ <- result.try(validate_models(single, catalog))
  let config =
    Config(
      state.storage,
      state.key,
      state.profiles,
      state.lease_duration_seconds,
      state.minimum_lifetime_milliseconds,
    )
  use prepared <- result.try(prepare_agents(config, single, catalog))
  let assert [prepared] = prepared
  use state <- result.try(
    persist_agents(state, replace_agent(state.group.agents, next_agent))
    |> result.map_error(fn(error) {
      let PreparedAgent(active:, ..) = prepared
      agent.discard(active)
      error
    }),
  )
  let child = make_agent(Group(coordinator), prepared)
  let assert True = process.link(agent.pid(child))
  agent.release(child)
  let children = [
    #(next_agent.id, child),
    ..list.filter(state.children, fn(child) { child.0 != next_agent.id })
  ]
  Ok(CoordinatorState(..state, children:))
}

fn persist_agents(
  state: CoordinatorState,
  agents: List(agent.State),
) -> Result(CoordinatorState, Error) {
  let group =
    AgentGroup(
      ..state.group,
      revision: state.group.revision + 1,
      agents:,
      execution: extend_claim(state),
    )
  use metadata <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, metadata:))
}

fn replace_agent(
  agents: List(agent.State),
  replacement: agent.State,
) -> List(agent.State) {
  list.map(agents, fn(item) {
    case item.id == replacement.id {
      True -> replacement
      False -> item
    }
  })
}

fn append_context(
  context: Option(List(llm.Message)),
  messages: List(llm.Message),
) -> Option(List(llm.Message)) {
  case context {
    None -> None
    Some(context) -> Some(list.append(context, messages))
  }
}

fn extend_claim(state: CoordinatorState) -> ExecutionState {
  Claimed(
    state.owner,
    execution_epoch(state.group.execution),
    system_time(Second) + state.lease_duration_seconds,
    execution_nonce(state.group.execution),
  )
}

fn stop_helper(pid: Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

fn find_child(
  children: List(#(String, agent.Handle)),
  id: String,
) -> Result(agent.Handle, Nil) {
  children
  |> list.find(fn(child) { child.0 == id })
  |> result.map(fn(child) { child.1 })
}

fn do_commit_agent(
  state: CoordinatorState,
  id: String,
  expected: Int,
  new_agent: agent.State,
) -> Result(#(CoordinatorState, CommitReceipt), Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use current <- result.try(find_agent(state.group.agents, id))
  use _ <- result.try(case current.revision == expected {
    True -> Ok(Nil)
    False -> Error(StaleAgentCommit(id, expected, current.revision))
  })
  use _ <- result.try(case new_agent.id == id {
    True -> Ok(Nil)
    False -> Error(InvalidGroup("commit agent id does not match state id"))
  })
  let agent_revision = current.revision + 1
  let new_agent = case new_agent.plugin_generation < current.plugin_generation {
    True ->
      agent.State(
        ..new_agent,
        plugin_states: current.plugin_states,
        plugin_generation: current.plugin_generation,
      )
    False -> new_agent
  }
  let has_pending = !list.is_empty(current.pending_messages)
  // This group CAS is the active-worker handoff: the new model output and all
  // messages that arrived during its LLM call are committed together, while
  // the inbox is cleared. The returned authoritative state makes the worker
  // continue immediately when anything was injected.
  let new_agent =
    agent.State(
      ..new_agent,
      revision: agent_revision,
      messages: list.append(new_agent.messages, current.pending_messages),
      context_messages: append_context(
        new_agent.context_messages,
        current.pending_messages,
      ),
      pending_messages: [],
      compaction_requested: int.max(
        new_agent.compaction_requested,
        current.compaction_requested,
      ),
      compaction_completed: int.max(
        new_agent.compaction_completed,
        current.compaction_completed,
      ),
      // A re-request accepted while this worker was mid-round durably bumped
      // `compaction_requested` and cleared the failure record. The worker's
      // stale in-memory error must not resurrect here, or the acknowledged
      // request stays paused forever (both the round-loop trigger and the
      // exit-restart path require a clear error).
      last_compaction_error: case
        current.compaction_requested > new_agent.compaction_requested
      {
        True -> current.last_compaction_error
        False -> new_agent.last_compaction_error
      },
      status: case has_pending {
        True -> agent.Ready
        False -> new_agent.status
      },
    )
  let agents =
    list.map(state.group.agents, fn(item) {
      case item.id == id {
        True -> new_agent
        False -> item
      }
    })
  let group_revision = state.group.revision + 1
  let execution =
    Claimed(
      state.owner,
      execution_epoch(state.group.execution),
      system_time(Second) + state.lease_duration_seconds,
      execution_nonce(state.group.execution),
    )
  let group =
    AgentGroup(..state.group, revision: group_revision, agents:, execution:)
  use metadata <- result.try(write_group(state, group))
  Ok(#(
    CoordinatorState(..state, group:, metadata:),
    CommitReceipt(new_agent, group_revision),
  ))
}

fn do_commit_callback_states(
  state: CoordinatorState,
  target_id: String,
  plugin_states: Dict(String, String),
  plugin_generation: Int,
) -> Result(CoordinatorState, Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use current <- result.try(find_agent(state.group.agents, target_id))
  case current.plugin_generation >= plugin_generation {
    True -> Ok(state)
    False ->
      write_callback_states(state, target_id, plugin_states, plugin_generation)
  }
}

fn write_callback_states(
  state: CoordinatorState,
  target_id: String,
  plugin_states: Dict(String, String),
  plugin_generation: Int,
) -> Result(CoordinatorState, Error) {
  let agents =
    list.map(state.group.agents, fn(item) {
      case item.id == target_id {
        True ->
          agent.State(
            ..item,
            plugin_states: plugin_states,
            plugin_generation: plugin_generation,
          )
        False -> item
      }
    })
  let execution = case state.group.execution {
    Claimed(_, epoch, _, nonce) ->
      Claimed(
        state.owner,
        epoch,
        system_time(Second) + state.lease_duration_seconds,
        nonce,
      )
    execution -> execution
  }
  let group =
    AgentGroup(
      ..state.group,
      revision: state.group.revision + 1,
      agents:,
      execution:,
    )
  use metadata <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, metadata:))
}

fn renew(state: CoordinatorState) -> Result(CoordinatorState, Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  case state.group.execution {
    Completed -> Ok(state)
    Claimed(owner, epoch, expires_at, nonce) ->
      case owner == state.owner && expires_at > system_time(Second) {
        False -> Error(LostGroupOwnership)
        True -> {
          let group =
            AgentGroup(
              ..state.group,
              revision: state.group.revision + 1,
              execution: Claimed(
                state.owner,
                epoch,
                system_time(Second) + state.lease_duration_seconds,
                nonce,
              ),
            )
          use metadata <- result.try(write_group(state, group))
          Ok(CoordinatorState(..state, group:, metadata:))
        }
      }
    _ -> Error(LostGroupOwnership)
  }
}

fn release(state: CoordinatorState) -> Result(CoordinatorState, Error) {
  let execution = case list.all(state.group.agents, agent_is_terminal) {
    True -> Completed
    False -> Idle
  }
  let group =
    AgentGroup(..state.group, revision: state.group.revision + 1, execution:)
  use metadata <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, metadata:, owned: False))
}

fn finish(state: CoordinatorState) -> Result(CoordinatorState, Error) {
  use _ <- result.try(
    storage.delete(state.storage, state.index_key)
    |> result.try_recover(fn(error) {
      case error {
        storage.NotFound(_) -> Ok(Nil)
        error -> Error(error)
      }
    })
    |> result.map_error(StorageFailed),
  )
  release(state)
}

/// Prefix containing durable records of running or crashed group claims.
pub fn running_index_prefix() -> String {
  "cluster/agent-groups/"
}

pub fn decode_running_index(
  index_key: String,
  body: BitArray,
) -> Result(RunningIndexEntry, Error) {
  use body <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) { DecodeFailed("running index is not UTF-8") }),
  )
  json.parse(body, {
    use group_id <- decode.field("group_id", decode.string)
    use group_key <- decode.field("group_key", decode.string)
    use owner <- decode.field("owner", decode.string)
    use epoch <- decode.field("epoch", decode.int)
    use lease_expires_at <- decode.field("lease_expires_at", decode.int)
    decode.success(RunningIndexEntry(
      index_key,
      group_id,
      group_key,
      owner,
      epoch,
      lease_expires_at,
    ))
  })
  |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) })
}

fn running_index_key(group: AgentGroup, owner: String) -> String {
  running_index_prefix()
  <> uri.percent_encode(group.id)
  <> "/"
  <> int.to_string(execution_epoch(group.execution))
  <> "_"
  <> owner
}

fn write_running_index(
  backend: Storage,
  index_key: String,
  group_key: String,
  group: AgentGroup,
  owner: String,
) -> Result(storage.Metadata, storage.Error) {
  let #(epoch, lease_expires_at) = case group.execution {
    Claimed(_, epoch, lease_expires_at, _) -> #(epoch, lease_expires_at)
    _ -> #(0, 0)
  }
  let body =
    json.object([
      #("schema_version", json.int(1)),
      #("group_id", json.string(group.id)),
      #("group_key", json.string(group_key)),
      #("owner", json.string(owner)),
      #("epoch", json.int(epoch)),
      #("lease_expires_at", json.int(lease_expires_at)),
    ])
    |> json.to_string
    |> bit_array.from_string
  case storage.put(backend, index_key, body, storage.IfAbsent) {
    Ok(metadata) -> Ok(metadata)
    Error(storage.PreconditionFailed(_)) ->
      // Conditional HTTP writes can succeed remotely and lose their response;
      // a retry then observes the object created by the first attempt. Accept
      // only an exact read-back match as our own ambiguous success.
      case storage.get(backend, index_key) {
        Ok(object) if object.body == body -> Ok(object.metadata)
        Ok(_) | Error(storage.NotFound(_)) ->
          Error(storage.PreconditionFailed(index_key))
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

fn agent_is_terminal(state: agent.State) -> Bool {
  case state.status {
    agent.Completed | agent.Failed(_) -> True
    _ -> False
  }
}

fn write_group(
  state: CoordinatorState,
  group: AgentGroup,
) -> Result(Metadata, Error) {
  let body = encode_group(group) |> json.to_string |> bit_array.from_string
  case
    storage.put(
      state.storage,
      state.key,
      body,
      storage.IfUnchanged(state.metadata.version),
    )
  {
    Ok(metadata) -> Ok(metadata)
    Error(storage.PreconditionFailed(_)) ->
      confirm_group_write(state.storage, state.key, body)
    Error(error) -> Error(storage_error(error))
  }
}

fn confirm_group_write(
  backend: Storage,
  key: String,
  intended_body: BitArray,
) -> Result(Metadata, Error) {
  case storage.get(backend, key) {
    Ok(object) if object.body == intended_body -> Ok(object.metadata)
    Ok(_) | Error(storage.PreconditionFailed(_)) -> Error(ConcurrentGroupUpdate)
    Error(error) -> Error(StorageFailed(error))
  }
}

fn storage_error(error: storage.Error) -> Error {
  case error {
    storage.PreconditionFailed(_) -> ConcurrentGroupUpdate
    error -> StorageFailed(error)
  }
}

fn validate(config: Config, group: AgentGroup) -> Result(Nil, Error) {
  use _ <- result.try(case config.lease_duration_seconds > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidGroup("lease duration must be positive"))
  })
  use _ <- result.try(case config.minimum_lifetime_milliseconds >= 0 {
    True -> Ok(Nil)
    False ->
      Error(InvalidGroup("minimum lifetime milliseconds cannot be negative"))
  })
  use _ <- result.try(
    case
      string.trim(group.id),
      string.trim(group.model_catalog_key),
      group.agents
    {
      "", _, _ -> Error(InvalidGroup("group id cannot be empty"))
      _, "", _ -> Error(InvalidGroup("model catalog key cannot be empty"))
      _, _, [] ->
        Error(InvalidGroup("agent group must contain at least one agent"))
      _, _, _ -> Ok(Nil)
    },
  )
  use _ <- result.try(
    config.profiles
    |> list.try_fold([], fn(ids, profile) {
      case list.contains(ids, profile.id) {
        True -> Error(InvalidGroup("duplicate agent profile: " <> profile.id))
        False -> Ok([profile.id, ..ids])
      }
    })
    |> result.map(fn(_) { Nil }),
  )
  use _ <- result.try(
    group.agents
    |> list.try_fold([], fn(ids, state) {
      case list.contains(ids, state.id) {
        True -> Error(DuplicateAgent(state.id))
        False -> Ok([state.id, ..ids])
      }
    })
    |> result.map(fn(_) { Nil }),
  )
  group.agents
  |> list.filter(fn(state) { state.status == agent.Ready })
  |> list.try_each(fn(state) {
    find_profile(config.profiles, state.profile_id)
    |> result.map(fn(_) { Nil })
  })
}

fn validate_models(
  group: AgentGroup,
  catalog: model_catalog.Catalog,
) -> Result(Nil, Error) {
  group.agents
  |> list.filter(fn(state) { state.status == agent.Ready })
  |> list.try_each(fn(state) {
    model_catalog.lookup(catalog, state.model_id)
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(_) { UnknownModel(state.id, state.model_id) })
  })
}

fn find_profile(
  profiles: List(agent_profile.AgentProfile),
  id: String,
) -> Result(agent_profile.AgentProfile, Error) {
  list.find(profiles, fn(profile) { profile.id == id })
  |> result.map_error(fn(_) { MissingProfile(id) })
}

fn find_agent(
  agents: List(agent.State),
  id: String,
) -> Result(agent.State, Error) {
  list.find(agents, fn(state) { state.id == id })
  |> result.map_error(fn(_) { MissingAgent(id) })
}

fn ensure_claimable(execution: ExecutionState) -> Result(Nil, Error) {
  case execution {
    Claimed(owner, _, expires, _) ->
      case expires > system_time(Second) {
        True -> Error(AlreadyClaimed(owner, expires))
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  }
}

fn claim(
  group: AgentGroup,
  owner: String,
  lease_duration_seconds: Int,
) -> AgentGroup {
  AgentGroup(
    ..group,
    revision: group.revision + 1,
    agents: list.map(group.agents, inject_pending),
    execution: Claimed(
      owner,
      execution_epoch(group.execution) + 1,
      system_time(Second) + lease_duration_seconds,
      claim_nonce(),
    ),
  )
}

fn inject_pending(state: agent.State) -> agent.State {
  case state.pending_messages {
    [] -> state
    pending ->
      agent.State(
        ..state,
        revision: state.revision + 1,
        messages: list.append(state.messages, pending),
        context_messages: append_context(state.context_messages, pending),
        pending_messages: [],
        status: agent.Ready,
      )
  }
}

fn execution_epoch(execution: ExecutionState) -> Int {
  case execution {
    Claimed(_, epoch, _, _) -> epoch
    _ -> 0
  }
}

fn execution_nonce(execution: ExecutionState) -> String {
  case execution {
    Claimed(_, _, _, nonce) -> nonce
    _ -> ""
  }
}

fn claim_nonce() -> String {
  crypto.strong_random_bytes(18) |> bit_array.base64_url_encode(False)
}

fn schedule_renewal(subject: Subject(Message), lease_seconds: Int) -> Nil {
  let delay = int.max(1, lease_seconds / 2) * 1000
  process.send_after(subject, delay, Renew(subject))
  Nil
}

fn owner_token() -> String {
  crypto.strong_random_bytes(24) |> bit_array.base64_url_encode(False)
}

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

fn encode_group(group: AgentGroup) -> json.Json {
  json.object([
    #("schema_version", json.int(1)),
    #("id", json.string(group.id)),
    #("model_catalog_key", json.string(group.model_catalog_key)),
    #("revision", json.int(group.revision)),
    #("agents", json.array(group.agents, agent.encode_state)),
    #("execution", encode_execution(group.execution)),
  ])
}

fn encode_execution(execution: ExecutionState) -> json.Json {
  case execution {
    Idle -> json.object([#("type", json.string("idle"))])
    Completed -> json.object([#("type", json.string("completed"))])
    Claimed(owner, epoch, expires, nonce) ->
      json.object([
        #("type", json.string("claimed")),
        #("owner", json.string(owner)),
        #("epoch", json.int(epoch)),
        #("lease_expires_at", json.int(expires)),
        #("nonce", json.string(nonce)),
      ])
  }
}

fn group_decoder() -> decode.Decoder(AgentGroup) {
  use schema <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use model_catalog_key <- decode.field("model_catalog_key", decode.string)
  use revision <- decode.field("revision", decode.int)
  use agents <- decode.field("agents", decode.list(of: agent.state_decoder()))
  use execution <- decode.field("execution", execution_decoder())
  case schema {
    1 ->
      decode.success(AgentGroup(
        id,
        model_catalog_key,
        revision,
        agents,
        execution,
      ))
    _ ->
      decode.failure(
        AgentGroup("", "", 0, [], Idle),
        "unsupported agent-group schema",
      )
  }
}

fn execution_decoder() -> decode.Decoder(ExecutionState) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "idle" -> decode.success(Idle)
    "completed" -> decode.success(Completed)
    "claimed" -> {
      use owner <- decode.field("owner", decode.string)
      use epoch <- decode.field("epoch", decode.int)
      use expires <- decode.field("lease_expires_at", decode.int)
      use nonce <- decode.optional_field("nonce", "", decode.string)
      decode.success(Claimed(owner, epoch, expires, nonce))
    }
    _ -> decode.failure(Idle, "unknown execution state")
  }
}
