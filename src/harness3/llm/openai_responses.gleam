import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm.{
  type Content, type Error, type Event, type FinishReason, type HttpRequest,
  type ImageDetail, type MediaSource, type Message, type Provider, type Request,
  type Role, type Tool, ApiError, Assistant, Auto, Base64, Cancelled,
  ContentStart, Developer, Document, Failed, FileId, Finished, High, HttpRequest,
  Image, InvalidRequest, InvalidResponse, Length, Low, MessageStart, MessageStop,
  OpenAIEncryptedReasoning, Other, Reasoning, ReasoningContent, ReasoningDelta,
  ReasoningEncrypted, RefusalDelta, Stop, System, Text, TextContent, TextDelta,
  ToolCall, ToolCallArgumentsDelta, ToolCallStart, ToolResult, Unsupported, Url,
  Usage, UsageReported, User,
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
  use message_items <- result.try(list.try_map(messages, encode_message_items))
  use tools <- result.try(list.try_map(tools, encode_tool))
  let fields = [
    #("model", json.string(model)),
    #("input", message_items |> list.flatten |> json.preprocessed_array),
    #("include", json.array(["reasoning.encrypted_content"], json.string)),
    #("tools", json.preprocessed_array(tools)),
    #("stream", json.bool(stream)),
  ]
  let fields = add_optional_int(fields, "max_output_tokens", max_output_tokens)
  let fields = add_optional_float(fields, "temperature", temperature)
  let Config(api_key:, ..) = config
  Ok(HttpRequest(
    method: "POST",
    url: base_url(config) <> "/v1/responses",
    headers: [
      #("authorization", "Bearer " <> api_key),
      #("content-type", "application/json"),
    ],
    body: json.object(fields) |> json.to_string,
  ))
}

fn encode_message_items(message: Message) -> Result(List(Json), Error) {
  let llm.Message(role:, content:) = message
  let regular = list.filter(content, is_regular_content)
  let reasoning = list.filter(content, is_reasoning_content)
  let special =
    list.filter(content, fn(content) {
      !is_regular_content(content) && !is_reasoning_content(content)
    })
  use regular <- result.try(list.try_map(regular, encode_content))
  use reasoning <- result.try(list.try_map(reasoning, encode_special_item))
  use special <- result.try(list.try_map(special, encode_special_item))
  let message = case regular {
    [] -> []
    _ -> [
      json.object([
        #("type", json.string("message")),
        #("role", json.string(role_name(role))),
        #("content", json.preprocessed_array(regular)),
      ]),
    ]
  }
  // A reasoning item precedes the visible output and tool calls it produced.
  Ok(list.append(reasoning, list.append(message, special)))
}

fn is_regular_content(content: Content) -> Bool {
  case content {
    Text(_) | Image(_, _) | Document(_) -> True
    Reasoning(..) | ToolCall(..) | ToolResult(..) -> False
  }
}

fn is_reasoning_content(content: Content) -> Bool {
  case content {
    Reasoning(..) -> True
    _ -> False
  }
}

fn role_name(role: Role) -> String {
  case role {
    System -> "system"
    Developer -> "developer"
    User | llm.ToolRole -> "user"
    Assistant -> "assistant"
  }
}

fn encode_content(content: Content) -> Result(Json, Error) {
  case content {
    Text(text) ->
      Ok(
        json.object([
          #("type", json.string("input_text")),
          #("text", json.string(text)),
        ]),
      )
    Image(source, detail) -> encode_image(source, detail)
    Document(source) -> encode_document(source)
    _ -> Error(InvalidRequest("expected regular message content"))
  }
}

fn encode_image(
  source: MediaSource,
  detail: ImageDetail,
) -> Result(Json, Error) {
  let fields = [
    #("type", json.string("input_image")),
    #("detail", json.string(detail_name(detail))),
  ]
  let fields = case source {
    Url(url) -> [#("image_url", json.string(url)), ..fields]
    Base64(media_type, data) -> [
      #("image_url", json.string("data:" <> media_type <> ";base64," <> data)),
      ..fields
    ]
    FileId(id) -> [#("file_id", json.string(id)), ..fields]
  }
  Ok(json.object(fields))
}

fn encode_document(source: MediaSource) -> Result(Json, Error) {
  let fields = [#("type", json.string("input_file"))]
  case source {
    Url(url) -> Ok(json.object([#("file_url", json.string(url)), ..fields]))
    FileId(id) -> Ok(json.object([#("file_id", json.string(id)), ..fields]))
    Base64(_, _) ->
      Error(Unsupported("Responses base64 documents without a filename"))
  }
}

fn detail_name(detail: ImageDetail) -> String {
  case detail {
    Auto -> "auto"
    Low -> "low"
    High -> "high"
  }
}

fn encode_special_item(content: Content) -> Result(Json, Error) {
  case content {
    ToolCall(id, name, arguments) ->
      Ok(
        json.object([
          #("type", json.string("function_call")),
          #("call_id", json.string(id)),
          #("name", json.string(name)),
          #("arguments", json.string(json.to_string(arguments))),
        ]),
      )
    ToolResult(id, content, _) -> {
      use output <- result.try(text_only(content))
      Ok(
        json.object([
          #("type", json.string("function_call_output")),
          #("call_id", json.string(id)),
          #("output", json.string(output)),
        ]),
      )
    }
    Reasoning(summary, Some(OpenAIEncryptedReasoning(id, encrypted))) ->
      Ok(
        json.object([
          #("type", json.string("reasoning")),
          #("id", json.string(id)),
          #(
            "summary",
            json.preprocessed_array(
              list.map(summary, fn(text) {
                json.object([
                  #("type", json.string("summary_text")),
                  #("text", json.string(text)),
                ])
              }),
            ),
          ),
          #("encrypted_content", json.string(encrypted)),
        ]),
      )
    Reasoning(_, Some(_)) ->
      Error(InvalidRequest(
        "encrypted reasoning belongs to a different provider",
      ))
    Reasoning(_, None) ->
      Error(InvalidRequest(
        "Responses reasoning input requires encrypted provider state",
      ))
    _ -> Error(InvalidRequest("expected tool content"))
  }
}

fn text_only(content: List(Content)) -> Result(String, Error) {
  content
  |> list.try_map(fn(part) {
    case part {
      Text(text) -> Ok(text)
      _ -> Error(Unsupported("non-text Responses tool results"))
    }
  })
  |> result.map(string.concat)
}

fn encode_tool(tool: Tool) -> Result(Json, Error) {
  let llm.Tool(name:, description:, input_schema:) = tool
  let fields = [
    #("type", json.string("function")),
    #("name", json.string(name)),
    #("parameters", input_schema),
  ]
  let fields = case description {
    Some(description) -> [#("description", json.string(description)), ..fields]
    None -> fields
  }
  Ok(json.object(fields))
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

type PartData {
  PartData(kind: String, text: String)
}

type ItemData {
  ItemData(
    kind: String,
    id: String,
    call_id: String,
    name: String,
    arguments: String,
    content: List(PartData),
    summary: List(PartData),
    encrypted_content: Option(String),
  )
}

type ResponseData {
  ResponseData(
    id: String,
    model: String,
    status: String,
    output: List(ItemData),
    usage: Option(UsageData),
  )
}

fn usage_decoder() -> decode.Decoder(UsageData) {
  use input <- decode.field("input_tokens", decode.int)
  use output <- decode.field("output_tokens", decode.int)
  use cached <- decode.optional_field("input_tokens_details", 0, {
    use cached <- decode.optional_field("cached_tokens", 0, decode.int)
    decode.success(cached)
  })
  decode.success(UsageData(input, output, cached))
}

fn part_decoder() -> decode.Decoder(PartData) {
  use kind <- decode.field("type", decode.string)
  use text <- decode.optional_field("text", "", decode.string)
  decode.success(PartData(kind, text))
}

fn item_decoder() -> decode.Decoder(ItemData) {
  use kind <- decode.field("type", decode.string)
  use id <- decode.optional_field("id", "", decode.string)
  use call_id <- decode.optional_field("call_id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use arguments <- decode.optional_field("arguments", "", decode.string)
  use content <- decode.optional_field(
    "content",
    [],
    decode.list(of: part_decoder()),
  )
  use summary <- decode.optional_field(
    "summary",
    [],
    decode.list(of: part_decoder()),
  )
  use encrypted_content <- decode.optional_field(
    "encrypted_content",
    None,
    decode.optional(decode.string),
  )
  decode.success(ItemData(
    kind,
    id,
    call_id,
    name,
    arguments,
    content,
    summary,
    encrypted_content,
  ))
}

fn response_decoder() -> decode.Decoder(ResponseData) {
  use id <- decode.field("id", decode.string)
  use model <- decode.field("model", decode.string)
  use status <- decode.field("status", decode.string)
  use output <- decode.optional_field(
    "output",
    [],
    decode.list(of: item_decoder()),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )
  decode.success(ResponseData(id, model, status, output, usage))
}

fn decode_response(status: Int, body: String) -> Result(List(Event), Error) {
  case status >= 200 && status < 300 {
    False -> Error(decode_api_error(status, body))
    True -> {
      use response <- result.try(parse(body, response_decoder()))
      Ok(response_events(response))
    }
  }
}

fn response_events(response: ResponseData) -> List(Event) {
  let ResponseData(id:, model:, status:, output:, usage:) = response
  let output = output |> list.index_map(output_item_events) |> list.flatten
  let usage = usage_events(usage)
  list.flatten([
    [MessageStart(id, model)],
    output,
    [Finished(response_finish(status))],
    usage,
    [MessageStop],
  ])
}

fn output_item_events(item: ItemData, index: Int) -> List(Event) {
  let ItemData(
    kind:,
    id:,
    call_id:,
    name:,
    arguments:,
    content:,
    summary:,
    encrypted_content:,
  ) = item
  case kind {
    "message" ->
      content
      |> list.index_map(fn(part, content_index) {
        let PartData(kind:, text:) = part
        case kind {
          "output_text" -> [
            ContentStart(content_index, TextContent),
            TextDelta(content_index, text),
          ]
          "refusal" -> [
            ContentStart(content_index, TextContent),
            RefusalDelta(content_index, text),
          ]
          _ -> [llm.UnknownEvent(kind)]
        }
      })
      |> list.flatten
    "function_call" -> [
      ToolCallStart(index, call_id, name),
      ToolCallArgumentsDelta(index, arguments),
    ]
    "reasoning" -> {
      let summary =
        summary
        |> list.map(fn(part) {
          let PartData(text:, ..) = part
          ReasoningDelta(index, text)
        })
      let encrypted = case encrypted_content {
        Some(value) -> [
          ReasoningEncrypted(index, OpenAIEncryptedReasoning(id, value)),
        ]
        None -> []
      }
      list.flatten([
        [ContentStart(index, ReasoningContent)],
        summary,
        encrypted,
        [llm.ContentStop(index)],
      ])
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
    "response.created" -> {
      use response <- result.try(
        parse(data, {
          use response <- decode.field("response", response_decoder())
          decode.success(response)
        }),
      )
      let ResponseData(id:, model:, ..) = response
      Ok([MessageStart(id, model)])
    }
    "response.content_part.added" -> decode_content_start(data)
    "response.output_text.delta" -> decode_text_delta(data, False)
    "response.refusal.delta" -> decode_refusal_delta(data)
    "response.reasoning_summary_text.delta" -> decode_text_delta(data, True)
    "response.function_call_arguments.delta" -> decode_arguments_delta(data)
    "response.output_item.added" -> decode_item_start(data)
    "response.content_part.done" -> decode_content_stop(data)
    "response.output_item.done" -> decode_item_done(data)
    "response.completed"
    | "response.incomplete"
    | "response.failed"
    | "response.cancelled" -> decode_terminal(data)
    kind -> Ok([llm.UnknownEvent(kind)])
  }
}

fn decode_content_start(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("content_index", decode.int)
    use kind <- decode.field("part", {
      use kind <- decode.field("type", decode.string)
      decode.success(kind)
    })
    let content_kind = case kind {
      "output_text" | "refusal" -> TextContent
      _ -> ReasoningContent
    }
    decode.success([ContentStart(index, content_kind)])
  })
}

fn decode_text_delta(
  data: String,
  reasoning: Bool,
) -> Result(List(Event), Error) {
  parse(data, {
    use content_index <- decode.optional_field("content_index", 0, decode.int)
    use output_index <- decode.optional_field("output_index", 0, decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success(case reasoning {
      True -> [ReasoningDelta(output_index, delta)]
      False -> [TextDelta(content_index, delta)]
    })
  })
}

fn decode_refusal_delta(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.optional_field("content_index", 0, decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success([RefusalDelta(index, delta)])
  })
}

fn decode_arguments_delta(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("output_index", decode.int)
    use delta <- decode.field("delta", decode.string)
    decode.success([ToolCallArgumentsDelta(index, delta)])
  })
}

fn decode_item_start(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("output_index", decode.int)
    use item <- decode.field("item", item_decoder())
    let ItemData(kind:, call_id:, name:, ..) = item
    decode.success(case kind {
      "function_call" -> [ToolCallStart(index, call_id, name)]
      "reasoning" -> [ContentStart(index, ReasoningContent)]
      kind -> [llm.UnknownEvent(kind)]
    })
  })
}

fn decode_item_done(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.field("output_index", decode.int)
    use item <- decode.field("item", item_decoder())
    let ItemData(kind:, id:, encrypted_content:, ..) = item
    decode.success(case kind, encrypted_content {
      "reasoning", Some(value) -> [
        ReasoningEncrypted(index, OpenAIEncryptedReasoning(id, value)),
        llm.ContentStop(index),
      ]
      "reasoning", None -> [llm.ContentStop(index)]
      "function_call", _ -> [llm.ContentStop(index)]
      _, _ -> []
    })
  })
}

fn decode_content_stop(data: String) -> Result(List(Event), Error) {
  parse(data, {
    use index <- decode.optional_field("content_index", 0, decode.int)
    decode.success([llm.ContentStop(index)])
  })
}

fn decode_terminal(data: String) -> Result(List(Event), Error) {
  use response <- result.try(
    parse(data, {
      use response <- decode.field("response", response_decoder())
      decode.success(response)
    }),
  )
  let ResponseData(status:, usage:, ..) = response
  Ok(
    list.flatten([
      [Finished(response_finish(status))],
      usage_events(usage),
      [MessageStop],
    ]),
  )
}

fn usage_events(usage: Option(UsageData)) -> List(Event) {
  case usage {
    Some(UsageData(input, output, cached)) -> [
      UsageReported(Usage(
        input_tokens: Some(input),
        output_tokens: Some(output),
        cache_read_tokens: Some(cached),
        cache_write_tokens: None,
      )),
    ]
    None -> []
  }
}

fn response_finish(status: String) -> FinishReason {
  case status {
    "completed" -> Stop
    "incomplete" -> Length
    "cancelled" -> Cancelled
    "failed" -> Failed("response failed")
    status -> Other(status)
  }
}

fn parse(data: String, decoder: decode.Decoder(a)) -> Result(a, Error) {
  json.parse(data, decoder)
  |> result.map_error(fn(error) { InvalidResponse(string.inspect(error)) })
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
