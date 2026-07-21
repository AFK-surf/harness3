import envoy
import gleam/bit_array
import gleam/crypto
import gleam/list
import harness3/agent_profile
import harness3_server/service
import simplifile

fn models_json() -> String {
  "{\"providers\":{\"test\":{\"name\":\"Test Provider\",\"baseUrl\":\"https://example.test/api/v3\",\"api\":\"openai-completions\",\"apiKey\":\"test-secret\",\"models\":[{\"id\":\"model-1\",\"name\":\"Model One\",\"contextWindow\":32768,\"maxTokens\":4096}]}}}"
}

fn service_environment(root: String) -> Nil {
  let models_path = root <> "/models.json"
  let workspace = root <> "/workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) =
    simplifile.write(to: models_path, contents: models_json())
  envoy.set("HARNESS3_MODELS_PATH", models_path)
  envoy.set("HARNESS3_PI_AUTH_PATH", root <> "/missing-auth.json")
  envoy.set("HARNESS3_PI_MODELS_STORE_PATH", root <> "/missing-store.json")
  envoy.set("HARNESS3_DATA_DIR", root <> "/data")
  envoy.set("HARNESS3_WORKSPACE_ROOT", workspace)
  envoy.set("HARNESS3_STORAGE", "local")
  envoy.unset("HARNESS3_MCP_CONFIG_PATH")
  Nil
}

/// Profiles are static node capabilities: registered at boot, before any
/// session is touched, so the recovery RPC path (`resume_registered`) can
/// place any group on this node.
pub fn boot_installs_kind_profiles_test() {
  let root =
    "/tmp/harness3-profile-install-test-"
    <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
  service_environment(root)

  let assert Ok(running) = service.start()

  // The three kind profiles are registered without any session having been
  // opened over HTTP.
  let assert Ok(kind_profiles) =
    agent_profile.profiles([
      "coding-workspace",
      "isolated-researcher",
      "mcp-researcher",
    ])
  assert list.length(kind_profiles) == 3

  service.stop(running)
  envoy.unset("HARNESS3_MCP_CONFIG_PATH")
  envoy.unset("HARNESS3_MODELS_PATH")
  envoy.unset("HARNESS3_PI_AUTH_PATH")
  envoy.unset("HARNESS3_PI_MODELS_STORE_PATH")
  envoy.unset("HARNESS3_DATA_DIR")
  envoy.unset("HARNESS3_WORKSPACE_ROOT")
  envoy.unset("HARNESS3_STORAGE")
  let assert Ok(Nil) = simplifile.delete(root)
}
