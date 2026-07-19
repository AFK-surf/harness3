import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/llm
import harness3/llm/anthropic_messages
import harness3/llm/openai_chat_completions
import harness3/llm/openai_responses

fn multimodal_request() -> llm.Request {
  llm.Request(
    model: "test-model",
    messages: [
      llm.Message(llm.User, [
        llm.Image(llm.Url("https://example.test/image.png"), llm.High),
        llm.Image(llm.Base64("image/png", "aGVsbG8="), llm.Low),
        llm.Document(llm.FileId("file_123")),
        llm.Text("Describe these inputs"),
      ]),
    ],
    tools: [
      llm.Tool(
        "lookup",
        Some("Look something up"),
        json.object([#("type", json.string("object"))]),
      ),
    ],
    max_output_tokens: Some(128),
    reasoning_effort: None,
    stream: True,
  )
}

pub fn multimodal_requests_test() {
  let request = multimodal_request()

  let assert Ok(llm.HttpRequest(body: chat_body, ..)) =
    llm.build_request(
      openai_chat_completions.new(openai_chat_completions.config("key")),
      request,
    )
  assert string.contains(chat_body, "image_url")
  assert string.contains(chat_body, "data:image/png;base64,aGVsbG8=")
  assert string.contains(chat_body, "file_123")
  assert string.contains(chat_body, "include_usage")

  let assert Ok(llm.HttpRequest(body: responses_body, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      request,
    )
  assert string.contains(responses_body, "input_image")
  assert string.contains(responses_body, "input_file")
  assert string.contains(responses_body, "max_output_tokens")
  assert string.contains(responses_body, "reasoning.encrypted_content")

  let assert Ok(llm.HttpRequest(
    headers: anthropic_headers,
    body: anthropic_body,
    ..,
  )) =
    llm.build_request(
      anthropic_messages.new(anthropic_messages.config("key")),
      request,
    )
  assert string.contains(anthropic_body, "\"type\":\"image\"")
  assert string.contains(anthropic_body, "\"type\":\"base64\"")
  assert string.contains(anthropic_body, "\"type\":\"file\"")
  assert string.contains(anthropic_body, "input_schema")
  assert string.contains(
    anthropic_body,
    "\"cache_control\":{\"type\":\"ephemeral\"}",
  )
  assert list.contains(anthropic_headers, #(
    "anthropic-beta",
    "files-api-2025-04-14",
  ))
}

pub fn tool_call_replay_request_test() {
  let request =
    llm.Request(
      model: "test-model",
      messages: [
        llm.Message(llm.User, [llm.Text("hi")]),
        llm.Message(llm.Assistant, [
          llm.ToolCall("call_1", "lookup", json.object([])),
        ]),
        llm.Message(llm.ToolRole, [
          llm.ToolResult("call_1", [llm.Text("ok")], False),
        ]),
        llm.Message(llm.Assistant, [llm.Text("prior answer")]),
        llm.Message(llm.User, [llm.Text("thanks")]),
      ],
      tools: [],
      max_output_tokens: None,
      reasoning_effort: None,
      stream: False,
    )

  let assert Ok(llm.HttpRequest(body: chat_body, ..)) =
    llm.build_request(
      openai_chat_completions.new(openai_chat_completions.config("key")),
      request,
    )
  // Empty tools arrays and tool-call-only content arrays are rejected upstream.
  assert !string.contains(chat_body, "\"tools\"")
  assert !string.contains(chat_body, "\"content\":[]")
  assert string.contains(chat_body, "tool_calls")

  let assert Ok(llm.HttpRequest(body: responses_body, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      request,
    )
  assert !string.contains(responses_body, "\"tools\"")
  assert string.contains(responses_body, "\"store\":false")
  assert string.contains(responses_body, "output_text")
  assert string.contains(responses_body, "input_text")

  let assert Ok(llm.HttpRequest(
    headers: anthropic_headers,
    body: anthropic_body,
    ..,
  )) =
    llm.build_request(
      anthropic_messages.new(anthropic_messages.config("key")),
      request,
    )
  assert !string.contains(anthropic_body, "\"tools\"")
  assert !list.any(anthropic_headers, fn(header) {
    header.0 == "anthropic-beta"
  })
}

pub fn anthropic_buffered_tool_use_test() {
  let provider = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(events) =
    llm.decode_response(
      provider,
      200,
      "{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{\"query\":\"cats\"}}],\"stop_reason\":\"tool_use\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}",
    )
  assert list.contains(events, llm.ToolCallStart(0, "toolu_1", "lookup"))
  assert list.contains(
    events,
    llm.ToolCallArgumentsDelta(0, "{\"query\":\"cats\"}"),
  )
  assert list.contains(events, llm.Finished(llm.ToolUse))
}

pub fn encrypted_reasoning_requests_test() {
  let responses_request =
    llm.request("test-model", [
      llm.Message(llm.Assistant, [
        llm.Reasoning(
          ["OpenAI summary"],
          Some(llm.OpenAIEncryptedReasoning("rs_1", "openai-ciphertext")),
        ),
        llm.Text("OpenAI answer"),
      ]),
    ])
  let assert Ok(llm.HttpRequest(body: responses_body, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      responses_request,
    )
  assert string.contains(responses_body, "reasoning.encrypted_content")
  assert string.contains(responses_body, "openai-ciphertext")
  assert string.contains(responses_body, "OpenAI summary")

  let anthropic_request =
    llm.request("test-model", [
      llm.Message(llm.Assistant, [
        llm.Reasoning(
          ["Anthropic thinking"],
          Some(llm.AnthropicSignedReasoning("anthropic-signature")),
        ),
        llm.Reasoning(
          [],
          Some(llm.AnthropicRedactedReasoning("anthropic-ciphertext")),
        ),
        llm.Text("Anthropic answer"),
      ]),
    ])
  let assert Ok(llm.HttpRequest(body: anthropic_body, ..)) =
    llm.build_request(
      anthropic_messages.new(anthropic_messages.config("key")),
      anthropic_request,
    )
  assert string.contains(anthropic_body, "anthropic-signature")
  assert string.contains(anthropic_body, "redacted_thinking")
  assert string.contains(anthropic_body, "anthropic-ciphertext")

  let assert Ok(llm.HttpRequest(body: chat_body, ..)) =
    llm.build_request(
      openai_chat_completions.new(openai_chat_completions.config("key")),
      responses_request,
    )
  assert string.contains(chat_body, "OpenAI answer")
  assert !string.contains(chat_body, "openai-ciphertext")
}

pub fn reasoning_only_chat_replay_omits_empty_content_test() {
  let request =
    llm.request("test-model", [
      llm.Message(llm.Assistant, [
        llm.Reasoning(["Prior reasoning"], None),
      ]),
    ])
  let provider =
    openai_chat_completions.new(openai_chat_completions.Config(
      api_key: "key",
      base_url: "https://provider.example.test/v1",
      max_tokens_field: openai_chat_completions.MaxCompletionTokens,
      reasoning_replay_field: openai_chat_completions.ReasoningField,
    ))
  let assert Ok(llm.HttpRequest(body:, ..)) =
    llm.build_request(provider, request)
  assert string.contains(body, "\"reasoning\":\"Prior reasoning\"")
  assert !string.contains(body, "\"content\":[]")
}

pub fn responses_replay_preserves_interleaved_item_order_test() {
  let request =
    llm.request("test-model", [
      llm.Message(llm.Assistant, [
        llm.Reasoning(
          ["first"],
          Some(llm.OpenAIEncryptedReasoning("rs_1", "cipher-first")),
        ),
        llm.ToolCall("call_1", "lookup", json.object([])),
        llm.Reasoning(
          ["second"],
          Some(llm.OpenAIEncryptedReasoning("rs_2", "cipher-second")),
        ),
        llm.Text("answer-last"),
      ]),
    ])
  let assert Ok(llm.HttpRequest(body:, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      request,
    )
  let assert Ok(#(_, after_first)) = string.split_once(body, "cipher-first")
  let assert Ok(#(_, after_call)) = string.split_once(after_first, "call_1")
  let assert Ok(#(_, after_second)) =
    string.split_once(after_call, "cipher-second")
  assert string.contains(after_second, "answer-last")
}

pub fn chat_completions_stream_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.config("key"))
  let start =
    "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":null}],\"usage\":null}"
  let usage =
    "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":6,\"total_tokens\":18,\"prompt_tokens_details\":{\"cached_tokens\":4,\"cache_write_tokens\":5}}}"

  let decoder = llm.stream_decoder(provider)
  let #(decoder, first) = llm.push(decoder, "data: " <> start)
  assert first == []
  let #(decoder, first) = llm.push(decoder, "\n\n")
  let #(_, second) =
    llm.push(decoder, "data: " <> usage <> "\n\ndata: [DONE]\n\n")
  let events = successful_events(list.append(first, second))

  assert list.contains(events, llm.MessageStart("chatcmpl_1", "gpt-test"))
  assert list.contains(events, llm.TextDelta(0, "Hello"))
  assert list.contains(events, llm.MessageStop)
  assert stats(events) == llm.Stats(12, 6, 4, 5)
}

pub fn chat_completions_embedded_error_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.config("key"))
  // OpenAI-style mid-stream error frame: bare `error` object with a string
  // type and no choices.
  let assert Error(llm.ApiError(0, "server_error", "The server had an error")) =
    llm.decode_stream_event(
      provider,
      "{\"error\":{\"message\":\"The server had an error\",\"type\":\"server_error\",\"param\":null,\"code\":null}}",
    )
  // OpenRouter-style: a chunk with a top-level `error` (integer code)
  // alongside a finish_reason "error" choice, delivered mid-stream or on a
  // 200-status body.
  let openrouter =
    "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"error\"}],\"error\":{\"code\":502,\"message\":\"Provider disconnected\"}}"
  let assert Error(llm.ApiError(502, "api_error", "Provider disconnected")) =
    llm.decode_stream_event(provider, openrouter)
  let assert Error(llm.ApiError(502, "api_error", "Provider disconnected")) =
    llm.decode_response(provider, 200, openrouter)
}

pub fn chat_completions_tool_call_indices_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.config("key"))
  let assert Ok(events) =
    llm.decode_response(
      provider,
      200,
      "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Let me check\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}},{\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}",
    )
  // Text stays at the choice index; tool calls take the following indices so
  // parallel calls never collapse onto one block.
  assert list.contains(events, llm.TextDelta(0, "Let me check"))
  assert list.contains(events, llm.ToolCallStart(2, "call_1", "lookup"))
  assert list.contains(events, llm.ToolCallStart(3, "call_2", "lookup"))
  assert list.contains(events, llm.Finished(llm.ToolUse))
}

pub fn chat_completions_max_tokens_field_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.Config(
      api_key: "key",
      base_url: "https://api.fireworks.ai/inference",
      max_tokens_field: openai_chat_completions.MaxTokens,
      reasoning_replay_field: openai_chat_completions.OmitReasoning,
    ))
  let assert Ok(llm.HttpRequest(url:, body:, ..)) =
    llm.build_request(
      provider,
      llm.Request(
        model: "test-model",
        messages: [llm.Message(llm.User, [llm.Text("hi")])],
        tools: [],
        max_output_tokens: Some(128),
        reasoning_effort: None,
        stream: True,
      ),
    )
  assert url == "https://api.fireworks.ai/inference/v1/chat/completions"
  assert string.contains(body, "\"max_tokens\":128")
  assert !string.contains(body, "max_completion_tokens")
}

pub fn chat_completions_versioned_base_url_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.Config(
      api_key: "key",
      base_url: "https://provider.example.test/api/v3",
      max_tokens_field: openai_chat_completions.MaxCompletionTokens,
      reasoning_replay_field: openai_chat_completions.OmitReasoning,
    ))
  let assert Ok(llm.HttpRequest(url:, ..)) =
    llm.build_request(
      provider,
      llm.request("provider-model", [
        llm.Message(llm.User, [llm.Text("hello")]),
      ]),
    )
  assert url == "https://provider.example.test/api/v3/chat/completions"
}

pub fn reasoning_effort_request_test() {
  let request =
    llm.Request(
      ..llm.request("test-model", [llm.Message(llm.User, [llm.Text("hi")])]),
      reasoning_effort: Some("high"),
    )

  let assert Ok(llm.HttpRequest(body: anthropic_body, ..)) =
    llm.build_request(
      anthropic_messages.new(anthropic_messages.config("key")),
      request,
    )
  assert string.contains(anthropic_body, "\"thinking\":{\"type\":\"adaptive\"}")
  assert string.contains(
    anthropic_body,
    "\"output_config\":{\"effort\":\"high\"}",
  )

  let assert Ok(llm.HttpRequest(body: chat_body, ..)) =
    llm.build_request(
      openai_chat_completions.new(openai_chat_completions.config("key")),
      request,
    )
  assert string.contains(chat_body, "\"reasoning_effort\":\"high\"")

  let assert Ok(llm.HttpRequest(body: responses_body, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      request,
    )
  assert string.contains(responses_body, "\"effort\":\"high\"")
  // Reasoning summaries require a verified organization, so they are never
  // requested.
  assert !string.contains(responses_body, "\"summary\":\"auto\"")
}

pub fn anthropic_finish_reasons_test() {
  let provider = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(paused) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"pause_turn\"},\"usage\":{\"output_tokens\":5}}",
    )
  assert list.contains(paused, llm.Finished(llm.Paused))
  let assert Ok(refused) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"},\"usage\":{\"output_tokens\":5}}",
    )
  assert list.contains(refused, llm.Finished(llm.ContentFilter))
  let assert Ok(overflow) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"model_context_window_exceeded\"},\"usage\":{\"output_tokens\":5}}",
    )
  assert list.contains(overflow, llm.Finished(llm.Length))
}

pub fn anthropic_message_delta_without_usage_test() {
  let provider = anthropic_messages.new(anthropic_messages.config("key"))
  // Adaptive-thinking streams emit message_delta frames without usage.
  let assert Ok(events) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null}}",
    )
  assert events == [llm.Finished(llm.Stop)]
}

pub fn chat_completions_reasoning_replay_test() {
  let request =
    llm.request("test-model", [
      llm.Message(llm.Assistant, [
        llm.Reasoning(["Prior ", "thinking"], None),
        llm.ToolCall("call_1", "lookup", json.object([])),
      ]),
      llm.Message(llm.ToolRole, [
        llm.ToolResult("call_1", [llm.Text("ok")], False),
      ]),
    ])

  let assert Ok(llm.HttpRequest(body: openai_body, ..)) =
    llm.build_request(
      openai_chat_completions.new(openai_chat_completions.config("key")),
      request,
    )
  assert !string.contains(openai_body, "Prior thinking")

  let fireworks =
    openai_chat_completions.new(openai_chat_completions.Config(
      api_key: "key",
      base_url: "https://api.fireworks.ai/inference",
      max_tokens_field: openai_chat_completions.MaxTokens,
      reasoning_replay_field: openai_chat_completions.ReasoningContentField,
    ))
  let assert Ok(llm.HttpRequest(body: fireworks_body, ..)) =
    llm.build_request(fireworks, request)
  assert string.contains(
    fireworks_body,
    "\"reasoning_content\":\"Prior thinking\"",
  )

  let openrouter =
    openai_chat_completions.new(openai_chat_completions.Config(
      api_key: "key",
      base_url: "https://openrouter.ai/api",
      max_tokens_field: openai_chat_completions.MaxCompletionTokens,
      reasoning_replay_field: openai_chat_completions.ReasoningField,
    ))
  let assert Ok(llm.HttpRequest(body: openrouter_body, ..)) =
    llm.build_request(openrouter, request)
  assert string.contains(openrouter_body, "\"reasoning\":\"Prior thinking\"")
  assert !string.contains(openrouter_body, "reasoning_content")
}

pub fn chat_completions_reasoning_delta_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.config("key"))
  let assert Ok(fireworks) =
    llm.decode_stream_event(
      provider,
      "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"Thinking\"},\"finish_reason\":null}]}",
    )
  assert list.contains(fireworks, llm.ContentStart(1, llm.ReasoningContent))
  assert list.contains(fireworks, llm.ReasoningDelta(1, "Thinking"))
  let assert Ok(openrouter) =
    llm.decode_stream_event(
      provider,
      "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"More\"},\"finish_reason\":null}]}",
    )
  assert list.contains(openrouter, llm.ContentStart(1, llm.ReasoningContent))
  assert list.contains(openrouter, llm.ReasoningDelta(1, "More"))
}

pub fn responses_base64_document_test() {
  let request =
    llm.request("test-model", [
      llm.Message(llm.User, [
        llm.Document(llm.Base64("application/pdf", "aGVsbG8=")),
      ]),
    ])
  let assert Ok(llm.HttpRequest(body:, ..)) =
    llm.build_request(
      openai_responses.new(openai_responses.config("key")),
      request,
    )
  assert string.contains(body, "\"filename\":\"document.pdf\"")
  assert string.contains(body, "data:application/pdf;base64,aGVsbG8=")
}

pub fn responses_terminal_details_test() {
  let provider = openai_responses.new(openai_responses.config("key"))
  let assert Ok(filtered) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[],\"usage\":null}}",
    )
  assert list.contains(filtered, llm.Finished(llm.ContentFilter))
  let assert Ok(truncated) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[],\"usage\":null}}",
    )
  assert list.contains(truncated, llm.Finished(llm.Length))
  let assert Ok(failed) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.failed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"boom\"},\"output\":[],\"usage\":null}}",
    )
  assert list.contains(failed, llm.Finished(llm.Failed("boom")))
}

pub fn responses_stream_error_test() {
  let provider = openai_responses.new(openai_responses.config("key"))
  let assert Error(llm.ApiError(0, "server_error", "The model had an error")) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"error\",\"code\":\"server_error\",\"message\":\"The model had an error\",\"param\":null}",
    )
}

pub fn responses_stream_test() {
  let provider = openai_responses.new(openai_responses.config("key"))
  let assert Ok(start) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"in_progress\",\"output\":[],\"usage\":null}}",
    )
  let assert Ok(delta) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}",
    )
  let assert Ok(reasoning_start) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}",
    )
  let assert Ok(reasoning_delta) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":1,\"summary_index\":0,\"delta\":\"Summary\"}",
    )
  let assert Ok(reasoning_done) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Summary\"}],\"encrypted_content\":\"openai-ciphertext\"}}",
    )
  let assert Ok(done) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":4,\"cache_write_tokens\":5},\"output_tokens\":6,\"total_tokens\":18}}}",
    )
  let events =
    list.flatten([
      start,
      delta,
      reasoning_start,
      reasoning_delta,
      reasoning_done,
      done,
    ])

  assert list.contains(events, llm.MessageStart("resp_1", "gpt-test"))
  assert list.contains(events, llm.TextDelta(0, "Hello"))
  assert list.contains(events, llm.ReasoningDelta(1, "Summary"))
  assert list.contains(
    events,
    llm.ReasoningEncrypted(
      1,
      llm.OpenAIEncryptedReasoning("rs_1", "openai-ciphertext"),
    ),
  )
  assert list.contains(events, llm.Finished(llm.Stop))
  assert stats(events) == llm.Stats(12, 6, 4, 5)
}

pub fn anthropic_stream_test() {
  let provider = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(start) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}",
    )
  let assert Ok(delta) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
    )
  let assert Ok(reasoning_start) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
    )
  let assert Ok(reasoning_delta) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Thinking\"}}",
    )
  let assert Ok(signature) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"anthropic-signature\"}}",
    )
  let assert Ok(redacted) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"anthropic-ciphertext\"}}",
    )
  let assert Ok(done) =
    llm.decode_stream_event(
      provider,
      "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":5}}",
    )
  let events =
    list.flatten([
      start,
      delta,
      reasoning_start,
      reasoning_delta,
      signature,
      redacted,
      done,
    ])

  assert list.contains(events, llm.MessageStart("msg_1", "claude-test"))
  assert list.contains(events, llm.TextDelta(0, "Hello"))
  assert list.contains(events, llm.ReasoningDelta(1, "Thinking"))
  assert list.contains(
    events,
    llm.ReasoningEncrypted(
      1,
      llm.AnthropicSignedReasoning("anthropic-signature"),
    ),
  )
  assert list.contains(
    events,
    llm.ReasoningEncrypted(
      2,
      llm.AnthropicRedactedReasoning("anthropic-ciphertext"),
    ),
  )
  assert list.contains(events, llm.Finished(llm.Stop))
  assert stats(events) == llm.Stats(10, 5, 2, 3)
}

pub fn encrypted_reasoning_buffered_test() {
  let responses = openai_responses.new(openai_responses.config("key"))
  let assert Ok(response_events) =
    llm.decode_response(
      responses,
      200,
      "{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Summary\"}],\"encrypted_content\":\"openai-ciphertext\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
    )
  assert list.contains(response_events, llm.ReasoningDelta(0, "Summary"))
  assert list.contains(
    response_events,
    llm.ReasoningEncrypted(
      0,
      llm.OpenAIEncryptedReasoning("rs_1", "openai-ciphertext"),
    ),
  )

  let anthropic = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(anthropic_events) =
    llm.decode_response(
      anthropic,
      200,
      "{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"Thinking\",\"signature\":\"anthropic-signature\"},{\"type\":\"redacted_thinking\",\"data\":\"anthropic-ciphertext\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
    )
  assert list.contains(
    anthropic_events,
    llm.ReasoningEncrypted(
      0,
      llm.AnthropicSignedReasoning("anthropic-signature"),
    ),
  )
  assert list.contains(
    anthropic_events,
    llm.ReasoningEncrypted(
      1,
      llm.AnthropicRedactedReasoning("anthropic-ciphertext"),
    ),
  )

  let assert Ok(unsigned_events) =
    llm.decode_response(
      anthropic,
      200,
      "{\"id\":\"msg_2\",\"model\":\"claude-test\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"Thinking\",\"signature\":\"\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
    )
  assert !list.contains(
    unsigned_events,
    llm.ReasoningEncrypted(0, llm.AnthropicSignedReasoning("")),
  )
}

fn successful_events(
  results: List(Result(llm.Event, llm.Error)),
) -> List(llm.Event) {
  results
  |> list.map(fn(result) {
    let assert Ok(event) = result
    event
  })
}

fn stats(events: List(llm.Event)) -> llm.Stats {
  list.fold(events, llm.empty_stats(), fn(stats, event) {
    case event {
      llm.UsageReported(usage) -> llm.apply_usage(stats, usage)
      _ -> stats
    }
  })
}
