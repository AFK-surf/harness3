import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import harness3/llm.{type Provider}
import harness3/llm/anthropic_messages
import harness3/llm/openai_chat_completions
import harness3/llm/openai_responses
import harness3/storage.{type Storage, type VersionToken}

pub type ModelType {
  OpenAIChatCompletions
  OpenAIResponses
  AnthropicMessages
}

pub opaque type Credentials {
  ApiKey(value: String)
  EnvironmentVariable(name: String)
}

/// Stores an API key directly in the catalog. Prefer `environment_variable`
/// for durable or shared storage backends.
pub fn api_key(value: String) -> Credentials {
  ApiKey(value)
}

/// Stores only an environment-variable name in the durable catalog. The key
/// is resolved on the node each time a provider is constructed.
pub fn environment_variable(name: String) -> Credentials {
  EnvironmentVariable(name)
}

pub type Model {
  Model(
    id: String,
    name: String,
    endpoint: String,
    model_type: ModelType,
    credentials: Credentials,
    context_window_tokens: Int,
    /// Per-model output-token cap sent with every request. `None` leaves the
    /// provider default (note the Anthropic adapter then falls back to its
    /// required-field minimum of 1024).
    max_output_tokens: Option(Int),
  )
}

pub type Catalog {
  Catalog(revision: Int, models: List(Model))
}

pub fn new() -> Catalog {
  Catalog(0, [])
}

pub type Error {
  InvalidCatalog(reason: String)
  DuplicateModel(id: String)
  UnknownModel(id: String)
  DecodeFailed(reason: String)
  StorageFailed(error: storage.Error)
  ConcurrentUpdate
}

pub opaque type Session {
  Session(
    storage: Storage,
    key: String,
    catalog: Catalog,
    version: VersionToken,
  )
}

pub fn create(
  storage: Storage,
  key: String,
  catalog: Catalog,
) -> Result(Session, Error) {
  use _ <- result.try(validate(catalog))
  let body = encode(catalog) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case storage.put(storage, key, body, storage.IfAbsent) {
      Ok(metadata) -> Ok(metadata)
      Error(storage.PreconditionFailed(_)) -> confirm_write(storage, key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(Session(storage, key, catalog, metadata.version))
}

pub fn resume(storage: Storage, key: String) -> Result(Session, Error) {
  use object <- result.try(
    storage.get(storage, key) |> result.map_error(StorageFailed),
  )
  use body <- result.try(
    bit_array.to_string(object.body)
    |> result.map_error(fn(_) { DecodeFailed("catalog is not UTF-8 JSON") }),
  )
  use catalog <- result.try(
    json.parse(body, catalog_decoder())
    |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) }),
  )
  use _ <- result.try(validate_loaded(catalog))
  Ok(Session(storage, key, catalog, object.metadata.version))
}

pub fn catalog(session: Session) -> Catalog {
  session.catalog
}

pub fn revision(catalog: Catalog) -> Int {
  catalog.revision
}

pub fn lookup(catalog: Catalog, id: String) -> Result(Model, Error) {
  list.find(catalog.models, fn(model) { model.id == id })
  |> result.map_error(fn(_) { UnknownModel(id) })
}

pub fn put_model(catalog: Catalog, model: Model) -> Result(Catalog, Error) {
  use _ <- result.try(validate_model(model))
  let models = case list.any(catalog.models, fn(item) { item.id == model.id }) {
    True ->
      list.map(catalog.models, fn(item) {
        case item.id == model.id {
          True -> model
          False -> item
        }
      })
    False -> list.append(catalog.models, [model])
  }
  Ok(Catalog(..catalog, models: models))
}

pub fn remove_model(catalog: Catalog, id: String) -> Result(Catalog, Error) {
  case list.any(catalog.models, fn(model) { model.id == id }) {
    False -> Error(UnknownModel(id))
    True ->
      Ok(
        Catalog(
          ..catalog,
          models: list.filter(catalog.models, fn(model) { model.id != id }),
        ),
      )
  }
}

pub fn commit(session: Session, catalog: Catalog) -> Result(Session, Error) {
  let next = Catalog(..catalog, revision: session.catalog.revision + 1)
  use _ <- result.try(validate(next))
  let body = encode(next) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case
      storage.put(
        session.storage,
        session.key,
        body,
        storage.IfUnchanged(session.version),
      )
    {
      Ok(metadata) -> Ok(metadata)
      Error(storage.PreconditionFailed(_)) ->
        confirm_write(session.storage, session.key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(Session(session.storage, session.key, next, metadata.version))
}

/// Confirms whether a conditional write that reported `PreconditionFailed`
/// actually succeeded (applied remotely, response lost, retry observed its own
/// object). Only an exact body match counts as our write.
fn confirm_write(
  backend: Storage,
  key: String,
  intended_body: BitArray,
) -> Result(storage.Metadata, Error) {
  case storage.get(backend, key) {
    Ok(object) if object.body == intended_body -> Ok(object.metadata)
    Ok(_) | Error(storage.PreconditionFailed(_)) -> Error(ConcurrentUpdate)
    Error(error) -> Error(StorageFailed(error))
  }
}

fn storage_error(error: storage.Error) -> Error {
  case error {
    storage.PreconditionFailed(_) -> ConcurrentUpdate
    error -> StorageFailed(error)
  }
}

pub fn provider(model: Model) -> Provider {
  let api_key = resolve_credentials(model.credentials)
  case model.model_type {
    OpenAIChatCompletions ->
      openai_chat_completions.new(openai_chat_completions.Config(
        api_key,
        model.endpoint,
        openai_chat_completions.MaxCompletionTokens,
        openai_chat_completions.OmitReasoning,
      ))
    OpenAIResponses ->
      openai_responses.new(openai_responses.Config(api_key, model.endpoint))
    AnthropicMessages ->
      anthropic_messages.new(anthropic_messages.Config(
        api_key,
        model.endpoint,
        "2023-06-01",
      ))
  }
}

pub fn validate(catalog: Catalog) -> Result(Nil, Error) {
  use _ <- result.try(list.try_each(catalog.models, validate_model))
  catalog.models
  |> list.try_fold([], fn(ids, model) {
    case list.contains(ids, model.id) {
      True -> Error(DuplicateModel(model.id))
      False -> Ok([model.id, ..ids])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_model(model: Model) -> Result(Nil, Error) {
  let secret = credential_value(model.credentials)
  case
    string.trim(model.id),
    string.trim(model.name),
    string.trim(model.endpoint),
    string.trim(secret),
    model.context_window_tokens
  {
    "", _, _, _, _ -> Error(InvalidCatalog("model id cannot be empty"))
    _, "", _, _, _ -> Error(InvalidCatalog("model name cannot be empty"))
    _, _, "", _, _ -> Error(InvalidCatalog("model endpoint cannot be empty"))
    _, _, _, "", _ -> Error(InvalidCatalog("model credentials cannot be empty"))
    _, _, _, _, tokens if tokens <= 0 ->
      Error(InvalidCatalog("model context window must be positive"))
    _, _, _, _, _ ->
      case model.max_output_tokens {
        option.Some(tokens) if tokens <= 0 ->
          Error(InvalidCatalog("model max output tokens must be positive"))
        _ -> Ok(Nil)
      }
  }
}

// Catalogs written before context windows were added decode with zero so an
// owning application can resume and replace them from its authoritative model
// configuration. New and committed catalogs must always use positive values.
fn validate_loaded(catalog: Catalog) -> Result(Nil, Error) {
  use _ <- result.try(
    catalog.models
    |> list.try_each(fn(model) {
      let secret = credential_value(model.credentials)
      case
        string.trim(model.id),
        string.trim(model.name),
        string.trim(model.endpoint),
        string.trim(secret),
        model.context_window_tokens
      {
        "", _, _, _, _ -> Error(InvalidCatalog("model id cannot be empty"))
        _, "", _, _, _ -> Error(InvalidCatalog("model name cannot be empty"))
        _, _, "", _, _ ->
          Error(InvalidCatalog("model endpoint cannot be empty"))
        _, _, _, "", _ ->
          Error(InvalidCatalog("model credentials cannot be empty"))
        _, _, _, _, tokens if tokens < 0 ->
          Error(InvalidCatalog("model context window cannot be negative"))
        _, _, _, _, _ -> Ok(Nil)
      }
    }),
  )
  catalog.models
  |> list.try_fold([], fn(ids, model) {
    case list.contains(ids, model.id) {
      True -> Error(DuplicateModel(model.id))
      False -> Ok([model.id, ..ids])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn encode(catalog: Catalog) -> json.Json {
  json.object([
    #("schema_version", json.int(2)),
    #("revision", json.int(catalog.revision)),
    #("models", json.array(catalog.models, encode_model)),
  ])
}

fn encode_model(model: Model) -> json.Json {
  let #(credential_type, value) = case model.credentials {
    ApiKey(value) -> #("api_key", value)
    EnvironmentVariable(name) -> #("environment_variable", name)
  }
  json.object([
    #("id", json.string(model.id)),
    #("name", json.string(model.name)),
    #("endpoint", json.string(model.endpoint)),
    #("type", json.string(model_type_name(model.model_type))),
    #("context_window_tokens", json.int(model.context_window_tokens)),
    #("max_output_tokens", json.nullable(model.max_output_tokens, json.int)),
    #(
      "credentials",
      json.object([
        #("type", json.string(credential_type)),
        #("value", json.string(value)),
      ]),
    ),
  ])
}

fn model_type_name(model_type: ModelType) -> String {
  case model_type {
    OpenAIChatCompletions -> "openai_chat_completions"
    OpenAIResponses -> "openai_responses"
    AnthropicMessages -> "anthropic_messages"
  }
}

fn model_type_decoder() -> decode.Decoder(ModelType) {
  decode.string
  |> decode.then(fn(value) {
    case value {
      "openai_chat_completions" -> decode.success(OpenAIChatCompletions)
      "openai_responses" -> decode.success(OpenAIResponses)
      "anthropic_messages" -> decode.success(AnthropicMessages)
      _ -> decode.failure(OpenAIResponses, "unsupported model type")
    }
  })
}

fn credentials_decoder() -> decode.Decoder(Credentials) {
  use kind <- decode.field("type", decode.string)
  use value <- decode.field("value", decode.string)
  case kind {
    "api_key" -> decode.success(ApiKey(value))
    "environment_variable" -> decode.success(EnvironmentVariable(value))
    _ -> decode.failure(ApiKey(""), "unsupported credential type")
  }
}

fn credential_value(credentials: Credentials) -> String {
  case credentials {
    ApiKey(value) | EnvironmentVariable(value) -> value
  }
}

fn resolve_credentials(credentials: Credentials) -> String {
  case credentials {
    ApiKey(value) -> value
    EnvironmentVariable(name) -> envoy.get(name) |> result.unwrap("")
  }
}

fn model_decoder() -> decode.Decoder(Model) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use endpoint <- decode.field("endpoint", decode.string)
  use model_type <- decode.field("type", model_type_decoder())
  use credentials <- decode.field("credentials", credentials_decoder())
  use context_window_tokens <- decode.optional_field(
    "context_window_tokens",
    0,
    decode.int,
  )
  use max_output_tokens <- decode.optional_field(
    "max_output_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(Model(
    id,
    name,
    endpoint,
    model_type,
    credentials,
    context_window_tokens,
    max_output_tokens,
  ))
}

fn catalog_decoder() -> decode.Decoder(Catalog) {
  use schema <- decode.field("schema_version", decode.int)
  use revision <- decode.field("revision", decode.int)
  use models <- decode.field("models", decode.list(of: model_decoder()))
  case schema {
    1 | 2 -> decode.success(Catalog(revision, models))
    _ -> decode.failure(Catalog(0, []), "unsupported catalog schema")
  }
}
