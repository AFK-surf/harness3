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
import harness3/model_catalog
import harness3/plugin
import harness3/plugin/mcp
import harness3/plugin/mcp/catalog as mcp_catalog
import harness3/plugin/mcp/configuration as mcp_configuration
import harness3/storage.{type Storage}
import harness3_server/coding_plugin
import harness3_server/config.{type ModelConfig}
import harness3_server/storage_config
import harness3_server/transport
import simplifile

const catalog_key = "harness3-server/catalog"

const mcp_catalog_key = "harness3-server/mcp-catalog"

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
  McpSpecialist(configuration_id: String)
}

pub type AgentSpec {
  AgentSpec(id: String, role: String, kind: AgentKind)
}

pub type SessionMetadata {
  SessionMetadata(
    id: String,
    title: String,
    prompt: String,
    workspace: String,
    model_id: String,
    created_at: Int,
    agents: List(AgentSpec),
  )
}

pub type Session {
  Session(metadata: SessionMetadata, group: agent_group.AgentGroup)
}

pub type CreateInput {
  CreateInput(
    model_id: String,
    workspace: String,
    team_size: Int,
    mcp_configuration_id: Option(String),
  )
}

pub opaque type Service {
  Service(
    storage: Storage,
    models: List(ModelConfig),
    workspace_root: String,
    mcp_runtime: mcp.Runtime,
    model_transport: agent.ModelTransport,
    max_output_tokens: Int,
    // Stable owner token for group claims, so every wake from this server
    // identifies the same node instead of minting a random owner per wake.
    owner: String,
  )
}

pub fn start() -> Result(Service, String) {
  use storage <- result.try(storage_config.from_environment())
  use models <- result.try(config.load_models(config.models_path()))
  use root <- result.try(resolve_workspace_root())
  use _ <- result.try(install_catalog(storage, models))
  use mcp_runtime <- result.try(start_mcp(storage))
  Ok(Service(
    storage:,
    models:,
    workspace_root: root,
    mcp_runtime:,
    model_transport: transport.buffered_http(config.environment_int(
      "HARNESS3_MODEL_TIMEOUT_MS",
      300_000,
    )),
    max_output_tokens: config.environment_int(
      "HARNESS3_MAX_OUTPUT_TOKENS",
      8192,
    ),
    owner: new_id(),
  ))
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
}

pub fn stop(service: Service) -> Nil {
  mcp.stop(service.mcp_runtime)
}

pub fn create_session(
  service: Service,
  input: CreateInput,
) -> Result(Session, String) {
  use _ <- result.try(validate_create(service, input))
  use mcp_configuration_id <- result.try(select_mcp_configuration(
    service,
    input,
  ))
  use workspace <- result.try(resolve_workspace(input.workspace))
  use _ <- result.try(
    simplifile.create_directory_all(workspace)
    |> result.map_error(simplifile.describe_error),
  )
  let id = new_id()
  let agents = team(input.team_size, mcp_configuration_id)
  let metadata =
    SessionMetadata(
      id:,
      title: "New coding session",
      prompt: "",
      workspace:,
      model_id: input.model_id,
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
      case agent_group.wake_detached(loaded, service.owner, fn() { Nil }) {
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
  case agent_group_registry.force_stop(id) {
    Ok(Nil) | Error(agent_group_registry.NotFound(_)) -> {
      // Per-session profiles are node-global ETS entries; a later resume
      // re-installs them, so drop them now instead of growing forever.
      agent_profile.uninstall(
        list.map(metadata.agents, fn(spec) { profile_id(metadata.id, spec.id) }),
      )
      Ok(Nil)
    }
    Error(error) -> Error(string.inspect(error))
  }
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
  use configured <- result.try(case existing, path {
    Some(session), _ -> Ok(mcp_catalog.catalog(session))
    None, None -> Ok(mcp_catalog.new())
    None, Some(path) -> {
      use configurations <- result.try(config.load_mcp_configurations(path))
      configurations
      |> list.try_fold(mcp_catalog.new(), fn(catalog, configuration) {
        mcp_catalog.put_configuration(catalog, configuration)
      })
      |> result.map_error(fn(error) { string.inspect(error) })
    }
  })
  let desired = configured
  use runtime <- result.try(
    mcp.start(desired, config.environment, fn() { system_time(Second) }),
  )
  case persist_mcp_catalog(backend, existing, desired) {
    Error(error) -> {
      mcp.stop(runtime)
      Error(error)
    }
    Ok(Nil) -> Ok(runtime)
  }
}

pub fn add_mcp_server(
  service: Service,
  configuration_id: String,
  configuration_label: String,
  server: mcp_configuration.Server,
) -> Result(mcp_configuration.Configuration, String) {
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
  Ok(configuration)
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

fn select_mcp_configuration(
  service: Service,
  input: CreateInput,
) -> Result(Option(String), String) {
  case input.mcp_configuration_id, input.team_size >= 2 {
    Some(_), False ->
      Error("an MCP specialist requires team_size to be at least 2")
    Some(id), True ->
      mcp.configuration(service.mcp_runtime, id)
      |> result.map(fn(_) { Some(id) })
    None, False -> Ok(None)
    None, True ->
      case
        mcp_configurations(service)
        |> list.filter(fn(configuration) {
          configuration.enabled && !list.is_empty(configuration.servers)
        })
      {
        [] -> Ok(None)
        [configuration, ..] -> Ok(Some(configuration.id))
      }
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
              title: title(first_message),
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
      use plugins <- result.try(case spec.kind {
        CodingAgent ->
          Ok([collaboration, coding_plugin.workspace(metadata.workspace)])
        ResearchAgent -> Ok([collaboration])
        McpSpecialist(configuration_id) -> {
          use configuration <- result.try(mcp.configuration(
            service.mcp_runtime,
            configuration_id,
          ))
          let specialist = mcp.plugin(service.mcp_runtime, configuration)
          Ok([collaboration, specialist])
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
      "You can inspect and modify the shared workspace and run commands with the installed coding tools."
    ResearchAgent ->
      "You have no filesystem, workspace, shell, or MCP tools. Your only tool is MessageAgent, and you can use it only to report to the lead."
    McpSpecialist(configuration_id) ->
      "You are the MCP specialist for global configuration `"
      <> configuration_id
      <> "`. You have only MessageAgent (to report to the lead), mcp.list (to inspect tools from currently reachable external servers), and mcp.call (to invoke a listed tool). You have no direct filesystem or shell access."
  }
}

fn initial_states(metadata: SessionMetadata) -> List(agent.State) {
  metadata.agents
  |> list.map(fn(spec) {
    let base = agent.state(spec.id, metadata.model_id)
    agent.State(
      ..base,
      profile_id: profile_id(metadata.id, spec.id),
      status: agent.Waiting,
    )
  })
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

fn team(size: Int, mcp_configuration_id: Option(String)) -> List(AgentSpec) {
  let #(researcher_kind, researcher_role) = case mcp_configuration_id {
    Some(id) -> #(
      McpSpecialist(id),
      "MCP research specialist for global configuration `"
        <> id
        <> "`. Has MessageAgent access only to the lead plus mcp.list and mcp.call access to tools discovered from currently reachable external servers; has no filesystem or shell access.",
    )
    None -> #(
      ResearchAgent,
      "Researcher without an MCP configuration. Has no filesystem, workspace, shell, or external MCP access; can only message the lead agent.",
    )
  }
  [
    AgentSpec(
      "lead",
      "Lead engineer. Has Read, Write, and Exec access to the selected workspace and can message every subagent; owns implementation, delegation, and verification.",
      CodingAgent,
    ),
    AgentSpec("researcher", researcher_role, researcher_kind),
    AgentSpec(
      "implementer",
      "Implementation specialist. Has Read, Write, and Exec access to the selected workspace and can message only the lead agent.",
      CodingAgent,
    ),
    AgentSpec(
      "reviewer",
      "Reviewer and test engineer. Has Read, Write, and Exec access to the selected workspace and can message only the lead agent.",
      CodingAgent,
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
    #("schema_version", json.int(2)),
    #("id", json.string(metadata.id)),
    #("title", json.string(metadata.title)),
    #("prompt", json.string(metadata.prompt)),
    #("workspace", json.string(metadata.workspace)),
    #("model_id", json.string(metadata.model_id)),
    #("created_at", json.int(metadata.created_at)),
    #(
      "agents",
      json.array(metadata.agents, fn(agent) {
        let #(kind, mcp_configuration_id) = case agent.kind {
          CodingAgent -> #("coding", None)
          ResearchAgent -> #("researcher", None)
          McpSpecialist(id) -> #("mcp", Some(id))
        }
        json.object([
          #("id", json.string(agent.id)),
          #("role", json.string(agent.role)),
          #("kind", json.string(kind)),
          #(
            "mcp_configuration_id",
            json.nullable(mcp_configuration_id, json.string),
          ),
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
  use model_id <- decode.field("model_id", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use agents <- decode.field("agents", decode.list(of: agent_spec_decoder()))
  case schema {
    2 ->
      decode.success(SessionMetadata(
        id,
        title,
        prompt,
        workspace,
        model_id,
        created_at,
        agents,
      ))
    _ ->
      decode.failure(
        SessionMetadata("", "", "", "", "", 0, []),
        "unsupported session metadata schema",
      )
  }
}

fn agent_spec_decoder() -> decode.Decoder(AgentSpec) {
  use id <- decode.field("id", decode.string)
  use role <- decode.field("role", decode.string)
  use kind <- decode.field("kind", decode.string)
  use mcp_configuration_id <- decode.optional_field(
    "mcp_configuration_id",
    None,
    decode.optional(decode.string),
  )
  case kind, mcp_configuration_id {
    "coding", _ -> decode.success(AgentSpec(id, role, CodingAgent))
    "researcher", _ -> decode.success(AgentSpec(id, role, ResearchAgent))
    "mcp", Some(configuration_id) ->
      decode.success(AgentSpec(id, role, McpSpecialist(configuration_id)))
    "mcp", None ->
      decode.failure(
        AgentSpec("", "", ResearchAgent),
        "MCP agent is missing mcp_configuration_id",
      )
    _, _ ->
      decode.failure(AgentSpec("", "", ResearchAgent), "unknown agent kind")
  }
}
