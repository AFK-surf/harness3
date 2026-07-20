import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/llm
import harness3/plugin as harness_plugin
import harness3/plugin/mcp/catalog
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/plugin as mcp_plugin
import harness3/plugin/mcp/protocol
import harness3/plugin/mcp/runtime
import harness3/storage/local
import simplifile

fn configured(manifest: configuration.Manifest) -> configuration.Configuration {
  configuration.Configuration(
    id: "research",
    label: "Research tools",
    enabled: True,
    servers: [
      configuration.Server(
        id: "search",
        transport: configuration.StreamableHttp("https://mcp.example.test/rpc", [
          configuration.Binding(
            "authorization",
            configuration.EnvironmentVariable("MCP_TEST_TOKEN"),
          ),
        ]),
        timeout_milliseconds: 1000,
      ),
    ],
    manifest: Some(manifest),
  )
}

fn persisted_manifest() -> configuration.Manifest {
  configuration.Manifest(0, [
    configuration.Tool(
      server_id: "search",
      name: "lookup",
      exposed_name: configuration.exposed_tool_name("search", "lookup"),
      description: Some("Look up evidence"),
      input_schema: json.object([
        #("type", json.string("object")),
        #("properties", json.object([])),
      ]),
      output_schema: None,
    ),
  ])
}

fn temporary_root() -> String {
  "/tmp/harness3-mcp-test-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

pub fn configuration_requires_absolute_process_paths_and_resolves_secrets_test() {
  let invalid =
    configuration.Configuration(
      id: "local",
      label: "Local",
      enabled: True,
      servers: [
        configuration.Server(
          id: "stdio",
          transport: configuration.Stdio("node", [], None, []),
          timeout_milliseconds: 1000,
        ),
      ],
      manifest: None,
    )
  let assert Error(configuration.InvalidConfiguration(reason)) =
    configuration.validate(invalid)
  assert string.contains(reason, "absolute")

  let bindings = [
    configuration.Binding("literal", configuration.Literal("visible")),
    configuration.Binding(
      "secret",
      configuration.EnvironmentVariable("MCP_TEST_TOKEN"),
    ),
  ]
  let assert Ok(resolved) =
    configuration.resolve_bindings(bindings, fn(name) {
      case name {
        "MCP_TEST_TOKEN" -> Ok("secret")
        _ -> Error(Nil)
      }
    })
  assert resolved == [#("literal", "visible"), #("secret", "secret")]
}

pub fn catalog_is_durable_and_uses_compare_and_swap_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let assert Ok(initial) =
    catalog.put_configuration(catalog.new(), configured(persisted_manifest()))
  let assert Ok(first) = catalog.create(backend, "mcp/catalog", initial)
  let assert Ok(stale) = catalog.resume(backend, "mcp/catalog")
  let assert Ok(changed) =
    catalog.put_configuration(
      catalog.catalog(first),
      configuration.Configuration(
        ..configured(persisted_manifest()),
        label: "Updated research tools",
      ),
    )
  let assert Ok(committed) = catalog.commit(first, changed)
  assert catalog.revision(catalog.catalog(committed)) == 1
  let assert Error(catalog.ConcurrentUpdate) =
    catalog.commit(stale, catalog.catalog(stale))
  let assert Ok(resumed) = catalog.resume(backend, "mcp/catalog")
  let assert Ok(found) = catalog.lookup(catalog.catalog(resumed), "research")
  assert found.label == "Updated research tools"
  let assert Some(manifest) = found.manifest
  let assert [tool] = manifest.tools
  assert string.contains(
    json.to_string(tool.input_schema),
    "\"type\":\"object\"",
  )
  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn runtime_discovers_and_broker_invokes_available_tools_test() {
  let without_manifest =
    configuration.Configuration(
      ..configured(persisted_manifest()),
      manifest: None,
    )
  let assert Ok(value) =
    catalog.put_configuration(catalog.new(), without_manifest)
  let connector = fn(_server, resolve_environment) {
    let assert Ok("token") = resolve_environment("MCP_TEST_TOKEN")
    Ok(
      client.connection(
        fn(method, params, _timeout) {
          case method {
            "initialize" ->
              Ok(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}",
              )
            "tools/list" ->
              Ok(
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"search_web\",\"description\":\"Search evidence\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}}]}}",
              )
            "tools/call" -> {
              assert string.contains(json.to_string(params), "search_web")
              Ok(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"evidence found\"}],\"isError\":false}}",
              )
            }
            _ -> Error("unexpected method")
          }
        },
        fn(method, _) {
          case method {
            "notifications/initialized" -> Ok(Nil)
            _ -> Error("unexpected notification")
          }
        },
        fn() { Nil },
      ),
    )
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(name) {
        case name {
          "MCP_TEST_TOKEN" -> Ok("token")
          _ -> Error(Nil)
        }
      },
      fn() { 1234 },
      connector,
    )
  let assert Ok(snapshot) = runtime.discover(mcp_runtime, "research")
  let runtime.Snapshot(configuration: discovered, ..) = snapshot
  let assert Some(manifest) = discovered.manifest
  let assert [tool] = manifest.tools
  assert tool.name == "search_web"
  assert tool.exposed_name
    == configuration.exposed_tool_name("search", "search_web")

  let value = mcp_plugin.new(mcp_runtime, snapshot)
  let assert Ok(registry) = harness_plugin.registry([value])
  let assert Ok(plugin_runtime) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  let tools = harness_plugin.tools(plugin_runtime)
  let assert [llm.Tool(name: list_name, ..), llm.Tool(name: call_name, ..)] =
    tools
  assert list_name == "mcp.list"
  assert call_name == "mcp.call"
  let assert Ok(#(
    _,
    harness_plugin.ToolOutput(content: [llm.Text(listing)], is_error: False),
  )) =
    harness_plugin.invoke_tool(
      plugin_runtime,
      list_name,
      harness_plugin.ToolInvocation("list", "{}"),
    )
  assert string.contains(listing, tool.exposed_name)
  assert string.contains(listing, "search_web")
  let assert Ok(#(
    _,
    harness_plugin.ToolOutput(
      content: [llm.Text("evidence found")],
      is_error: False,
    ),
  )) =
    harness_plugin.invoke_tool(
      plugin_runtime,
      call_name,
      harness_plugin.ToolInvocation(
        "call",
        json.object([
          #("tool", json.string(tool.exposed_name)),
          #("arguments", json.object([#("query", json.string("MCP"))])),
        ])
          |> json.to_string,
      ),
    )
  runtime.stop(mcp_runtime)
}

pub fn discovery_excludes_failed_servers_without_failing_test() {
  let configured =
    configuration.Configuration(
      id: "mixed",
      label: "Partially available",
      enabled: True,
      servers: [
        configuration.Server(
          id: "down",
          transport: configuration.StreamableHttp(
            "https://down.example.test/mcp",
            [],
          ),
          timeout_milliseconds: 1000,
        ),
        configuration.Server(
          id: "up",
          transport: configuration.StreamableHttp(
            "https://up.example.test/mcp",
            [],
          ),
          timeout_milliseconds: 1000,
        ),
      ],
      manifest: None,
    )
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured)
  let connector = fn(server: configuration.Server, _resolve_environment) {
    case server.id {
      "down" -> Error("connection refused")
      _ ->
        Ok(
          client.connection(
            fn(method, _params, _timeout) {
              case method {
                "initialize" ->
                  Ok(
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}",
                  )
                "tools/list" ->
                  Ok(
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"available\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]}}",
                  )
                _ -> Error("unexpected method")
              }
            },
            fn(method, _) {
              case method {
                "notifications/initialized" -> Ok(Nil)
                _ -> Error("unexpected notification")
              }
            },
            fn() { Nil },
          ),
        )
    }
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Error(Nil) },
      fn() { 1234 },
      connector,
    )
  let assert Ok(snapshot) = runtime.discover(mcp_runtime, "mixed")
  let runtime.Snapshot(configuration:, failures:, ..) = snapshot
  let assert Some(manifest) = configuration.manifest
  let assert [available] = manifest.tools
  assert available.server_id == "up"
  let assert [runtime.ServerFailure(server_id:, reason:)] = failures
  assert server_id == "down"
  assert reason == "connection refused"
  runtime.stop(mcp_runtime)
}

pub fn protocol_reports_json_rpc_and_tool_errors_test() {
  let assert Error(error) =
    protocol.decode_call_result(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"not found\"}}",
    )
  assert error == "MCP error -32601: not found"
  let assert Error(arguments_error) =
    protocol.tools_call_params("tool", "[\"not\",\"an\",\"object\"]")
  assert string.contains(arguments_error, "expected a JSON object")
}

/// Opt-in live transport smoke. Normal test runs do no network I/O; setting
/// HARNESS3_COMPOSIO_SMOKE_KEY exercises initialize and tools/list against the
/// public Composio MCP endpoint through the reusable Streamable HTTP client.
pub fn composio_streamable_http_smoke_test() {
  case envoy.get("HARNESS3_COMPOSIO_SMOKE_KEY") {
    Error(_) -> Nil
    Ok(_) -> {
      let configuration =
        configuration.Configuration(
          id: "composio-smoke",
          label: "Composio smoke",
          enabled: True,
          servers: [
            configuration.Server(
              id: "composio",
              transport: configuration.StreamableHttp(
                "https://connect.composio.dev/mcp",
                [
                  configuration.Binding(
                    "x-consumer-api-key",
                    configuration.EnvironmentVariable(
                      "HARNESS3_COMPOSIO_SMOKE_KEY",
                    ),
                  ),
                ],
              ),
              timeout_milliseconds: 30_000,
            ),
          ],
          manifest: None,
        )
      let assert Ok(value) =
        catalog.put_configuration(catalog.new(), configuration)
      let assert Ok(mcp_runtime) = runtime.start(value, envoy.get, fn() { 0 })
      let assert Ok(snapshot) = runtime.discover(mcp_runtime, "composio-smoke")
      let runtime.Snapshot(configuration:, ..) = snapshot
      let assert Some(manifest) = configuration.manifest
      assert !list.is_empty(manifest.tools)
      runtime.stop(mcp_runtime)
    }
  }
}

import envoy
