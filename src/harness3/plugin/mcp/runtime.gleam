//// Node-wide registry of MCP *configurations*.
////
//// This owns durable configuration only — the same role `model_catalog` plays
//// for models. It deliberately owns no connections and performs no discovery:
//// connections belong to the agent that uses them (see `mcp/connections`), so
//// one agent can never tear down or block another's servers through shared
//// state.

import exception
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/plugin/mcp/catalog
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/connections
import harness3/plugin/mcp/stdio
import harness3/plugin/mcp/streamable_http

pub opaque type Runtime {
  Runtime(subject: Subject(Message))
}

pub type Connector =
  connections.Connector

type State {
  State(
    catalog: catalog.Catalog,
    connector: Connector,
    resolve_environment: fn(String) -> Result(String, Nil),
    now_seconds: fn() -> Int,
  )
}

type Message {
  GetCatalog(reply: Subject(catalog.Catalog))
  PutConfiguration(
    configuration: configuration.Configuration,
    reply: Subject(Result(Nil, String)),
  )
  GetConfiguration(
    configuration_id: String,
    reply: Subject(Result(configuration.Configuration, String)),
  )
  GetConnectionSpec(
    configuration_id: String,
    reply: Subject(Result(connections.Spec, String)),
    runtime: Subject(Message),
  )
  Stop
}

pub fn start(
  catalog: catalog.Catalog,
  resolve_environment: fn(String) -> Result(String, Nil),
  now_seconds: fn() -> Int,
) -> Result(Runtime, String) {
  start_with_connector(
    catalog,
    resolve_environment,
    now_seconds,
    connect_server,
  )
}

pub fn start_with_connector(
  catalog: catalog.Catalog,
  resolve_environment: fn(String) -> Result(String, Nil),
  now_seconds: fn() -> Int,
  connector: Connector,
) -> Result(Runtime, String) {
  actor.new(State(catalog, connector, resolve_environment, now_seconds))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Runtime(started.data) })
  |> result.map_error(fn(error) { string.inspect(error) })
}

pub fn catalog(runtime: Runtime) -> catalog.Catalog {
  let Runtime(subject) = runtime
  process.call_forever(subject, GetCatalog)
}

pub fn put_configuration(
  runtime: Runtime,
  configuration: configuration.Configuration,
) -> Result(Nil, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 5000, fn(reply) {
      PutConfiguration(configuration, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP runtime is unavailable" })
  |> result.flatten
}

/// Looks up a configuration. Every call here is served from memory, so it is
/// safe from any process — including the group coordinator.
pub fn configuration(
  runtime: Runtime,
  configuration_id: String,
) -> Result(configuration.Configuration, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 5000, fn(reply) {
      GetConfiguration(configuration_id, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP runtime is unavailable" })
  |> result.flatten
}

/// Resolves everything an agent needs to open its own connections. The caller
/// opens them itself, so the transports belong to the caller's process.
pub fn connection_spec(
  runtime: Runtime,
  configuration_id: String,
) -> Result(connections.Spec, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 5000, fn(reply) {
      GetConnectionSpec(configuration_id, reply, subject)
    })
  })
  |> result.map_error(fn(_) { "MCP runtime is unavailable" })
  |> result.flatten
}

pub fn stop(runtime: Runtime) -> Nil {
  let Runtime(subject) = runtime
  process.send(subject, Stop)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    GetCatalog(reply) -> {
      process.send(reply, state.catalog)
      actor.continue(state)
    }
    PutConfiguration(configuration, reply) ->
      case catalog.put_configuration(state.catalog, configuration) {
        Error(error) -> {
          process.send(reply, Error(string.inspect(error)))
          actor.continue(state)
        }
        Ok(next_catalog) -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, catalog: next_catalog))
        }
      }
    GetConfiguration(configuration_id, reply) -> {
      process.send(reply, enabled_configuration(state, configuration_id))
      actor.continue(state)
    }
    GetConnectionSpec(configuration_id, reply, runtime) -> {
      process.send(
        reply,
        enabled_configuration(state, configuration_id)
          |> result.map(fn(_) {
            connections.Spec(
              // Re-read on every discovery so configuration edits reach
              // agents that are already running.
              fn() { configuration_of(runtime, configuration_id) },
              state.connector,
              state.resolve_environment,
              state.now_seconds,
            )
          }),
      )
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

/// Distinguishes an authoritative answer ("this configuration is gone or
/// disabled") from a failure to reach the registry at all. Only the former may
/// tear down an agent's live transports.
fn configuration_of(
  runtime: Subject(Message),
  configuration_id: String,
) -> Result(configuration.Configuration, connections.LoadError) {
  case
    exception.rescue(fn() {
      process.call(runtime, 5000, fn(reply) {
        GetConfiguration(configuration_id, reply)
      })
    })
  {
    Error(_) -> Error(connections.Unavailable("MCP runtime is unavailable"))
    Ok(Error(reason)) -> Error(connections.Revoked(reason))
    Ok(Ok(configuration)) -> Ok(configuration)
  }
}

fn enabled_configuration(
  state: State,
  id: String,
) -> Result(configuration.Configuration, String) {
  use configuration <- result.try(
    catalog.lookup(state.catalog, id)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case configuration.enabled {
    True -> Ok(configuration)
    False -> Error("MCP configuration is disabled: " <> id)
  }
}

fn connect_server(
  server: configuration.Server,
  resolve_environment: fn(String) -> Result(String, Nil),
) -> Result(client.Connection, String) {
  case server.transport {
    configuration.Stdio(..) -> stdio.connect(server, resolve_environment)
    configuration.StreamableHttp(..) ->
      streamable_http.connect(server, resolve_environment)
  }
}
