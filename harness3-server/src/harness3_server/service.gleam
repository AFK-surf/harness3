import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import harness3/agent
import harness3/agent_group
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/model_catalog
import harness3/plugin
import harness3/storage.{type Storage}
import harness3_server/coding_plugin
import harness3_server/config.{type ModelConfig}
import harness3_server/storage_config
import harness3_server/transport
import simplifile

const catalog_key = "harness3-server/catalog"

const sessions_prefix = "harness3-server/sessions/"

const lease_seconds = 30

const minimum_lifetime_milliseconds = 5000

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

pub type AgentSpec {
  AgentSpec(id: String, role: String)
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
  CreateInput(model_id: String, workspace: String, team_size: Int)
}

pub opaque type Service {
  Service(
    storage: Storage,
    models: List(ModelConfig),
    workspace_root: String,
    model_transport: agent.ModelTransport,
    max_output_tokens: Int,
  )
}

pub fn start() -> Result(Service, String) {
  use storage <- result.try(storage_config.from_environment())
  use models <- result.try(config.load_models(config.models_path()))
  use root <- result.try(resolve_workspace_root())
  use _ <- result.try(install_catalog(storage, models))
  Ok(Service(
    storage:,
    models:,
    workspace_root: root,
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

pub fn models(service: Service) -> List(ModelConfig) {
  service.models
}

pub fn workspace_root(service: Service) -> String {
  service.workspace_root
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
  let agents = team(input.team_size)
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
  let group_config = group_config(service, metadata)
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
      let config = group_config(service, metadata)
      use loaded <- result.try(
        agent_group.resume(config)
        |> result.map_error(fn(error) {
          "could not resume session: " <> string.inspect(error)
        }),
      )
      use group <- result.try(
        agent_group.wake(loaded)
        |> result.map_error(fn(error) {
          "could not wake session: " <> string.inspect(error)
        }),
      )
      agent_group.send_message(group, agent_id, message)
      |> result.map_error(fn(error) { string.inspect(error) })
    }
    Error(error) -> Error(string.inspect(error))
  }
}

pub fn stop_session(service: Service, id: String) -> Result(Nil, String) {
  use _ <- result.try(load_metadata(service, id))
  case agent_group_registry.force_stop(id) {
    Ok(Nil) | Error(agent_group_registry.NotFound(_)) -> Ok(Nil)
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
  agent_group.load(group_config(service, metadata))
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
) -> agent_group.Config {
  let profiles =
    list.map(metadata.agents, fn(spec) {
      let teammates =
        metadata.agents
        |> list.map(fn(item) { item.id })
        |> list.filter(fn(id) { id != spec.id })
      let coding =
        coding_plugin.new(
          metadata.id,
          spec.id,
          spec.role,
          metadata.workspace,
          teammates,
        )
      let assert Ok(registry) = plugin.registry([coding])
      agent_profile.AgentProfile(
        id: profile_id(metadata.id, spec.id),
        registry:,
        transport: service.model_transport,
        max_output_tokens: Some(service.max_output_tokens),
        reasoning_effort: None,
        observe: fn(_) { Ok(Nil) },
      )
    })
  agent_group.Config(
    storage: service.storage,
    object_key: group_key(metadata.id),
    profiles:,
    lease_duration_seconds: lease_seconds,
    minimum_lifetime_milliseconds: minimum_lifetime_milliseconds,
  )
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

fn team(size: Int) -> List(AgentSpec) {
  [
    AgentSpec(
      "lead",
      "Lead engineer. Own the task, inspect the repository, implement the main solution, delegate bounded work, and verify the final result.",
    ),
    AgentSpec(
      "researcher",
      "Repository researcher. Investigate architecture, constraints, and likely failure modes; send concise findings to the lead.",
    ),
    AgentSpec(
      "implementer",
      "Implementation specialist. Take a clearly assigned portion, make focused edits, run relevant tests, and report changed files.",
    ),
    AgentSpec(
      "reviewer",
      "Reviewer and test engineer. Inspect the current work for correctness, run tests, identify regressions, and suggest precise fixes.",
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
    #("schema_version", json.int(1)),
    #("id", json.string(metadata.id)),
    #("title", json.string(metadata.title)),
    #("prompt", json.string(metadata.prompt)),
    #("workspace", json.string(metadata.workspace)),
    #("model_id", json.string(metadata.model_id)),
    #("created_at", json.int(metadata.created_at)),
    #(
      "agents",
      json.array(metadata.agents, fn(agent) {
        json.object([
          #("id", json.string(agent.id)),
          #("role", json.string(agent.role)),
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
    1 ->
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
  decode.success(AgentSpec(id, role))
}
