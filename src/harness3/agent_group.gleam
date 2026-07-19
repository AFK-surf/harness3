import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import harness3/agent
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/model_catalog
import harness3/storage.{type Metadata, type Storage, type VersionToken}

pub type ExecutionState {
  Idle
  Claimed(owner: String, epoch: Int, lease_expires_at: Int)
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
  )
}

pub type Error {
  InvalidGroup(reason: String)
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
  CommitReceipt(agent_revision: Int, group_revision: Int)
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
  AgentExited(id: String)
  CallbackHelperExited(pid: Pid)
  StopIfEmpty
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
    storage.put(config.storage, config.object_key, body, storage.IfAbsent)
    |> result.map_error(storage_error),
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
  let profile_ids =
    group.agents
    |> list.filter(fn(state) { state.status == agent.Ready })
    |> list.map(fn(state) { state.profile_id })
  use profiles <- result.try(
    agent_profile.profiles(profile_ids)
    |> result.map_error(fn(error) { ProfileUnavailable(string.inspect(error)) }),
  )
  let config = Config(storage, object_key, profiles, lease_duration_seconds)
  use _ <- result.try(validate(config, group))
  Ok(LoadedGroup(config, group, object.metadata.version))
}

pub fn loaded_state(loaded: LoadedGroup) -> AgentGroup {
  let LoadedGroup(group:, ..) = loaded
  group
}

/// Claims a loaded group and starts its coordinator and agent processes.
pub fn wake(loaded: LoadedGroup) -> Result(Group, Error) {
  let LoadedGroup(config:, group:, version:) = loaded
  use catalog_session <- result.try(
    model_catalog.resume(config.storage, group.model_catalog_key)
    |> result.map_error(ModelCatalogFailed),
  )
  let catalog = model_catalog.catalog(catalog_session)
  use _ <- result.try(validate_models(group, catalog))
  use _ <- result.try(ensure_claimable(group.execution))
  let owner = owner_token()
  let claimed = claim(group, owner, config.lease_duration_seconds)
  let claimed_body =
    encode_group(claimed) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    storage.put(
      config.storage,
      config.object_key,
      claimed_body,
      storage.IfUnchanged(version),
    )
    |> result.map_error(storage_error),
  )
  let index_key = running_index_key(claimed, owner)
  start_coordinator(config, claimed, metadata, owner, index_key, catalog)
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
    )
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) { ProcessStartFailed(string.inspect(error)) }),
  )
  let handle = Group(started.data)
  agent_group_registry.register(group.id, started.pid, fn() {
    stop(handle) |> result.map_error(string.inspect)
  })
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
      process.unlink(started.pid)
      process.kill(started.pid)
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
  process.send(subject, StopIfEmpty)
  Ok(handle)
}

fn prepare_agents(
  config: Config,
  group: AgentGroup,
  catalog: model_catalog.Catalog,
) -> Result(List(PreparedAgent), Error) {
  group.agents
  |> list.filter(fn(state) { state.status == agent.Ready })
  |> list.try_map(fn(state) {
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
      )
    use active <- result.try(
      agent.activate(state, agent_config)
      |> result.map_error(fn(error) { AgentActivationFailed(state.id, error) }),
    )
    Ok(PreparedAgent(state.id, active, profile))
  })
}

fn launch_agent(group: Group, prepared: PreparedAgent) -> agent.Handle {
  let PreparedAgent(id:, active:, profile:) = prepared
  let checkpoint =
    agent.checkpointer(fn(expected, state) {
      commit_agent(group, id, expected, state)
      |> result.map(fn(receipt) {
        let CommitReceipt(agent_revision:, group_revision:) = receipt
        agent.CommitReceipt(agent_revision, group_revision)
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
      process.send(subject, AgentExited(id))
    })
  let Group(subject) = group
  process.call_forever(subject, fn(reply) { RegisterChild(id, child, reply) })
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
    AgentExited(id) -> {
      let children = list.filter(state.children, fn(child) { child.0 != id })
      case children, state.helpers {
        [], [] -> {
          let _ = finish(CoordinatorState(..state, children:))
          agent_group_registry.unregister(state.group.id, process.self())
          actor.stop()
        }
        _, _ -> actor.continue(CoordinatorState(..state, children:))
      }
    }
    CallbackHelperExited(pid) -> {
      let helpers = list.filter(state.helpers, fn(helper) { helper != pid })
      case state.children, helpers {
        [], [] -> {
          let _ = finish(CoordinatorState(..state, helpers:))
          agent_group_registry.unregister(state.group.id, process.self())
          actor.stop()
        }
        _, _ -> actor.continue(CoordinatorState(..state, helpers:))
      }
    }
    StopIfEmpty ->
      case state.children, state.helpers {
        [], [] -> {
          let _ = finish(state)
          agent_group_registry.unregister(state.group.id, process.self())
          actor.stop()
        }
        _, _ -> actor.continue(state)
      }
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
              process.send(coordinator, CallbackHelperExited(process.self()))
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
  let new_agent = agent.State(..new_agent, revision: agent_revision)
  let agents =
    list.map(state.group.agents, fn(item) {
      case item.id == id {
        True -> new_agent
        False -> item
      }
    })
  let group_revision = state.group.revision + 1
  let execution = case list.all(agents, agent_is_terminal) {
    True -> Completed
    False ->
      Claimed(
        state.owner,
        execution_epoch(state.group.execution),
        system_time(Second) + state.lease_duration_seconds,
      )
  }
  let group =
    AgentGroup(..state.group, revision: group_revision, agents:, execution:)
  use metadata <- result.try(write_group(state, group))
  Ok(#(
    CoordinatorState(..state, group:, metadata:),
    CommitReceipt(agent_revision, group_revision),
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
    Claimed(_, epoch, _) ->
      Claimed(
        state.owner,
        epoch,
        system_time(Second) + state.lease_duration_seconds,
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
    Claimed(owner, epoch, expires_at) ->
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
  case state.group.execution {
    Completed -> Ok(CoordinatorState(..state, owned: False))
    _ -> {
      let group =
        AgentGroup(
          ..state.group,
          revision: state.group.revision + 1,
          execution: Idle,
        )
      use metadata <- result.try(write_group(state, group))
      Ok(CoordinatorState(..state, group:, metadata:, owned: False))
    }
  }
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
    Claimed(_, epoch, lease_expires_at) -> #(epoch, lease_expires_at)
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
  storage.put(backend, index_key, body, storage.IfAbsent)
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
    Claimed(owner, _, expires) ->
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
    execution: case list.all(group.agents, agent_is_terminal) {
      True -> Completed
      False ->
        Claimed(
          owner,
          execution_epoch(group.execution) + 1,
          system_time(Second) + lease_duration_seconds,
        )
    },
  )
}

fn execution_epoch(execution: ExecutionState) -> Int {
  case execution {
    Claimed(_, epoch, _) -> epoch
    _ -> 0
  }
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
    Claimed(owner, epoch, expires) ->
      json.object([
        #("type", json.string("claimed")),
        #("owner", json.string(owner)),
        #("epoch", json.int(epoch)),
        #("lease_expires_at", json.int(expires)),
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
      decode.success(Claimed(owner, epoch, expires))
    }
    _ -> decode.failure(Idle, "unknown execution state")
  }
}
