import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/agent
import harness3/model_catalog
import harness3/plugin
import harness3/storage.{type Storage, type VersionToken}

pub type ExecutionState {
  Idle
  Claimed(owner: String, epoch: Int, lease_expires_at: Int)
  Completed
}

pub type AgentGroup {
  AgentGroup(
    id: String,
    revision: Int,
    agents: List(agent.State),
    execution: ExecutionState,
  )
}

pub fn new(id: String, agents: List(agent.State)) -> AgentGroup {
  AgentGroup(id, 0, agents, Idle)
}

pub type AgentDefinition {
  AgentDefinition(
    id: String,
    registry: plugin.Registry,
    transport: agent.ModelTransport,
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    reasoning_effort: Option(String),
    observe: fn(agent.Event) -> Result(Nil, agent.Error),
  )
}

pub type Config {
  Config(
    storage: Storage,
    object_key: String,
    catalog: model_catalog.Catalog,
    definitions: List(AgentDefinition),
    lease_duration_seconds: Int,
  )
}

pub type Error {
  InvalidGroup(reason: String)
  MissingAgent(id: String)
  MissingDefinition(id: String)
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
}

pub type CommitReceipt {
  CommitReceipt(agent_revision: Int, group_revision: Int)
}

pub opaque type Group {
  Group(subject: Subject(Message))
}

type CoordinatorState {
  CoordinatorState(
    storage: Storage,
    key: String,
    group: AgentGroup,
    version: VersionToken,
    owner: String,
    lease_duration_seconds: Int,
    owned: Bool,
    children: List(#(String, agent.Handle)),
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
  RegisterChild(id: String, handle: agent.Handle)
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
  PreparedAgent(id: String, active: agent.Active, definition: AgentDefinition)
}

pub fn create(config: Config, group: AgentGroup) -> Result(Group, Error) {
  use _ <- result.try(validate(config, group))
  let owner = owner_token()
  let claimed = claim(group, owner, config.lease_duration_seconds)
  let body = encode_group(claimed) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    storage.put(config.storage, config.object_key, body, storage.IfAbsent)
    |> result.map_error(storage_error),
  )
  start_coordinator(config, claimed, metadata.version, owner)
}

pub fn resume(config: Config) -> Result(Group, Error) {
  use object <- result.try(
    storage.get(config.storage, config.object_key)
    |> result.map_error(StorageFailed),
  )
  use body <- result.try(
    bit_array.to_string(object.body)
    |> result.map_error(fn(_) { DecodeFailed("agent group is not UTF-8 JSON") }),
  )
  use group <- result.try(
    json.parse(body, group_decoder())
    |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) }),
  )
  use _ <- result.try(validate(config, group))
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
      storage.IfUnchanged(object.metadata.version),
    )
    |> result.map_error(storage_error),
  )
  start_coordinator(config, claimed, metadata.version, owner)
}

fn start_coordinator(
  config: Config,
  group: AgentGroup,
  version: VersionToken,
  owner: String,
) -> Result(Group, Error) {
  use prepared <- result.try(prepare_agents(config, group))
  let state =
    CoordinatorState(
      config.storage,
      config.object_key,
      group,
      version,
      owner,
      config.lease_duration_seconds,
      True,
      [],
    )
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) { ProcessStartFailed(string.inspect(error)) }),
  )
  let handle = Group(started.data)
  schedule_renewal(started.data, config.lease_duration_seconds)
  let children = list.map(prepared, fn(item) { launch_agent(handle, item) })
  list.each(children, agent.release)
  Ok(handle)
}

fn prepare_agents(
  config: Config,
  group: AgentGroup,
) -> Result(List(PreparedAgent), Error) {
  group.agents
  |> list.filter(fn(state) { state.status == agent.Ready })
  |> list.try_map(fn(state) {
    use definition <- result.try(find_definition(config.definitions, state.id))
    use model <- result.try(
      model_catalog.lookup(config.catalog, state.model_id)
      |> result.map_error(fn(_) { UnknownModel(state.id, state.model_id) }),
    )
    let agent_config =
      agent.Config(
        provider: model_catalog.provider(model),
        model_name: model.name,
        catalog_revision: model_catalog.revision(config.catalog),
        registry: definition.registry,
        transport: definition.transport,
        max_output_tokens: definition.max_output_tokens,
        temperature: definition.temperature,
        reasoning_effort: definition.reasoning_effort,
      )
    use active <- result.try(
      agent.activate(state, agent_config)
      |> result.map_error(fn(error) { AgentActivationFailed(state.id, error) }),
    )
    Ok(PreparedAgent(state.id, active, definition))
  })
}

fn launch_agent(group: Group, prepared: PreparedAgent) -> agent.Handle {
  let PreparedAgent(id:, active:, definition:) = prepared
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
  let child = agent.start(active, checkpoint, router, definition.observe)
  let Group(subject) = group
  process.send(subject, RegisterChild(id, child))
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
            ConcurrentGroupUpdate | LostGroupOwnership ->
              list.each(state.children, fn(child) { agent.stop(child.1) })
            _ -> Nil
          }
          actor.continue(case error {
            ConcurrentGroupUpdate | LostGroupOwnership ->
              CoordinatorState(..state, owned: False)
            _ -> state
          })
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
    RegisterChild(id, handle) ->
      actor.continue(
        CoordinatorState(..state, children: [#(id, handle), ..state.children]),
      )
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
      case source == target_id, source_exists, target {
        True, _, _ ->
          process.send(reply, Error(AgentCallbackUnavailable(target_id)))
        _, False, _ ->
          process.send(reply, Error(AgentCallbackUnavailable(source)))
        _, _, Error(_) ->
          process.send(reply, Error(AgentCallbackUnavailable(target_id)))
        False, True, Ok(handle) -> {
          let _ =
            process.spawn_unlinked(fn() {
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
            })
          Nil
        }
      }
      actor.continue(state)
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
            ConcurrentGroupUpdate | LostGroupOwnership ->
              list.each(state.children, fn(child) { agent.stop(child.1) })
            _ -> Nil
          }
          actor.continue(case error {
            ConcurrentGroupUpdate | LostGroupOwnership ->
              CoordinatorState(..state, owned: False)
            _ -> state
          })
        }
      }
    }
    Renew(subject) -> {
      let next = case renew(state) {
        Ok(state) -> state
        Error(_) -> {
          list.each(state.children, fn(child) { agent.stop(child.1) })
          CoordinatorState(..state, owned: False)
        }
      }
      case next.owned, next.group.execution {
        True, Claimed(..) ->
          schedule_renewal(subject, next.lease_duration_seconds)
        _, _ -> Nil
      }
      actor.continue(next)
    }
    Stop(reply) -> {
      list.each(state.children, fn(child) { agent.stop(child.1) })
      let released = release(state)
      process.send(reply, released |> result.map(fn(_) { Nil }))
      actor.stop()
    }
  }
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
  use version <- result.try(write_group(state, group))
  Ok(#(
    CoordinatorState(..state, group:, version:),
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
  use version <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, version:))
}

fn renew(state: CoordinatorState) -> Result(CoordinatorState, Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  case state.group.execution {
    Completed -> Ok(state)
    _ -> {
      let group =
        AgentGroup(
          ..state.group,
          revision: state.group.revision + 1,
          execution: Claimed(
            state.owner,
            execution_epoch(state.group.execution),
            system_time(Second) + state.lease_duration_seconds,
          ),
        )
      use version <- result.try(write_group(state, group))
      Ok(CoordinatorState(..state, group:, version:))
    }
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
      use version <- result.try(write_group(state, group))
      Ok(CoordinatorState(..state, group:, version:, owned: False))
    }
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
) -> Result(VersionToken, Error) {
  let body = encode_group(group) |> json.to_string |> bit_array.from_string
  storage.put(
    state.storage,
    state.key,
    body,
    storage.IfUnchanged(state.version),
  )
  |> result.map(fn(metadata) { metadata.version })
  |> result.map_error(storage_error)
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
  use _ <- result.try(case string.trim(group.id), group.agents {
    "", _ -> Error(InvalidGroup("group id cannot be empty"))
    _, [] -> Error(InvalidGroup("agent group must contain at least one agent"))
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(
    config.definitions
    |> list.try_fold([], fn(ids, definition) {
      case list.contains(ids, definition.id) {
        True ->
          Error(InvalidGroup("duplicate agent definition: " <> definition.id))
        False -> Ok([definition.id, ..ids])
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
    use _ <- result.try(find_definition(config.definitions, state.id))
    model_catalog.lookup(config.catalog, state.model_id)
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(_) { UnknownModel(state.id, state.model_id) })
  })
}

fn find_definition(
  definitions: List(AgentDefinition),
  id: String,
) -> Result(AgentDefinition, Error) {
  list.find(definitions, fn(definition) { definition.id == id })
  |> result.map_error(fn(_) { MissingDefinition(id) })
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
  use revision <- decode.field("revision", decode.int)
  use agents <- decode.field("agents", decode.list(of: agent.state_decoder()))
  use execution <- decode.field("execution", execution_decoder())
  case schema {
    1 -> decode.success(AgentGroup(id, revision, agents, execution))
    _ ->
      decode.failure(
        AgentGroup("", 0, [], Idle),
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
