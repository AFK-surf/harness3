import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import harness3/model_catalog
import simplifile

pub type ModelConfig {
  ModelConfig(
    id: String,
    provider_id: String,
    display_name: String,
    remote_id: String,
    endpoint: String,
    api_key: String,
    model_type: model_catalog.ModelType,
    context_window_tokens: Int,
    max_output_tokens: Option(Int),
  )
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

pub fn load_models(path: String) -> Result(List(ModelConfig), String) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "could not read Pi model configuration: "
      <> simplifile.describe_error(error)
    }),
  )
  use providers <- result.try(
    json.parse(body, providers_decoder())
    |> result.map_error(fn(error) {
      "could not decode Pi model configuration: " <> string.inspect(error)
    }),
  )
  use models <- result.try(
    providers
    |> dict.to_list
    |> list.try_map(fn(entry) { provider_models(entry.0, entry.1) })
    |> result.map(list.flatten),
  )
  case models {
    [] -> Error("Pi model configuration contains no supported models")
    _ -> Ok(models)
  }
}

pub fn catalog_model(model: ModelConfig) -> model_catalog.Model {
  let credential_variable =
    "HARNESS3_RUNTIME_MODEL_KEY_"
    <> {
      crypto.hash(crypto.Sha256, bit_array.from_string(model.id))
      |> bit_array.base16_encode
    }
  // Pi permits literal keys in models.json. Keep that secret process-local and
  // persist only this generated reference in the harness model catalog.
  envoy.set(credential_variable, model.api_key)
  model_catalog.Model(
    id: model.id,
    // In harness3 this is the provider-facing model name, not the UI label.
    name: model.remote_id,
    endpoint: model.endpoint,
    model_type: model.model_type,
    credentials: model_catalog.environment_variable(credential_variable),
    context_window_tokens: model.context_window_tokens,
  )
}

fn providers_decoder() -> decode.Decoder(dict.Dict(String, PiProvider)) {
  use providers <- decode.field(
    "providers",
    decode.dict(decode.string, provider_decoder()),
  )
  decode.success(providers)
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
        api_key:,
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
