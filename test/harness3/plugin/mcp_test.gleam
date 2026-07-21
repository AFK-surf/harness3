import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import harness3/llm
import harness3/plugin as harness_plugin
import harness3/plugin/mcp/catalog
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/connections
import harness3/plugin/mcp/plugin as mcp_plugin
import harness3/plugin/mcp/protocol
import harness3/plugin/mcp/runtime
import harness3/storage/local
import simplifile

fn configured() -> configuration.Configuration {
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
  )
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
    catalog.put_configuration(catalog.new(), configured())
  let assert Ok(first) = catalog.create(backend, "mcp/catalog", initial)
  let assert Ok(stale) = catalog.resume(backend, "mcp/catalog")
  let assert Ok(changed) =
    catalog.put_configuration(
      catalog.catalog(first),
      configuration.Configuration(
        ..configured(),
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
  let assert [server] = found.servers
  assert server.id == "search"
  let assert configuration.StreamableHttp(endpoint, _) = server.transport
  assert endpoint == "https://mcp.example.test/rpc"
  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn activation_never_touches_mcp_servers_test() {
  // Activation runs inside the group coordinator, which also renews the
  // group's lease. A connector reached during activation would mean a slow
  // MCP server could cost the group its lease.
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
  let connector = fn(_server, _resolve) {
    panic as "activation must not open MCP connections"
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Ok("token") },
      fn() { 1234 },
      connector,
    )
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "research")
      }),
    ])
  let assert Ok(_) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  runtime.stop(mcp_runtime)
}

pub fn each_agent_owns_its_own_connections_test() {
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
  let closed = process.new_subject()
  let connector = fn(_server, _resolve) {
    Ok(stub_connection() |> closing_notifier(closed))
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Ok("token") },
      fn() { 1234 },
      connector,
    )
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")

  // Two agents, each with its own activated plugin runtime.
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "research")
      }),
    ])
  let assert Ok(agent_a) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  let assert Ok(agent_b) =
    harness_plugin.activate(registry, harness_plugin.empty_states())

  let assert Ok(#(agent_a, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent_a,
      "mcp.list",
      harness_plugin.ToolInvocation("list-a", "{}"),
    )
  // B listing must not disturb A: no connection of A's is closed by it.
  let assert Ok(#(_, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent_b,
      "mcp.list",
      harness_plugin.ToolInvocation("list-b", "{}"),
    )
  assert process.receive(closed, within: 100) == Error(Nil)

  // A's connection is still usable after B has been through discovery.
  let assert Ok(#(_, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent_a,
      "mcp.call",
      harness_plugin.ToolInvocation(
        "call-a",
        json.object([
          #(
            "tool",
            json.string(configuration.broker_tool_name("search", "search_web")),
          ),
          #("arguments", json.object([])),
        ])
          |> json.to_string,
      ),
    )
  runtime.stop(mcp_runtime)
}

fn closing_notifier(
  connection: client.Connection,
  closed: process.Subject(Nil),
) -> client.Connection {
  client.connection(
    fn(method, params, timeout) {
      client.request(connection, method, params, timeout)
    },
    fn(method, params) { client.notify(connection, method, params) },
    fn() { process.send(closed, Nil) },
  )
}

pub fn edited_configuration_reaches_a_running_agent_test() {
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
  let connects = process.new_subject()
  let connector = fn(server: configuration.Server, _resolve) {
    process.send(connects, server.id)
    Ok(stub_connection())
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Ok("token") },
      fn() { 1234 },
      connector,
    )
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "research")
      }),
    ])
  let assert Ok(agent) =
    harness_plugin.activate(registry, harness_plugin.empty_states())

  let assert Ok(#(agent, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list-1", "{}"),
    )
  let assert Ok("search") = process.receive(connects, within: 1000)
  // A second listing inside the TTL reuses the existing connection.
  let assert Ok(#(agent, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list-2", "{}"),
    )
  assert process.receive(connects, within: 100) == Error(Nil)

  // An operator edits the configuration: the running agent must pick it up
  // rather than keep serving the previous definition until its TTL lapses.
  let assert Ok(Nil) =
    runtime.put_configuration(
      mcp_runtime,
      configuration.Configuration(..current, servers: [
        configuration.Server(
          id: "replacement",
          transport: configuration.StreamableHttp(
            "https://mcp.example.test/rpc",
            [],
          ),
          timeout_milliseconds: 1000,
        ),
      ]),
    )
  let assert Ok(#(_, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list-3", "{}"),
    )
  let assert Ok("replacement") = process.receive(connects, within: 1000)
  runtime.stop(mcp_runtime)
}

pub fn releasing_the_plugin_closes_its_transports_test() {
  // A linked process is NOT taken down by its owner's normal exit, so the
  // release hook is what actually stops an agent's MCP servers when its
  // plugin host finishes gracefully.
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
  let closed = process.new_subject()
  let connector = fn(_server, _resolve) {
    Ok(stub_connection() |> closing_notifier(closed))
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Ok("token") },
      fn() { 1234 },
      connector,
    )
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "research")
      }),
    ])
  let assert Ok(agent) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  let assert Ok(#(agent, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list", "{}"),
    )
  assert process.receive(closed, within: 100) == Error(Nil)

  harness_plugin.release(agent)
  let assert Ok(Nil) = process.receive(closed, within: 1000)
  runtime.stop(mcp_runtime)
}

pub fn revoking_a_configuration_closes_its_transports_test() {
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
  let closed = process.new_subject()
  let connector = fn(_server, _resolve) {
    Ok(stub_connection() |> closing_notifier(closed))
  }
  let assert Ok(mcp_runtime) =
    runtime.start_with_connector(
      value,
      fn(_) { Ok("token") },
      fn() { 1234 },
      connector,
    )
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "research")
      }),
    ])
  let assert Ok(agent) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  let assert Ok(#(agent, harness_plugin.ToolOutput(is_error: False, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list", "{}"),
    )

  // Disabling the configuration must stop the servers, not merely refuse new
  // calls while they keep running.
  let assert Ok(Nil) =
    runtime.put_configuration(
      mcp_runtime,
      configuration.Configuration(..current, enabled: False),
    )
  let assert Ok(#(_, harness_plugin.ToolOutput(is_error: True, ..))) =
    harness_plugin.invoke_tool(
      agent,
      "mcp.list",
      harness_plugin.ToolInvocation("list-2", "{}"),
    )
  let assert Ok(Nil) = process.receive(closed, within: 1000)
  runtime.stop(mcp_runtime)
}

fn stub_connection() -> client.Connection {
  client.connection(
    fn(method, _params, _timeout) {
      case method {
        "initialize" ->
          Ok(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}",
          )
        "tools/list" ->
          Ok(
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"search_web\",\"inputSchema\":{\"type\":\"object\"}}]}}",
          )
        "tools/call" ->
          Ok(
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":false}}",
          )
        _ -> Error("unexpected method")
      }
    },
    fn(_method, _params) { Ok(Nil) },
    fn() { Nil },
  )
}

pub fn server_initiated_request_is_not_taken_as_a_response_test() {
  // A server request shares the client's ID space; treating it as a response
  // would resolve an unrelated pending request with the wrong document.
  assert protocol.response_id(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
    )
    == Error(Nil)
  assert protocol.response_id(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}",
    )
    == Ok(1)
}

pub fn runtime_discovers_and_broker_invokes_available_tools_test() {
  let assert Ok(value) = catalog.put_configuration(catalog.new(), configured())
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
  let assert Ok(current) = runtime.configuration(mcp_runtime, "research")
  let broker_name = configuration.broker_tool_name("search", "search_web")
  assert string.starts_with(broker_name, "mcp.server_search_tool_search_web_")
  assert !string.contains(broker_name, "__")
  assert string.lowercase(broker_name) == broker_name

  let value =
    mcp_plugin.new(mcp_runtime, fn() {
      runtime.load_configuration(mcp_runtime, "research")
    })
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
  assert string.contains(listing, broker_name)
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
          #("tool", json.string(broker_name)),
          #("arguments", json.object([#("query", json.string("MCP"))])),
        ])
          |> json.to_string,
      ),
    )
  let relabelled = configuration.Configuration(..current, label: "Renamed")
  let assert Ok(Nil) = runtime.put_configuration(mcp_runtime, relabelled)
  let assert Ok(after_update) = runtime.configuration(mcp_runtime, "research")
  assert after_update.label == "Renamed"
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
  let assert Ok(current) = runtime.configuration(mcp_runtime, "mixed")
  let assert Ok(registry) =
    harness_plugin.registry([
      mcp_plugin.new(mcp_runtime, fn() {
        runtime.load_configuration(mcp_runtime, "mixed")
      }),
    ])
  let assert Ok(plugin_runtime) =
    harness_plugin.activate(registry, harness_plugin.empty_states())
  let assert Ok(#(
    _,
    harness_plugin.ToolOutput(content: [llm.Text(listing)], is_error: False),
  )) =
    harness_plugin.invoke_tool(
      plugin_runtime,
      "mcp.list",
      harness_plugin.ToolInvocation("list", "{}"),
    )
  // The reachable server's tools are listed and the unreachable one is
  // reported rather than failing the whole listing.
  assert string.contains(listing, "available")
  assert string.contains(listing, "connection refused")
  assert string.contains(listing, "\"server_id\":\"down\"")
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
        )
      let assert Ok(value) =
        catalog.put_configuration(catalog.new(), configuration)
      let assert Ok(mcp_runtime) = runtime.start(value, envoy.get, fn() { 0 })
      let assert Ok(spec) =
        runtime.loader_spec(mcp_runtime, fn() { Ok(configuration) })
      let #(connections, listed) = connections.list(connections.new(spec))
      let assert Ok(listing) = listed
      assert !list.is_empty(listing.tools)
      let _ = connections.close(connections)
      runtime.stop(mcp_runtime)
    }
  }
}

import envoy
