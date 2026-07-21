import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/llm
import harness3/llm/openai_codex
import harness3/llm/openai_oauth

fn test_credentials() -> fn() -> Result(openai_oauth.Credentials, openai_oauth.Error) {
  fn() {
    Ok(openai_oauth.Credentials(
      access: "access-token",
      refresh: "refresh-token",
      expires: 9_999_999_999_999,
      account_id: "acct-fallback",
    ))
  }
}

fn test_provider() -> llm.Provider {
  openai_codex.new(openai_codex.Config(
    credentials: test_credentials(),
    base_url: "https://chatgpt.com/backend-api",
    originator: openai_codex.default_originator,
    session_id: None,
  ))
}

pub fn codex_request_shape_test() {
  let request =
    llm.Request(
      model: "gpt-5.5",
      messages: [
        llm.Message(llm.System, [llm.Text("You are a careful coding agent.")]),
        llm.Message(llm.User, [llm.Text("hello")]),
      ],
      tools: [
        llm.Tool("coding.read", Some("Read a file"), json.object([
          #("type", json.string("object")),
        ])),
      ],
      max_output_tokens: Some(1024),
      reasoning_effort: None,
      // The transport always clears this for buffered requests; the Codex
      // backend requires streaming anyway and the provider must force it.
      stream: False,
    )
  let assert Ok(llm.HttpRequest(method:, url:, headers:, body:)) =
    llm.build_request(test_provider(), request)
  assert method == "POST"
  assert url == "https://chatgpt.com/backend-api/codex/responses"
  assert list.contains(headers, #("authorization", "Bearer access-token"))
  // The stored accountId is the fallback for a non-JWT access token.
  assert list.contains(headers, #("chatgpt-account-id", "acct-fallback"))
  assert list.contains(headers, #("originator", "pi"))
  assert list.contains(headers, #("openai-beta", "responses=experimental"))
  assert list.contains(headers, #("accept", "text/event-stream"))

  assert string.contains(body, "\"store\":false")
  assert string.contains(body, "\"stream\":true")
  assert string.contains(body, "\"instructions\":\"You are a careful coding agent.")
  assert string.contains(body, "\"verbosity\":\"low\"")
  assert string.contains(body, "reasoning.encrypted_content")
  assert string.contains(body, "\"tool_choice\":\"auto\"")
  assert string.contains(body, "\"parallel_tool_calls\":true")
  // The Codex backend rejects max_output_tokens; it is never forwarded.
  assert !string.contains(body, "max_output_tokens")
  // Dotted harness tool names are escaped for the backend's name pattern.
  assert string.contains(body, "\"name\":\"coding__read\"")
  assert !string.contains(body, "coding.read")
  // The system prompt moves to instructions; no system role stays in input.
  assert !string.contains(body, "\"role\":\"system\"")
  assert string.contains(body, "\"role\":\"user\"")
}

pub fn codex_request_escapes_replayed_tool_call_names_test() {
  let request =
    llm.Request(
      model: "gpt-5.5",
      messages: [
        llm.Message(llm.User, [llm.Text("check the weather")]),
        llm.Message(llm.Assistant, [
          llm.ToolCall("call_1", "cloud_storage.get_url", json.object([])),
        ]),
        llm.Message(llm.ToolRole, [
          llm.ToolResult("call_1", [llm.Text("https://example.test")], False),
        ]),
      ],
      tools: [],
      max_output_tokens: None,
      reasoning_effort: None,
      stream: False,
    )
  let assert Ok(llm.HttpRequest(body:, ..)) =
    llm.build_request(test_provider(), request)
  assert string.contains(body, "\"name\":\"cloud_storage__get_url\"")
  assert !string.contains(body, "cloud_storage.get_url")
}

pub fn codex_decodes_wire_tool_names_test() {
  let sse =
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"team__message_agent\"}}\n\n"
    <> "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}\n\n"
    <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.5\",\"status\":\"completed\"}}\n\n"
  let assert Ok(events) = llm.decode_response(test_provider(), 200, sse)
  assert list.contains(events, llm.ToolCallStart(0, "call_1", "team.message_agent"))
}

pub fn codex_request_default_instructions_test() {
  let request =
    llm.request("gpt-5.5", [llm.Message(llm.User, [llm.Text("hello")])])
  let assert Ok(llm.HttpRequest(body:, ..)) =
    llm.build_request(test_provider(), request)
  assert string.contains(body, "\"instructions\":\"You are a helpful assistant.\"")
}

pub fn codex_url_suffixes_test() {
  let config = fn(base_url) {
    openai_codex.Config(
      credentials: test_credentials(),
      base_url:,
      originator: openai_codex.default_originator,
      session_id: None,
    )
  }
  let request = llm.request("gpt-5.5", [])
  let assert Ok(llm.HttpRequest(url:, ..)) =
    llm.build_request(openai_codex.new(config("https://chatgpt.com/backend-api/")), request)
  assert url == "https://chatgpt.com/backend-api/codex/responses"
  let assert Ok(llm.HttpRequest(url:, ..)) =
    llm.build_request(
      openai_codex.new(config("https://chatgpt.com/backend-api/codex")),
      request,
    )
  assert url == "https://chatgpt.com/backend-api/codex/responses"
}

pub fn codex_buffered_sse_response_test() {
  let sse =
    "event: response.created\n"
    <> "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.5\",\"status\":\"in_progress\"}}\n\n"
    <> "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"Hel\"}\n\n"
    <> "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"lo\"}\n\n"
    <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-5.5\",\"status\":\"completed\",\"usage\":{\"input_tokens\":12,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":5}}}}\n\n"
    <> "data: [DONE]\n\n"
  let assert Ok(events) = llm.decode_response(test_provider(), 200, sse)
  assert list.contains(events, llm.MessageStart("resp_1", "gpt-5.5"))
  assert list.contains(events, llm.TextDelta(0, "Hel"))
  assert list.contains(events, llm.TextDelta(0, "lo"))
  assert list.contains(events, llm.Finished(llm.Stop))
  assert list.contains(
    events,
    llm.UsageReported(llm.Usage(Some(7), Some(2), Some(5), None)),
  )
  assert list.contains(events, llm.MessageStop)
}

pub fn codex_response_requires_terminal_event_test() {
  let sse =
    "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"truncated\"}\n\n"
  let assert Error(llm.InvalidResponse(_)) =
    llm.decode_response(test_provider(), 200, sse)
}

pub fn codex_error_response_test() {
  let body =
    "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Store must be set to false\"}}"
  let assert Error(llm.ApiError(400, "invalid_request_error", message)) =
    llm.decode_response(test_provider(), 400, body)
  assert string.contains(message, "Store must be set to false")
}
