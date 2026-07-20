import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/json_document

pub type InitializeResult {
  InitializeResult(protocol_version: String, tools: Bool)
}

pub type ToolPage {
  ToolPage(tools: List(configuration.Tool), next_cursor: Option(String))
}

pub type Content {
  Text(text: String)
  Image(data: String, media_type: String)
  Other(document: String)
}

pub type CallResult {
  CallResult(
    content: List(Content),
    structured_content: Option(String),
    is_error: Bool,
  )
}

pub fn request(id: Int, method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(id)),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

pub fn notification(method: String, params: json.Json) -> String {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("method", json.string(method)),
    #("params", params),
  ])
  |> json.to_string
}

pub fn response_id(document: String) -> Result(Int, Nil) {
  json.parse(document, id_decoder())
  |> result.map_error(fn(_) { Nil })
}

pub fn initialize_params() -> json.Json {
  json.object([
    #("protocolVersion", json.string(configuration.protocol_version)),
    #("capabilities", json.object([])),
    #(
      "clientInfo",
      json.object([
        #("name", json.string("harness3")),
        #("version", json.string("1.0.0")),
      ]),
    ),
  ])
}

pub fn decode_initialize(document: String) -> Result(InitializeResult, String) {
  use _ <- result.try(check_error(document))
  json.parse(document, initialize_response_decoder())
  |> result.map_error(fn(error) {
    "invalid MCP initialize response: " <> string.inspect(error)
  })
}

pub fn decode_tools_page(
  document: String,
  server_id: String,
) -> Result(ToolPage, String) {
  use _ <- result.try(check_error(document))
  json.parse(document, tools_response_decoder(server_id))
  |> result.map_error(fn(error) {
    "invalid MCP tools/list response: " <> string.inspect(error)
  })
}

pub fn decode_call_result(document: String) -> Result(CallResult, String) {
  use _ <- result.try(check_error(document))
  json.parse(document, call_response_decoder())
  |> result.map_error(fn(error) {
    "invalid MCP tools/call response: " <> string.inspect(error)
  })
}

pub fn tools_list_params(cursor: Option(String)) -> json.Json {
  case cursor {
    None -> json.object([])
    Some(cursor) -> json.object([#("cursor", json.string(cursor))])
  }
}

pub fn tools_call_params(
  name: String,
  arguments: String,
) -> Result(json.Json, String) {
  use arguments <- result.try(json_document.parse_object(arguments))
  Ok(
    json.object([
      #("name", json.string(name)),
      #("arguments", arguments),
    ]),
  )
}

fn id_decoder() -> decode.Decoder(Int) {
  use id <- decode.field("id", decode.int)
  decode.success(id)
}

fn initialize_response_decoder() -> decode.Decoder(InitializeResult) {
  use initialized <- decode.field("result", initialize_result_decoder())
  decode.success(initialized)
}

fn initialize_result_decoder() -> decode.Decoder(InitializeResult) {
  use protocol_version <- decode.field("protocolVersion", decode.string)
  use tools <- decode.field("capabilities", tools_capability_decoder())
  decode.success(InitializeResult(protocol_version, tools))
}

fn tools_capability_decoder() -> decode.Decoder(Bool) {
  use tools <- decode.optional_field(
    "tools",
    None,
    decode.optional(decode.dynamic),
  )
  decode.success(tools != None)
}

fn tools_response_decoder(server_id: String) -> decode.Decoder(ToolPage) {
  use page <- decode.field("result", tools_page_decoder(server_id))
  decode.success(page)
}

fn tools_page_decoder(server_id: String) -> decode.Decoder(ToolPage) {
  use tools <- decode.field("tools", decode.list(of: tool_decoder(server_id)))
  use next_cursor <- decode.optional_field(
    "nextCursor",
    None,
    decode.optional(decode.string),
  )
  decode.success(ToolPage(tools, next_cursor))
}

fn tool_decoder(server_id: String) -> decode.Decoder(configuration.Tool) {
  use name <- decode.field("name", decode.string)
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use input_schema <- decode.field(
    "inputSchema",
    json_document.object_decoder(),
  )
  use output_schema <- decode.optional_field(
    "outputSchema",
    None,
    decode.optional(json_document.object_decoder()),
  )
  decode.success(configuration.Tool(
    server_id:,
    name:,
    exposed_name: configuration.exposed_tool_name(server_id, name),
    description:,
    input_schema:,
    output_schema:,
  ))
}

fn call_response_decoder() -> decode.Decoder(CallResult) {
  use call <- decode.field("result", call_result_decoder())
  decode.success(call)
}

fn call_result_decoder() -> decode.Decoder(CallResult) {
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(of: content_decoder()),
  )
  use structured <- decode.optional_field(
    "structuredContent",
    None,
    decode.optional(json_document_decoder()),
  )
  use is_error <- decode.optional_field("isError", False, decode.bool)
  decode.success(CallResult(content, structured, is_error))
}

fn content_decoder() -> decode.Decoder(Content) {
  decode.dynamic
  |> decode.then(fn(value) {
    case decode.run(value, content_type_decoder()) {
      Ok("text") ->
        decode.run(value, text_value_decoder())
        |> decoder_result(Text, Other(json_document.to_string(value)))
      Ok("image") -> {
        let decoded = {
          use data <- result.try(decode.run(value, image_data_decoder()))
          use media_type <- result.try(decode.run(
            value,
            image_media_type_decoder(),
          ))
          Ok(Image(data, media_type))
        }
        case decoded {
          Ok(content) -> decode.success(content)
          Error(_) -> decode.success(Other(json_document.to_string(value)))
        }
      }
      _ -> decode.success(Other(json_document.to_string(value)))
    }
  })
}

fn content_type_decoder() -> decode.Decoder(String) {
  use value <- decode.field("type", decode.string)
  decode.success(value)
}

fn text_value_decoder() -> decode.Decoder(String) {
  use value <- decode.field("text", decode.string)
  decode.success(value)
}

fn image_data_decoder() -> decode.Decoder(String) {
  use value <- decode.field("data", decode.string)
  decode.success(value)
}

fn image_media_type_decoder() -> decode.Decoder(String) {
  use value <- decode.field("mimeType", decode.string)
  decode.success(value)
}

fn decoder_result(
  value: Result(a, List(decode.DecodeError)),
  wrap: fn(a) -> Content,
  fallback: Content,
) -> decode.Decoder(Content) {
  case value {
    Ok(value) -> decode.success(wrap(value))
    Error(_) -> decode.success(fallback)
  }
}

fn check_error(document: String) -> Result(Nil, String) {
  case json.parse(document, optional_error_decoder()) {
    Ok(None) -> Ok(Nil)
    Ok(Some(#(code, message))) ->
      Error("MCP error " <> int_to_string(code) <> ": " <> message)
    Error(error) -> Error("invalid MCP response: " <> string.inspect(error))
  }
}

fn optional_error_decoder() -> decode.Decoder(Option(#(Int, String))) {
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(error_decoder()),
  )
  decode.success(error)
}

fn error_decoder() -> decode.Decoder(#(Int, String)) {
  use code <- decode.optional_field("code", 0, decode.int)
  use message <- decode.optional_field(
    "message",
    "MCP request failed",
    decode.string,
  )
  decode.success(#(code, message))
}

fn json_document_decoder() -> decode.Decoder(String) {
  decode.dynamic |> decode.map(json_document.to_string)
}

fn int_to_string(value: Int) -> String {
  value |> json.int |> json.to_string
}
