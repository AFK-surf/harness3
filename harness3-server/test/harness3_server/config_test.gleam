import envoy
import gleam/bit_array
import gleam/crypto
import gleam/list
import harness3/agent
import harness3/agent_group
import harness3/model_catalog
import harness3_server/config
import harness3_server/service
import simplifile

fn temporary_root(label: String) -> String {
  "/tmp/"
  <> label
  <> "-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn models_json() -> String {
  "{\"providers\":{\"test\":{\"name\":\"Test Provider\",\"baseUrl\":\"https://example.test/api/v3\",\"api\":\"openai-completions\",\"apiKey\":\"test-secret\",\"models\":[{\"id\":\"model-1\",\"name\":\"Model One\",\"contextWindow\":32768,\"maxTokens\":4096}]}}}"
}

pub fn pi_models_load_and_catalog_restart_is_idempotent_test() {
  let root = temporary_root("harness3-server-config-test")
  let models_path = root <> "/models.json"
  let data_path = root <> "/data"
  let workspace = root <> "/workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) =
    simplifile.write(to: models_path, contents: models_json())

  let assert Ok(models) = config.load_models(models_path)
  let assert [model] = models
  assert model.id == "test/model-1"
  assert model.remote_id == "model-1"
  assert model.display_name == "Model One · Test Provider"
  assert model.model_type == model_catalog.OpenAIChatCompletions
  assert model.context_window_tokens == 32_768

  envoy.set("HARNESS3_MODELS_PATH", models_path)
  envoy.set("HARNESS3_DATA_DIR", data_path)
  envoy.set("HARNESS3_WORKSPACE_ROOT", workspace)
  envoy.set("HARNESS3_STORAGE", "local")
  let assert Ok(first) = service.start()
  let assert Ok(second) = service.start()
  assert list.length(service.models(first)) == 1
  assert service.workspace_root(second) == workspace
  assert service.resolve_workspace("nested")
    == Error("workspace path must be absolute")
  let outside = root <> "-outside"
  assert service.resolve_workspace(outside) == Ok(outside)

  let assert Ok(service.Session(metadata, group)) =
    service.create_session(
      second,
      service.CreateInput("test/model-1", workspace, 2),
    )
  assert metadata.title == "New coding session"
  assert metadata.prompt == ""
  assert group.execution == agent_group.Idle
  assert list.length(group.agents) == 2
  assert list.all(group.agents, fn(state) {
    state.status == agent.Waiting && list.is_empty(state.messages)
  })

  envoy.unset("HARNESS3_MODELS_PATH")
  envoy.unset("HARNESS3_DATA_DIR")
  envoy.unset("HARNESS3_WORKSPACE_ROOT")
  envoy.unset("HARNESS3_STORAGE")
  let assert Ok(Nil) = simplifile.delete(root)
}
