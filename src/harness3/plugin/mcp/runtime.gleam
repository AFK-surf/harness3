import exception
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/plugin/mcp/catalog
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol
import harness3/plugin/mcp/stdio
import harness3/plugin/mcp/streamable_http

pub type Snapshot {
  Snapshot(catalog_revision: Int, configuration: configuration.Configuration)
}

pub opaque type Runtime {
  Runtime(subject: Subject(Message))
}

pub type Connector =
  fn(configuration.Server, fn(String) -> Result(String, Nil)) ->
    Result(client.Connection, String)

type Connected {
  Connected(
    configuration_id: String,
    server_id: String,
    client: client.Connection,
  )
}

type State {
  State(
    catalog: catalog.Catalog,
    connections: List(Connected),
    connector: Connector,
    resolve_environment: fn(String) -> Result(String, Nil),
    now_seconds: fn() -> Int,
  )
}

type Message {
  GetCatalog(reply: Subject(catalog.Catalog))
  GetSnapshot(
    configuration_id: String,
    reply: Subject(Result(Snapshot, String)),
  )
  Refresh(configuration_id: String, reply: Subject(Result(Nil, String)))
  Call(
    configuration_id: String,
    exposed_name: String,
    arguments: String,
    reply: Subject(Result(protocol.CallResult, String)),
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
  actor.new(State(catalog, [], connector, resolve_environment, now_seconds))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Runtime(started.data) })
  |> result.map_error(fn(error) { string.inspect(error) })
}

pub fn catalog(runtime: Runtime) -> catalog.Catalog {
  let Runtime(subject) = runtime
  process.call_forever(subject, GetCatalog)
}

pub fn snapshot(
  runtime: Runtime,
  configuration_id: String,
) -> Result(Snapshot, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 5000, fn(reply) {
      GetSnapshot(configuration_id, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP runtime is unavailable" })
  |> result.flatten
}

pub fn refresh(
  runtime: Runtime,
  configuration_id: String,
) -> Result(Nil, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 3_600_000, fn(reply) {
      Refresh(configuration_id, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP refresh timed out" })
  |> result.flatten
}

pub fn call(
  runtime: Runtime,
  configuration_id: String,
  exposed_name: String,
  arguments: String,
) -> Result(protocol.CallResult, String) {
  let Runtime(subject) = runtime
  exception.rescue(fn() {
    process.call(subject, 301_000, fn(reply) {
      Call(configuration_id, exposed_name, arguments, reply)
    })
  })
  |> result.map_error(fn(_) { "MCP tool call timed out" })
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
    GetSnapshot(configuration_id, reply) -> {
      let snapshot = case catalog.lookup(state.catalog, configuration_id) {
        Error(error) -> Error(string.inspect(error))
        Ok(configuration) ->
          case configuration.enabled {
            True -> Ok(Snapshot(catalog.revision(state.catalog), configuration))
            False ->
              Error("MCP configuration is disabled: " <> configuration_id)
          }
      }
      process.send(reply, snapshot)
      actor.continue(state)
    }
    Refresh(configuration_id, reply) -> {
      case refresh_configuration(state, configuration_id) {
        Ok(next) -> {
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Call(configuration_id, exposed_name, arguments, reply) -> {
      let outcome = prepare_call(state, configuration_id, exposed_name)
      case outcome {
        Error(error) -> process.send(reply, Error(error))
        Ok(#(connection, tool, timeout)) -> {
          let _ =
            process.spawn_unlinked(fn() {
              process.send(
                reply,
                client.call_tool(connection, tool.name, arguments, timeout),
              )
            })
          Nil
        }
      }
      actor.continue(state)
    }
    Stop -> {
      list.each(state.connections, fn(entry) { client.close(entry.client) })
      actor.stop()
    }
  }
}

fn refresh_configuration(state: State, id: String) -> Result(State, String) {
  use configuration <- result.try(
    catalog.lookup(state.catalog, id)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use _ <- result.try(case configuration.enabled {
    True -> Ok(Nil)
    False -> Error("MCP configuration is disabled: " <> id)
  })
  use discovered <- result.try(
    discover_servers(configuration.servers, id, state, []),
  )
  let connections = list.map(discovered, fn(item) { item.0 })
  let tools = discovered |> list.flat_map(fn(item) { item.1 })
  let updated =
    configuration.Configuration(
      ..configuration,
      manifest: Some(configuration.Manifest(state.now_seconds(), tools)),
    )
  case catalog.put_configuration(state.catalog, updated) {
    Error(error) -> {
      list.each(connections, fn(entry) { client.close(entry.client) })
      Error(string.inspect(error))
    }
    Ok(next_catalog) -> {
      let #(old, retained) =
        list.partition(state.connections, fn(entry) {
          entry.configuration_id == id
        })
      list.each(old, fn(entry) { client.close(entry.client) })
      Ok(
        State(
          ..state,
          catalog: next_catalog,
          connections: list.append(retained, connections),
        ),
      )
    }
  }
}

fn discover_servers(
  servers: List(configuration.Server),
  configuration_id: String,
  state: State,
  discovered: List(#(Connected, List(configuration.Tool))),
) -> Result(List(#(Connected, List(configuration.Tool))), String) {
  case servers {
    [] -> Ok(list.reverse(discovered))
    [server, ..rest] -> {
      let outcome = {
        use connection <- result.try(state.connector(
          server,
          state.resolve_environment,
        ))
        case client.initialize(connection, server.timeout_milliseconds) {
          Error(error) -> {
            client.close(connection)
            Error(server.id <> ": " <> error)
          }
          Ok(Nil) ->
            case
              client.list_tools(
                connection,
                server.id,
                server.timeout_milliseconds,
              )
            {
              Error(error) -> {
                client.close(connection)
                Error(server.id <> ": " <> error)
              }
              Ok(tools) ->
                Ok(#(Connected(configuration_id, server.id, connection), tools))
            }
        }
      }
      case outcome {
        Ok(item) ->
          discover_servers(rest, configuration_id, state, [item, ..discovered])
        Error(error) -> {
          list.each(discovered, fn(item) { client.close(item.0.client) })
          Error(error)
        }
      }
    }
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

fn prepare_call(
  state: State,
  configuration_id: String,
  exposed_name: String,
) -> Result(#(client.Connection, configuration.Tool, Int), String) {
  use configuration <- result.try(
    catalog.lookup(state.catalog, configuration_id)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use _ <- result.try(case configuration.enabled {
    True -> Ok(Nil)
    False -> Error("MCP configuration is disabled: " <> configuration_id)
  })
  use manifest <- result.try(case configuration.manifest {
    Some(manifest) -> Ok(manifest)
    None -> Error("MCP configuration has no discovered tool manifest")
  })
  use tool <- result.try(
    list.find(manifest.tools, fn(tool) { tool.exposed_name == exposed_name })
    |> result.map_error(fn(_) { "unknown MCP tool: " <> exposed_name }),
  )
  use server <- result.try(
    list.find(configuration.servers, fn(server) { server.id == tool.server_id })
    |> result.map_error(fn(_) { "MCP tool references an unknown server" }),
  )
  use connected <- result.try(
    list.find(state.connections, fn(entry) {
      entry.configuration_id == configuration_id
      && entry.server_id == tool.server_id
    })
    |> result.map_error(fn(_) {
      "MCP server is unavailable: " <> tool.server_id
    }),
  )
  Ok(#(connected.client, tool, server.timeout_milliseconds))
}
