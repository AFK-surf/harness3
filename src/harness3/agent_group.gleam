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

/// Consecutive times a worker holding an unresolved tool journal may exit and
/// be restarted without any successful commit in between. The journal can only
/// close via a commit, so exhausting this budget means storage writes are
/// failing; the coordinator abandons instead of hot-looping restarts, and
/// recovery re-dispatches the group after the lease expires.
const max_journal_restarts = 3

/// User message prepended to an injected synthetic tool call when the pair
/// would otherwise start the conversation or directly follow an assistant
/// message; provider APIs reject both shapes.
const synthetic_call_hint = "The next message is a synthetic tool call and its result, injected into this session by the harness."

pub type ExecutionState {
  /// `epoch` is carried through every state, not just `Claimed`: it is the
  /// fencing token in the running-index key, so releasing a claim must not
  /// reset it. A reused epoch can collide with a stale index entry left by an
  /// abnormally terminated coordinator, which would durably claim the group
  /// with no coordinator running.
  Idle(epoch: Int)
  /// `nonce` is unique per claim attempt. Claim bodies must differ between
  /// two concurrent wakes even when they share an owner and a wall-clock
  /// second, otherwise the ambiguous-CAS read-back confirmation could accept
  /// a twin's claim as its own and run two coordinators for one group.
  Claimed(owner: String, epoch: Int, lease_expires_at: Int, nonce: String)
  Completed(epoch: Int)
}

pub type AgentGroup {
  AgentGroup(
    id: String,
    model_catalog_key: String,
    revision: Int,
    agents: List(agent.State),
    /// Extended attributes: opaque application-owned key/value metadata,
    /// persisted with the group and never interpreted by the harness.
    attributes: Dict(String, String),
    execution: ExecutionState,
  )
}

/// A durable update command for a group's roster and extended attributes.
/// Commands carry no agent state: the group's single writer applies them to
/// the state it authoritatively holds — atomically with a wake's claim CAS
/// (`wake_detached_updated`), or serialized through a live coordinator
/// (`update_group`, attributes only) — so a stale caller snapshot can never
/// overwrite concurrent progress. Attribute maps are upserts merged into the
/// existing attributes; a `Some` roster declares the desired agent list
/// (pending messages of surviving agents are folded in by the claim, those of
/// removed agents are dropped with them).
pub type GroupUpdate {
  GroupUpdate(
    attributes: Dict(String, String),
    agent_attributes: Dict(String, Dict(String, String)),
    roster: Option(List(RosterEntry)),
  )
}

/// One agent in a declared roster. An existing agent with this id keeps its
/// durable state (history, plugin state, inbox, status); a new id is created
/// from scratch with `initial_status`. Changing an existing agent's model
/// scrubs provider-locked encrypted reasoning from its conversation, since
/// replaying foreign provider state is rejected by every adapter.
pub type RosterEntry {
  RosterEntry(
    id: String,
    profile_id: String,
    model_id: String,
    attributes: Dict(String, String),
    initial_status: agent.Status,
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
  AgentGroup(id, model_catalog_key, 0, agents, dict.new(), Idle(0))
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
    journal_restarts: Dict(String, Int),
  )
}

type Message {
  CommitAgent(
    id: String,
    expected_revision: Int,
    state: agent.State,
    mode: agent.CommitMode,
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
  InjectGroupToolCall(
    agent_id: String,
    tool_name: String,
    arguments: String,
    response: String,
    coordinator: Subject(Message),
    reply: Subject(Result(Nil, Error)),
  )
  RequestCompaction(
    agent_id: String,
    coordinator: Subject(Message),
    reply: Subject(Result(Int, Error)),
  )
  UpdateGroup(update: GroupUpdate, reply: Subject(Result(Nil, Error)))
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

/// What a delivery injects into an agent's conversation.
type Delivery {
  TextDelivery(content: String)
  ToolCallDelivery(tool_name: String, arguments: String, response: String)
}

pub fn create(config: Config, group: AgentGroup) -> Result(LoadedGroup, Error) {
  use _ <- result.try(validate(config, group))
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

/// Loads a group with an explicit profile list. Neither `create` nor `resume`
/// writes to the node's profile registry: registering profiles as node
/// capabilities (for `resume_registered` and the recovery RPC path) is the
/// application's responsibility, via `agent_profile.install`.
pub fn resume(config: Config) -> Result(LoadedGroup, Error) {
  use object <- result.try(
    storage.get(config.storage, config.object_key)
    |> result.map_error(StorageFailed),
  )
  use group <- result.try(decode_group_body(object.body))
  use _ <- result.try(validate(config, group))
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
  detached(fn() {
    wake_as_with_membership_refresh(loaded, owner, refresh_membership)
  })
}

/// Like `wake_detached`, but applies a durable update to the group atomically
/// with the claim CAS before the coordinator starts. This is the only way to
/// replace the roster of a group: a dormant group has no other writer, and a
/// claimed group must be stopped first (the wake fails with `AlreadyClaimed`
/// otherwise), so the update can never race a live coordinator's commits.
pub fn wake_detached_updated(
  loaded: LoadedGroup,
  owner: String,
  update: GroupUpdate,
  refresh_membership: fn() -> Nil,
) -> Result(Group, Error) {
  detached(fn() {
    wake_with_update(loaded, owner, Some(update), refresh_membership)
  })
}

fn detached(run: fn() -> Result(Group, Error)) -> Result(Group, Error) {
  let reply = process.new_subject()
  let waker = process.spawn_unlinked(fn() { process.send(reply, run()) })
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
  wake_with_update(loaded, owner, None, refresh_membership)
}

fn wake_with_update(
  loaded: LoadedGroup,
  owner: String,
  update: Option(GroupUpdate),
  refresh_membership: fn() -> Nil,
) -> Result(Group, Error) {
  let LoadedGroup(config:, group:, version:) = loaded
  // The update is validated against the same profiles and catalog as the wake
  // itself, then committed by the claim CAS below: one atomic write covers
  // both, and `IfUnchanged(version)` fences out anything that changed the
  // group since it was loaded.
  use group <- result.try(case update {
    None -> Ok(group)
    Some(update) -> {
      use updated <- result.try(apply_update(group, update))
      use _ <- result.try(validate(config, updated))
      Ok(updated)
    }
  })
  use catalog_session <- result.try(
    model_catalog.resume(config.storage, group.model_catalog_key)
    |> result.map_error(ModelCatalogFailed),
  )
  let catalog = model_catalog.catalog(catalog_session)
  use _ <- result.try(ensure_claimable(group.execution))
  // Never derive the new epoch from the group object alone. A group written
  // before the epoch was carried through `Idle`/`Completed` decodes with epoch
  // 0, so its epochs would restart and could collide with an index entry a
  // previously crashed coordinator left behind — reusing a running-index key
  // and failing every wake for that owner. Surviving entries are the
  // authority on how far the epoch has actually advanced.
  let floor =
    int.max(execution_epoch(group.execution), indexed_epoch(config, group))
  let claimed = claim(group, owner, floor, config.lease_duration_seconds)
  // Validate the *claimed* group, not the loaded one: the claim promotes
  // agents with queued inbox messages to Ready, so a dormant agent whose
  // profile is missing or whose model left the catalog must fail the wake
  // here — before the claim CAS commits — rather than in `prepare_agents`
  // afterwards, which would strand a durable claim.
  use _ <- result.try(validate(config, claimed))
  use _ <- result.try(validate_models(claimed, catalog))
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

/// Reads and decodes the durable group object without profiles, validation,
/// claiming, or process starts. This is how an application renders a view of
/// a group — or reconstructs the profiles a full `resume` needs from the
/// group's own extended attributes — before it can build a `Config`.
pub fn peek(backend: Storage, object_key: String) -> Result(AgentGroup, Error) {
  use object <- result.try(
    storage.get(backend, object_key)
    |> result.map_error(StorageFailed),
  )
  decode_group_body(object.body)
}

fn apply_update(
  group: AgentGroup,
  update: GroupUpdate,
) -> Result(AgentGroup, Error) {
  let GroupUpdate(attributes:, agent_attributes:, roster:) = update
  let agents = case roster {
    None -> group.agents
    Some(entries) ->
      list.map(entries, fn(entry) { apply_roster_entry(group.agents, entry) })
  }
  use agents <- result.try(
    agent_attributes
    |> dict.to_list
    |> list.try_fold(agents, fn(agents, entry) {
      let #(id, upserts) = entry
      use _ <- result.try(find_agent(agents, id))
      Ok(
        list.map(agents, fn(state) {
          case state.id == id {
            True ->
              agent.State(
                ..state,
                attributes: dict.merge(state.attributes, upserts),
              )
            False -> state
          }
        }),
      )
    }),
  )
  Ok(
    AgentGroup(
      ..group,
      agents:,
      attributes: dict.merge(group.attributes, attributes),
    ),
  )
}

fn apply_roster_entry(
  current: List(agent.State),
  entry: RosterEntry,
) -> agent.State {
  let RosterEntry(id:, profile_id:, model_id:, attributes:, initial_status:) =
    entry
  case list.find(current, fn(state) { state.id == id }) {
    Error(_) ->
      agent.State(
        ..agent.state(id, model_id),
        profile_id:,
        attributes:,
        status: initial_status,
      )
    Ok(state) -> {
      let state = agent.State(..state, profile_id:, attributes:)
      case state.model_id == model_id {
        True -> state
        False ->
          agent.State(
            ..state,
            model_id:,
            messages: scrub_encrypted_reasoning(state.messages),
            context_messages: option.map(
              state.context_messages,
              scrub_encrypted_reasoning,
            ),
            pending_messages: scrub_encrypted_reasoning(state.pending_messages),
            last_catalog_revision: None,
            last_context_tokens: None,
          )
      }
    }
  }
}

fn scrub_encrypted_reasoning(messages: List(llm.Message)) -> List(llm.Message) {
  list.map(messages, fn(message) {
    llm.Message(..message, content: list.map(message.content, scrub_content))
  })
}

fn scrub_content(content: llm.Content) -> llm.Content {
  case content {
    llm.Reasoning(summary, _) -> llm.Reasoning(summary, None)
    llm.ToolResult(id, content, is_error) ->
      llm.ToolResult(id, list.map(content, scrub_content), is_error)
    content -> content
  }
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
  // From here on the claim CAS has already committed. Every failure before
  // the running index is published must undo it, or the group stays durably
  // `Claimed` with no coordinator and no index entry — rejecting every wake
  // with `AlreadyClaimed` and invisible to recovery until the lease expires.
  use prepared <- result.try(
    prepare_agents(config, group, catalog)
    |> result.map_error(fn(error) {
      release_unpublished_claim(config, group, metadata)
      error
    }),
  )
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
      dict.new(),
    )
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) {
      discard_prepared(prepared)
      release_unpublished_claim(config, group, metadata)
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
    fn(agent_id, tool_name, arguments, response) {
      inject_tool_call(handle, agent_id, tool_name, arguments, response)
      |> result.map_error(string.inspect)
    },
    fn(agent_id) {
      request_compaction(handle, agent_id)
      |> result.map_error(string.inspect)
    },
    fn(attributes, agent_attributes) {
      update_group(handle, GroupUpdate(attributes, agent_attributes, None))
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
      // The claim CAS already committed, so without a compensating write the
      // group stays durably `Claimed` with no coordinator and no index entry:
      // unwakeable until the lease expires and invisible to recovery.
      release_unpublished_claim(config, group, metadata)
      Error(StorageFailed(error))
    }
    Ok(_) -> start_agents(config, prepared, handle, started.data)
  }
}

/// Best-effort undo of a claim whose running index could not be published.
/// Uses the version returned by the claim write, so it cannot clobber another
/// owner: if anyone else has written since, the CAS simply fails and the lease
/// expiry path takes over.
fn release_unpublished_claim(
  config: Config,
  group: AgentGroup,
  metadata: Metadata,
) -> Nil {
  let released =
    AgentGroup(
      ..group,
      revision: group.revision + 1,
      execution: Idle(execution_epoch(group.execution)),
    )
  let body = encode_group(released) |> json.to_string |> bit_array.from_string
  let _ =
    storage.put(
      config.storage,
      config.object_key,
      body,
      storage.IfUnchanged(metadata.version),
    )
  Nil
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
    case prepare_agent(config, group, state, catalog) {
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
  group: AgentGroup,
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
      max_output_tokens: model.max_output_tokens,
      reasoning_effort: profile.reasoning_effort,
      context_window_tokens: model.context_window_tokens,
      group_context: group_context_of(group, state.id),
    )
  use active <- result.try(
    agent.activate(state, agent_config)
    |> result.map_error(fn(error) { AgentActivationFailed(state.id, error) }),
  )
  Ok(PreparedAgent(state.id, active, profile))
}

/// The durable group-level identity plugins see at activation: group id and
/// attributes, plus every other agent as an id/attributes peer entry.
fn group_context_of(group: AgentGroup, agent_id: String) -> agent.GroupContext {
  agent.GroupContext(
    group_id: group.id,
    group_attributes: group.attributes,
    peers: group.agents
      |> list.filter(fn(peer) { peer.id != agent_id })
      |> list.map(fn(peer) { #(peer.id, peer.attributes) }),
  )
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
    agent.checkpointer_with_mode(fn(expected, state, mode) {
      commit_agent_with_mode(group, id, expected, state, mode)
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
  commit_agent_with_mode(group, id, expected_revision, state, agent.RoundCommit)
}

fn commit_agent_with_mode(
  group: Group,
  id: String,
  expected_revision: Int,
  state: agent.State,
  mode: agent.CommitMode,
) -> Result(CommitReceipt, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    CommitAgent(id, expected_revision, state, mode, reply)
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

/// Durably injects a synthetic tool call and its result into an agent's
/// history: an assistant `ToolCall` followed by the matching `ToolResult`.
/// The tool does not need to exist in the agent's tool list. The agent wakes
/// or picks the pair up at its next round exactly like a user message.
pub fn inject_tool_call(
  group: Group,
  agent_id: String,
  tool_name: String,
  arguments: String,
  response: String,
) -> Result(Nil, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) {
    InjectGroupToolCall(
      agent_id,
      tool_name,
      arguments,
      response,
      subject,
      reply,
    )
  })
}

/// Durably merges extended-attribute upserts into an awake group through its
/// coordinator, serialized with commits and lease renewal. Roster commands
/// (`roster: Some(..)`) are rejected: a live group's workers hold profiles and
/// in-flight rounds for the current roster, so a roster change must stop the
/// group and ride a wake instead (`wake_detached_updated`).
pub fn update_group(group: Group, update: GroupUpdate) -> Result(Nil, Error) {
  let Group(subject) = group
  process.call_forever(subject, fn(reply) { UpdateGroup(update, reply) })
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
    CommitAgent(id, expected, agent_state, mode, reply) -> {
      let outcome = do_commit_agent(state, id, expected, agent_state, mode)
      case outcome {
        Ok(#(state, receipt)) -> {
          process.send(reply, Ok(receipt))
          // A successful commit proves storage writes work again; the
          // worker's journal-restart budget starts over.
          actor.continue(
            CoordinatorState(
              ..state,
              journal_restarts: dict.delete(state.journal_restarts, id),
            ),
          )
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
              case current.tool_journal {
                // A worker that exits after a tool-progress checkpoint must be
                // replaced even with an empty inbox, so the journal can be
                // closed with an honest interrupted/unknown ToolResult block.
                // The restart budget is consumed only by exits with no
                // successful commit in between (`CommitAgent` resets it);
                // exhausting it means commits are failing persistently, so
                // restarting would spin — abandon and let recovery re-dispatch
                // the group after the lease expires.
                Some(_) -> {
                  let attempts =
                    dict.get(state.journal_restarts, id)
                    |> result.unwrap(0)
                  case attempts < max_journal_restarts {
                    False -> {
                      abandon(state)
                      actor.stop()
                    }
                    True -> {
                      let state =
                        CoordinatorState(
                          ..state,
                          journal_restarts: dict.insert(
                            state.journal_restarts,
                            id,
                            attempts + 1,
                          ),
                        )
                      case start_agent_worker(state, current, coordinator) {
                        Ok(next) -> actor.continue(next)
                        Error(_) -> {
                          abandon(state)
                          actor.stop()
                        }
                      }
                    }
                  }
                }
                None ->
                  case current.pending_messages {
                    [] ->
                      // A compaction request accepted while this worker was
                      // already exiting is durable but was never executed;
                      // nothing else would ever pick it up (wakes only start
                      // Ready agents). Restart a worker for it — unless the last
                      // attempt failed, in which case restarting would retry a
                      // failing compaction forever.
                      case
                        current.compaction_requested
                        > current.compaction_completed
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
    SendGroupMessage(agent_id, content, coordinator, reply) ->
      handle_delivery(
        state,
        agent_id,
        TextDelivery(content),
        coordinator,
        reply,
      )
    InjectGroupToolCall(
      agent_id,
      tool_name,
      arguments,
      response,
      coordinator,
      reply,
    ) ->
      handle_delivery(
        state,
        agent_id,
        ToolCallDelivery(tool_name, arguments, response),
        coordinator,
        reply,
      )
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
    UpdateGroup(update, reply) -> {
      case do_update_group(state, update) {
        Ok(next) -> {
          process.send(reply, Ok(Nil))
          actor.continue(next)
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

fn handle_delivery(
  state: CoordinatorState,
  agent_id: String,
  delivery: Delivery,
  coordinator: Subject(Message),
  reply: Subject(Result(Nil, Error)),
) -> actor.Next(CoordinatorState, Message) {
  case deliver_message(state, agent_id, delivery, coordinator) {
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

fn deliver_message(
  state: CoordinatorState,
  target_id: String,
  delivery: Delivery,
  coordinator: Subject(Message),
) -> Result(CoordinatorState, Error) {
  // Shape validation is pure, so it runs before any ownership or existence
  // check: a malformed delivery fails the same way regardless of coordinator
  // state.
  use base <- result.try(delivery_messages(delivery))
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use current <- result.try(find_agent(state.group.agents, target_id))
  let running =
    state.children
    |> list.find(fn(child) { child.0 == target_id })
    |> result.map(fn(child) { process.is_alive(agent.pid(child.1)) })
    |> result.unwrap(False)
  let incoming = case delivery {
    TextDelivery(_) -> base
    ToolCallDelivery(..) ->
      case injection_needs_hint(current, running) {
        True -> [llm.Message(llm.User, [llm.Text(synthetic_call_hint)]), ..base]
        False -> base
      }
  }
  case running {
    True -> queue_pending_messages(state, current, incoming)
    False -> inject_and_start(state, current, incoming, coordinator)
  }
}

fn delivery_messages(delivery: Delivery) -> Result(List(llm.Message), Error) {
  case delivery {
    TextDelivery(content) ->
      case string.trim(content) {
        "" -> Error(InvalidMessage("message cannot be empty"))
        _ -> Ok([llm.Message(llm.User, [llm.Text(content)])])
      }
    ToolCallDelivery(tool_name, arguments, response) ->
      synthetic_tool_call(tool_name, arguments, response)
  }
}

/// A synthetic tool call cannot start a conversation (provider APIs require a
/// user turn first) or directly follow an assistant message (role alternation
/// and `tool_use`/`tool_result` pairing break), so those shapes get a user
/// hint before the pair. For a running worker the in-flight round's output
/// lands between the durable tail and the pair, and it may end with a bare
/// assistant message, so an empty inbox always gets the hint; an
/// already-queued inbox never ends with an assistant message (deliveries only
/// append sequences ending in user text or a tool result) and needs none. The
/// hint can produce consecutive user messages; every supported provider
/// accepts those.
fn injection_needs_hint(current: agent.State, running: Bool) -> Bool {
  case running {
    True -> list.is_empty(current.pending_messages)
    False ->
      case list.last(list.append(current.messages, current.pending_messages)) {
        Error(_) -> True
        Ok(llm.Message(llm.Assistant, _)) -> True
        Ok(_) -> False
      }
  }
}

/// Builds the assistant `ToolCall` + `ToolResult` pair for a synthetic tool
/// call. Arguments must be a JSON object: that is the only shape provider
/// APIs accept for tool-use input.
fn synthetic_tool_call(
  tool_name: String,
  arguments: String,
  response: String,
) -> Result(List(llm.Message), Error) {
  use _ <- result.try(case string.trim(tool_name) {
    "" -> Error(InvalidMessage("tool name cannot be empty"))
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    json.parse(arguments, decode.dict(decode.string, decode.dynamic))
    |> result.map(fn(_) { Nil })
    |> result.map_error(fn(_) {
      InvalidMessage("tool call arguments must be a JSON object")
    }),
  )
  use _ <- result.try(case string.trim(response) {
    "" -> Error(InvalidMessage("tool call response cannot be empty"))
    _ -> Ok(Nil)
  })
  let call_id =
    "synthetic-"
    <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
  Ok([
    llm.Message(llm.Assistant, [
      llm.ToolCall(call_id, tool_name, raw_json(arguments)),
    ]),
    llm.Message(llm.ToolRole, [
      llm.ToolResult(call_id, [llm.Text(response)], False),
    ]),
  ])
}

@external(erlang, "gleam_stdlib", "identity")
fn raw_json(value: String) -> json.Json

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
    state.group,
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
        state.group,
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

fn queue_pending_messages(
  state: CoordinatorState,
  current: agent.State,
  incoming: List(llm.Message),
) -> Result(CoordinatorState, Error) {
  // The active worker still commits against this same agent revision. Persist
  // the inbox without advancing that revision; its next commit atomically
  // consumes the pending messages into the conversation.
  let replacement =
    agent.State(
      ..current,
      pending_messages: list.append(current.pending_messages, incoming),
    )
  persist_agents(state, replace_agent(state.group.agents, replacement))
}

fn inject_and_start(
  state: CoordinatorState,
  current: agent.State,
  incoming: List(llm.Message),
  coordinator: Subject(Message),
) -> Result(CoordinatorState, Error) {
  // No worker owns this state. Ordinarily move the durable inbox and new
  // delivery into the conversation before starting it. An unresolved tool
  // journal is the exception: its assistant ToolCall must remain adjacent to
  // the eventual complete ToolResult block, so keep every delivery queued.
  let next_agent = case current.tool_journal {
    Some(_) ->
      agent.State(
        ..current,
        revision: current.revision + 1,
        pending_messages: list.append(current.pending_messages, incoming),
        status: agent.Ready,
      )
    None ->
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
  }
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
  // Prepared against the full group, not `single`: plugins must see the
  // agent's real peers.
  use prepared <- result.try(prepare_agent(
    config,
    state.group,
    next_agent,
    catalog,
  ))
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
  mode: agent.CommitMode,
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
  use _ <- result.try(case mode, new_agent.tool_journal {
    agent.ToolProgressCommit, Some(_) -> Ok(Nil)
    agent.ToolProgressCommit, None ->
      Error(InvalidGroup("tool progress commit has no tool journal"))
    agent.RoundCommit, None -> Ok(Nil)
    agent.RoundCommit, Some(_) ->
      Error(InvalidGroup("round commit left a tool journal unresolved"))
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
  // Tool progress is write-ahead state: messages arriving while a tool call
  // is unresolved must stay in the inbox, otherwise a user message could be
  // persisted between an assistant ToolCall and its matching ToolResult block.
  let #(messages, context_messages, pending_messages, has_pending) = case mode {
    agent.ToolProgressCommit -> #(
      new_agent.messages,
      new_agent.context_messages,
      current.pending_messages,
      False,
    )
    agent.RoundCommit -> #(
      list.append(new_agent.messages, current.pending_messages),
      append_context(new_agent.context_messages, current.pending_messages),
      [],
      !list.is_empty(current.pending_messages),
    )
  }
  let new_agent =
    agent.State(
      ..new_agent,
      revision: agent_revision,
      messages:,
      context_messages:,
      pending_messages:,
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

fn do_update_group(
  state: CoordinatorState,
  update: GroupUpdate,
) -> Result(CoordinatorState, Error) {
  use _ <- result.try(case state.owned {
    True -> Ok(Nil)
    False -> Error(LostGroupOwnership)
  })
  use _ <- result.try(case update.roster {
    Some(_) -> Error(InvalidGroup("cannot replace the roster of a live group"))
    None -> Ok(Nil)
  })
  use updated <- result.try(apply_update(state.group, update))
  let group =
    AgentGroup(
      ..updated,
      revision: state.group.revision + 1,
      execution: extend_claim(state),
    )
  use metadata <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, metadata:))
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
    Completed(_) -> Ok(state)
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
  let epoch = execution_epoch(state.group.execution)
  let execution = case list.all(state.group.agents, agent_is_terminal) {
    True -> Completed(epoch)
    False -> Idle(epoch)
  }
  let group =
    AgentGroup(..state.group, revision: state.group.revision + 1, execution:)
  use metadata <- result.try(write_group(state, group))
  Ok(CoordinatorState(..state, group:, metadata:, owned: False))
}

fn finish(state: CoordinatorState) -> Result(CoordinatorState, Error) {
  // Release first. Deleting the index before the claim is released risks a
  // group that is durably `Claimed` with no index entry — invisible to
  // recovery, and unwakeable until the lease expires. The opposite order at
  // worst leaves a stale index entry for an already-released group, which
  // recovery resolves by waking a claimable group.
  use released <- result.try(release(state))
  use _ <- result.try(
    storage.delete(released.storage, released.index_key)
    |> result.try_recover(fn(error) {
      case error {
        storage.NotFound(_) -> Ok(Nil)
        error -> Error(error)
      }
    })
    |> result.map_error(StorageFailed),
  )
  Ok(released)
}

/// Durably finalizes a group whose owner is gone: releases an expired claim
/// by CAS, then removes its stale running-index entries so recovery stops
/// resurrecting it. A dormant group only has its stale entries cleaned.
/// Fails with `AlreadyClaimed` while the lease is unexpired — the owner may
/// merely be behind a membership gap, and only lease expiry proves it gone.
///
/// The release CAS comes *first*, and index entries (only at or below the
/// epoch read from the group object; a concurrent fresh claim always takes a
/// higher epoch) are removed only after it succeeds. The opposite order is
/// unsafe even though it looks tidier: an "expired" lease can belong to a
/// still-live owner whose clock disagrees with ours, and its next commit
/// CAS-extends the lease and beats our release — if we had already deleted
/// its index entry, that running claimed group would be invisible to
/// recovery forever. Losing the CAS proves someone is alive, and their
/// entries must survive; a crash after the release merely leaves stale
/// entries, which cost one spurious wake.
pub fn release_abandoned(
  backend: Storage,
  object_key: String,
) -> Result(Nil, Error) {
  use object <- result.try(
    storage.get(backend, object_key)
    |> result.map_error(StorageFailed),
  )
  use group <- result.try(decode_group_body(object.body))
  use _ <- result.try(case group.execution {
    Idle(_) | Completed(_) -> Ok(Nil)
    Claimed(owner, _, expires, _) ->
      case expires > system_time(Second) {
        True -> Error(AlreadyClaimed(owner, expires))
        False -> {
          let epoch = execution_epoch(group.execution)
          let execution = case list.all(group.agents, agent_is_terminal) {
            True -> Completed(epoch)
            False -> Idle(epoch)
          }
          let released =
            AgentGroup(..group, revision: group.revision + 1, execution:)
          let body =
            encode_group(released) |> json.to_string |> bit_array.from_string
          case
            storage.put(
              backend,
              object_key,
              body,
              storage.IfUnchanged(object.metadata.version),
            )
          {
            Ok(_) -> Ok(Nil)
            Error(storage.PreconditionFailed(_)) ->
              confirm_group_write(backend, object_key, body)
              |> result.map(fn(_) { Nil })
            Error(error) -> Error(storage_error(error))
          }
        }
      }
  })
  delete_index_entries(backend, group.id, execution_epoch(group.execution))
}

/// Deletes this group's running-index entries whose epoch is at or below
/// `up_to_epoch`. Entry epochs are part of the key, so no bodies are read;
/// keys that do not parse are left alone.
fn delete_index_entries(
  backend: Storage,
  group_id: String,
  up_to_epoch: Int,
) -> Result(Nil, Error) {
  let prefix = running_index_prefix() <> uri.percent_encode(group_id) <> "/"
  use entries <- result.try(
    storage.list(backend, prefix)
    |> result.map_error(StorageFailed),
  )
  entries
  |> list.filter(fn(entry) {
    case
      entry.key
      |> string.drop_start(string.length(prefix))
      |> string.split_once("_")
    {
      Ok(#(epoch, _)) ->
        case int.parse(epoch) {
          Ok(epoch) -> epoch <= up_to_epoch
          Error(_) -> False
        }
      Error(_) -> False
    }
  })
  |> list.try_each(fn(entry) {
    storage.delete(backend, entry.key)
    |> result.try_recover(fn(error) {
      case error {
        storage.NotFound(_) -> Ok(Nil)
        error -> Error(error)
      }
    })
    |> result.map(fn(_) { Nil })
    |> result.map_error(StorageFailed)
  })
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
  epoch_floor: Int,
  lease_duration_seconds: Int,
) -> AgentGroup {
  AgentGroup(
    ..group,
    revision: group.revision + 1,
    agents: list.map(group.agents, inject_pending),
    execution: Claimed(
      owner,
      epoch_floor + 1,
      system_time(Second) + lease_duration_seconds,
      claim_nonce(),
    ),
  )
}

/// Highest epoch among this group's surviving running-index entries, or 0 when
/// the prefix cannot be read. A read failure only means the claim may reuse an
/// epoch, which the index write then rejects — the same outcome as before this
/// check existed, so it must not fail the wake.
fn indexed_epoch(config: Config, group: AgentGroup) -> Int {
  let prefix = running_index_prefix() <> uri.percent_encode(group.id) <> "/"
  case storage.list(config.storage, prefix) {
    Error(_) -> 0
    Ok(entries) ->
      list.fold(entries, 0, fn(highest, item) {
        case storage.get(config.storage, item.key) {
          Error(_) -> highest
          Ok(object) ->
            case decode_running_index(item.key, object.body) {
              Ok(entry) if entry.group_id == group.id ->
                int.max(highest, entry.epoch)
              _ -> highest
            }
        }
      })
  }
}

fn inject_pending(state: agent.State) -> agent.State {
  // An unresolved tool journal owns the gap after its assistant ToolCall.
  // Keep deliveries in the inbox until recovery has materialized a complete
  // ToolResult block, or they would split an invalid provider conversation.
  case state.tool_journal {
    Some(_) -> agent.State(..state, status: agent.Ready)
    None ->
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
}

fn execution_epoch(execution: ExecutionState) -> Int {
  case execution {
    Claimed(_, epoch, _, _) -> epoch
    Idle(epoch) | Completed(epoch) -> epoch
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
    #("attributes", json.dict(group.attributes, fn(key) { key }, json.string)),
    #("execution", encode_execution(group.execution)),
  ])
}

fn encode_execution(execution: ExecutionState) -> json.Json {
  case execution {
    Idle(epoch) ->
      json.object([
        #("type", json.string("idle")),
        #("epoch", json.int(epoch)),
      ])
    Completed(epoch) ->
      json.object([
        #("type", json.string("completed")),
        #("epoch", json.int(epoch)),
      ])
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
  use attributes <- decode.optional_field(
    "attributes",
    dict.new(),
    decode.dict(decode.string, decode.string),
  )
  use execution <- decode.field("execution", execution_decoder())
  case schema {
    1 ->
      decode.success(AgentGroup(
        id,
        model_catalog_key,
        revision,
        agents,
        attributes,
        execution,
      ))
    _ ->
      decode.failure(
        AgentGroup("", "", 0, [], dict.new(), Idle(0)),
        "unsupported agent-group schema",
      )
  }
}

fn execution_decoder() -> decode.Decoder(ExecutionState) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "idle" -> {
      use epoch <- decode.optional_field("epoch", 0, decode.int)
      decode.success(Idle(epoch))
    }
    "completed" -> {
      use epoch <- decode.optional_field("epoch", 0, decode.int)
      decode.success(Completed(epoch))
    }
    "claimed" -> {
      use owner <- decode.field("owner", decode.string)
      use epoch <- decode.field("epoch", decode.int)
      use expires <- decode.field("lease_expires_at", decode.int)
      use nonce <- decode.optional_field("nonce", "", decode.string)
      decode.success(Claimed(owner, epoch, expires, nonce))
    }
    _ -> decode.failure(Idle(0), "unknown execution state")
  }
}
