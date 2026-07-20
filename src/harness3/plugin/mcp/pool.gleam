//// Per-agent ownership of MCP server connections.
////
//// A pool belongs to exactly one agent: it is started from inside that
//// agent's plugin host (so it is linked to the host and dies with the agent)
//// and its handle is kept in the plugin's ephemeral resource. Connections are
//// therefore never shared between agents, and one agent's discovery can never
//// close a connection another agent is calling through.

import exception
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol

/// How long a discovered manifest is reused before the pool re-lists tools.
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

pub type Connector =
  fn(configuration.Server, fn(String) -> Result(String, Nil)) ->
    Result(client.Connection, String)

/// Everything a pool needs to reach its servers. The configuration is read
/// through a function rather than captured once, so an operator editing it
/// reaches running agents: a changed configuration invalidates the manifest
/// and forces reconnection on the next use.
pub type Spec {
  Spec(
    load_configuration: fn() -> Result(configuration.Configuration, String),
    connector: Connector,
    resolve_environment: fn(String) -> Result(String, Nil),
    now_seconds: fn() -> Int,
  )
}

pub opaque type Pool {
  Pool(subject: Subject(Message))
}

type Connected {
  Connected(server_id: String, client: client.Connection)
}

type State {
  State(
    spec: Spec,
    /// The configuration the current connections were opened against.
    configuration: Option(configuration.Configuration),
    connections: List(Connected),
    tools: List(configuration.Tool),
    failures: List(ServerFailure),
    discovered_at: Option(Int),
  )
}

type Message {
  List(reply: Subject(Result(Listing, String)))
  Call(
    exposed_name: String,
    arguments: String,
    reply: Subject(Result(protocol.CallResult, String)),
  )
  Stop
}

/// Starts a pool. Call this from the process that should own it — inside an
/// agent's plugin host — so the link ties the pool's lifetime to that agent.
pub fn start(spec: Spec) -> Result(Pool, String) {
  actor.new(State(spec, None, [], [], [], None))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Pool(started.data) })
  |> result.map_error(fn(error) { string.inspect(error) })
}

/// Lists the tools reachable through this agent's servers, discovering first
/// when no fresh manifest is held. Blocks the calling plugin host only.
pub fn list(pool: Pool, timeout: Int) -> Result(Listing, String) {
  let Pool(subject) = pool
  exception.rescue(fn() { process.call(subject, timeout, List) })
  |> result.map_error(fn(_) { "MCP connections are unavailable" })
  |> result.flatten
}

pub fn call(
  pool: Pool,
  exposed_name: String,
  arguments: String,
  timeout: Int,
) -> Result(protocol.CallResult, String) {
  let Pool(subject) = pool
  exception.rescue(fn() {
    process.call(subject, timeout, fn(reply) {
      Call(exposed_name, arguments, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP tool call timed out" })
  |> result.flatten
}

pub fn stop(pool: Pool) -> Nil {
  let Pool(subject) = pool
  process.send(subject, Stop)
}

pub fn alive(pool: Pool) -> Bool {
  let Pool(subject) = pool
  case process.subject_owner(subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    List(reply) -> {
      let #(next, loaded) = ensure_discovered(state)
      process.send(reply, case loaded, next.configuration {
        Error(error), _ -> Error(error)
        Ok(Nil), Some(configuration) ->
          Ok(Listing(configuration, next.tools, next.failures))
        Ok(Nil), None -> Error("MCP configuration is unavailable")
      })
      actor.continue(next)
    }
    Call(exposed_name, arguments, reply) -> {
      let #(next, loaded) = ensure_discovered(state)
      case result.try(loaded, fn(_) { prepare_call(next, exposed_name) }) {
        Error(error) -> process.send(reply, Error(error))
        Ok(#(connection, tool, timeout)) ->
          // Run the call outside the pool so a slow tool does not block this
          // agent's own `mcp.list`, and so the pool can still be stopped.
          process.spawn_unlinked(fn() {
            process.send(
              reply,
              client.call_tool(connection, tool.name, arguments, timeout),
            )
          })
          |> fn(_) { Nil }
      }
      actor.continue(next)
    }
    Stop -> {
      close_all(state)
      actor.stop()
    }
  }
}

fn ensure_discovered(state: State) -> #(State, Result(Nil, String)) {
  let Spec(load_configuration:, connector:, resolve_environment:, now_seconds:) =
    state.spec
  case load_configuration() {
    Error(error) -> #(state, Error(error))
    Ok(configuration) ->
      case is_fresh(state, configuration) {
        True -> #(state, Ok(Nil))
        False -> {
          close_all(state)
          let #(discovered, failures) =
            discover_servers(
              configuration.servers,
              connector,
              resolve_environment,
              [],
              [],
            )
          #(
            State(
              ..state,
              configuration: Some(configuration),
              connections: list.map(discovered, fn(item) { item.0 }),
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

fn is_fresh(state: State, configuration: configuration.Configuration) -> Bool {
  // An edited configuration must not keep serving connections opened against
  // the previous definition.
  let unchanged = state.configuration == Some(configuration)
  case state.discovered_at {
    None -> False
    Some(at) -> {
      let Spec(now_seconds:, ..) = state.spec
      let within_ttl = now_seconds() - at < manifest_ttl_seconds
      // A connection that has since died forces a re-listing rather than
      // failing every call until the TTL lapses.
      let live =
        list.all(state.connections, fn(entry) { client.alive(entry.client) })
      let covered =
        list.all(configuration.servers, fn(server) {
          list.any(state.failures, fn(failure) {
            failure.server_id == server.id
          })
          || list.any(state.connections, fn(entry) {
            entry.server_id == server.id
          })
        })
      unchanged && within_ttl && live && covered
    }
  }
}

fn close_all(state: State) -> Nil {
  list.each(state.connections, fn(entry) { client.close(entry.client) })
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
  state: State,
  exposed_name: String,
) -> Result(#(client.Connection, configuration.Tool, Int), String) {
  use configuration <- result.try(case state.configuration {
    Some(configuration) -> Ok(configuration)
    None -> Error("MCP configuration is unavailable")
  })
  use tool <- result.try(
    list.find(state.tools, fn(tool) { tool.exposed_name == exposed_name })
    |> result.map_error(fn(_) { "unknown MCP tool: " <> exposed_name }),
  )
  use server <- result.try(
    list.find(configuration.servers, fn(server) { server.id == tool.server_id })
    |> result.map_error(fn(_) { "MCP tool references an unknown server" }),
  )
  use connected <- result.try(
    list.find(state.connections, fn(entry) { entry.server_id == tool.server_id })
    |> result.map_error(fn(_) {
      "MCP server is unavailable: " <> tool.server_id
    }),
  )
  Ok(#(connected.client, tool, server.timeout_milliseconds))
}
