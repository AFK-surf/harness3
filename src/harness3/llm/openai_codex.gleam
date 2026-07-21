import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm.{
  type Error, type Event, type HttpRequest, type Provider, type Request,
  ApiError, HttpRequest, InvalidResponse, System,
}
import harness3/llm/openai_oauth
import harness3/llm/openai_responses

/// The product identity Pi sends on Codex backend requests.
pub const default_originator = "pi"

/// The ChatGPT Codex backend speaks the Responses API with a few deltas from
/// api.openai.com: requests must carry the account and originator headers,
/// must set `store: false` and `stream: true`, and the system prompt travels
/// in `instructions` rather than as an input message. Because streaming is
/// mandatory, a buffered response body is a complete SSE transcript, which
/// `decode_response` replays through the shared stream decoder.
pub type Config {
  Config(
    /// Resolves fresh OAuth credentials on every request build. Access
    /// tokens rotate independently of provider-construction time, so the
    /// token is never captured in the provider value itself.
    credentials: fn() -> Result(openai_oauth.Credentials, openai_oauth.Error),
    base_url: String,
    /// Product identity the backend requires (Pi sends "pi").
    originator: String,
    /// Cache-affinity key forwarded as `prompt_cache_key` and the session
    /// headers. Optional; omitting it only forgoes prompt-cache routing.
    session_id: Option(String),
  )
}

pub fn new(config: Config) -> Provider {
  llm.from_functions(
    build: fn(request) { build(config, request) },
    response: decode_response,
    stream_event: fn(data) {
      openai_responses.decode_stream_event(data)
      |> result.map(decode_tool_names)
    },
  )
}

/// The backend restricts tool names to `[a-zA-Z0-9_-]+`, but harness tools
/// are dotted (`coding.read`). Names are escaped reversibly at the provider
/// boundary: each `.` becomes `__` on the wire and `__` becomes `.` on the
/// way back, the same convention MCP gateways use. This is unambiguous for
/// every harness-generated name — snake_case sanitizers collapse separator
/// runs, so no tool name ever contains a literal `__`.
fn encode_tool_name(name: String) -> String {
  string.replace(name, ".", "__")
}

fn decode_tool_name(name: String) -> String {
  string.replace(name, "__", ".")
}

fn decode_tool_names(events: List(Event)) -> List(Event) {
  list.map(events, fn(event) {
    case event {
      llm.ToolCallStart(index, id, name) ->
        llm.ToolCallStart(index, id, decode_tool_name(name))
      event -> event
    }
  })
}

fn responses_url(base: String) -> String {
  let base = case string.ends_with(base, "/") {
    True -> string.drop_end(base, 1)
    False -> base
  }
  case string.ends_with(base, "/codex/responses") {
    True -> base
    False ->
      case string.ends_with(base, "/codex") {
        True -> base <> "/responses"
        False -> base <> "/codex/responses"
      }
  }
}

fn build(config: Config, request: Request) -> Result(HttpRequest, Error) {
  let llm.Request(model:, messages:, tools:, reasoning_effort:, ..) = request
  let #(instructions, input_messages) = split_instructions(messages)
  // Replayed tool calls carry harness (dotted) names too; they must be
  // escaped on the wire exactly like the tool definitions.
  let input_messages =
    list.map(input_messages, fn(message) {
      let llm.Message(role:, content:) = message
      llm.Message(
        role,
        list.map(content, fn(part) {
          case part {
            llm.ToolCall(id, name, arguments) ->
              llm.ToolCall(id, encode_tool_name(name), arguments)
            part -> part
          }
        }),
      )
    })
  use message_items <- result.try(list.try_map(
    input_messages,
    openai_responses.encode_message_items,
  ))
  use tools <- result.try(
    list.try_map(tools, fn(tool) {
      let llm.Tool(name:, description:, input_schema:) = tool
      openai_responses.encode_tool(llm.Tool(
        encode_tool_name(name),
        description,
        input_schema,
      ))
    }),
  )
  // max_output_tokens is deliberately not forwarded: the Codex backend
  // rejects the parameter outright.
  let fields = [
    #("model", json.string(model)),
    #("instructions", json.string(instructions)),
    #("input", message_items |> list.flatten |> json.preprocessed_array),
    #("text", json.object([#("verbosity", json.string("low"))])),
    // reasoning.encrypted_content is only available for stateless requests.
    #("include", json.array(["reasoning.encrypted_content"], json.string)),
    // The Codex backend rejects any other combination of these two.
    #("store", json.bool(False)),
    #("stream", json.bool(True)),
    #("tool_choice", json.string("auto")),
    #("parallel_tool_calls", json.bool(True)),
  ]
  let fields = case tools {
    [] -> fields
    _ -> [#("tools", json.preprocessed_array(tools)), ..fields]
  }
  let fields = case reasoning_effort {
    Some(effort) -> [
      #(
        "reasoning",
        json.object([
          #("effort", json.string(effort)),
          #("summary", json.string("auto")),
        ]),
      ),
      ..fields
    ]
    None -> fields
  }
  let fields = case config.session_id {
    Some(session_id) -> [
      #("prompt_cache_key", json.string(session_id)),
      ..fields
    ]
    None -> fields
  }
  use credentials <- result.try(
    config.credentials()
    |> result.map_error(fn(error) {
      ApiError(0, "oauth_error", openai_oauth.describe_error(error))
    }),
  )
  let session_headers = case config.session_id {
    Some(session_id) -> [
      #("session-id", session_id),
      #("x-client-request-id", session_id),
    ]
    None -> []
  }
  Ok(HttpRequest(
    method: "POST",
    url: responses_url(config.base_url),
    headers: list.flatten([
      [
        #("authorization", "Bearer " <> credentials.access),
        #("chatgpt-account-id", openai_oauth.account_id(credentials)),
        #("originator", config.originator),
        #("user-agent", config.originator),
        #("openai-beta", "responses=experimental"),
        #("accept", "text/event-stream"),
        #("content-type", "application/json"),
      ],
      session_headers,
    ]),
    body: json.object(fields) |> json.to_string,
  ))
}

/// Moves the system prompt out of the message list: the Codex backend wants
/// it in the top-level `instructions` field and rejects system-role input
/// items. Multiple system messages join with a blank line.
fn split_instructions(
  messages: List(llm.Message),
) -> #(String, List(llm.Message)) {
  let #(system_texts, rest) =
    list.partition(messages, fn(message) {
      let llm.Message(role:, ..) = message
      role == System
    })
  let instructions =
    system_texts
    |> list.flat_map(fn(message) {
      let llm.Message(content:, ..) = message
      list.filter_map(content, fn(part) {
        case part {
          llm.Text(text) -> Ok(text)
          _ -> Error(Nil)
        }
      })
    })
    |> list.filter(fn(text) { string.trim(text) != "" })
    |> string.join("\n\n")
  case instructions {
    "" -> #("You are a helpful assistant.", rest)
    _ -> #(instructions, rest)
  }
}

/// The buffered body of a Codex response is a complete SSE transcript
/// (`stream: true` is mandatory), so replay every frame through the shared
/// Responses stream decoder instead of parsing a single JSON document.
fn decode_response(status: Int, body: String) -> Result(List(Event), Error) {
  case status >= 200 && status < 300 {
    False -> openai_responses.decode_response(status, body)
    True -> decode_stream_body(body)
  }
}

fn decode_stream_body(body: String) -> Result(List(Event), Error) {
  body
  |> string.replace("\r\n", "\n")
  |> string.split("\n\n")
  |> list.try_fold([], fn(events, frame) {
    case frame_data(frame) {
      None -> Ok(events)
      Some("[DONE]") -> Ok(events)
      Some(data) -> {
        use decoded <- result.try(openai_responses.decode_stream_event(data))
        Ok(list.append(events, decoded))
      }
    }
  })
  |> result.try(fn(events) {
    case list.any(events, is_terminal) {
      True -> Ok(events)
      False ->
        Error(InvalidResponse(
          "Codex stream ended before a terminal response event",
        ))
    }
  })
  |> result.map(decode_tool_names)
}

fn is_terminal(event: Event) -> Bool {
  case event {
    llm.Finished(_) -> True
    _ -> False
  }
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
