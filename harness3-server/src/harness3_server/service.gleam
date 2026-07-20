import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import harness3/agent
import harness3/agent_group
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/cluster/agent_group_rpc
import harness3/cluster/core
import harness3/llm
import harness3/model_catalog
import harness3/plugin
import harness3/plugin/cloud_storage
import harness3/plugin/mcp
import harness3/plugin/mcp/catalog as mcp_catalog
import harness3/plugin/mcp/configuration as mcp_configuration
import harness3/storage.{type Storage, type VersionToken}
import harness3_server/coding_plugin
import harness3_server/config.{type ModelConfig}
import harness3_server/storage_config
import harness3_server/transport
import simplifile

const catalog_key = "harness3-server/catalog"

const mcp_catalog_key = "harness3-server/mcp-catalog"

const all_mcp_configuration_id = "__harness3_server_all_mcp_servers__"

const sessions_prefix = "harness3-server/sessions/"

const lease_seconds = 30

const minimum_lifetime_milliseconds = 5000

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub type AgentKind {
  CodingAgent
  ResearchAgent
  McpSpecialist
}

pub type AgentSpec {
  AgentSpec(id: String, role: String, kind: AgentKind, model_id: String)
}

pub type SessionMetadata {
  SessionMetadata(
    id: String,
    title: String,
    prompt: String,
    workspace: String,
    created_at: Int,
    agents: List(AgentSpec),
  )
}

pub type Session {
  Session(metadata: SessionMetadata, group: agent_group.AgentGroup)
}

pub type CreateInput {
  CreateInput(model_id: String, workspace: String, team_size: Int)
}

pub type UpdateInput {
  UpdateInput(name: String, agents: List(AgentSpec))
}

pub opaque type Service {
  Service(
    storage: Storage,
    models: List(ModelConfig),
    workspace_root: String,
    mcp_runtime: mcp.Runtime,
    cluster: core.Cluster,
    model_transport: agent.ModelTransport,
    max_output_tokens: Int,
  )
}

pub fn start() -> Result(Service, String) {
  use storage <- result.try(storage_config.from_environment())
  use models <- result.try(config.load_models(config.models_path()))
  use root <- result.try(resolve_workspace_root())
  use _ <- result.try(install_catalog(storage, models))
  use mcp_runtime <- result.try(start_mcp(storage))
  let cluster =
    core.config(
      storage,
      config.environment_or("HARNESS3_CLUSTER_BIND", "127.0.0.1"),
      config.environment_int("HARNESS3_CLUSTER_PORT", 0),
    )
    |> core.with_rpc_plugin(agent_group_rpc.plugin(storage, lease_seconds))
    |> core.start
  case cluster {
    Error(error) -> {
      mcp.stop(mcp_runtime)
      Error("could not start cluster RPC node: " <> string.inspect(error))
    }
    Ok(cluster) ->
      Ok(Service(
        storage:,
        models:,
        workspace_root: root,
        mcp_runtime:,
        cluster:,
        model_transport: transport.buffered_http(config.environment_int(
          "HARNESS3_MODEL_TIMEOUT_MS",
          300_000,
        )),
        max_output_tokens: config.environment_int(
          "HARNESS3_MAX_OUTPUT_TOKENS",
          8192,
        ),
      ))
  }
}

pub fn models(service: Service) -> List(ModelConfig) {
  service.models
}

pub fn workspace_root(service: Service) -> String {
  service.workspace_root
}

pub fn mcp_configurations(
  service: Service,
) -> List(mcp_configuration.Configuration) {
  service.mcp_runtime
  |> mcp.catalog
  |> mcp_catalog.configurations
  |> list.filter(fn(configuration) {
    configuration.id != all_mcp_configuration_id
  })
}

pub fn stop(service: Service) -> Nil {
  core.stop(service.cluster)
  mcp.stop(service.mcp_runtime)
}

pub fn create_session(
  service: Service,
  input: CreateInput,
) -> Result(Session, String) {
  use _ <- result.try(validate_create(service, input))
  use workspace <- result.try(resolve_workspace(input.workspace))
  use _ <- result.try(
    simplifile.create_directory_all(workspace)
    |> result.map_error(simplifile.describe_error),
  )
  let id = new_id()
  let agents = team(input.team_size, has_mcp_servers(service), input.model_id)
  let metadata =
    SessionMetadata(
      id:,
      title: "New coding session",
      prompt: "",
      workspace:,
      created_at: system_time(Second),
      agents:,
    )
  use group_config <- result.try(group_config(service, metadata))
  let meta_key = metadata_key(id)
  use _ <- result.try(
    storage.put(
      service.storage,
      meta_key,
      encode_metadata(metadata) |> json.to_string |> bit_array.from_string,
      storage.IfAbsent,
    )
    |> result.map_error(fn(error) {
      "could not persist session metadata: " <> string.inspect(error)
    }),
  )
  let states = initial_states(metadata)
  let created =
    agent_group.create(group_config, agent_group.new(id, catalog_key, states))
  case created {
    Error(error) -> {
      let _ = storage.delete(service.storage, meta_key)
      Error("could not create agent group: " <> string.inspect(error))
    }
    Ok(loaded) -> Ok(Session(metadata, agent_group.loaded_state(loaded)))
  }
}

pub fn list_sessions(service: Service) -> Result(List(Session), String) {
  use objects <- result.try(
    storage.list(service.storage, sessions_prefix)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use sessions <- result.try(
    objects
    |> list.filter(fn(object) { string.ends_with(object.key, "/metadata") })
    |> list.try_map(fn(object) {
      use metadata <- result.try(load_metadata_key(service, object.key))
      load_session(service, metadata)
    }),
  )
  Ok(
    list.sort(sessions, fn(left, right) {
      let Session(metadata: left, ..) = left
      let Session(metadata: right, ..) = right
      case int.compare(right.created_at, left.created_at) {
        order.Eq -> string.compare(left.id, right.id)
        ordering -> ordering
      }
    }),
  )
}

pub fn get_session(service: Service, id: String) -> Result(Session, String) {
  use metadata <- result.try(load_metadata(service, id))
  load_session(service, metadata)
}

/// Replaces a session's durable name and agent roster. Roster changes stop
/// running agents through the host-routed RPC first; surviving agent histories
/// and plugin state are retained, while newly added agents start dormant. A
/// name-only update does not interrupt a running group.
pub fn update_session(
  service: Service,
  id: String,
  input: UpdateInput,
) -> Result(Session, String) {
  use agents <- result.try(validate_update(service, input))
  use metadata_object <- result.try(
    storage.get(service.storage, metadata_key(id))
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use current_metadata <- result.try(decode_metadata_body(metadata_object.body))
  let next_metadata =
    SessionMetadata(..current_metadata, title: string.trim(input.name), agents:)
  let metadata_body =
    encode_metadata(next_metadata) |> json.to_string |> bit_array.from_string
  case agents == current_metadata.agents {
    True -> {
      use _ <- result.try(persist_metadata_update(
        service,
        id,
        metadata_body,
        metadata_object.metadata.version,
      ))
      load_session(service, next_metadata)
    }
    False ->
      update_session_roster(
        service,
        id,
        current_metadata,
        next_metadata,
        metadata_body,
        metadata_object.metadata.version,
      )
  }
}

fn update_session_roster(
  service: Service,
  id: String,
  current_metadata: SessionMetadata,
  next_metadata: SessionMetadata,
  metadata_body: BitArray,
  metadata_version: VersionToken,
) -> Result(Session, String) {
  // Construct every profile before stopping anything. A missing MCP
  // configuration or invalid plugin graph must leave the live team untouched.
  use next_config <- result.try(group_config(service, next_metadata))
  use _ <- result.try(stop_session(service, id))
  use current_config <- result.try(group_config(service, current_metadata))
  use current_group <- result.try(
    agent_group.load(current_config)
    |> result.map_error(fn(error) {
      "could not load stopped agent group: " <> string.inspect(error)
    }),
  )
  let next_states = reconcile_agents(current_group.agents, next_metadata)
  use next_group <- result.try(
    agent_group.reconfigure(next_config, next_states)
    |> result.map_error(fn(error) {
      "could not update agent group: " <> string.inspect(error)
    }),
  )
  case persist_metadata_update(service, id, metadata_body, metadata_version) {
    Ok(Nil) -> {
      let retained_ids =
        list.map(next_metadata.agents, fn(spec) { profile_id(id, spec.id) })
      current_metadata.agents
      |> list.map(fn(spec) { profile_id(id, spec.id) })
      |> list.filter(fn(profile) { !list.contains(retained_ids, profile) })
      |> agent_profile.uninstall
      Ok(Session(next_metadata, next_group))
    }
    Error(error) -> {
      let rollback =
        agent_group.reconfigure(current_config, current_group.agents)
      case rollback {
        Ok(_) -> {
          let previous_ids =
            list.map(current_metadata.agents, fn(spec) {
              profile_id(id, spec.id)
            })
          next_metadata.agents
          |> list.map(fn(spec) { profile_id(id, spec.id) })
          |> list.filter(fn(profile) { !list.contains(previous_ids, profile) })
          |> agent_profile.uninstall
          Error("could not persist updated session metadata: " <> error)
        }
        Error(rollback_error) ->
          Error(
            "could not persist updated session metadata: "
            <> error
            <> "; agent-group rollback also failed: "
            <> string.inspect(rollback_error),
          )
      }
    }
  }
}

fn persist_metadata_update(
  service: Service,
  id: String,
  intended_body: BitArray,
  version: VersionToken,
) -> Result(Nil, String) {
  let key = metadata_key(id)
  case
    storage.put(
      service.storage,
      key,
      intended_body,
      storage.IfUnchanged(version),
    )
  {
    Ok(_) -> Ok(Nil)
    Error(storage.PreconditionFailed(_)) ->
      case storage.get(service.storage, key) {
        Ok(object) if object.body == intended_body -> Ok(Nil)
        Ok(_) | Error(storage.PreconditionFailed(_)) ->
          Error("session metadata changed concurrently")
        Error(error) -> Error(string.inspect(error))
      }
    Error(error) -> Error(string.inspect(error))
  }
}

pub fn send_message(
  service: Service,
  id: String,
  agent_id: String,
  message: String,
) -> Result(Nil, String) {
  use _ <- result.try(case string.trim(message) {
    "" -> Error("message cannot be empty")
    _ -> Ok(Nil)
  })
  use metadata <- result.try(load_metadata(service, id))
  use _ <- result.try(validate_agent(metadata, agent_id))
  use metadata <- result.try(initialize_session_metadata(
    service,
    metadata,
    message,
  ))
  case agent_group_registry.send_message(id, agent_id, message) {
    Ok(Nil) -> Ok(Nil)
    Error(agent_group_registry.NotFound(_)) -> {
      use config <- result.try(group_config(service, metadata))
      use loaded <- result.try(
        agent_group.resume(config)
        |> result.map_error(fn(error) {
          "could not resume session: " <> string.inspect(error)
        }),
      )
      // Detached: this runs in a transient web-request handler; a direct
      // wake would link the whole group process tree to it.
      case
        agent_group.wake_detached(loaded, core.token(service.cluster), fn() {
          core.refresh(service.cluster)
        })
      {
        Ok(group) ->
          agent_group.send_message(group, agent_id, message)
          |> result.map_error(fn(error) { string.inspect(error) })
        // A concurrent request won the wake race and the group is now
        // running; deliver through the registry instead of surfacing the
        // race to the client. The winner may still be registering, so allow
        // one short retry.
        Error(agent_group.ConcurrentGroupUpdate)
        | Error(agent_group.AlreadyClaimed(_, _)) ->
          deliver_registered(id, agent_id, message, 3)
        Error(error) ->
          Error("could not wake session: " <> string.inspect(error))
      }
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// Wakes the group through the cluster RPC, then durably requests compaction
/// through the host-routed compaction RPC.
pub fn request_compaction(
  service: Service,
  id: String,
  agent_id: String,
) -> Result(Int, String) {
  use metadata <- result.try(load_metadata(service, id))
  use _ <- result.try(validate_agent(metadata, agent_id))
  // Install this session's profiles before the wake RPC may choose this node.
  // Resuming is read-only and leaves the group dormant.
  use group_config <- result.try(group_config(service, metadata))
  use _ <- result.try(
    agent_group.resume(group_config)
    |> result.map_error(fn(error) {
      "could not prepare session for compaction: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(
    cluster_call(
      service,
      agent_group_rpc.wake_method_name(),
      agent_group_rpc.wake_request(id, group_key(id)),
      decode.string,
    )
    |> result.map_error(fn(error) { "could not wake session: " <> error }),
  )
  cluster_call(
    service,
    agent_group_rpc.compaction_method_name(),
    agent_group_rpc.compaction_request(id, agent_id),
    decode.int,
  )
  |> result.map_error(fn(error) { "could not request compaction: " <> error })
}

fn cluster_call(
  service: Service,
  method: String,
  request: request,
  decoder: decode.Decoder(response),
) -> Result(response, String) {
  let #(ip, port) = core.node(service.cluster)
  core.call(ip, port, core.token(service.cluster), method, request, decoder)
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn deliver_registered(
  id: String,
  agent_id: String,
  message: String,
  attempts: Int,
) -> Result(Nil, String) {
  case agent_group_registry.send_message(id, agent_id, message) {
    Ok(Nil) -> Ok(Nil)
    Error(agent_group_registry.NotFound(_)) if attempts > 1 -> {
      process.sleep(100)
      deliver_registered(id, agent_id, message, attempts - 1)
    }
    Error(error) ->
      Error(
        "could not deliver after concurrent wake: " <> string.inspect(error),
      )
  }
}

pub fn stop_session(service: Service, id: String) -> Result(Nil, String) {
  use metadata <- result.try(load_metadata(service, id))
  use session <- result.try(load_session(service, metadata))
  let Session(group:, ..) = session
  use _ <- result.try(case group.execution {
    agent_group.Claimed(..) ->
      cluster_call(
        service,
        agent_group_rpc.stop_method_name(),
        agent_group_rpc.stop_request(id),
        decode.string,
      )
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(error) { "could not stop session: " <> error })
    agent_group.Idle(_) | agent_group.Completed(_) -> Ok(Nil)
  })
  // Per-session profiles are node-global ETS entries; a later resume
  // re-installs them, so drop them now instead of growing forever.
  agent_profile.uninstall(
    list.map(metadata.agents, fn(spec) { profile_id(metadata.id, spec.id) }),
  )
  Ok(Nil)
}

fn resolve_workspace_root() -> Result(String, String) {
  let configured = config.environment_or("HARNESS3_WORKSPACE_ROOT", "..")
  simplifile.resolve(configured)
  |> result.map_error(simplifile.describe_error)
}

fn install_catalog(
  backend: Storage,
  models: List(ModelConfig),
) -> Result(Nil, String) {
  use catalog <- result.try(
    models
    |> list.try_fold(model_catalog.new(), fn(catalog, model) {
      model_catalog.put_model(catalog, config.catalog_model(model))
    })
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case model_catalog.create(backend, catalog_key, catalog) {
    Ok(_) -> Ok(Nil)
    Error(model_catalog.ConcurrentUpdate) -> {
      use current <- result.try(
        model_catalog.resume(backend, catalog_key)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      model_catalog.commit(current, catalog)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(error) { string.inspect(error) })
    }
    Error(error) -> Error(string.inspect(error))
  }
}

fn start_mcp(backend: Storage) -> Result(mcp.Runtime, String) {
  use path <- result.try(config.mcp_configurations_path())
  use existing <- result.try(case mcp_catalog.resume(backend, mcp_catalog_key) {
    Ok(session) -> Ok(Some(session))
    Error(mcp_catalog.StorageFailed(storage.NotFound(_))) -> Ok(None)
    Error(error) ->
      Error("could not load MCP catalog: " <> string.inspect(error))
  })
  // `persist` is False when the durable catalog is already what we want:
  // committing an identical catalog on every boot bumps its revision for no
  // reason, and loses the CAS — failing startup — against any edit that lands
  // concurrently.
  use #(desired, persist) <- result.try(case existing, path {
    Some(session), _ -> Ok(#(mcp_catalog.catalog(session), False))
    None, None -> Ok(#(mcp_catalog.new(), True))
    None, Some(path) -> {
      use configurations <- result.try(config.load_mcp_configurations(path))
      configurations
      |> list.try_fold(mcp_catalog.new(), fn(catalog, configuration) {
        mcp_catalog.put_configuration(catalog, configuration)
      })
      |> result.map(fn(catalog) { #(catalog, True) })
      |> result.map_error(fn(error) { string.inspect(error) })
    }
  })
  use _ <- result.try(
    case mcp_catalog.lookup(desired, all_mcp_configuration_id) {
      Error(mcp_catalog.UnknownConfiguration(_)) -> Ok(Nil)
      Ok(_) ->
        Error(
          "MCP configuration ID is reserved by harness3-server: "
          <> all_mcp_configuration_id,
        )
      Error(error) -> Error(string.inspect(error))
    },
  )
  use runtime <- result.try(
    mcp.start(desired, config.environment, fn() { system_time(Second) }),
  )
  let initialized = case persist {
    False -> Ok(Nil)
    True -> persist_mcp_catalog(backend, existing, desired)
  }
  case initialized {
    Error(error) -> {
      mcp.stop(runtime)
      Error(error)
    }
    Ok(Nil) ->
      case refresh_all_mcp_configuration(runtime) {
        Ok(Nil) -> Ok(runtime)
        Error(error) -> {
          mcp.stop(runtime)
          Error(error)
        }
      }
  }
}

pub fn add_mcp_server(
  service: Service,
  configuration_id: String,
  configuration_label: String,
  server: mcp_configuration.Server,
) -> Result(mcp_configuration.Configuration, String) {
  use _ <- result.try(case configuration_id == all_mcp_configuration_id {
    True -> Error("MCP configuration ID is reserved by harness3-server")
    False -> Ok(Nil)
  })
  use configuration <- result.try(commit_mcp_change(
    service.storage,
    fn(catalog) {
      let existing = mcp_catalog.lookup(catalog, configuration_id)
      use current <- result.try(case existing {
        Ok(configuration) -> Ok(configuration)
        Error(mcp_catalog.UnknownConfiguration(_)) ->
          Ok(
            mcp_configuration.Configuration(
              id: configuration_id,
              label: configuration_label,
              enabled: True,
              servers: [],
            ),
          )
        Error(error) -> Error(string.inspect(error))
      })
      use _ <- result.try(
        case list.any(current.servers, fn(item) { item.id == server.id }) {
          True ->
            Error(
              "MCP server already exists in configuration `"
              <> configuration_id
              <> "`: "
              <> server.id,
            )
          False -> Ok(Nil)
        },
      )
      let updated =
        mcp_configuration.Configuration(
          ..current,
          label: configuration_label,
          servers: list.append(current.servers, [server]),
        )
      mcp_catalog.put_configuration(catalog, updated)
      |> result.map(fn(next) { #(next, updated) })
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    3,
  ))
  use _ <- result.try(mcp.put_configuration(service.mcp_runtime, configuration))
  use _ <- result.try(refresh_all_mcp_configuration(service.mcp_runtime))
  Ok(configuration)
}

/// Replaces an existing MCP server without contacting it. The configuration
/// and server IDs are stable path identities; editable transport settings and
/// bindings come from `replacement`.
pub fn update_mcp_server(
  service: Service,
  configuration_id: String,
  server_id: String,
  replacement: mcp_configuration.Server,
) -> Result(mcp_configuration.Configuration, String) {
  let replacement = mcp_configuration.Server(..replacement, id: server_id)
  use configuration <- result.try(commit_mcp_change(
    service.storage,
    fn(catalog) {
      use current <- result.try(
        mcp_catalog.lookup(catalog, configuration_id)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      use _ <- result.try(
        case list.any(current.servers, fn(server) { server.id == server_id }) {
          True -> Ok(Nil)
          False ->
            Error(
              "unknown MCP server in configuration `"
              <> configuration_id
              <> "`: "
              <> server_id,
            )
        },
      )
      let updated =
        mcp_configuration.Configuration(
          ..current,
          servers: list.map(current.servers, fn(server) {
            case server.id == server_id {
              True -> replacement
              False -> server
            }
          }),
        )
      mcp_catalog.put_configuration(catalog, updated)
      |> result.map(fn(next) { #(next, updated) })
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    3,
  ))
  use _ <- result.try(mcp.put_configuration(service.mcp_runtime, configuration))
  use _ <- result.try(refresh_all_mcp_configuration(service.mcp_runtime))
  Ok(configuration)
}

pub fn remove_mcp_server(
  service: Service,
  configuration_id: String,
  server_id: String,
) -> Result(mcp_configuration.Configuration, String) {
  use configuration <- result.try(commit_mcp_change(
    service.storage,
    fn(catalog) {
      use current <- result.try(
        mcp_catalog.lookup(catalog, configuration_id)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      use _ <- result.try(
        case list.any(current.servers, fn(server) { server.id == server_id }) {
          True -> Ok(Nil)
          False ->
            Error(
              "unknown MCP server in configuration `"
              <> configuration_id
              <> "`: "
              <> server_id,
            )
        },
      )
      let updated =
        mcp_configuration.Configuration(
          ..current,
          servers: list.filter(current.servers, fn(server) {
            server.id != server_id
          }),
        )
      mcp_catalog.put_configuration(catalog, updated)
      |> result.map(fn(next) { #(next, updated) })
      |> result.map_error(fn(error) { string.inspect(error) })
    },
    3,
  ))
  use _ <- result.try(mcp.put_configuration(service.mcp_runtime, configuration))
  use _ <- result.try(refresh_all_mcp_configuration(service.mcp_runtime))
  Ok(configuration)
}

fn refresh_all_mcp_configuration(runtime: mcp.Runtime) -> Result(Nil, String) {
  runtime
  |> mcp.catalog
  |> mcp_catalog.configurations
  |> list.filter(fn(configuration) {
    configuration.id != all_mcp_configuration_id && configuration.enabled
  })
  |> list.flat_map(fn(configuration) {
    list.map(configuration.servers, fn(server) {
      mcp_configuration.Server(
        ..server,
        id: aggregate_server_id(configuration.id, server.id),
      )
    })
  })
  |> fn(servers) {
    mcp_configuration.Configuration(
      id: all_mcp_configuration_id,
      label: "All enabled MCP servers",
      enabled: True,
      servers:,
    )
  }
  |> fn(configuration) { mcp.put_configuration(runtime, configuration) }
}

fn aggregate_server_id(configuration_id: String, server_id: String) -> String {
  "c"
  <> int.to_string(string.length(configuration_id))
  <> "_"
  <> configuration_id
  <> "_"
  <> server_id
}

fn commit_mcp_change(
  backend: Storage,
  change: fn(mcp_catalog.Catalog) ->
    Result(#(mcp_catalog.Catalog, mcp_configuration.Configuration), String),
  attempts: Int,
) -> Result(mcp_configuration.Configuration, String) {
  use session <- result.try(
    mcp_catalog.resume(backend, mcp_catalog_key)
    |> result.map_error(fn(error) {
      "could not load MCP catalog: " <> string.inspect(error)
    }),
  )
  use #(next, configuration) <- result.try(change(mcp_catalog.catalog(session)))
  case mcp_catalog.commit(session, next) {
    Ok(_) -> Ok(configuration)
    Error(mcp_catalog.ConcurrentUpdate) if attempts > 1 ->
      commit_mcp_change(backend, change, attempts - 1)
    Error(error) ->
      Error("could not persist MCP catalog: " <> string.inspect(error))
  }
}

fn persist_mcp_catalog(
  backend: Storage,
  existing: Option(mcp_catalog.Session),
  catalog: mcp_catalog.Catalog,
) -> Result(Nil, String) {
  let persisted = case existing {
    Some(session) -> mcp_catalog.commit(session, catalog)
    None -> mcp_catalog.create(backend, mcp_catalog_key, catalog)
  }
  persisted
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    "could not persist MCP catalog: " <> string.inspect(error)
  })
}

fn validate_create(
  service: Service,
  input: CreateInput,
) -> Result(Nil, String) {
  case
    list.any(service.models, fn(model) { model.id == input.model_id }),
    input.team_size >= 1 && input.team_size <= 4
  {
    False, _ -> Error("unknown model: " <> input.model_id)
    _, False -> Error("team_size must be between 1 and 4")
    _, _ -> Ok(Nil)
  }
}

fn validate_update(
  service: Service,
  input: UpdateInput,
) -> Result(List(AgentSpec), String) {
  use _ <- result.try(case string.trim(input.name) {
    "" -> Error("agent group name cannot be empty")
    _ -> Ok(Nil)
  })
  use _ <- result.try(case input.agents {
    [] -> Error("agent group must contain at least one agent")
    _ -> Ok(Nil)
  })
  input.agents
  |> list.try_fold([], fn(validated: List(AgentSpec), spec) {
    let normalized =
      AgentSpec(..spec, id: string.trim(spec.id), role: string.trim(spec.role))
    use _ <- result.try(case normalized.id {
      "" -> Error("agent id cannot be empty")
      _ -> Ok(Nil)
    })
    use _ <- result.try(case normalized.role {
      "" -> Error("agent role cannot be empty: " <> normalized.id)
      _ -> Ok(Nil)
    })
    use _ <- result.try(
      case list.any(validated, fn(agent) { agent.id == normalized.id }) {
        True -> Error("duplicate agent id: " <> normalized.id)
        False -> Ok(Nil)
      },
    )
    use _ <- result.try(
      case
        list.any(service.models, fn(model) { model.id == normalized.model_id })
      {
        True -> Ok(Nil)
        False -> Error("unknown model: " <> normalized.model_id)
      },
    )
    use _ <- result.try(case normalized.kind {
      CodingAgent | ResearchAgent -> Ok(Nil)
      McpSpecialist ->
        mcp.configuration(service.mcp_runtime, all_mcp_configuration_id)
        |> result.map(fn(_) { Nil })
    })
    Ok([normalized, ..validated])
  })
  |> result.map(list.reverse)
}

fn has_mcp_servers(service: Service) -> Bool {
  case mcp.configuration(service.mcp_runtime, all_mcp_configuration_id) {
    Ok(configuration) -> !list.is_empty(configuration.servers)
    Error(_) -> False
  }
}

/// Validates and normalizes an absolute workspace path.
pub fn resolve_workspace(requested: String) -> Result(String, String) {
  let requested = string.trim(requested)
  case requested, filepath.is_absolute(requested) {
    "", _ -> Error("workspace path cannot be empty")
    _, False -> Error("workspace path must be absolute")
    _, True ->
      simplifile.resolve(requested)
      |> result.map_error(simplifile.describe_error)
  }
}

fn load_session(
  service: Service,
  metadata: SessionMetadata,
) -> Result(Session, String) {
  use group_config <- result.try(group_config(service, metadata))
  agent_group.load(group_config)
  |> result.map(fn(group) { Session(metadata, group) })
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn load_metadata(
  service: Service,
  id: String,
) -> Result(SessionMetadata, String) {
  load_metadata_key(service, metadata_key(id))
}

fn load_metadata_key(
  service: Service,
  key: String,
) -> Result(SessionMetadata, String) {
  use object <- result.try(
    storage.get(service.storage, key)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  decode_metadata_body(object.body)
}

fn decode_metadata_body(body: BitArray) -> Result(SessionMetadata, String) {
  use body <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) { "session metadata is not UTF-8" }),
  )
  json.parse(body, metadata_decoder())
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn initialize_session_metadata(
  service: Service,
  metadata: SessionMetadata,
  first_message: String,
) -> Result(SessionMetadata, String) {
  case metadata.prompt {
    "" -> {
      let key = metadata_key(metadata.id)
      use object <- result.try(
        storage.get(service.storage, key)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      use current <- result.try(decode_metadata_body(object.body))
      case current.prompt {
        "" -> {
          let updated =
            SessionMetadata(
              ..current,
              title: case current.title {
                "New coding session" -> title(first_message)
                title -> title
              },
              prompt: first_message,
            )
          case
            storage.put(
              service.storage,
              key,
              encode_metadata(updated)
                |> json.to_string
                |> bit_array.from_string,
              storage.IfUnchanged(object.metadata.version),
            )
          {
            Ok(_) -> Ok(updated)
            Error(storage.PreconditionFailed(_)) ->
              load_metadata(service, metadata.id)
            Error(error) -> Error(string.inspect(error))
          }
        }
        _ -> Ok(current)
      }
    }
    _ -> Ok(metadata)
  }
}

fn group_config(
  service: Service,
  metadata: SessionMetadata,
) -> Result(agent_group.Config, String) {
  use profiles <- result.try(
    list.try_map(metadata.agents, fn(spec) {
      let message_targets = case spec.id {
        "lead" ->
          metadata.agents
          |> list.map(fn(item) { item.id })
          |> list.filter(fn(id) { id != "lead" })
        _ ->
          case list.any(metadata.agents, fn(item) { item.id == "lead" }) {
            True -> ["lead"]
            False -> []
          }
      }
      let collaboration =
        coding_plugin.collaboration(
          metadata.id,
          spec.id,
          spec.role,
          message_targets,
          capability_instructions(spec.kind),
        )
      let group_storage = cloud_storage.new(service.storage, metadata.id)
      use plugins <- result.try(case spec.kind {
        CodingAgent ->
          Ok([
            collaboration,
            group_storage,
            coding_plugin.workspace(metadata.workspace),
          ])
        ResearchAgent -> Ok([collaboration, group_storage])
        McpSpecialist -> {
          use configuration <- result.try(mcp.configuration(
            service.mcp_runtime,
            all_mcp_configuration_id,
          ))
          let specialist = mcp.plugin(service.mcp_runtime, configuration)
          Ok([collaboration, group_storage, specialist])
        }
      })
      use registry <- result.try(
        plugin.registry(plugins)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      Ok(
        agent_profile.AgentProfile(
          id: profile_id(metadata.id, spec.id),
          registry:,
          transport: service.model_transport,
          max_output_tokens: Some(service.max_output_tokens),
          reasoning_effort: None,
          observe: fn(_) { Ok(Nil) },
        ),
      )
    }),
  )
  Ok(agent_group.Config(
    storage: service.storage,
    object_key: group_key(metadata.id),
    profiles:,
    lease_duration_seconds: lease_seconds,
    minimum_lifetime_milliseconds: minimum_lifetime_milliseconds,
  ))
}

fn capability_instructions(kind: AgentKind) -> String {
  case kind {
    CodingAgent ->
      "You can inspect and modify the shared workspace, run commands with the installed coding tools, and read, write, list, delete, or create transfer URLs for durable cloud-storage objects shared by this agent group."
    ResearchAgent ->
      "You have no filesystem, workspace, shell, or MCP tools. You can use `team.message_agent` only to report to the lead, and you can use the `cloud_storage.*` tools to read, write, list, delete, or create transfer URLs for durable objects shared by this agent group."
    McpSpecialist ->
      "You are the MCP research specialist with access to all enabled global MCP servers. You have `team.message_agent` (to report to the lead), `mcp.list` (to inspect tools from currently reachable external servers), `mcp.call` (to invoke a listed tool), and the `cloud_storage.*` tools for durable objects shared by this agent group. You have no direct filesystem or shell access."
  }
}

fn initial_states(metadata: SessionMetadata) -> List(agent.State) {
  metadata.agents
  |> list.map(fn(spec) {
    let base = agent.state(spec.id, spec.model_id)
    agent.State(
      ..base,
      profile_id: profile_id(metadata.id, spec.id),
      status: agent.Waiting,
    )
  })
}

fn reconcile_agents(
  current: List(agent.State),
  metadata: SessionMetadata,
) -> List(agent.State) {
  metadata.agents
  |> list.map(fn(spec) {
    case list.find(current, fn(state) { state.id == spec.id }) {
      Error(_) -> {
        let base = agent.state(spec.id, spec.model_id)
        agent.State(
          ..base,
          profile_id: profile_id(metadata.id, spec.id),
          status: agent.Waiting,
        )
      }
      Ok(state) if state.model_id == spec.model_id ->
        agent.State(..state, profile_id: profile_id(metadata.id, spec.id))
      Ok(state) ->
        agent.State(
          ..state,
          profile_id: profile_id(metadata.id, spec.id),
          model_id: spec.model_id,
          messages: sanitize_messages(state.messages),
          context_messages: option.map(
            state.context_messages,
            sanitize_messages,
          ),
          pending_messages: sanitize_messages(state.pending_messages),
          last_catalog_revision: None,
          last_context_tokens: None,
        )
    }
  })
}

fn sanitize_messages(messages: List(llm.Message)) -> List(llm.Message) {
  list.map(messages, fn(message) {
    llm.Message(..message, content: list.map(message.content, sanitize_content))
  })
}

fn sanitize_content(content: llm.Content) -> llm.Content {
  case content {
    llm.Reasoning(summary, _) -> llm.Reasoning(summary, None)
    llm.ToolResult(id, content, is_error) ->
      llm.ToolResult(id, list.map(content, sanitize_content), is_error)
    content -> content
  }
}

fn validate_agent(
  metadata: SessionMetadata,
  id: String,
) -> Result(Nil, String) {
  case list.any(metadata.agents, fn(agent) { agent.id == id }) {
    True -> Ok(Nil)
    False -> Error("unknown agent: " <> id)
  }
}

fn team(size: Int, mcp_available: Bool, model_id: String) -> List(AgentSpec) {
  let #(researcher_kind, researcher_role) = case mcp_available {
    True -> #(
      McpSpecialist,
      "MCP research specialist with `mcp.list` and `mcp.call` access to every enabled global MCP server, `cloud_storage.*` access to shared durable objects, and `team.message_agent` access only to the lead; has no filesystem or shell access.",
    )
    False -> #(
      ResearchAgent,
      "Researcher without configured MCP servers. Has shared durable cloud-storage access and can message only the lead agent; has no filesystem, workspace, shell, or external MCP access.",
    )
  }
  [
    AgentSpec(
      "lead",
      "Lead engineer. Has `coding.read`, `coding.write`, and `coding.exec` access to the selected workspace, `cloud_storage.*` access to shared durable objects, and `team.message_agent` access to every subagent; owns implementation, delegation, and verification.",
      CodingAgent,
      model_id,
    ),
    AgentSpec("researcher", researcher_role, researcher_kind, model_id),
    AgentSpec(
      "implementer",
      "Implementation specialist. Has `coding.read`, `coding.write`, and `coding.exec` access to the selected workspace and `cloud_storage.*` access to shared durable objects; `team.message_agent` can target only the lead agent.",
      CodingAgent,
      model_id,
    ),
    AgentSpec(
      "reviewer",
      "Reviewer and test engineer. Has `coding.read`, `coding.write`, and `coding.exec` access to the selected workspace and `cloud_storage.*` access to shared durable objects; `team.message_agent` can target only the lead agent.",
      CodingAgent,
      model_id,
    ),
  ]
  |> list.take(size)
}

fn new_id() -> String {
  "session-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn title(prompt: String) -> String {
  let title = prompt |> string.trim |> string.replace("\n", " ")
  case string.length(title) > 64 {
    True -> string.slice(title, 0, 64) <> "…"
    False -> title
  }
}

fn profile_id(session_id: String, agent_id: String) -> String {
  session_id <> ":" <> agent_id
}

fn metadata_key(id: String) -> String {
  sessions_prefix <> id <> "/metadata"
}

fn group_key(id: String) -> String {
  sessions_prefix <> id <> "/group"
}

fn encode_metadata(metadata: SessionMetadata) -> json.Json {
  json.object([
    #("schema_version", json.int(4)),
    #("id", json.string(metadata.id)),
    #("title", json.string(metadata.title)),
    #("prompt", json.string(metadata.prompt)),
    #("workspace", json.string(metadata.workspace)),
    #("created_at", json.int(metadata.created_at)),
    #(
      "agents",
      json.array(metadata.agents, fn(agent) {
        let kind = case agent.kind {
          CodingAgent -> "coding"
          ResearchAgent -> "researcher"
          McpSpecialist -> "mcp"
        }
        json.object([
          #("id", json.string(agent.id)),
          #("role", json.string(agent.role)),
          #("kind", json.string(kind)),
          #("model_id", json.string(agent.model_id)),
        ])
      }),
    ),
  ])
}

fn metadata_decoder() -> decode.Decoder(SessionMetadata) {
  use schema <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use prompt <- decode.field("prompt", decode.string)
  use workspace <- decode.field("workspace", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use agents <- decode.field("agents", decode.list(of: agent_spec_decoder()))
  case schema {
    4 ->
      decode.success(SessionMetadata(
        id,
        title,
        prompt,
        workspace,
        created_at,
        agents,
      ))
    _ ->
      decode.failure(
        SessionMetadata("", "", "", "", 0, []),
        "unsupported session metadata schema",
      )
  }
}

fn agent_spec_decoder() -> decode.Decoder(AgentSpec) {
  use id <- decode.field("id", decode.string)
  use role <- decode.field("role", decode.string)
  use kind <- decode.field("kind", decode.string)
  use model_id <- decode.field("model_id", decode.string)
  case kind {
    "coding" -> decode.success(AgentSpec(id, role, CodingAgent, model_id))
    "researcher" -> decode.success(AgentSpec(id, role, ResearchAgent, model_id))
    "mcp" -> decode.success(AgentSpec(id, role, McpSpecialist, model_id))
    _ ->
      decode.failure(AgentSpec("", "", ResearchAgent, ""), "unknown agent kind")
  }
}
