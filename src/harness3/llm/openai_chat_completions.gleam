import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm.{
  type Content, type Error, type Event, type FinishReason, type HttpRequest,
  type ImageDetail, type MediaSource, type Message, type Provider, type Request,
  type Role, type Tool, ApiError, Assistant, Auto, Base64,
  ContentFilter, Developer, Document, FileId, Finished,
  High, HttpRequest, Image, InvalidRequest, InvalidResponse, Length, Low,
  MessageStart, MessageStop, Other, RefusalDelta, Stop, System, Text,
  TextDelta, ToolCall, ToolCallArgumentsDelta,
  ToolCallStart, ToolResult, ToolUse, Unsupported, Url, Usage,
  UsageReported, User,
}

pub type Config {
  Config(api_key: String, base_url: String)
}

pub fn config(api_key: String) -> Config {
  Config(api_key, "https://api.openai.com")
}

pub fn new(config: Config) -> Provider {
  llm.from_functions(
    build: fn(request) { build(config, request) },
    response: decode_response,
    stream_event: decode_stream_event,
  )
}

fn base_url(config: Config) -> String {
  let Config(base_url:, ..) = config
  case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1)
    False -> base_url
  }
}

fn build(config: Config, request: Request) -> Result(HttpRequest, Error) {
  let llm.Request(
    model:,
    messages:,
    tools:,
    max_output_tokens:,
    temperature:,
    stream:,
  ) = request
  use messages <- result.try(list.try_map(messages, encode_message))
  use tools <- result.try(list.try_map(tools, encode_tool))
  let fields = [
    #("model", json.string(model)),
    #("messages", json.preprocessed_array(messages)),
    #("tools", json.preprocessed_array(tools)),
    #("stream", json.bool(stream)),
  ]
  let fields = add_optional_int(fields, "max_completion_tokens", max_output_tokens)
  let fields = add_optional_float(fields, "temperature", temperature)
  let fields = case stream {
    True -> [
      #("stream_options", json.object([#("include_usage", json.bool(True))])),
      ..fields
    ]
    False -> fields
  }
  let Config(api_key:, ..) = config
  Ok(
    HttpRequest(
      method: "POST",
      url: base_url(config) <> "/v1/chat/completions",
      headers: [
        #("authorization", "Bearer " <> api_key),
        #("content-type", "application/json"),
      ],
      body: json.object(fields) |> json.to_string,
    ),
  )
}

fn role_name(role: Role) -> String {
  case role {
    System -> "system"
    Developer -> "developer"
    User -> "user"
    Assistant -> "assistant"
    llm.ToolRole -> "tool"
  }
}

fn encode_message(message: Message) -> Result(Json, Error) {
  let llm.Message(role:, content:) = message
  case role {
    llm.ToolRole -> encode_tool_result_message(content)
    _ -> {
      let regular = list.filter(content, fn(part) { !is_tool_call(part) })
      let calls = list.filter(content, is_tool_call)
      use regular <- result.try(list.try_map(regular, encode_content))
      use calls <- result.try(list.try_map(calls, encode_tool_call))
      let fields = [
        #("role", json.string(role_name(role))),
        #("content", json.preprocessed_array(regular)),
      ]
      let fields = case calls {
        [] -> fields
        _ -> [#("tool_calls", json.preprocessed_array(calls)), ..fields]
      }
      Ok(json.object(fields))
    }
  }
}

fn is_tool_call(content: Content) -> Bool {
  case content {
    ToolCall(..) -> True
    _ -> False
  }
}

fn encode_content(content: Content) -> Result(Json, Error) {
  case content {
    Text(text) -> Ok(json.object([
      #("type", json.string("text")),
      #("text", json.string(text)),
    ]))
    Image(source, detail) -> {
      use url <- result.try(image_url(source))
      Ok(json.object([
        #("type", json.string("image_url")),
        #("image_url", json.object([
          #("url", json.string(url)),
          #("detail", json.string(detail_name(detail))),
        ])),
      ]))
    }
    Document(FileId(id)) -> Ok(json.object([
      #("type", json.string("file")),
      #("file", json.object([#("file_id", json.string(id))])),
    ]))
    Document(_) -> Error(Unsupported("Chat Completions document URLs/base64"))
    ToolCall(..) -> Error(InvalidRequest("tool calls must be assistant content"))
    ToolResult(..) -> Error(InvalidRequest("tool results require the tool role"))
  }
}

fn image_url(source: MediaSource) -> Result(String, Error) {
  case source {
    Url(url) -> Ok(url)
    Base64(media_type, data) -> Ok("data:" <> media_type <> ";base64," <> data)
    FileId(_) -> Error(Unsupported("Chat Completions image file IDs"))
  }
}

fn detail_name(detail: ImageDetail) -> String {
  case detail {
    Auto -> "auto"
    Low -> "low"
    High -> "high"
  }
}

fn encode_tool_call(content: Content) -> Result(Json, Error) {
  case content {
    ToolCall(id, name, arguments) -> Ok(json.object([
      #("id", json.string(id)),
      #("type", json.string("function")),
      #("function", json.object([
        #("name", json.string(name)),
        #("arguments", json.string(json.to_string(arguments))),
      ])),
    ]))
    _ -> Error(InvalidRequest("expected a tool call"))
  }
}

fn encode_tool_result_message(content: List(Content)) -> Result(Json, Error) {
  case content {
    [ToolResult(id, result_content, _)] -> {
      use text <- result.try(text_only(result_content))
      Ok(json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(id)),
        #("content", json.string(text)),
      ]))
    }
    _ -> Error(InvalidRequest("tool messages require exactly one ToolResult"))
  }
}

fn text_only(content: List(Content)) -> Result(String, Error) {
  content
  |> list.try_map(fn(part) {
    case part {
      Text(text) -> Ok(text)
      _ -> Error(Unsupported("non-text Chat Completions tool results"))
    }
  })
  |> result.map(string.concat)
}

fn encode_tool(tool: Tool) -> Result(Json, Error) {
  let llm.Tool(name:, description:, input_schema:) = tool
  let function = [
    #("name", json.string(name)),
    #("parameters", input_schema),
  ]
  let function = case description {
    Some(description) -> [#("description", json.string(description)), ..function]
    None -> function
  }
  Ok(json.object([
    #("type", json.string("function")),
    #("function", json.object(function)),
  ]))
}

fn add_optional_int(fields, name, value: Option(Int)) {
  case value {
    Some(value) -> [#(name, json.int(value)), ..fields]
    None -> fields
  }
}

fn add_optional_float(fields, name, value: Option(Float)) {
  case value {
    Some(value) -> [#(name, json.float(value)), ..fields]
    None -> fields
  }
}

type UsageData {
  UsageData(input: Int, output: Int, cached: Int)
}

type ToolDelta {
  ToolDelta(index: Int, id: Option(String), name: Option(String), arguments: Option(String))
}

type Delta {
  Delta(
    role: Option(String),
    content: Option(String),
    refusal: Option(String),
    tool_calls: List(ToolDelta),
  )
}

type Choice {
  Choice(index: Int, delta: Delta, finish_reason: Option(String))
}

type Chunk {
  Chunk(id: String, model: String, choices: List(Choice), usage: Option(UsageData))
}

fn usage_decoder() -> decode.Decoder(UsageData) {
  use input <- decode.field("prompt_tokens", decode.int)
  use output <- decode.field("completion_tokens", decode.int)
  use cached <- decode.optional_field(
    "prompt_tokens_details",
    0,
    {
      use cached <- decode.optional_field("cached_tokens", 0, decode.int)
      decode.success(cached)
    },
  )
  decode.success(UsageData(input, output, cached))
}

fn tool_delta_decoder() -> decode.Decoder(ToolDelta) {
  use index <- decode.optional_field("index", 0, decode.int)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use function <- decode.optional_field(
    "function",
    #(None, None),
    {
      use name <- decode.optional_field("name", None, decode.optional(decode.string))
      use arguments <- decode.optional_field("arguments", None, decode.optional(decode.string))
      decode.success(#(name, arguments))
    },
  )
  decode.success(ToolDelta(index, id, function.0, function.1))
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use role <- decode.optional_field("role", None, decode.optional(decode.string))
  use content <- decode.optional_field("content", None, decode.optional(decode.string))
  use refusal <- decode.optional_field("refusal", None, decode.optional(decode.string))
  use tool_calls <- decode.optional_field("tool_calls", [], decode.list(of: tool_delta_decoder()))
  decode.success(Delta(role, content, refusal, tool_calls))
}

fn choice_decoder() -> decode.Decoder(Choice) {
  use index <- decode.field("index", decode.int)
  use delta <- decode.optional_field("delta", Delta(None, None, None, []), delta_decoder())
  use delta <- decode.optional_field("message", delta, delta_decoder())
  use finish <- decode.optional_field("finish_reason", None, decode.optional(decode.string))
  decode.success(Choice(index, delta, finish))
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  use id <- decode.optional_field("id", "", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use choices <- decode.optional_field("choices", [], decode.list(of: choice_decoder()))
  use usage <- decode.optional_field("usage", None, decode.optional(usage_decoder()))
  decode.success(Chunk(id, model, choices, usage))
}

fn decode_stream_event(data: String) -> Result(List(Event), Error) {
  decode_chunk(data, True)
}

fn decode_response(status: Int, body: String) -> Result(List(Event), Error) {
  case status >= 200 && status < 300 {
    True -> decode_chunk(body, False)
    False -> Error(decode_api_error(status, body))
  }
}

fn decode_chunk(data: String, streaming: Bool) -> Result(List(Event), Error) {
  use chunk <- result.try(
    json.parse(data, chunk_decoder())
    |> result.map_error(fn(error) { InvalidResponse(string.inspect(error)) }),
  )
  let Chunk(id:, model:, choices:, usage:) = chunk
  let start = case streaming, choices {
    True, [Choice(delta: Delta(role: Some(_), ..), ..), ..] -> [MessageStart(id, model)]
    False, _ -> [MessageStart(id, model)]
    _, _ -> []
  }
  let events = choices |> list.flat_map(choice_events)
  let usage = case usage {
    Some(UsageData(input, output, cached)) -> [UsageReported(Usage(
      input_tokens: Some(input),
      output_tokens: Some(output),
      cache_read_tokens: Some(cached),
      cache_write_tokens: None,
    ))]
    None -> []
  }
  let stop = case streaming {
    False -> [MessageStop]
    True -> []
  }
  Ok(list.flatten([start, events, usage, stop]))
}

fn choice_events(choice: Choice) -> List(Event) {
  let Choice(index:, delta:, finish_reason: finish) = choice
  let Delta(content:, refusal:, tool_calls:, ..) = delta
  let content_events = case content {
    Some(text) -> [TextDelta(index, text)]
    None -> []
  }
  let refusal_events = case refusal {
    Some(text) -> [RefusalDelta(index, text)]
    None -> []
  }
  let tool_events = tool_calls |> list.flat_map(fn(call) {
    let ToolDelta(index:, id:, name:, arguments:) = call
    let start = case id, name {
      Some(id), Some(name) -> [ToolCallStart(index, id, name)]
      Some(id), None -> [ToolCallStart(index, id, "")]
      None, Some(name) -> [ToolCallStart(index, "", name)]
      None, None -> []
    }
    let arguments = case arguments {
      Some(arguments) -> [ToolCallArgumentsDelta(index, arguments)]
      None -> []
    }
    list.append(start, arguments)
  })
  let finish = case finish {
    Some(reason) -> [Finished(finish_reason(reason))]
    None -> []
  }
  list.flatten([content_events, refusal_events, tool_events, finish])
}

fn finish_reason(reason: String) -> FinishReason {
  case reason {
    "stop" -> Stop
    "length" -> Length
    "tool_calls" | "function_call" -> ToolUse
    "content_filter" -> ContentFilter
    reason -> Other(reason)
  }
}

fn decode_api_error(status: Int, body: String) -> Error {
  let decoder = {
    use kind <- decode.field("error", {
      use kind <- decode.optional_field("type", "api_error", decode.string)
      decode.success(kind)
    })
    use message <- decode.field("error", {
      use message <- decode.optional_field("message", body, decode.string)
      decode.success(message)
    })
    decode.success(#(kind, message))
  }
  case json.parse(body, decoder) {
    Ok(#(kind, message)) -> ApiError(status, kind, message)
    Error(_) -> ApiError(status, "api_error", body)
  }
}
