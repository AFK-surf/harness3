import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Role {
  System
  Developer
  User
  Assistant
  ToolRole
}

pub type MediaSource {
  Url(url: String)
  Base64(media_type: String, data: String)
  FileId(id: String)
}

pub type ImageDetail {
  Auto
  Low
  High
}

pub type Content {
  Text(text: String)
  Image(source: MediaSource, detail: ImageDetail)
  Document(source: MediaSource)
  ToolCall(id: String, name: String, arguments: Json)
  ToolResult(tool_call_id: String, content: List(Content), is_error: Bool)
}

pub type Message {
  Message(role: Role, content: List(Content))
}

pub type Tool {
  Tool(name: String, description: Option(String), input_schema: Json)
}

pub type Request {
  Request(
    model: String,
    messages: List(Message),
    tools: List(Tool),
    max_output_tokens: Option(Int),
    temperature: Option(Float),
    stream: Bool,
  )
}

pub fn request(model: String, messages: List(Message)) -> Request {
  Request(
    model:,
    messages:,
    tools: [],
    max_output_tokens: None,
    temperature: None,
    stream: True,
  )
}

pub type HttpRequest {
  HttpRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
  )
}

pub type Usage {
  Usage(
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cache_read_tokens: Option(Int),
    cache_write_tokens: Option(Int),
  )
}

pub type Stats {
  Stats(
    input_tokens: Int,
    output_tokens: Int,
    cache_read_tokens: Int,
    cache_write_tokens: Int,
  )
}

pub fn empty_stats() -> Stats {
  Stats(0, 0, 0, 0)
}

/// Applies a provider usage report. Missing fields retain their prior values;
/// provider reports are cumulative snapshots, not additive deltas.
pub fn apply_usage(stats: Stats, usage: Usage) -> Stats {
  let Stats(input_tokens:, output_tokens:, cache_read_tokens:, cache_write_tokens:) =
    stats
  let Usage(
    input_tokens: new_input,
    output_tokens: new_output,
    cache_read_tokens: new_cache_read,
    cache_write_tokens: new_cache_write,
  ) = usage
  Stats(
    input_tokens: option_value(new_input, input_tokens),
    output_tokens: option_value(new_output, output_tokens),
    cache_read_tokens: option_value(new_cache_read, cache_read_tokens),
    cache_write_tokens: option_value(new_cache_write, cache_write_tokens),
  )
}

fn option_value(value: Option(a), fallback: a) -> a {
  case value {
    Some(value) -> value
    None -> fallback
  }
}

pub type ContentKind {
  TextContent
  ReasoningContent
  ToolCallContent
}

pub type FinishReason {
  Stop
  Length
  ToolUse
  ContentFilter
  Cancelled
  Failed(reason: String)
  Other(reason: String)
}

/// Provider-neutral streaming events. The same event sequence is produced for
/// buffered JSON responses and individual SSE data records.
pub type Event {
  MessageStart(id: String, model: String)
  ContentStart(index: Int, kind: ContentKind)
  TextDelta(index: Int, text: String)
  ReasoningDelta(index: Int, text: String)
  RefusalDelta(index: Int, text: String)
  ToolCallStart(index: Int, id: String, name: String)
  ToolCallArgumentsDelta(index: Int, json_fragment: String)
  ContentStop(index: Int)
  Finished(reason: FinishReason)
  UsageReported(usage: Usage)
  MessageStop
  UnknownEvent(kind: String)
}

pub type Error {
  InvalidRequest(reason: String)
  Unsupported(feature: String)
  InvalidResponse(reason: String)
  ApiError(status: Int, kind: String, message: String)
}

pub opaque type Provider {
  Provider(
    build_request: fn(Request) -> Result(HttpRequest, Error),
    decode_response: fn(Int, String) -> Result(List(Event), Error),
    decode_stream_event: fn(String) -> Result(List(Event), Error),
  )
}

pub fn from_functions(
  build build_request: fn(Request) -> Result(HttpRequest, Error),
  response decode_response: fn(Int, String) -> Result(List(Event), Error),
  stream_event decode_stream_event: fn(String) -> Result(List(Event), Error),
) -> Provider {
  Provider(build_request, decode_response, decode_stream_event)
}

pub fn build_request(
  provider: Provider,
  request: Request,
) -> Result(HttpRequest, Error) {
  let Provider(build_request:, ..) = provider
  build_request(request)
}

pub fn decode_response(
  provider: Provider,
  status: Int,
  body: String,
) -> Result(List(Event), Error) {
  let Provider(decode_response:, ..) = provider
  decode_response(status, body)
}

/// Decodes one SSE `data:` payload. `[DONE]` produces no events.
pub fn decode_stream_event(
  provider: Provider,
  data: String,
) -> Result(List(Event), Error) {
  case string.trim(data) {
    "[DONE]" -> Ok([])
    data -> {
      let Provider(decode_stream_event:, ..) = provider
      decode_stream_event(data)
    }
  }
}

pub opaque type StreamDecoder {
  StreamDecoder(provider: Provider, buffer: String)
}

pub fn stream_decoder(provider: Provider) -> StreamDecoder {
  StreamDecoder(provider, "")
}

/// Pushes an arbitrary SSE text chunk and returns every complete normalized
/// event. The decoder retains an incomplete trailing SSE frame.
pub fn push(
  decoder: StreamDecoder,
  chunk: String,
) -> #(StreamDecoder, List(Result(Event, Error))) {
  let StreamDecoder(provider:, buffer:) = decoder
  let pieces =
    string.replace(buffer <> chunk, "\r\n", "\n")
    |> string.split("\n\n")
  let count = list.length(pieces)
  let frames = list.take(pieces, count - 1)
  let remainder = list.last(pieces) |> result.unwrap("")
  let events =
    frames
    |> list.flat_map(fn(frame) {
      case frame_data(frame) {
        None -> []
        Some(data) ->
          case decode_stream_event(provider, data) {
            Ok(events) -> list.map(events, Ok)
            Error(error) -> [Error(error)]
          }
      }
    })
  #(StreamDecoder(provider, remainder), events)
}

fn frame_data(frame: String) -> Option(String) {
  let data =
    frame
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case line {
        "data:" <> value -> Ok(string.trim_start(value))
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")
  case data {
    "" -> None
    _ -> Some(data)
  }
}
