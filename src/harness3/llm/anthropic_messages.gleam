import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm.{
  type Content, type Error, type Event, type FinishReason, type HttpRequest,
  type MediaSource, type Message, type Provider, type Request, type Role,
  type Tool, AnthropicRedactedReasoning, AnthropicSignedReasoning, ApiError,
  Assistant, Base64, ContentFilter, ContentStart, Developer, Document, Finished,
  HttpRequest, Image, InvalidRequest, InvalidResponse, Length, MessageStart,
  MessageStop, Other, Paused, Reasoning, ReasoningContent, ReasoningDelta,
  ReasoningEncrypted, Stop, System, Text, TextContent, TextDelta, ToolCall,
  ToolCallArgumentsDelta, ToolCallStart, ToolResult, ToolUse, Unsupported, Url,
  Usage, UsageReported, User,
}

pub type Config {
  Config(api_key: String, base_url: String, api_version: String)
}

pub fn config(api_key: String) -> Config {
  Config(api_key, "https://api.anthropic.com", "2023-06-01")
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
    reasoning_effort:,
    stream:,
  ) = request
  let needs_files_beta = uses_file_ids(messages)
  use system <- result.try(encode_system(messages))
  use messages <- result.try(
    messages
    |> list.filter(fn(message) {
      let llm.Message(role:, ..) = message
      role != System && role != Developer
    })
    |> list.try_map(encode_message),
  )
  use tools <- result.try(list.try_map(tools, encode_tool))
  let fields = [
    #("model", json.string(model)),
    #("max_tokens", json.int(max_output_tokens |> option_int(1024))),
    #("messages", json.preprocessed_array(messages)),
    #("stream", json.bool(stream)),
    // Anthropic caches nothing without an explicit breakpoint; the top-level
    // marker auto-places it on the last cacheable block, so each turn extends
    // the cached prefix.
    #("cache_control", json.object([#("type", json.string("ephemeral"))])),
  ]
  let fields = case tools {
    [] -> fields
    _ -> [#("tools", json.preprocessed_array(tools)), ..fields]
  }
  let fields = case system {
    "" -> fields
    _ -> [#("system", json.string(system)), ..fields]
  }
  // Adaptive thinking with an effort hint; requires a Claude 4.6+ model.
  let fields = case reasoning_effort {
    Some(effort) -> [
      #("thinking", json.object([#("type", json.string("adaptive"))])),
      #("output_config", json.object([#("effort", json.string(effort))])),
      ..fields
    ]
    None -> fields
  }
  let Config(api_key:, api_version:, ..) = config
  let headers = [
    #("x-api-key", api_key),
    #("anthropic-version", api_version),
    #("content-type", "application/json"),
  ]
  // File references are rejected without the Files API beta opt-in.
  let headers = case needs_files_beta {
    True -> [#("anthropic-beta", "files-api-2025-04-14"), ..headers]
    False -> headers
  }
  Ok(HttpRequest(
    method: "POST",
    url: base_url(config) <> "/v1/messages",
    headers:,
    body: json.object(fields) |> json.to_string,
  ))
}

fn uses_file_ids(messages: List(Message)) -> Bool {
  list.any(messages, fn(message) {
    let llm.Message(content:, ..) = message
    list.any(content, content_uses_file_id)
  })
}

fn content_uses_file_id(content: Content) -> Bool {
  case content {
    Image(llm.FileId(_), _) | Document(llm.FileId(_)) -> True
    ToolResult(_, content, _) -> list.any(content, content_uses_file_id)
    _ -> False
  }
}

fn option_int(value: Option(Int), fallback: Int) -> Int {
  case value {
    Some(value) -> value
    None -> fallback
  }
}

fn encode_system(messages: List(Message)) -> Result(String, Error) {
  messages
  |> list.filter_map(fn(message) {
    let llm.Message(role:, content:) = message
    case role {
      System | Developer -> Ok(content)
      _ -> Error(Nil)
    }
  })
  |> list.flatten
  |> list.try_map(fn(content) {
    case content {
      Text(text) -> Ok(text)
      _ -> Error(InvalidRequest("Anthropic system messages must be text"))
    }
  })
  |> result.map(fn(parts) { string.join(parts, "\n") })
}

fn encode_message(message: Message) -> Result(Json, Error) {
  let llm.Message(role:, content:) = message
  use content <- result.try(list.try_map(content, encode_content))
  Ok(
    json.object([
      #("role", json.string(role_name(role))),
      #("content", json.preprocessed_array(content)),
    ]),
  )
}

fn role_name(role: Role) -> String {
  case role {
    Assistant -> "assistant"
    User | llm.ToolRole -> "user"
    System | Developer -> "user"
  }
}

fn encode_content(content: Content) -> Result(Json, Error) {
  case content {
    Text(text) ->
      Ok(
        json.object([
          #("type", json.string("text")),
          #("text", json.string(text)),
        ]),
      )
    Image(source, _) ->
      Ok(
        json.object([
          #("type", json.string("image")),
          #("source", encode_source(source)),
        ]),
      )
    Document(source) ->
      Ok(
        json.object([
          #("type", json.string("document")),
          #("source", encode_source(source)),
        ]),
      )
    ToolCall(id, name, arguments) ->
      Ok(
        json.object([
          #("type", json.string("tool_use")),
          #("id", json.string(id)),
          #("name", json.string(name)),
          #("input", arguments),
        ]),
      )
    ToolResult(id, content, is_error) -> {
      use content <- result.try(list.try_map(content, encode_result_content))
      Ok(
        json.object([
          #("type", json.string("tool_result")),
          #("tool_use_id", json.string(id)),
          #("content", json.preprocessed_array(content)),
          #("is_error", json.bool(is_error)),
        ]),
      )
    }
    Reasoning(summary, Some(AnthropicSignedReasoning(signature))) ->
      Ok(
        json.object([
          #("type", json.string("thinking")),
          #("thinking", json.string(string.concat(summary))),
          #("signature", json.string(signature)),
        ]),
      )
    Reasoning(_, Some(AnthropicRedactedReasoning(data))) ->
      Ok(
        json.object([
          #("type", json.string("redacted_thinking")),
          #("data", json.string(data)),
        ]),
      )
    Reasoning(_, Some(_)) ->
      Error(InvalidRequest(
        "encrypted reasoning belongs to a different provider",
      ))
    Reasoning(_, None) ->
      Error(InvalidRequest(
        "Anthropic reasoning input requires signed or redacted provider state",
      ))
  }
}

fn encode_result_content(content: Content) -> Result(Json, Error) {
  case content {
    Text(_) | Image(_, _) -> encode_content(content)
    Document(_) ->
      Error(Unsupported("Anthropic document blocks inside tool results"))
    _ -> Error(InvalidRequest("nested tool calls/results are not supported"))
  }
}

fn encode_source(source: MediaSource) -> Json {
  case source {
    Url(url) ->
      json.object([
        #("type", json.string("url")),
        #("url", json.string(url)),
      ])
    Base64(media_type, data) ->
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(media_type)),
        #("data", json.string(data)),
      ])
    llm.FileId(id) ->
      json.object([
        #("type", json.string("file")),
        #("file_id", json.string(id)),
      ])
  }
}

fn encode_tool(tool: Tool) -> Result(Json, Error) {
  let llm.Tool(name:, description:, input_schema:) = tool
  let fields = [
    #("name", json.string(name)),
    #("input_schema", input_schema),
  ]
  let fields = case description {
    Some(description) -> [#("description", json.string(description)), ..fields]
    None -> fields
  }
  Ok(json.object(fields))
}

type UsageData {
  UsageData(
    input: Option(Int),
    output: Option(Int),
    cache_read: Option(Int),
    cache_write: Option(Int),
  )
}

type BlockData {
  BlockData(
    kind: String,
    text: String,
    thinking: String,
    id: String,
    name: String,
    input: Option(Dynamic),
    signature: String,
    data: String,
  )
}

type MessageData {
  MessageData(
    id: String,
    model: String,
    content: List(BlockData),
    stop_reason: Option(String),
    usage: UsageData,
  )
}

// `gleam_json_ffi:json_to_string` only accepts iodata built by gleam_json's
// encoders; a decoded term (an Erlang map) must be re-encoded via OTP's
// `json` module, which gleam_json already requires.
@external(erlang, "json", "encode")
fn encode_json_term(value: Dynamic) -> Dynamic

@external(erlang, "erlang", "iolist_to_binary")
fn iodata_to_string(value: Dynamic) -> String

fn dynamic_json_to_string(value: Dynamic) -> String {
  value |> encode_json_term |> iodata_to_string
}

fn usage_decoder() -> decode.Decoder(UsageData) {
  use input <- decode.optional_field(
    "input_tokens",
    None,
    decode.optional(decode.int),
  )
  use output <- decode.optional_field(
    "output_tokens",
    None,
    decode.optional(decode.int),
  )
  use cache_read <- decode.optional_field(
    "cache_read_input_tokens",
    None,
    decode.optional(decode.int),
  )
  use cache_write <- decode.optional_field(
    "cache_creation_input_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(UsageData(input, output, cache_read, cache_write))
}

fn block_decoder() -> decode.Decoder(BlockData) {
  use kind <- decode.field("type", decode.string)
  use text <- decode.optional_field("text", "", decode.string)
  use thinking <- decode.optional_field("thinking", "", decode.string)
  use id <- decode.optional_field("id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use input <- decode.optional_field(
    "input",
    None,
    decode.optional(decode.dynamic),
  )
  use signature <- decode.optional_field("signature", "", decode.string)
  use data <- decode.optional_field("data", "", decode.string)
  decode.success(BlockData(
    kind,
    text,
    thinking,
    id,
    name,
    input,
    signature,
    data,
  ))
}

fn message_decoder() -> decode.Decoder(MessageData) {
  use id <- decode.field("id", decode.string)
  use model <- decode.field("model", decode.string)
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(of: block_decoder()),
  )
  use stop_reason <- decode.optional_field(
    "stop_reason",
    None,
    decode.optional(decode.string),
  )
  use usage <- decode.field("usage", usage_decoder())
  decode.success(MessageData(id, model, content, stop_reason, usage))
}

fn decode_response(status: Int, body: String) -> Result(List(Event), Error) {
  case status >= 200 && status < 300 {
    False -> Error(decode_api_error(status, body))
    True -> {
      use message <- result.try(parse(body, message_decoder()))
      let MessageData(id:, model:, content:, stop_reason:, usage:) = message
      let content = content |> list.index_map(block_events) |> list.flatten
      Ok(
        list.flatten([
          [MessageStart(id, model)],
          content,
          finish_events(stop_reason),
          [usage_event(usage), MessageStop],
        ]),
      )
    }
  }
}

fn block_events(block: BlockData, index: Int) -> List(Event) {
  let BlockData(kind:, text:, thinking:, id:, name:, input:, signature:, data:) =
    block
  case kind {
    "text" -> [
      ContentStart(index, TextContent),
      TextDelta(index, text),
      llm.ContentStop(index),
    ]
    "thinking" -> [
      ContentStart(index, ReasoningContent),
      ReasoningDelta(index, thinking),
      ReasoningEncrypted(index, AnthropicSignedReasoning(signature)),
      llm.ContentStop(index),
    ]
    "redacted_thinking" -> [
      ContentStart(index, ReasoningContent),
      ReasoningEncrypted(index, AnthropicRedactedReasoning(data)),
      llm.ContentStop(index),
    ]
    "tool_use" -> {
      let arguments = case input {
        Some(input) -> dynamic_json_to_string(input)
        None -> "{}"
      }
      [
        ToolCallStart(index, id, name),
        ToolCallArgumentsDelta(index, arguments),
        llm.ContentStop(index),
      ]
    }
    kind -> [llm.UnknownEvent(kind)]
  }
}

fn decode_stream_event(data: String) -> Result(List(Event), Error) {
  use kind <- result.try(
    parse(data, {
      use kind <- decode.field("type", decode.string)
      decode.success(kind)
    }),
  )
  case kind {
    "message_start" ->
      parse(data, {
        use message <- decode.field("message", message_decoder())
        let MessageData(id:, model:, usage:, ..) = message
        decode.success([MessageStart(id, model), usage_event(usage)])
      })
    "content_block_start" -> decode_block_start(data)
    "content_block_delta" -> decode_block_delta(data)
    "content_block_stop" ->
      parse(data, {
        use index <- decode.field("index", decode.int)
        decode.success([llm.ContentStop(index)])
      })
    "message_delta" -> decode_message_delta(data)
    "message_stop" -> Ok([MessageStop])
    "ping" -> Ok([])
    "error" -> Error(decode_stream_error(data))
    kind -> Ok([llm.UnknownEvent(kind)])
  }
}

fn decode_block_start(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("index", decode.int)
    use block <- decode.field("content_block", block_decoder())
    let BlockData(kind:, id:, name:, data:, ..) = block
    decode.success(case kind {
      "text" -> [ContentStart(index, TextContent)]
      "thinking" -> [ContentStart(index, ReasoningContent)]
      "redacted_thinking" -> [
        ContentStart(index, ReasoningContent),
        ReasoningEncrypted(index, AnthropicRedactedReasoning(data)),
      ]
      "tool_use" -> [ToolCallStart(index, id, name)]
      kind -> [llm.UnknownEvent(kind)]
    })
  })
}

fn decode_block_delta(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("index", decode.int)
    use delta <- decode.field("delta", {
      use kind <- decode.field("type", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      use thinking <- decode.optional_field("thinking", "", decode.string)
      use partial_json <- decode.optional_field(
        "partial_json",
        "",
        decode.string,
      )
      use signature <- decode.optional_field("signature", "", decode.string)
      decode.success(#(kind, text, thinking, partial_json, signature))
    })
    decode.success(case delta {
      #("text_delta", text, _, _, _) -> [TextDelta(index, text)]
      #("thinking_delta", _, thinking, _, _) -> [
        ReasoningDelta(index, thinking),
      ]
      #("signature_delta", _, _, _, signature) -> [
        ReasoningEncrypted(index, AnthropicSignedReasoning(signature)),
      ]
      #("input_json_delta", _, _, partial_json, _) -> [
        ToolCallArgumentsDelta(index, partial_json),
      ]
      #(kind, _, _, _, _) -> [llm.UnknownEvent(kind)]
    })
  })
}

fn decode_message_delta(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use stop_reason <- decode.field("delta", {
      use reason <- decode.optional_field(
        "stop_reason",
        None,
        decode.optional(decode.string),
      )
      decode.success(reason)
    })
    // Not every message_delta carries usage: adaptive-thinking streams emit
    // frames with only a stop_reason.
    use usage <- decode.optional_field(
      "usage",
      None,
      decode.optional(usage_decoder()),
    )
    let usage = case usage {
      Some(usage) -> [usage_event(usage)]
      None -> []
    }
    decode.success(list.append(finish_events(stop_reason), usage))
  })
}

fn finish_events(reason: Option(String)) -> List(Event) {
  case reason {
    Some(reason) -> [Finished(finish_reason(reason))]
    None -> []
  }
}

fn finish_reason(reason: String) -> FinishReason {
  case reason {
    "end_turn" | "stop_sequence" -> Stop
    "max_tokens" | "model_context_window_exceeded" -> Length
    "tool_use" -> ToolUse
    "refusal" -> ContentFilter
    "pause_turn" -> Paused
    reason -> Other(reason)
  }
}

fn usage_event(usage: UsageData) -> Event {
  let UsageData(input:, output:, cache_read:, cache_write:) = usage
  UsageReported(Usage(
    input_tokens: input,
    output_tokens: output,
    cache_read_tokens: cache_read,
    cache_write_tokens: cache_write,
  ))
}

fn parse(data: String, decoder: decode.Decoder(a)) -> Result(a, Error) {
  json.parse(data, decoder)
  |> result.map_error(fn(error) { InvalidResponse(string.inspect(error)) })
}

fn decode_stream_error(body: String) -> Error {
  decode_api_error(0, body)
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
