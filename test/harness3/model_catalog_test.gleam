import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import harness3/llm
import harness3/model_catalog
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

fn temporary_root(label: String) -> String {
  let suffix =
    crypto.strong_random_bytes(12) |> bit_array.base64_url_encode(False)
  "/tmp/harness3-" <> label <> "-" <> suffix
}

pub fn model_catalog_persistence_and_cas_test() {
  let root = temporary_root("model-catalog-test")
  let storage = local.new(local.config(root))
  let model =
    model_catalog.Model(
      id: "primary",
      name: "gpt-test",
      endpoint: "https://example.test",
      model_type: model_catalog.OpenAIResponses,
      credentials: model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(first) =
    model_catalog.create(storage, "catalog/models", catalog)
  let assert Ok(stale) = model_catalog.resume(storage, "catalog/models")

  let second_model =
    model_catalog.Model(
      id: "secondary",
      name: "claude-test",
      endpoint: "https://anthropic.example.test",
      model_type: model_catalog.AnthropicMessages,
      credentials: model_catalog.api_key("another-secret"),
    )
  let assert Ok(updated) =
    model_catalog.put_model(model_catalog.catalog(first), second_model)
  let assert Ok(committed) = model_catalog.commit(first, updated)
  assert model_catalog.revision(model_catalog.catalog(committed)) == 1

  let assert Error(model_catalog.ConcurrentUpdate) =
    model_catalog.commit(stale, model_catalog.catalog(stale))
  let assert Ok(resumed) = model_catalog.resume(storage, "catalog/models")
  let assert Ok(found) =
    model_catalog.lookup(model_catalog.catalog(resumed), "primary")
  assert found.name == "gpt-test"
  let _provider: llm.Provider = model_catalog.provider(found)

  remove_directory(root)
}
