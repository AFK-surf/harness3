//// Per-agent ownership of MCP server connections.
////
//// These connections belong to exactly one agent. They are opened from inside
//// that agent's plugin host, so the transport actors are spawn-linked to the
//// host and die with the agent, and the value holding them lives in the
//// plugin's ephemeral resource. Nothing here is shared between agents, so one
//// agent can never close or block another's servers.
////
//// This is deliberately plain state rather than a process: the plugin host is
//// already the single, serialized owner, and an intermediate actor would add
//// a hop without adding isolation — it would be linked to the host too.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol

/// How long a discovered manifest is reused before servers are re-listed.
const manifest_ttl_seconds = 300

pub type ServerFailure {
  ServerFailure(server_id: String, reason: String)
}

pub type Listing {
  Listing(
    configuration: configuration.Configuration,
    tools: List(configuration.Tool),
    failures: List(ServerFailure),
  )
}

/// Why a configuration could not be loaded. `Revoked` is authoritative — the
/// configuration is gone or disabled, so its servers must stop. `Unavailable`
/// is a transient read failure, where tearing down live transports would kill
/// OS child processes and discard HTTP sessions that are still perfectly good.
pub type LoadError {
  Revoked(reason: String)
  Unavailable(reason: String)
}

pub fn load_error_reason(error: LoadError) -> String {
  case error {
    Revoked(reason) | Unavailable(reason) -> reason
  }
}

pub type Connector =
  fn(configuration.Server, fn(String) -> Result(String, Nil)) ->
    Result(client.Connection, String)

/// Everything needed to reach an agent's servers. The configuration is read
/// through a function rather than captured once, so an operator editing it
/// reaches running agents: a changed configuration invalidates the manifest
/// and forces reconnection on next use.
pub type Spec {
  Spec(
    load_configuration: fn() -> Result(configuration.Configuration, LoadError),
    connector: Connector,
    resolve_environment: fn(String) -> Result(String, Nil),
    now_seconds: fn() -> Int,
  )
}

type Connected {
  Connected(server_id: String, client: client.Connection)
}

pub opaque type Connections {
  Connections(
    spec: Spec,
    /// The configuration the current connections were opened against.
    configuration: Option(configuration.Configuration),
    open: List(Connected),
    tools: List(configuration.Tool),
    failures: List(ServerFailure),
    discovered_at: Option(Int),
  )
}

/// Creates an unconnected value. Servers are contacted on first use, from
/// whichever process calls `list` or `call` — which must be the agent's
/// plugin host, so the transports it opens are owned by that agent.
pub fn new(spec: Spec) -> Connections {
  Connections(spec, None, [], [], [], None)
}

/// Lists the tools reachable through this agent's servers, connecting and
/// discovering first when no fresh manifest is held.
pub fn list(
  connections: Connections,
) -> #(Connections, Result(Listing, String)) {
  let #(next, discovered) = ensure_discovered(connections)
  let listing = case discovered, next.configuration {
    Error(error), _ -> Error(error)
    Ok(Nil), Some(configuration) ->
      Ok(Listing(configuration, next.tools, next.failures))
    Ok(Nil), None -> Error("MCP configuration is unavailable")
  }
  #(next, listing)
}

pub fn call(
  connections: Connections,
  broker_name: String,
  arguments: String,
) -> #(Connections, Result(protocol.CallResult, String)) {
  let #(next, discovered) = ensure_discovered(connections)
  let outcome = {
    use _ <- result.try(discovered)
    use #(connection, tool, timeout) <- result.try(prepare_call(
      next,
      broker_name,
    ))
    client.call_tool(connection, tool.name, arguments, timeout)
  }
  #(next, outcome)
}

/// Closes every open transport. The agent's plugin host dying closes them
/// anyway through the link; this is for callers that finish with them sooner.
pub fn close(connections: Connections) -> Connections {
  close_all(connections)
  Connections(..connections, open: [], discovered_at: None)
}

fn ensure_discovered(
  connections: Connections,
) -> #(Connections, Result(Nil, String)) {
  let Spec(load_configuration:, connector:, resolve_environment:, now_seconds:) =
    connections.spec
  case load_configuration() {
    // Revoked: nothing authorizes these servers any more, so stop them rather
    // than leave them running for the agent's lifetime.
    Error(Revoked(reason)) -> #(close(connections), Error(reason))
    // Transient: keep the transports and fail just this call.
    Error(Unavailable(reason)) -> #(connections, Error(reason))
    Ok(configuration) ->
      case is_fresh(connections, configuration) {
        True -> #(connections, Ok(Nil))
        False -> {
          close_all(connections)
          let #(discovered, failures) =
            discover_servers(
              configuration.servers,
              connector,
              resolve_environment,
              [],
              [],
            )
          #(
            Connections(
              ..connections,
              configuration: Some(configuration),
              open: list.map(discovered, fn(item) { item.0 }),
              tools: list.flat_map(discovered, fn(item) { item.1 }),
              failures:,
              discovered_at: Some(now_seconds()),
            ),
            Ok(Nil),
          )
        }
      }
  }
}

fn is_fresh(
  connections: Connections,
  configuration: configuration.Configuration,
) -> Bool {
  // An edited configuration must not keep serving connections opened against
  // the previous definition.
  let unchanged = connections.configuration == Some(configuration)
  case connections.discovered_at {
    None -> False
    Some(at) -> {
      let Spec(now_seconds:, ..) = connections.spec
      let within_ttl = now_seconds() - at < manifest_ttl_seconds
      // A transport that has since died forces re-listing rather than failing
      // every call until the TTL lapses.
      let live =
        list.all(connections.open, fn(entry) { client.alive(entry.client) })
      let covered =
        list.all(configuration.servers, fn(server) {
          list.any(connections.failures, fn(failure) {
            failure.server_id == server.id
          })
          || list.any(connections.open, fn(entry) {
            entry.server_id == server.id
          })
        })
      unchanged && within_ttl && live && covered
    }
  }
}

fn close_all(connections: Connections) -> Nil {
  list.each(connections.open, fn(entry) { client.close(entry.client) })
}

fn discover_servers(
  servers: List(configuration.Server),
  connector: Connector,
  resolve_environment: fn(String) -> Result(String, Nil),
  discovered: List(#(Connected, List(configuration.Tool))),
  failures: List(ServerFailure),
) -> #(List(#(Connected, List(configuration.Tool))), List(ServerFailure)) {
  case servers {
    [] -> #(list.reverse(discovered), list.reverse(failures))
    [server, ..rest] ->
      case discover_server(server, connector, resolve_environment) {
        Ok(item) ->
          discover_servers(
            rest,
            connector,
            resolve_environment,
            [item, ..discovered],
            failures,
          )
        Error(error) ->
          discover_servers(rest, connector, resolve_environment, discovered, [
            ServerFailure(server.id, error),
            ..failures
          ])
      }
  }
}

fn discover_server(
  server: configuration.Server,
  connector: Connector,
  resolve_environment: fn(String) -> Result(String, Nil),
) -> Result(#(Connected, List(configuration.Tool)), String) {
  use connection <- result.try(connector(server, resolve_environment))
  case client.initialize(connection, server.timeout_milliseconds) {
    Error(error) -> {
      client.close(connection)
      Error(error)
    }
    Ok(Nil) ->
      case
        client.list_tools(connection, server.id, server.timeout_milliseconds)
      {
        Error(error) -> {
          client.close(connection)
          Error(error)
        }
        Ok(tools) ->
          case validate_server_tools(tools) {
            Error(error) -> {
              client.close(connection)
              Error(error)
            }
            Ok(Nil) -> Ok(#(Connected(server.id, connection), tools))
          }
      }
  }
}

fn validate_server_tools(
  tools: List(configuration.Tool),
) -> Result(Nil, String) {
  tools
  |> list.try_fold([], fn(names, tool) {
    case list.contains(names, tool.name) {
      True -> Error("MCP server returned duplicate tool: " <> tool.name)
      False -> Ok([tool.name, ..names])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn prepare_call(
  connections: Connections,
  broker_name: String,
) -> Result(#(client.Connection, configuration.Tool, Int), String) {
  use configuration <- result.try(case connections.configuration {
    Some(configuration) -> Ok(configuration)
    None -> Error("MCP configuration is unavailable")
  })
  use tool <- result.try(
    list.find(connections.tools, fn(tool) { tool.broker_name == broker_name })
    |> result.map_error(fn(_) { "unknown MCP tool: " <> broker_name }),
  )
  use server <- result.try(
    list.find(configuration.servers, fn(server) { server.id == tool.server_id })
    |> result.map_error(fn(_) { "MCP tool references an unknown server" }),
  )
  use connected <- result.try(
    list.find(connections.open, fn(entry) { entry.server_id == tool.server_id })
    |> result.map_error(fn(_) {
      "MCP server is unavailable: " <> tool.server_id
    }),
  )
  Ok(#(connected.client, tool, server.timeout_milliseconds))
}
