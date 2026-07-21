import envoy
import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm/openai_oauth
import harness3/model_catalog
import harness3/plugin/mcp/configuration as mcp_configuration
import simplifile

pub type ModelConfig {
  ModelConfig(
    id: String,
    provider_id: String,
    display_name: String,
    remote_id: String,
    endpoint: String,
    credentials: ModelCredentials,
    model_type: model_catalog.ModelType,
    context_window_tokens: Int,
    max_output_tokens: Option(Int),
  )
}

pub type ModelCredentials {
  ApiKey(String)
  /// Pi's ChatGPT OAuth login, resolved from the auth file on every request.
  OpenAIOAuthFile(path: String)
}

type PiModel {
  PiModel(
    id: String,
    name: String,
    context_window_tokens: Int,
    max_tokens: Option(Int),
  )
}

type PiProvider {
  PiProvider(
    name: String,
    base_url: String,
    api: String,
    api_key: String,
    models: List(PiModel),
  )
}

pub fn environment(name: String) -> Result(String, Nil) {
  envoy.get(name)
}

pub fn environment_or(name: String, fallback: String) -> String {
  environment(name) |> result.unwrap(fallback)
}

pub fn environment_int(name: String, fallback: Int) -> Int {
  case environment(name) {
    Ok(value) -> int.parse(value) |> result.unwrap(fallback)
    Error(_) -> fallback
  }
}

pub fn models_path() -> String {
  let home = environment_or("HOME", ".")
  environment_or("HARNESS3_MODELS_PATH", home <> "/.pi/agent/models.json")
}

pub fn pi_auth_path() -> String {
  let home = environment_or("HOME", ".")
  environment_or("HARNESS3_PI_AUTH_PATH", home <> "/.pi/agent/auth.json")
}

pub fn pi_models_store_path() -> String {
  let home = environment_or("HOME", ".")
  environment_or(
    "HARNESS3_PI_MODELS_STORE_PATH",
    home <> "/.pi/agent/models-store.json",
  )
}

pub fn mcp_configurations_path() -> Result(Option(String), String) {
  case environment("HARNESS3_MCP_CONFIG_PATH") {
    Error(_) -> Ok(None)
    Ok(path) ->
      case filepath.is_absolute(path) {
        True -> Ok(Some(path))
        False -> Error("HARNESS3_MCP_CONFIG_PATH must be absolute")
      }
  }
}

pub fn load_mcp_configurations(
  path: String,
) -> Result(List(mcp_configuration.Configuration), String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "could not read MCP configuration: " <> simplifile.describe_error(error)
    }),
  )
  use configurations <- result.try(
    json.parse(body, mcp_configurations_decoder())
    |> result.map_error(fn(error) {
      "could not decode MCP configuration: " <> string.inspect(error)
    }),
  )
  configurations
  |> list.try_each(mcp_configuration.validate)
  |> result.map_error(fn(error) { string.inspect(error) })
  |> result.map(fn(_) { configurations })
}

pub fn load_models(path: String) -> Result(List(ModelConfig), String) {
  use custom <- result.try(load_pi_models(path))
  let oauth = load_oauth_models(pi_auth_path(), pi_models_store_path())
  case list.append(custom, oauth) {
    [] ->
      Error(
        "no models configured: "
        <> path
        <> " has no supported providers and no OpenAI OAuth credentials were found (log in with Pi first)",
      )
    models -> Ok(models)
  }
}

fn load_pi_models(path: String) -> Result(List(ModelConfig), String) {
  case simplifile.read(path) {
    // A missing file just means no custom providers — an OAuth-only Pi
    // installation is valid. Malformed content stays a hard error.
    Error(simplifile.Enoent) -> Ok([])
    Error(error) ->
      Error(
        "could not read Pi model configuration: "
        <> simplifile.describe_error(error),
      )
    Ok(body) -> {
      use providers <- result.try(
        json.parse(body, providers_decoder())
        |> result.map_error(fn(error) {
          "could not decode Pi model configuration: " <> string.inspect(error)
        }),
      )
      providers
      |> dict.to_list
      |> list.try_map(fn(entry) { provider_models(entry.0, entry.1) })
      |> result.map(list.flatten)
    }
  }
}

/// OpenAI models driven by Pi's ChatGPT OAuth login. The model list comes
/// from Pi's models store (its cache of what the account can use); without
/// it, a snapshot of Pi's built-in registry is used. Any problem — no auth
/// file, no openai-codex entry, undecodable store — simply yields no OAuth
/// models rather than failing startup, so API-key providers keep working.
fn load_oauth_models(
  auth_path: String,
  store_path: String,
) -> List(ModelConfig) {
  case openai_oauth.load(auth_path) {
    Error(_) -> []
    Ok(_) -> {
      let models = case read_store_models(store_path) {
        Ok(models) -> models
        Error(_) -> builtin_codex_models()
      }
      list.map(models, fn(model) {
        let #(id, name, context_window, max_tokens) = model
        ModelConfig(
          id: openai_oauth.provider_id <> "/" <> id,
          provider_id: openai_oauth.provider_id,
          display_name: name <> " · OpenAI Codex",
          remote_id: id,
          endpoint: codex_base_url,
          credentials: OpenAIOAuthFile(auth_path),
          model_type: model_catalog.OpenAICodexResponses,
          context_window_tokens: context_window,
          max_output_tokens: Some(max_tokens),
        )
      })
    }
  }
}

const codex_base_url = "https://chatgpt.com/backend-api"

/// Pi's models-store.json: a per-provider cache of remotely confirmed models.
/// Only the openai-codex entry is read here.
fn read_store_models(
  path: String,
) -> Result(List(#(String, String, Int, Int)), String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(simplifile.describe_error),
  )
  use store <- result.try(
    json.parse(body, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use entry <- result.try(
    dict.get(store, openai_oauth.provider_id)
    |> result.map_error(fn(_) { "no openai-codex entry in models store" }),
  )
  decode.run(entry, {
    use models <- decode.field(
      "models",
      decode.list(of: store_model_decoder()),
    )
    decode.success(models)
  })
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn store_model_decoder() -> decode.Decoder(#(String, String, Int, Int)) {
  use id <- decode.field("id", decode.string)
  use name <- decode.optional_field("name", id, decode.string)
  use context_window <- decode.field("contextWindow", decode.int)
  use max_tokens <- decode.optional_field("maxTokens", 128_000, decode.int)
  decode.success(#(id, name, context_window, max_tokens))
}

/// Snapshot of Pi's generated openai-codex registry (packages/ai
/// openai-codex.models.ts), used only when no models store exists.
fn builtin_codex_models() -> List(#(String, String, Int, Int)) {
  [
    #("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark", 128_000, 128_000),
    #("gpt-5.4", "GPT-5.4", 272_000, 128_000),
    #("gpt-5.4-mini", "GPT-5.4 mini", 272_000, 128_000),
    #("gpt-5.5", "GPT-5.5", 272_000, 128_000),
    #("gpt-5.6-luna", "GPT-5.6 Luna", 372_000, 128_000),
    #("gpt-5.6-sol", "GPT-5.6 Sol", 372_000, 128_000),
    #("gpt-5.6-terra", "GPT-5.6 Terra", 372_000, 128_000),
  ]
}

pub fn catalog_model(model: ModelConfig) -> model_catalog.Model {
  model_catalog.Model(
    id: model.id,
    // In harness3 this is the provider-facing model name, not the UI label.
    name: model.remote_id,
    endpoint: model.endpoint,
    model_type: model.model_type,
    credentials: catalog_credentials(model),
    context_window_tokens: model.context_window_tokens,
    max_output_tokens: model.max_output_tokens,
  )
}

fn catalog_credentials(model: ModelConfig) -> model_catalog.Credentials {
  case model.credentials {
    OpenAIOAuthFile(path) -> model_catalog.openai_oauth_file(path)
    ApiKey(api_key) -> {
      let credential_variable =
        "HARNESS3_RUNTIME_MODEL_KEY_"
        <> {
          crypto.hash(crypto.Sha256, bit_array.from_string(model.id))
          |> bit_array.base16_encode
        }
      // Pi permits literal keys in models.json. Keep that secret
      // process-local and persist only this generated reference in the
      // harness model catalog.
      envoy.set(credential_variable, api_key)
      model_catalog.environment_variable(credential_variable)
    }
  }
}

fn providers_decoder() -> decode.Decoder(dict.Dict(String, PiProvider)) {
  use providers <- decode.field(
    "providers",
    decode.dict(decode.string, provider_decoder()),
  )
  decode.success(providers)
}

fn mcp_configurations_decoder() -> decode.Decoder(
  List(mcp_configuration.Configuration),
) {
  use configurations <- decode.field(
    "configurations",
    decode.list(of: mcp_configuration.decoder()),
  )
  decode.success(configurations)
}

fn provider_decoder() -> decode.Decoder(PiProvider) {
  use name <- decode.field("name", decode.string)
  use base_url <- decode.field("baseUrl", decode.string)
  use api <- decode.field("api", decode.string)
  use api_key <- decode.field("apiKey", decode.string)
  use models <- decode.field("models", decode.list(of: model_decoder()))
  decode.success(PiProvider(name, base_url, api, api_key, models))
}

fn model_decoder() -> decode.Decoder(PiModel) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use context_window_tokens <- decode.field("contextWindow", decode.int)
  use max_tokens <- decode.optional_field(
    "maxTokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(PiModel(id, name, context_window_tokens, max_tokens))
}

fn provider_models(
  provider_id: String,
  provider: PiProvider,
) -> Result(List(ModelConfig), String) {
  use model_type <- result.try(model_type(provider.api))
  use api_key <- result.try(resolve_api_key(provider.api_key))
  Ok(
    provider.models
    |> list.map(fn(model) {
      ModelConfig(
        id: provider_id <> "/" <> model.id,
        provider_id:,
        display_name: model.name <> " · " <> provider.name,
        remote_id: model.id,
        endpoint: provider.base_url,
        credentials: ApiKey(api_key),
        model_type:,
        context_window_tokens: model.context_window_tokens,
        max_output_tokens: model.max_tokens,
      )
    }),
  )
}

fn model_type(api: String) -> Result(model_catalog.ModelType, String) {
  case api {
    "openai-completions" | "openai-chat-completions" ->
      Ok(model_catalog.OpenAIChatCompletions)
    "openai-responses" -> Ok(model_catalog.OpenAIResponses)
    "anthropic-messages" -> Ok(model_catalog.AnthropicMessages)
    other -> Error("unsupported Pi provider API: " <> other)
  }
}

fn resolve_api_key(value: String) -> Result(String, String) {
  case value {
    "$" <> variable ->
      environment(variable)
      |> result.map_error(fn(_) {
        "missing API key environment variable " <> variable
      })
    value -> Ok(value)
  }
}
