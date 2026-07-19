import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import harness3/llm
import harness3/llm/anthropic_messages
import harness3/llm/openai_chat_completions
import harness3/llm/openai_responses

fn multimodal_request() -> llm.Request {
  llm.Request(
    model: "test-model",
    messages: [llm.Message(llm.User, [
      llm.Image(llm.Url("https://example.test/image.png"), llm.High),
      llm.Image(llm.Base64("image/png", "aGVsbG8="), llm.Low),
      llm.Document(llm.FileId("file_123")),
      llm.Text("Describe these inputs"),
    ])],
    tools: [llm.Tool(
      "lookup",
      Some("Look something up"),
      json.object([#("type", json.string("object"))]),
    )],
    max_output_tokens: Some(128),
    temperature: Some(0.2),
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

  let assert Ok(llm.HttpRequest(body: anthropic_body, ..)) =
    llm.build_request(
      anthropic_messages.new(anthropic_messages.config("key")),
      request,
    )
  assert string.contains(anthropic_body, "\"type\":\"image\"")
  assert string.contains(anthropic_body, "\"type\":\"base64\"")
  assert string.contains(anthropic_body, "\"type\":\"file\"")
  assert string.contains(anthropic_body, "input_schema")
}

pub fn encrypted_reasoning_requests_test() {
  let responses_request = llm.request("test-model", [
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

  let anthropic_request = llm.request("test-model", [
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

pub fn chat_completions_stream_test() {
  let provider =
    openai_chat_completions.new(openai_chat_completions.config("key"))
  let start =
    "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"finish_reason\":null}],\"usage\":null}"
  let usage =
    "{\"id\":\"chatcmpl_1\",\"model\":\"gpt-test\",\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":6,\"total_tokens\":18,\"prompt_tokens_details\":{\"cached_tokens\":4}}}"

  let decoder = llm.stream_decoder(provider)
  let #(decoder, first) = llm.push(decoder, "data: " <> start)
  assert first == []
  let #(decoder, first) = llm.push(decoder, "\n\n")
  let #(_, second) = llm.push(decoder, "data: " <> usage <> "\n\ndata: [DONE]\n\n")
  let events = successful_events(list.append(first, second))

  assert list.contains(events, llm.MessageStart("chatcmpl_1", "gpt-test"))
  assert list.contains(events, llm.TextDelta(0, "Hello"))
  assert stats(events) == llm.Stats(12, 6, 4, 0)
}

pub fn responses_stream_test() {
  let provider = openai_responses.new(openai_responses.config("key"))
  let assert Ok(start) = llm.decode_stream_event(provider,
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"in_progress\",\"output\":[],\"usage\":null}}",
  )
  let assert Ok(delta) = llm.decode_stream_event(provider,
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}",
  )
  let assert Ok(reasoning_start) = llm.decode_stream_event(provider,
    "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[]}}",
  )
  let assert Ok(reasoning_delta) = llm.decode_stream_event(provider,
    "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":1,\"summary_index\":0,\"delta\":\"Summary\"}",
  )
  let assert Ok(reasoning_done) = llm.decode_stream_event(provider,
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Summary\"}],\"encrypted_content\":\"openai-ciphertext\"}}",
  )
  let assert Ok(done) = llm.decode_stream_event(provider,
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":4},\"output_tokens\":6,\"total_tokens\":18}}}",
  )
  let events = list.flatten([
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
  assert list.contains(events, llm.ReasoningEncrypted(
    1,
    llm.OpenAIEncryptedReasoning("rs_1", "openai-ciphertext"),
  ))
  assert list.contains(events, llm.Finished(llm.Stop))
  assert stats(events) == llm.Stats(12, 6, 4, 0)
}

pub fn anthropic_stream_test() {
  let provider = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(start) = llm.decode_stream_event(provider,
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}",
  )
  let assert Ok(delta) = llm.decode_stream_event(provider,
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}",
  )
  let assert Ok(reasoning_start) = llm.decode_stream_event(provider,
    "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}",
  )
  let assert Ok(reasoning_delta) = llm.decode_stream_event(provider,
    "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Thinking\"}}",
  )
  let assert Ok(signature) = llm.decode_stream_event(provider,
    "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"anthropic-signature\"}}",
  )
  let assert Ok(redacted) = llm.decode_stream_event(provider,
    "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"anthropic-ciphertext\"}}",
  )
  let assert Ok(done) = llm.decode_stream_event(provider,
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":5}}",
  )
  let events = list.flatten([
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
  assert list.contains(events, llm.ReasoningEncrypted(
    1,
    llm.AnthropicSignedReasoning("anthropic-signature"),
  ))
  assert list.contains(events, llm.ReasoningEncrypted(
    2,
    llm.AnthropicRedactedReasoning("anthropic-ciphertext"),
  ))
  assert list.contains(events, llm.Finished(llm.Stop))
  assert stats(events) == llm.Stats(10, 5, 2, 3)
}

pub fn encrypted_reasoning_buffered_test() {
  let responses = openai_responses.new(openai_responses.config("key"))
  let assert Ok(response_events) = llm.decode_response(responses, 200,
    "{\"id\":\"resp_1\",\"model\":\"gpt-test\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Summary\"}],\"encrypted_content\":\"openai-ciphertext\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
  )
  assert list.contains(response_events, llm.ReasoningDelta(0, "Summary"))
  assert list.contains(response_events, llm.ReasoningEncrypted(
    0,
    llm.OpenAIEncryptedReasoning("rs_1", "openai-ciphertext"),
  ))

  let anthropic = anthropic_messages.new(anthropic_messages.config("key"))
  let assert Ok(anthropic_events) = llm.decode_response(anthropic, 200,
    "{\"id\":\"msg_1\",\"model\":\"claude-test\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"Thinking\",\"signature\":\"anthropic-signature\"},{\"type\":\"redacted_thinking\",\"data\":\"anthropic-ciphertext\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
  )
  assert list.contains(anthropic_events, llm.ReasoningEncrypted(
    0,
    llm.AnthropicSignedReasoning("anthropic-signature"),
  ))
  assert list.contains(anthropic_events, llm.ReasoningEncrypted(
    1,
    llm.AnthropicRedactedReasoning("anthropic-ciphertext"),
  ))
}

fn successful_events(results: List(Result(llm.Event, llm.Error))) -> List(llm.Event) {
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
