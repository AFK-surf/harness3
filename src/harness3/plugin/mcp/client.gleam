import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import harness3/plugin/mcp/configuration.{type Tool}
import harness3/plugin/mcp/protocol

pub opaque type Connection {
  Connection(
    request: fn(String, json.Json, Int) -> Result(String, String),
    notify: fn(String, json.Json) -> Result(Nil, String),
    close: fn() -> Nil,
    alive: fn() -> Bool,
  )
}

pub fn connection(
  request: fn(String, json.Json, Int) -> Result(String, String),
  notify: fn(String, json.Json) -> Result(Nil, String),
  close: fn() -> Nil,
) -> Connection {
  Connection(request, notify, close, fn() { True })
}

/// Adds a liveness probe so a holder can tell a dropped transport from a fresh
/// one and re-discover instead of failing every call.
pub fn with_liveness(
  connection: Connection,
  alive: fn() -> Bool,
) -> Connection {
  Connection(..connection, alive: alive)
}

pub fn initialize(connection: Connection, timeout: Int) -> Result(Nil, String) {
  let Connection(request:, notify:, ..) = connection
  use document <- result.try(request(
    "initialize",
    protocol.initialize_params(),
    timeout,
  ))
  use initialized <- result.try(protocol.decode_initialize(document))
  // Initialization is a negotiation: the server answers with the version it
  // will actually speak, which is legitimately an older revision than the one
  // proposed. Accepting only an exact match rejects essentially every server
  // in the field, so accept any revision this client understands.
  use _ <- result.try(
    case
      list.contains(configuration.supported_protocol_versions, {
        initialized.protocol_version
      })
    {
      True -> Ok(Nil)
      False ->
        Error(
          "unsupported MCP protocol version: " <> initialized.protocol_version,
        )
    },
  )
  use _ <- result.try(case initialized.tools {
    True -> Ok(Nil)
    False -> Error("MCP server does not advertise the tools capability")
  })
  notify("notifications/initialized", json.object([]))
}

pub fn list_tools(
  connection: Connection,
  server_id: String,
  timeout: Int,
) -> Result(List(Tool), String) {
  list_tool_pages(connection, server_id, timeout, None, [], 0)
}

/// Caps the tool manifest a single server can contribute. Every listed tool
/// is serialized into the agent's context by `mcp.list`, so an unbounded (or
/// hostile) server would otherwise exhaust memory and the context window.
const maximum_tools = 500

const maximum_pages = 100

fn list_tool_pages(
  connection: Connection,
  server_id: String,
  timeout: Int,
  cursor: Option(String),
  accumulated: List(Tool),
  page_count: Int,
) -> Result(List(Tool), String) {
  use _ <- result.try(case page_count < maximum_pages {
    True -> Ok(Nil)
    False -> Error("MCP tools/list exceeded 100 pages")
  })
  let Connection(request:, ..) = connection
  use document <- result.try(request(
    "tools/list",
    protocol.tools_list_params(cursor),
    timeout,
  ))
  use page <- result.try(protocol.decode_tools_page(document, server_id))
  // Prepended in reverse and flipped once at the end: appending each page
  // would be quadratic in page count.
  let accumulated =
    list.fold(page.tools, accumulated, fn(items, tool) { [tool, ..items] })
  use _ <- result.try(case list.length(accumulated) <= maximum_tools {
    True -> Ok(Nil)
    False -> Error("MCP server returned more than 500 tools")
  })
  case page.next_cursor {
    None -> Ok(list.reverse(accumulated))
    Some(next) ->
      list_tool_pages(
        connection,
        server_id,
        timeout,
        Some(next),
        accumulated,
        page_count + 1,
      )
  }
}

pub fn call_tool(
  connection: Connection,
  name: String,
  arguments: String,
  timeout: Int,
) -> Result(protocol.CallResult, String) {
  let Connection(request:, ..) = connection
  use params <- result.try(protocol.tools_call_params(name, arguments))
  use document <- result.try(request("tools/call", params, timeout))
  protocol.decode_call_result(document)
}

pub fn close(connection: Connection) -> Nil {
  let Connection(close:, ..) = connection
  close()
}

/// Whether the transport process backing this connection is still running.
pub fn alive(connection: Connection) -> Bool {
  let Connection(alive:, ..) = connection
  alive()
}

/// Sends a request over this connection. Exposed so wrappers (tests, tracing)
/// can delegate without reimplementing the transport.
pub fn request(
  connection: Connection,
  method: String,
  params: json.Json,
  timeout: Int,
) -> Result(String, String) {
  let Connection(request:, ..) = connection
  request(method, params, timeout)
}

pub fn notify(
  connection: Connection,
  method: String,
  params: json.Json,
) -> Result(Nil, String) {
  let Connection(notify:, ..) = connection
  notify(method, params)
}
