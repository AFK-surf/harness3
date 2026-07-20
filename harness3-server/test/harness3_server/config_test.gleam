import envoy
import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import harness3/agent
import harness3/agent_group
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/llm
import harness3/model_catalog
import harness3/plugin
import harness3/plugin/mcp/configuration as mcp_configuration
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

fn mcp_server_script() -> String {
  "while IFS= read -r line; do case \"$line\" in *'\"method\":\"initialize\"'*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"test\",\"version\":\"1\"}}}' ;; *'\"method\":\"tools/list\"'*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"lookup\",\"description\":\"Look up evidence\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}' ;; esac; done"
}

fn mcp_config_json() -> String {
  let configuration =
    mcp_configuration.Configuration(
      id: "research",
      label: "Research MCP",
      enabled: True,
      servers: [
        mcp_configuration.Server(
          id: "evidence",
          transport: mcp_configuration.Stdio(
            "/bin/sh",
            ["-c", mcp_server_script()],
            None,
            [],
          ),
          timeout_milliseconds: 1000,
        ),
      ],
    )
  json.object([
    #("configurations", json.array([configuration], mcp_configuration.encode)),
  ])
  |> json.to_string
}

fn unavailable_mcp_config_json() -> String {
  let configuration =
    mcp_configuration.Configuration(
      id: "offline",
      label: "Unavailable MCP",
      enabled: True,
      servers: [
        mcp_configuration.Server(
          id: "missing",
          transport: mcp_configuration.Stdio(
            "/path/that/does/not/exist/harness3-mcp",
            [],
            None,
            [],
          ),
          timeout_milliseconds: 1000,
        ),
      ],
    )
  json.object([
    #("configurations", json.array([configuration], mcp_configuration.encode)),
  ])
  |> json.to_string
}

fn tool_names(profile: agent_profile.AgentProfile) -> List(String) {
  let assert Ok(runtime) =
    plugin.activate(profile.registry, plugin.empty_states())
  plugin.tools(runtime)
  |> list.map(fn(tool) {
    let llm.Tool(name:, ..) = tool
    name
  })
}

fn assert_cloud_storage_tools(names: List(String)) -> Nil {
  list.each(
    [
      "cloud_storage_read",
      "cloud_storage_write",
      "cloud_storage_list",
      "cloud_storage_delete",
      "cloud_storage_get_url",
    ],
    fn(name) {
      assert list.contains(names, name)
    },
  )
}

pub fn pi_models_load_and_catalog_restart_is_idempotent_test() {
  let root = temporary_root("harness3-server-config-test")
  let models_path = root <> "/models.json"
  let data_path = root <> "/data"
  let workspace = root <> "/workspace"
  let mcp_path = root <> "/mcp.json"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
  let assert Ok(Nil) =
    simplifile.write(to: models_path, contents: models_json())
  let assert Ok(Nil) =
    simplifile.write(to: mcp_path, contents: mcp_config_json())

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
  envoy.set("HARNESS3_MCP_CONFIG_PATH", "relative-mcp.json")
  assert config.mcp_configurations_path()
    == Error("HARNESS3_MCP_CONFIG_PATH must be absolute")
  envoy.set("HARNESS3_MCP_CONFIG_PATH", mcp_path)
  let assert Ok(first) = service.start()
  let assert Ok(second) = service.start()
  assert list.length(service.models(first)) == 1
  assert service.workspace_root(second) == workspace
  let assert [mcp_configuration] = service.mcp_configurations(second)
  assert mcp_configuration.id == "research"
  let assert [mcp_server] = mcp_configuration.servers
  assert mcp_server.id == "evidence"
  assert service.resolve_workspace("nested")
    == Error("workspace path must be absolute")
  let outside = root <> "-outside"
  assert service.resolve_workspace(outside) == Ok(outside)

  let assert Ok(service.Session(metadata, group)) =
    service.create_session(
      second,
      service.CreateInput("test/model-1", workspace, 3, None),
    )
  assert metadata.title == "New coding session"
  assert metadata.prompt == ""
  assert group.execution == agent_group.Idle
  assert list.length(group.agents) == 3
  assert list.all(group.agents, fn(state) {
    state.status == agent.Waiting && list.is_empty(state.messages)
  })
  let assert [
    service.AgentSpec(kind: service.CodingAgent, ..),
    service.AgentSpec(kind: service.McpSpecialist("research"), ..),
    service.AgentSpec(kind: service.CodingAgent, ..),
  ] = metadata.agents
  // Manual compaction always wakes through the RPC first. The request still
  // fails validation because a newly created agent has no history, but its
  // group is active by the time the compaction RPC runs.
  let assert Error(compaction_error) =
    service.request_compaction(second, metadata.id, "lead")
  assert string.contains(compaction_error, "no messages to compact")
  assert list.contains(agent_group_registry.alive_ids(), metadata.id)
  let assert Error(unknown_compaction_agent) =
    service.request_compaction(second, metadata.id, "missing")
  assert string.contains(unknown_compaction_agent, "unknown agent")

  let assert Ok([lead_profile, researcher_profile, implementer_profile]) =
    agent_profile.profiles([
      metadata.id <> ":lead",
      metadata.id <> ":researcher",
      metadata.id <> ":implementer",
    ])
  let lead_tools = tool_names(lead_profile)
  let researcher_tools = tool_names(researcher_profile)
  let implementer_tools = tool_names(implementer_profile)
  let exposed = mcp_configuration.exposed_tool_name("evidence", "lookup")
  assert list.contains(lead_tools, "Read")
  assert list.contains(lead_tools, "MessageAgent")
  assert_cloud_storage_tools(lead_tools)
  assert_cloud_storage_tools(researcher_tools)
  assert_cloud_storage_tools(implementer_tools)
  assert !list.contains(lead_tools, exposed)
  assert list.contains(researcher_tools, "MessageAgent")
  assert list.contains(researcher_tools, "mcp.list")
  assert list.contains(researcher_tools, "mcp.call")
  assert !list.contains(researcher_tools, exposed)
  assert !list.contains(researcher_tools, "Read")
  let assert Ok(researcher_runtime) =
    plugin.activate(researcher_profile.registry, plugin.empty_states())
  let assert Ok(lead_runtime) =
    plugin.activate(lead_profile.registry, plugin.empty_states())
  let assert Ok(#(_, plugin.ToolOutput(is_error: False, ..))) =
    plugin.invoke_tool(
      lead_runtime,
      "cloud_storage_write",
      plugin.ToolInvocation(
        "write-shared-object",
        json.object([
          #("key", json.string("handoff/shared.txt")),
          #("content", json.string("shared between profiles")),
        ])
          |> json.to_string,
      ),
    )
  let assert Ok(#(
    _,
    plugin.ToolOutput(
      content: [llm.Text("shared between profiles")],
      is_error: False,
    ),
  )) =
    plugin.invoke_tool(
      researcher_runtime,
      "cloud_storage_read",
      plugin.ToolInvocation(
        "read-shared-object",
        "{\"key\":\"handoff/shared.txt\"}",
      ),
    )
  let assert Ok(#(
    _,
    plugin.ToolOutput(content: [llm.Text(listing)], is_error: False),
  )) =
    plugin.invoke_tool(
      researcher_runtime,
      "mcp.list",
      plugin.ToolInvocation("list-tools", "{}"),
    )
  assert string.contains(listing, exposed)
  let assert Ok(#(_, plugin.ToolOutput(is_error: True, ..))) =
    plugin.invoke_tool(
      researcher_runtime,
      "MessageAgent",
      plugin.ToolInvocation(
        "blocked-peer-message",
        "{\"agent_id\":\"implementer\",\"message\":\"bypass lead\"}",
      ),
    )

  let assert Ok(Nil) = service.stop_session(second, metadata.id)
  let seeded_ui_server =
    mcp_configuration.Server(
      id: "ui-added",
      transport: mcp_configuration.StreamableHttp(
        "https://ui.example.test/mcp",
        [],
      ),
      timeout_milliseconds: 5000,
    )
  let assert Ok(_) =
    service.add_mcp_server(second, "research", "Research MCP", seeded_ui_server)
  service.stop(first)
  service.stop(second)

  let assert Ok(after_seed_restart) = service.start()
  let assert [after_seed_configuration] =
    service.mcp_configurations(after_seed_restart)
  assert list.contains(after_seed_configuration.servers, seeded_ui_server)
  service.stop(after_seed_restart)

  envoy.unset("HARNESS3_MCP_CONFIG_PATH")
  envoy.set("HARNESS3_DATA_DIR", root <> "/data-without-mcp")
  let assert Ok(without_mcp) = service.start()
  let assert Ok(service.Session(metadata: without_mcp_metadata, ..)) =
    service.create_session(
      without_mcp,
      service.CreateInput("test/model-1", workspace, 2, None),
    )
  let assert [_, service.AgentSpec(kind: service.ResearchAgent, ..)] =
    without_mcp_metadata.agents
  let assert Ok([researcher_without_mcp]) =
    agent_profile.profiles([
      without_mcp_metadata.id <> ":researcher",
    ])
  let researcher_without_mcp_tools = tool_names(researcher_without_mcp)
  assert researcher_without_mcp_tools
    == [
      "MessageAgent",
      "cloud_storage_read",
      "cloud_storage_write",
      "cloud_storage_list",
      "cloud_storage_delete",
      "cloud_storage_get_url",
    ]
  let assert Ok(Nil) =
    service.stop_session(without_mcp, without_mcp_metadata.id)
  let managed_server =
    mcp_configuration.Server(
      id: "web-added",
      transport: mcp_configuration.StreamableHttp(
        "https://mcp.example.test/mcp",
        [
          mcp_configuration.Binding(
            "authorization",
            mcp_configuration.EnvironmentVariable("WEB_MCP_TOKEN"),
          ),
        ],
      ),
      timeout_milliseconds: 12_000,
    )
  let assert Ok(added) =
    service.add_mcp_server(
      without_mcp,
      "web-managed",
      "Web managed MCP",
      managed_server,
    )
  assert added.servers == [managed_server]
  let assert [live_added] = service.mcp_configurations(without_mcp)
  assert live_added.servers == [managed_server]
  let assert Error(duplicate_error) =
    service.add_mcp_server(
      without_mcp,
      "web-managed",
      "Web managed MCP",
      managed_server,
    )
  assert string.contains(duplicate_error, "already exists")
  service.stop(without_mcp)

  let assert Ok(after_add_restart) = service.start()
  let assert [persisted_web_configuration] =
    service.mcp_configurations(after_add_restart)
  assert persisted_web_configuration.id == "web-managed"
  assert persisted_web_configuration.servers == [managed_server]
  let assert Ok(after_remove) =
    service.remove_mcp_server(after_add_restart, "web-managed", "web-added")
  assert after_remove.servers == []
  let assert [live_removed] = service.mcp_configurations(after_add_restart)
  assert live_removed.servers == []
  service.stop(after_add_restart)

  let assert Ok(after_remove_restart) = service.start()
  let assert [empty_web_configuration] =
    service.mcp_configurations(after_remove_restart)
  assert empty_web_configuration.id == "web-managed"
  assert empty_web_configuration.servers == []
  service.stop(after_remove_restart)

  let unavailable_path = root <> "/unavailable-mcp.json"
  let assert Ok(Nil) =
    simplifile.write(
      to: unavailable_path,
      contents: unavailable_mcp_config_json(),
    )
  envoy.set("HARNESS3_MCP_CONFIG_PATH", unavailable_path)
  envoy.set("HARNESS3_DATA_DIR", root <> "/data-with-offline-mcp")
  let assert Ok(with_offline_mcp) = service.start()
  let assert Ok(service.Session(metadata: offline_metadata, ..)) =
    service.create_session(
      with_offline_mcp,
      service.CreateInput("test/model-1", workspace, 2, None),
    )
  let assert [_, service.AgentSpec(kind: service.McpSpecialist("offline"), ..)] =
    offline_metadata.agents
  let assert Ok([offline_profile]) =
    agent_profile.profiles([offline_metadata.id <> ":researcher"])
  let assert Ok(offline_runtime) =
    plugin.activate(offline_profile.registry, plugin.empty_states())
  let offline_tools =
    plugin.tools(offline_runtime)
    |> list.map(fn(tool) {
      let llm.Tool(name:, ..) = tool
      name
    })
  assert list.contains(offline_tools, "MessageAgent")
  assert list.contains(offline_tools, "mcp.list")
  assert list.contains(offline_tools, "mcp.call")
  assert_cloud_storage_tools(offline_tools)
  assert !list.contains(offline_tools, "Read")
  let assert Ok(#(
    _,
    plugin.ToolOutput(content: [llm.Text(offline_listing)], is_error: False),
  )) =
    plugin.invoke_tool(
      offline_runtime,
      "mcp.list",
      plugin.ToolInvocation("list-offline-tools", "{}"),
    )
  assert string.contains(offline_listing, "\"tools\":[]")
  assert string.contains(offline_listing, "\"server_id\":\"missing\"")
  let assert Ok(Nil) =
    service.stop_session(with_offline_mcp, offline_metadata.id)
  service.stop(with_offline_mcp)

  envoy.unset("HARNESS3_MCP_CONFIG_PATH")
  envoy.unset("HARNESS3_MODELS_PATH")
  envoy.unset("HARNESS3_DATA_DIR")
  envoy.unset("HARNESS3_WORKSPACE_ROOT")
  envoy.unset("HARNESS3_STORAGE")
  let assert Ok(Nil) = simplifile.delete(root)
}
