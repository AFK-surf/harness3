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
  )
}

pub fn connection(
  request: fn(String, json.Json, Int) -> Result(String, String),
  notify: fn(String, json.Json) -> Result(Nil, String),
  close: fn() -> Nil,
) -> Connection {
  Connection(request, notify, close)
}

pub fn initialize(connection: Connection, timeout: Int) -> Result(Nil, String) {
  let Connection(request:, notify:, ..) = connection
  use document <- result.try(request(
    "initialize",
    protocol.initialize_params(),
    timeout,
  ))
  use initialized <- result.try(protocol.decode_initialize(document))
  use _ <- result.try(
    case initialized.protocol_version == configuration.protocol_version {
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

fn list_tool_pages(
  connection: Connection,
  server_id: String,
  timeout: Int,
  cursor: Option(String),
  accumulated: List(Tool),
  page_count: Int,
) -> Result(List(Tool), String) {
  use _ <- result.try(case page_count < 100 {
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
  let accumulated = list.append(accumulated, page.tools)
  case page.next_cursor {
    None -> Ok(accumulated)
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
