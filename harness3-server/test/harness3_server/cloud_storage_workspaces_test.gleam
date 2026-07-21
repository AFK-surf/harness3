import envoy
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/agent_profile
import harness3/llm
import harness3/plugin
import harness3/storage
import harness3/storage/local
import harness3_server/cloud_storage_workspaces as storage_workspaces
import harness3_server/service
import simplifile

/// The wake RPC routes through the recovery leader, which is elected
/// asynchronously after service start; a request racing the first election
/// fails on the missing leader lock. Retry until the election has settled.
fn request_compaction_after_election(
  running: service.Service,
  session_id: String,
  agent_id: String,
  attempts: Int,
) -> Result(Int, String) {
  case service.request_compaction(running, session_id, agent_id) {
    Error(error) if attempts > 1 ->
      case string.contains(error, "recovery-leader") {
        True -> {
          process.sleep(100)
          request_compaction_after_election(
            running,
            session_id,
            agent_id,
            attempts - 1,
          )
        }
        False -> Error(error)
      }
    outcome -> outcome
  }
}

fn temporary_root(label: String) -> String {
  "/tmp/"
  <> label
  <> "-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn models_json() -> String {
  "{\"providers\":{\"test\":{\"name\":\"Test Provider\",\"baseUrl\":\"https://example.test/api/v3\",\"api\":\"openai-completions\",\"apiKey\":\"test-secret\",\"models\":[{\"id\":\"model-1\",\"name\":\"Model One\",\"contextWindow\":32768,\"maxTokens\":4096}]}}}"
}

pub fn workspace_validation_test() {
  let catalog = storage_workspaces.new()
  let put = fn(workspace) {
    storage_workspaces.put_workspace(catalog, workspace)
  }

  // ID rules mirror the management UI: non-empty, URL-safe characters only.
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("", "Label", "team/a"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("bad id", "Label", "team/a"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("bad/id", "Label", "team/a"))

  // Labels are required and trimmed; prefixes must be safe relative paths.
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "  ", "team/a"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", ""))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", "/absolute"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", "../outside"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", "a//b"))

  // Harness control-plane namespaces are off limits, with or without the
  // trailing slash, while lookalike names stay allowed.
  let assert Error(storage_workspaces.InvalidWorkspace(reason)) =
    put(storage_workspaces.Workspace("alpha", "Label", "cluster"))
  assert string.contains(reason, "harness-internal")
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", "cluster/locks"))
  let assert Error(storage_workspaces.InvalidWorkspace(_)) =
    put(storage_workspaces.Workspace("alpha", "Label", "harness3-server/groups"))
  let assert Ok(catalog) =
    put(storage_workspaces.Workspace("alpha", " Alpha ", "team/alpha"))
  let assert Ok(catalog) =
    storage_workspaces.put_workspace(
      catalog,
      storage_workspaces.Workspace("beta", "Beta", "clusters/shared/"),
    )

  // Workspaces are stored normalized: trimmed label, slash-terminated prefix.
  let assert Ok(alpha) = storage_workspaces.lookup(catalog, "alpha")
  assert alpha.label == "Alpha"
  assert alpha.prefix == "team/alpha/"
  let assert Ok(beta) = storage_workspaces.lookup(catalog, "beta")
  assert beta.prefix == "clusters/shared/"
  let assert Error(storage_workspaces.UnknownWorkspace("missing")) =
    storage_workspaces.lookup(catalog, "missing")

  assert storage_workspaces.default_prefix("team-a")
    == "plugins/cloud_storage/workspaces/team-a/objects/"
}

pub fn catalog_round_trips_through_storage_with_cas_test() {
  let root = temporary_root("harness3-workspaces-catalog-test")
  let backend = local.new(local.config(root))
  let key = "test/workspaces-catalog"

  let assert Error(storage_workspaces.StorageFailed(storage.NotFound(_))) =
    storage_workspaces.resume(backend, key)

  let workspace = storage_workspaces.Workspace("alpha", "Alpha", "team/alpha/")
  let assert Ok(session) =
    storage_workspaces.create(backend, key, storage_workspaces.new())
  let assert Ok(next) =
    storage_workspaces.put_workspace(
      storage_workspaces.catalog(session),
      workspace,
    )
  let assert Ok(committed) = storage_workspaces.commit(session, next)

  let assert Ok(resumed) = storage_workspaces.resume(backend, key)
  assert storage_workspaces.workspaces(storage_workspaces.catalog(resumed))
    == [workspace]

  // A stale session loses the CAS race instead of overwriting the winner.
  let assert Ok(winner) =
    storage_workspaces.remove_workspace(
      storage_workspaces.catalog(resumed),
      "alpha",
    )
  let assert Ok(_) = storage_workspaces.commit(resumed, winner)
  let assert Error(storage_workspaces.ConcurrentUpdate) =
    storage_workspaces.commit(committed, next)

  let assert Ok(Nil) = simplifile.delete(root)
}

fn start_service(root: String) -> service.Service {
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
  let assert Ok(started) = service.start()
  started
}

fn unset_service_environment() -> Nil {
  envoy.unset("HARNESS3_MCP_CONFIG_PATH")
  envoy.unset("HARNESS3_MODELS_PATH")
  envoy.unset("HARNESS3_PI_AUTH_PATH")
  envoy.unset("HARNESS3_PI_MODELS_STORE_PATH")
  envoy.unset("HARNESS3_DATA_DIR")
  envoy.unset("HARNESS3_WORKSPACE_ROOT")
  envoy.unset("HARNESS3_STORAGE")
}

/// Activates the lead agent's registered profile the way a real worker
/// would: hosted on the session's durable group identity, so the generic
/// plugins resolve the session's workspace and storage scope from attributes.
fn lead_runtime(
  running: service.Service,
  session_id: String,
) -> plugin.Runtime {
  let assert Ok(sessions) = service.list_sessions(running)
  let assert Ok(service.Session(group:, ..)) =
    list.find(sessions, fn(session) {
      let service.Session(metadata:, ..) = session
      metadata.id == session_id
    })
  let assert Ok(lead) =
    list.find(group.agents, fn(agent) { agent.id == "lead" })
  let assert Ok([lead_profile]) = agent_profile.profiles([lead.profile_id])
  let assert Ok(runtime) =
    plugin.activate_hosted(
      lead_profile.registry,
      plugin.empty_states(),
      plugin.Host(
        group_id: group.id,
        agent_id: lead.id,
        agent_attributes: lead.attributes,
        group_attributes: group.attributes,
        peers: [],
      ),
    )
  runtime
}

fn storage_write(
  runtime: plugin.Runtime,
  key: String,
  content: String,
) -> plugin.Runtime {
  let assert Ok(#(runtime, plugin.ToolOutput(is_error: False, ..))) =
    plugin.invoke_tool(
      runtime,
      "cloud_storage.write",
      plugin.ToolInvocation(
        "write",
        json.object([
          #("key", json.string(key)),
          #("content", json.string(content)),
        ])
          |> json.to_string,
      ),
    )
  runtime
}

fn storage_read(runtime: plugin.Runtime, key: String) -> plugin.ToolOutput {
  let assert Ok(#(_, output)) =
    plugin.invoke_tool(
      runtime,
      "cloud_storage.read",
      plugin.ToolInvocation(
        "read",
        json.object([#("key", json.string(key))]) |> json.to_string,
      ),
    )
  output
}

fn assert_reads(runtime: plugin.Runtime, key: String, content: String) -> Nil {
  let assert plugin.ToolOutput(content: [llm.Text(found)], is_error: False) =
    storage_read(runtime, key)
  assert found == content
}

fn assert_missing(runtime: plugin.Runtime, key: String) -> Nil {
  let assert plugin.ToolOutput(is_error: True, ..) = storage_read(runtime, key)
  Nil
}

pub fn sessions_share_storage_through_their_associated_workspace_test() {
  let root = temporary_root("harness3-workspaces-service-test")
  let data_path = root <> "/data"
  let workspace = root <> "/workspace"
  let running = start_service(root)

  // The catalog is created lazily: a fresh server has no workspaces.
  assert service.cloud_storage_workspaces(running) == []

  let assert Ok(shared) =
    service.add_cloud_storage_workspace(running, "shared", "Shared team", "")
  assert shared.prefix == "plugins/cloud_storage/workspaces/shared/objects/"
  let assert Ok(custom) =
    service.add_cloud_storage_workspace(running, "custom", "Custom", "teams/x")
  assert custom.prefix == "teams/x/"
  assert service.cloud_storage_workspaces(running) == [shared, custom]

  let assert Error(duplicate) =
    service.add_cloud_storage_workspace(running, "shared", "Again", "")
  assert string.contains(duplicate, "already exists")
  let assert Error(invalid) =
    service.add_cloud_storage_workspace(running, "evil", "Evil", "cluster/x")
  assert string.contains(invalid, "harness-internal")
  let assert Error(unknown_update) =
    service.update_cloud_storage_workspace(running, "missing", "M", "")
  assert string.contains(unknown_update, "unknown cloud storage workspace")

  let assert Ok(first) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, Some("shared")),
    )
  let assert Ok(second) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, Some("shared")),
    )
  let assert Ok(isolated) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, None),
    )
  assert first.metadata.cloud_storage_workspace == Some("shared")
  assert isolated.metadata.cloud_storage_workspace == None

  let assert Error(unknown_association) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, Some("missing")),
    )
  assert string.contains(unknown_association, "unknown cloud storage workspace")

  // Associated sessions share objects; an unassociated session stays on its
  // own isolated namespace.
  let first_lead = lead_runtime(running, first.metadata.id)
  let _ = storage_write(first_lead, "notes/shared.txt", "for the team")
  assert_reads(
    lead_runtime(running, second.metadata.id),
    "notes/shared.txt",
    "for the team",
  )
  assert_missing(
    lead_runtime(running, isolated.metadata.id),
    "notes/shared.txt",
  )
  let assert Ok(_) =
    storage.get(
      local.new(local.config(data_path)),
      "plugins/cloud_storage/workspaces/shared/objects/notes/shared.txt",
    )

  // The isolated session's objects live under its own per-session namespace.
  let backend = local.new(local.config(data_path))
  let isolated_lead = lead_runtime(running, isolated.metadata.id)
  let _ = storage_write(isolated_lead, "notes/private.txt", "only this session")
  let assert Ok(_) =
    storage.get(
      backend,
      "plugins/cloud_storage/sessions/"
        <> isolated.metadata.id
        <> "/objects/notes/private.txt",
    )

  // A referenced workspace cannot be removed.
  let assert Error(in_use) =
    service.remove_cloud_storage_workspace(running, "shared")
  assert string.contains(in_use, "still used by")
  assert string.contains(in_use, first.metadata.id)

  // Re-associating without roster changes still rebuilds plugins: the second
  // session moves to the custom workspace and no longer sees shared objects.
  let assert Ok(service.Session(metadata: moved, ..)) =
    service.update_session(
      running,
      second.metadata.id,
      service.UpdateInput(
        "Second session",
        second.metadata.agents,
        service.SetAssociation(Some("custom")),
      ),
    )
  assert moved.cloud_storage_workspace == Some("custom")
  assert_missing(lead_runtime(running, second.metadata.id), "notes/shared.txt")

  // KeepAssociation leaves the workspace alone across a plain rename.
  let assert Ok(service.Session(metadata: renamed, ..)) =
    service.update_session(
      running,
      second.metadata.id,
      service.UpdateInput(
        "Renamed session",
        second.metadata.agents,
        service.KeepAssociation,
      ),
    )
  assert renamed.title == "Renamed session"
  assert renamed.cloud_storage_workspace == Some("custom")

  // Clearing the association returns the session to its isolated namespace.
  let assert Ok(service.Session(metadata: cleared, ..)) =
    service.update_session(
      running,
      second.metadata.id,
      service.UpdateInput(
        "Renamed session",
        second.metadata.agents,
        service.SetAssociation(None),
      ),
    )
  assert cleared.cloud_storage_workspace == None

  // Editing a workspace's prefix is picked up by associated sessions the next
  // time their profiles are built (here: a wake via the compaction RPC).
  let assert Ok(repointed) =
    service.update_cloud_storage_workspace(
      running,
      "shared",
      "Shared team",
      "teams/repointed",
    )
  assert repointed.prefix == "teams/repointed/"
  let assert Error(compaction_error) =
    service.request_compaction(running, first.metadata.id, "lead")
  assert string.contains(compaction_error, "no messages to compact")
  let repointed_lead = lead_runtime(running, first.metadata.id)
  assert_missing(repointed_lead, "notes/shared.txt")
  let _ = storage_write(repointed_lead, "notes/new.txt", "moved")
  let assert Ok(_) = storage.get(backend, "teams/repointed/notes/new.txt")

  // Removing the last reference unblocks removal; the stored objects stay.
  let assert Ok(_) =
    service.update_session(
      running,
      first.metadata.id,
      service.UpdateInput(
        "First session",
        first.metadata.agents,
        service.SetAssociation(None),
      ),
    )
  let assert Ok(Nil) = service.remove_cloud_storage_workspace(running, "shared")
  assert service.cloud_storage_workspaces(running) == [custom]
  let assert Error(removed) =
    service.remove_cloud_storage_workspace(running, "shared")
  assert string.contains(removed, "unknown cloud storage workspace")
  let assert Ok(_) =
    storage.get(
      backend,
      "plugins/cloud_storage/workspaces/shared/objects/notes/shared.txt",
    )

  let assert Ok(Nil) = service.stop_session(running, first.metadata.id)
  let assert Ok(Nil) = service.stop_session(running, second.metadata.id)
  let assert Ok(Nil) = service.stop_session(running, isolated.metadata.id)
  service.stop(running)

  // The catalog and the session associations survive a restart.
  let restarted = start_service(root)
  assert service.cloud_storage_workspaces(restarted) == [custom]
  let assert Ok(service.Session(metadata: persisted, ..)) =
    service.get_session(restarted, isolated.metadata.id)
  assert persisted.cloud_storage_workspace == None
  service.stop(restarted)

  unset_service_environment()
  let assert Ok(Nil) = simplifile.delete(root)
}

/// A workspace removal racing a session's association leaves the session
/// referencing a workspace the catalog no longer contains. Wake paths must
/// fail with a repair hint, and the edit path must stay able to re-point or
/// clear the dead association instead of wedging on the pre-edit profiles.
pub fn a_session_whose_workspace_vanished_stays_repairable_test() {
  let root = temporary_root("harness3-workspaces-repair-test")
  let data_path = root <> "/data"
  let workspace = root <> "/workspace"
  let running = start_service(root)

  let assert Ok(_) =
    service.add_cloud_storage_workspace(running, "shared", "Shared", "")
  let assert Ok(_) =
    service.add_cloud_storage_workspace(running, "custom", "Custom", "t/custom")
  let assert Ok(repoint_target) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, Some("shared")),
    )
  let assert Ok(clear_target) =
    service.create_session(
      running,
      service.CreateInput("test/model-1", workspace, 1, Some("shared")),
    )

  // The race outcome, produced directly: the catalog commits a removal while
  // both sessions still carry the association attribute.
  let backend = local.new(local.config(data_path))
  let assert Ok(catalog_session) =
    storage_workspaces.resume(
      backend,
      "harness3-server/cloud-storage-workspaces",
    )
  let assert Ok(narrowed) =
    storage_workspaces.remove_workspace(
      storage_workspaces.catalog(catalog_session),
      "shared",
    )
  let assert Ok(_) = storage_workspaces.commit(catalog_session, narrowed)

  // The dangling association no longer blocks waking or editing the session:
  // the storage scope is resolved per tool invocation, so the
  // misconfiguration surfaces as an actionable tool error while the session
  // itself stays runnable and repairable.
  let assert Error(wake_error) =
    request_compaction_after_election(
      running,
      repoint_target.metadata.id,
      "lead",
      50,
    )
  assert string.contains(wake_error, "no messages to compact")
  let assert plugin.ToolOutput(content: [llm.Text(dangling)], is_error: True) =
    storage_read(lead_runtime(running, repoint_target.metadata.id), "any.txt")
  assert string.contains(dangling, "re-point or clear")
  let assert Ok(_) =
    service.update_session(
      running,
      repoint_target.metadata.id,
      service.UpdateInput(
        "Plain rename",
        repoint_target.metadata.agents,
        service.KeepAssociation,
      ),
    )

  // Re-pointing repairs the first session.
  let assert Ok(service.Session(metadata: repointed, ..)) =
    service.update_session(
      running,
      repoint_target.metadata.id,
      service.UpdateInput(
        "Repaired session",
        repoint_target.metadata.agents,
        service.SetAssociation(Some("custom")),
      ),
    )
  assert repointed.cloud_storage_workspace == Some("custom")
  let _ =
    storage_write(
      lead_runtime(running, repointed.id),
      "fixed.txt",
      "re-pointed",
    )
  let assert Ok(_) = storage.get(backend, "t/custom/fixed.txt")

  // Clearing repairs the second.
  let assert Ok(service.Session(metadata: cleared, ..)) =
    service.update_session(
      running,
      clear_target.metadata.id,
      service.UpdateInput(
        "Cleared session",
        clear_target.metadata.agents,
        service.SetAssociation(None),
      ),
    )
  assert cleared.cloud_storage_workspace == None
  let _ =
    storage_write(lead_runtime(running, cleared.id), "fixed.txt", "cleared")
  let assert Ok(_) =
    storage.get(
      backend,
      "plugins/cloud_storage/sessions/" <> cleared.id <> "/objects/fixed.txt",
    )

  let assert Ok(Nil) = service.stop_session(running, repointed.id)
  let assert Ok(Nil) = service.stop_session(running, cleared.id)
  service.stop(running)

  unset_service_environment()
  let assert Ok(Nil) = simplifile.delete(root)
}
