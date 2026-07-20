import exception
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/llm
import harness3/plugin

const callback_timeout_milliseconds = 5000

const plugin_host_stop_milliseconds = 5000

const compaction_instruction = "Create a handover summary of the entire session above so another instance can continue after the earlier model context is discarded. Preserve the objective, constraints, decisions, completed work, exact paths and identifiers, command and test results, failures, current state, and remaining steps. Do not call tools. Output exactly one block and no text outside it:\n\n<handover>\n...\n</handover>"

pub type Status {
  Ready
  Waiting
  Completed
  Failed(reason: String)
}

pub type State {
  State(
    id: String,
    profile_id: String,
    revision: Int,
    model_id: String,
    round: Int,
    /// Complete, client-visible session history. Compaction never removes
    /// messages from this list.
    messages: List(llm.Message),
    /// The model-facing context after compaction. `None` means `messages` is
    /// still the active context.
    context_messages: Option(List(llm.Message)),
    pending_messages: List(llm.Message),
    stats: llm.Stats,
    plugin_states: Dict(String, String),
    plugin_generation: Int,
    last_catalog_revision: Option(Int),
    last_context_tokens: Option(Int),
    compaction_requested: Int,
    compaction_completed: Int,
    last_compaction_error: Option(String),
    status: Status,
  )
}

pub fn state(id: String, model_id: String) -> State {
  State(
    id:,
    profile_id: id,
    revision: 0,
    model_id:,
    round: 0,
    messages: [],
    context_messages: None,
    pending_messages: [],
    stats: llm.empty_stats(),
    plugin_states: plugin.empty_states(),
    plugin_generation: 0,
    last_catalog_revision: None,
    last_context_tokens: None,
    compaction_requested: 0,
    compaction_completed: 0,
    last_compaction_error: None,
    status: Ready,
  )
}

pub type TransportError {
  TransportError(reason: String)
}

/// A transport must not produce the next event until `consume` has returned.
pub opaque type ModelTransport {
  ModelTransport(
    run: fn(llm.Provider, llm.Request, fn(llm.Event) -> Result(Nil, Error)) ->
      Result(Nil, TransportError),
  )
}

pub fn model_transport(
  run: fn(llm.Provider, llm.Request, fn(llm.Event) -> Result(Nil, Error)) ->
    Result(Nil, TransportError),
) -> ModelTransport {
  ModelTransport(run)
}

pub type Config {
  Config(
    provider: llm.Provider,
    model_name: String,
    catalog_revision: Int,
    registry: plugin.Registry,
    transport: ModelTransport,
    max_output_tokens: Option(Int),
    reasoning_effort: Option(String),
    context_window_tokens: Int,
  )
}

pub type Error {
  PluginError(error: plugin.Error)
  ModelTransportFailed(reason: String)
  InvalidModelOutput(reason: String)
  ObserverFailed(reason: String)
  CommitFailed(reason: String)
  AccumulatorFailed(reason: String)
}

pub type Event {
  ModelEvent(event: llm.Event)
  ToolStarted(id: String, name: String)
  ToolFinished(id: String, name: String, is_error: Bool)
}

pub type Disposition {
  Continue
  Complete
}

pub opaque type Active {
  Active(state: State, config: Config, plugins: PluginHost)
}

pub opaque type CallbackRouter {
  CallbackRouter(
    call: fn(String, String, String, String) -> Result(String, Error),
  )
}

pub fn callback_router(
  call: fn(String, String, String, String) -> Result(String, Error),
) -> CallbackRouter {
  CallbackRouter(call)
}

pub opaque type PluginHost {
  PluginHost(subject: Subject(PluginMessage))
}

pub type CallbackResult {
  CallbackResult(
    output: String,
    plugin_states: Dict(String, String),
    plugin_generation: Int,
  )
}

type PluginSnapshot {
  PluginSnapshot(generation: Int, states: Dict(String, String))
}

type PluginHostState {
  PluginHostState(runtime: plugin.Runtime, generation: Int)
}

type PluginMessage {
  GetPrompt(reply: Subject(String))
  GetTools(reply: Subject(List(llm.Tool)))
  GetStates(reply: Subject(PluginSnapshot))
  InvokeTool(
    name: String,
    invocation: plugin.ToolInvocation,
    router: CallbackRouter,
    reply: Subject(Result(plugin.ToolOutput, Error)),
  )
  InvokeCallback(
    plugin_name: String,
    callback: String,
    input: String,
    router: CallbackRouter,
    reply: Subject(Result(CallbackResult, Error)),
  )
  StopPlugins
}

pub fn activate(state: State, config: Config) -> Result(Active, Error) {
  use runtime <- result.try(
    plugin.activate(config.registry, state.plugin_states)
    |> result.map_error(PluginError),
  )
  use host <- result.try(start_plugin_host(runtime, state.plugin_generation))
  Ok(Active(state, config, host))
}

/// Releases an activated agent that will not be started, stopping its plugin
/// host process. An `Active` that is neither started nor discarded leaks the
/// host actor: it is linked only to the process that called `activate`, and a
/// normal exit of that process does not take it down.
pub fn discard(active: Active) -> Nil {
  let Active(plugins:, ..) = active
  stop_plugin_host(plugins)
}

fn start_plugin_host(
  runtime: plugin.Runtime,
  generation: Int,
) -> Result(PluginHost, Error) {
  actor.new(PluginHostState(runtime, generation))
  |> actor.on_message(handle_plugin_message)
  |> actor.start
  |> result.map(fn(started) { PluginHost(started.data) })
  |> result.map_error(fn(error) {
    PluginError(plugin.HookFailed("runtime", "start", string.inspect(error)))
  })
}

fn handle_plugin_message(
  state: PluginHostState,
  message: PluginMessage,
) -> actor.Next(PluginHostState, PluginMessage) {
  let PluginHostState(runtime:, generation:) = state
  case message {
    GetPrompt(reply) -> {
      process.send(reply, plugin.system_prompt(runtime))
      actor.continue(state)
    }
    GetTools(reply) -> {
      process.send(reply, plugin.tools(runtime))
      actor.continue(state)
    }
    GetStates(reply) -> {
      process.send(
        reply,
        PluginSnapshot(generation, plugin.encoded_states(runtime)),
      )
      actor.continue(state)
    }
    InvokeTool(name, invocation, router, reply) -> {
      let CallbackRouter(call:) = router
      let invoked =
        plugin.invoke_tool_with_agent_callbacks(
          runtime,
          name,
          invocation,
          Some(fn(agent_id, plugin_name, callback, input) {
            call(agent_id, plugin_name, callback, input)
            |> result.map_error(fn(error) {
              plugin.AgentCallbackFailed(string.inspect(error))
            })
          }),
        )
        |> result.map_error(PluginError)
      case invoked {
        Ok(#(runtime, output)) -> {
          process.send(reply, Ok(output))
          actor.continue(PluginHostState(runtime, generation + 1))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    InvokeCallback(plugin_name, callback, input, router, reply) -> {
      let CallbackRouter(call:) = router
      let invoked =
        plugin.invoke_callback(
          runtime,
          plugin_name,
          callback,
          input,
          fn(agent_id, plugin_name, callback, input) {
            call(agent_id, plugin_name, callback, input)
            |> result.map_error(fn(error) {
              plugin.AgentCallbackFailed(string.inspect(error))
            })
          },
        )
        |> result.map_error(PluginError)
      case invoked {
        Ok(#(runtime, output)) -> {
          process.send(
            reply,
            Ok(CallbackResult(
              output,
              plugin.encoded_states(runtime),
              generation + 1,
            )),
          )
          actor.continue(PluginHostState(runtime, generation + 1))
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    StopPlugins -> {
      // A linked process is not taken down by its owner's *normal* exit, so
      // anything a plugin owns (MCP transports and their OS children) must be
      // told to stop here. Hooks only send, so this does not block.
      plugin.release(runtime)
      actor.stop()
    }
  }
}

fn plugin_prompt(host: PluginHost) -> String {
  let PluginHost(subject) = host
  process.call_forever(subject, GetPrompt)
}

fn plugin_tools(host: PluginHost) -> List(llm.Tool) {
  let PluginHost(subject) = host
  process.call_forever(subject, GetTools)
}

fn plugin_states(host: PluginHost) -> PluginSnapshot {
  let PluginHost(subject) = host
  process.call_forever(subject, GetStates)
}

pub type RoundResult {
  RoundResult(active: Active, state: State, disposition: Disposition)
}

type Part {
  TextPart(text: String)
  ReasoningPart(summary: String, encrypted: Option(llm.EncryptedReasoning))
  ToolPart(id: String, name: String, arguments: String)
}

type Accumulator {
  Accumulator(
    parts: Dict(Int, Part),
    active_slots: Dict(Int, Int),
    next_slot: Int,
    stats: llm.Stats,
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    finish: Option(llm.FinishReason),
    error: Option(Error),
  )
}

type AccumulatorMessage {
  Consume(llm.Event, Subject(Result(Nil, Error)))
  Read(Subject(Accumulator))
  StopAccumulator
}

pub fn run_round(
  active: Active,
  router: CallbackRouter,
  observe: fn(Event) -> Result(Nil, Error),
) -> Result(RoundResult, Error) {
  let Active(state:, config:, plugins:) = active
  use accumulated <- result.try(run_model(
    active,
    normal_request_messages(state, plugins),
    config.max_output_tokens,
    observe,
  ))
  use _ <- result.try(validate_finish(accumulated.finish))
  use assistant_content <- result.try(parts_to_content(accumulated.parts))
  let assistant = llm.Message(llm.Assistant, assistant_content)
  use tool_messages <- result.try(execute_tools(
    plugins,
    router,
    assistant_content,
    observe,
  ))
  let additions = [assistant, ..tool_messages]
  let messages = list.append(state.messages, additions)
  let context_messages = case state.context_messages {
    None -> None
    Some(context) -> Some(list.append(context, additions))
  }
  let disposition = case accumulated.finish, tool_messages {
    Some(llm.Paused), _ -> Continue
    _, [] -> Complete
    _, _ -> Continue
  }
  let status = case disposition {
    Continue -> Ready
    Complete -> Completed
  }
  let PluginSnapshot(generation:, states:) = plugin_states(plugins)
  let state =
    State(
      ..state,
      round: state.round + 1,
      messages:,
      context_messages:,
      stats: add_stats(state.stats, accumulated.stats),
      plugin_states: states,
      plugin_generation: generation,
      last_catalog_revision: Some(config.catalog_revision),
      last_context_tokens: context_tokens(accumulated),
      status:,
    )
  let active = Active(state, config, plugins)
  Ok(RoundResult(active, state, disposition))
}

fn normal_request_messages(
  state: State,
  plugins: PluginHost,
) -> List(llm.Message) {
  let context = case state.context_messages {
    Some(messages) -> messages
    None -> state.messages
  }
  case plugin_prompt(plugins) {
    "" -> context
    prompt -> [llm.Message(llm.System, [llm.Text(prompt)]), ..context]
  }
}

fn run_model(
  active: Active,
  messages: List(llm.Message),
  max_output_tokens: Option(Int),
  observe: fn(Event) -> Result(Nil, Error),
) -> Result(Accumulator, Error) {
  let Active(config:, plugins:, ..) = active
  use accumulator <- result.try(start_accumulator())
  let request =
    llm.Request(
      model: config.model_name,
      messages:,
      tools: plugin_tools(plugins),
      max_output_tokens:,
      reasoning_effort: config.reasoning_effort,
      stream: True,
    )
  let ModelTransport(run:) = config.transport
  let transport_result =
    run(config.provider, request, fn(event) {
      use _ <- result.try(observe(ModelEvent(event)))
      process.call(accumulator, 5000, fn(reply) { Consume(event, reply) })
    })
  let accumulated = process.call(accumulator, 5000, Read)
  process.send(accumulator, StopAccumulator)
  use _ <- result.try(
    transport_result
    |> result.map_error(fn(error) {
      let TransportError(reason) = error
      ModelTransportFailed(reason)
    }),
  )
  use _ <- result.try(case accumulated.error {
    Some(error) -> Error(error)
    None -> Ok(Nil)
  })
  Ok(accumulated)
}

fn context_tokens(accumulated: Accumulator) -> Option(Int) {
  case accumulated.input_tokens {
    None -> None
    Some(input) -> {
      // `input_tokens` excludes cached tokens on every provider (Anthropic
      // reports only post-breakpoint tokens; the OpenAI adapters normalize to
      // the same semantics), and the Anthropic adapter enables automatic
      // caching unconditionally. Occupancy must therefore add cache reads and
      // writes, or a cache-dominated conversation never crosses the
      // compaction threshold and overflows the window instead.
      let llm.Stats(cache_read_tokens:, cache_write_tokens:, ..) =
        accumulated.stats
      Some(
        input
        + option.unwrap(accumulated.output_tokens, 0)
        + cache_read_tokens
        + cache_write_tokens,
      )
    }
  }
}

fn start_accumulator() -> Result(Subject(AccumulatorMessage), Error) {
  actor.new(Accumulator(
    dict.new(),
    dict.new(),
    0,
    llm.empty_stats(),
    None,
    None,
    None,
    None,
  ))
  |> actor.on_message(handle_accumulator)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(error) { AccumulatorFailed(string.inspect(error)) })
}

fn handle_accumulator(
  state: Accumulator,
  message: AccumulatorMessage,
) -> actor.Next(Accumulator, AccumulatorMessage) {
  case message {
    Consume(event, reply) -> {
      let next = accumulate(state, event)
      process.send(reply, case next.error {
        Some(error) -> Error(error)
        None -> Ok(Nil)
      })
      actor.continue(next)
    }
    Read(reply) -> {
      process.send(reply, state)
      actor.continue(state)
    }
    StopAccumulator -> actor.stop()
  }
}

fn accumulate(state: Accumulator, event: llm.Event) -> Accumulator {
  case event {
    llm.ContentStart(index, llm.TextContent) ->
      start_part(state, index, TextPart(""))
    llm.ContentStart(index, llm.ReasoningContent) ->
      start_part(state, index, ReasoningPart("", None))
    llm.TextDelta(index, text) -> update_or_start_text(state, index, text)
    llm.RefusalDelta(index, text) -> update_or_start_text(state, index, text)
    llm.ReasoningDelta(index, text) ->
      update_part(state, index, fn(part) {
        case part {
          ReasoningPart(summary, encrypted) ->
            ReasoningPart(summary <> text, encrypted)
          _ -> part
        }
      })
    llm.ReasoningEncrypted(index, encrypted) ->
      update_part(state, index, fn(part) {
        case part {
          ReasoningPart(summary, _) -> ReasoningPart(summary, Some(encrypted))
          _ -> part
        }
      })
    llm.ToolCallStart(index, id, name) ->
      start_part(state, index, ToolPart(id, name, ""))
    llm.ToolCallArgumentsDelta(index, fragment) ->
      update_part(state, index, fn(part) {
        case part {
          ToolPart(id, name, arguments) ->
            ToolPart(id, name, arguments <> fragment)
          _ -> part
        }
      })
    llm.UsageReported(usage) -> {
      let llm.Usage(input_tokens:, output_tokens:, ..) = usage
      Accumulator(
        ..state,
        stats: llm.apply_usage(state.stats, usage),
        input_tokens: prefer_usage(input_tokens, state.input_tokens),
        output_tokens: prefer_usage(output_tokens, state.output_tokens),
      )
    }
    llm.Finished(reason) -> Accumulator(..state, finish: Some(reason))
    llm.ContentStop(index) ->
      Accumulator(..state, active_slots: dict.delete(state.active_slots, index))
    _ -> state
  }
}

fn prefer_usage(latest: Option(Int), current: Option(Int)) -> Option(Int) {
  case latest {
    Some(_) -> latest
    None -> current
  }
}

fn validate_finish(finish: Option(llm.FinishReason)) -> Result(Nil, Error) {
  case finish {
    None | Some(llm.Stop) | Some(llm.ToolUse) | Some(llm.Paused) -> Ok(Nil)
    Some(llm.Length) -> Error(InvalidModelOutput("model output was truncated"))
    Some(llm.ContentFilter) ->
      Error(InvalidModelOutput("model output was blocked by a content filter"))
    Some(llm.Cancelled) -> Error(InvalidModelOutput("model turn was cancelled"))
    Some(llm.Failed(reason)) -> Error(InvalidModelOutput(reason))
    Some(llm.Other(reason)) ->
      Error(InvalidModelOutput("model stopped unexpectedly: " <> reason))
  }
}

fn add_stats(total: llm.Stats, round: llm.Stats) -> llm.Stats {
  let llm.Stats(
    input_tokens: total_input,
    output_tokens: total_output,
    cache_read_tokens: total_cache_read,
    cache_write_tokens: total_cache_write,
  ) = total
  let llm.Stats(
    input_tokens: round_input,
    output_tokens: round_output,
    cache_read_tokens: round_cache_read,
    cache_write_tokens: round_cache_write,
  ) = round
  llm.Stats(
    input_tokens: total_input + round_input,
    output_tokens: total_output + round_output,
    cache_read_tokens: total_cache_read + round_cache_read,
    cache_write_tokens: total_cache_write + round_cache_write,
  )
}

fn compaction_target(state: State, config: Config) -> Option(Int) {
  // A failed attempt pauses the manual request rather than retrying it at
  // every round boundary (one wasted LLM call per round); a new explicit
  // request clears the recorded error and restores eligibility.
  let manually_requested =
    state.compaction_requested > state.compaction_completed
    && state.last_compaction_error == None
  // Automatic compaction deliberately also runs after a round that completed
  // the agent: a dormant agent is revived by the next message, and compacting
  // eagerly means that revival starts from a compacted handover instead of
  // paying for compaction before its first new round.
  let automatically_requested = case state.last_context_tokens {
    Some(tokens) if config.context_window_tokens > 0 ->
      tokens * 5 >= config.context_window_tokens * 4
    _ -> False
  }
  case manually_requested, automatically_requested {
    True, _ -> Some(state.compaction_requested)
    False, True -> Some(state.compaction_completed + 1)
    False, False -> None
  }
}

fn compact(
  active: Active,
  target: Int,
  observe: fn(Event) -> Result(Nil, Error),
) -> Result(#(Active, State), Error) {
  let Active(state:, config:, plugins:) = active
  let messages =
    normal_request_messages(state, plugins)
    |> list.append([
      llm.Message(llm.User, [llm.Text(compaction_instruction)]),
    ])
  use accumulated <- result.try(run_model(
    active,
    messages,
    compaction_output_tokens(config),
    observe,
  ))
  use _ <- result.try(validate_compaction_finish(accumulated.finish))
  use content <- result.try(parts_to_content(accumulated.parts))
  use output <- result.try(compaction_text(content))
  use handover <- result.try(parse_handover(output))
  let compacted_context = [
    llm.Message(llm.User, [
      llm.Text("Continue from this compacted handover:\n\n" <> handover),
    ]),
  ]
  let state =
    State(
      ..state,
      context_messages: Some(compacted_context),
      stats: add_stats(state.stats, accumulated.stats),
      last_catalog_revision: Some(config.catalog_revision),
      last_context_tokens: None,
      compaction_requested: int.max(state.compaction_requested, target),
      compaction_completed: target,
      last_compaction_error: None,
    )
  Ok(#(Active(state, config, plugins), state))
}

fn compaction_output_tokens(config: Config) -> Option(Int) {
  case config.context_window_tokens > 0 {
    False -> config.max_output_tokens
    True -> {
      let cap = int.max(1, config.context_window_tokens / 10)
      case config.max_output_tokens {
        Some(limit) -> Some(int.min(limit, cap))
        None -> Some(cap)
      }
    }
  }
}

fn validate_compaction_finish(
  finish: Option(llm.FinishReason),
) -> Result(Nil, Error) {
  case finish {
    None | Some(llm.Stop) -> Ok(Nil)
    Some(llm.ToolUse) ->
      Error(InvalidModelOutput("compaction must not call tools"))
    Some(llm.Paused) ->
      Error(InvalidModelOutput("compaction response was paused"))
    other -> validate_finish(other)
  }
}

fn compaction_text(content: List(llm.Content)) -> Result(String, Error) {
  content
  |> list.try_fold("", fn(text, part) {
    case part {
      llm.Text(value) -> Ok(text <> value)
      llm.Reasoning(..) -> Ok(text)
      _ ->
        Error(InvalidModelOutput(
          "compaction output must contain only a handover summary",
        ))
    }
  })
}

fn parse_handover(output: String) -> Result(String, Error) {
  let open = "<handover>"
  let close = "</handover>"
  let output = string.trim(output)
  case string.starts_with(output, open), string.ends_with(output, close) {
    True, True -> {
      let body =
        output
        |> string.drop_start(string.length(open))
        |> string.drop_end(string.length(close))
        |> string.trim
      case
        body == ""
        || string.contains(body, open)
        || string.contains(body, close)
      {
        True -> Error(InvalidModelOutput("compaction handover is malformed"))
        False -> Ok(open <> "\n" <> body <> "\n" <> close)
      }
    }
    _, _ ->
      Error(InvalidModelOutput(
        "compaction output must be wrapped in <handover> tags",
      ))
  }
}

fn update_or_start_text(
  state: Accumulator,
  index: Int,
  text: String,
) -> Accumulator {
  let state = case dict.has_key(state.active_slots, index) {
    True -> state
    False -> start_part(state, index, TextPart(""))
  }
  update_part(state, index, fn(part) {
    case part {
      TextPart(current) -> TextPart(current <> text)
      _ -> part
    }
  })
}

fn start_part(
  state: Accumulator,
  external_index: Int,
  part: Part,
) -> Accumulator {
  case dict.get(state.active_slots, external_index) {
    Ok(slot) -> {
      let merged = case dict.get(state.parts, slot), part {
        Ok(ToolPart(id, name, arguments)), ToolPart(next_id, next_name, _) ->
          ToolPart(
            prefer_nonempty(id, next_id),
            prefer_nonempty(name, next_name),
            arguments,
          )
        Ok(existing), _ -> existing
        Error(_), replacement -> replacement
      }
      Accumulator(..state, parts: dict.insert(state.parts, slot, merged))
    }
    Error(_) -> {
      let slot = state.next_slot
      Accumulator(
        ..state,
        parts: dict.insert(state.parts, slot, part),
        active_slots: dict.insert(state.active_slots, external_index, slot),
        next_slot: slot + 1,
      )
    }
  }
}

fn prefer_nonempty(current: String, candidate: String) -> String {
  case current {
    "" -> candidate
    _ -> current
  }
}

fn update_part(
  state: Accumulator,
  index: Int,
  update: fn(Part) -> Part,
) -> Accumulator {
  case dict.get(state.active_slots, index) {
    Ok(slot) ->
      case dict.get(state.parts, slot) {
        Ok(part) ->
          Accumulator(
            ..state,
            parts: dict.insert(state.parts, slot, update(part)),
          )
        Error(_) -> state
      }
    Error(_) ->
      Accumulator(
        ..state,
        error: Some(InvalidModelOutput(
          "delta received before content start at index "
          <> int.to_string(index),
        )),
      )
  }
}

fn parts_to_content(
  parts: Dict(Int, Part),
) -> Result(List(llm.Content), Error) {
  parts
  |> dict.to_list
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.try_map(fn(entry) {
    case entry.1 {
      TextPart(text) -> Ok(llm.Text(text))
      ReasoningPart(summary, encrypted) ->
        Ok(llm.Reasoning([summary], encrypted))
      ToolPart(id, name, arguments) -> {
        // A tool call with no arguments: providers differ on whether they send
        // an empty-object delta at all (Anthropic's buffered path does, its
        // streaming path does not), so normalize rather than fail the round.
        let arguments = case string.trim(arguments) {
          "" -> "{}"
          arguments -> arguments
        }
        use _ <- result.try(
          json.parse(arguments, decode.dynamic)
          |> result.map_error(fn(error) {
            InvalidModelOutput(
              "invalid tool arguments: " <> string.inspect(error),
            )
          }),
        )
        Ok(llm.ToolCall(id, name, raw_json(arguments)))
      }
    }
  })
}

@external(erlang, "gleam_stdlib", "identity")
fn raw_json(value: String) -> Json

fn execute_tools(
  host: PluginHost,
  router: CallbackRouter,
  content: List(llm.Content),
  observe: fn(Event) -> Result(Nil, Error),
) -> Result(List(llm.Message), Error) {
  content
  |> list.filter_map(fn(part) {
    case part {
      llm.ToolCall(id, name, arguments) ->
        Ok(#(id, name, json.to_string(arguments)))
      _ -> Error(Nil)
    }
  })
  |> list.try_fold([], fn(messages, call) {
    let #(id, name, arguments) = call
    use _ <- result.try(observe(ToolStarted(id, name)))
    let PluginHost(subject) = host
    use output <- result.try(
      process.call_forever(subject, fn(reply) {
        InvokeTool(name, plugin.ToolInvocation(id, arguments), router, reply)
      }),
    )
    let plugin.ToolOutput(content, is_error) = output
    use _ <- result.try(observe(ToolFinished(id, name, is_error)))
    let message =
      llm.Message(llm.ToolRole, [llm.ToolResult(id, content, is_error)])
    Ok(list.append(messages, [message]))
  })
}

pub type CommitReceipt {
  CommitReceipt(state: State, group_revision: Int)
}

pub opaque type Checkpointer {
  Checkpointer(commit: fn(Int, State) -> Result(CommitReceipt, Error))
}

pub fn checkpointer(
  commit: fn(Int, State) -> Result(CommitReceipt, Error),
) -> Checkpointer {
  Checkpointer(commit)
}

pub opaque type Handle {
  Handle(
    pid: Pid,
    plugins: PluginHost,
    router: CallbackRouter,
    gate: Subject(Nil),
  )
}

pub fn start(
  active: Active,
  checkpointer: Checkpointer,
  router: CallbackRouter,
  observe: fn(Event) -> Result(Nil, Error),
  on_exit: fn() -> Nil,
) -> Handle {
  let ready = process.new_subject()
  let Active(plugins:, ..) = active
  let pid =
    process.spawn_unlinked(fn() {
      let plugin_pid = plugin_host_pid(plugins)
      let assert True = process.link(plugin_pid)
      let gate = process.new_subject()
      process.send(ready, gate)
      let assert Ok(Nil) = process.receive(gate, within: 60_000)
      run_loop(active, checkpointer, router, observe)
      stop_plugin_host(plugins)
      on_exit()
    })
  let assert Ok(gate) = process.receive(ready, within: 5000)
  process.unlink(plugin_host_pid(plugins))
  Handle(pid, plugins, router, gate)
}

pub fn release(handle: Handle) -> Nil {
  let Handle(gate:, ..) = handle
  process.send(gate, Nil)
}

fn run_loop(
  active: Active,
  checkpointer: Checkpointer,
  router: CallbackRouter,
  observe: fn(Event) -> Result(Nil, Error),
) -> Nil {
  let Active(state:, config:, plugins:) = active
  case compaction_target(state, config) {
    Some(target) ->
      case compact(active, target, observe) {
        Error(error) -> {
          let failed =
            State(
              ..state,
              compaction_requested: int.max(state.compaction_requested, target),
              last_compaction_error: Some(string.inspect(error)),
            )
          let Checkpointer(commit:) = checkpointer
          case commit(state.revision, failed) {
            // The commit atomically folded any messages that arrived during
            // the failed compaction into the conversation; exiting here would
            // strand them with no worker. Continue with normal rounds —
            // deliberately not `run_loop`, which would retry the failing
            // compaction immediately and block round execution.
            Ok(CommitReceipt(state: committed, ..))
              if committed.status == Ready
            ->
              run_normal_loop(
                Active(committed, config, plugins),
                checkpointer,
                router,
                observe,
              )
            _ -> Nil
          }
        }
        Ok(#(_, compacted)) -> {
          let Checkpointer(commit:) = checkpointer
          case commit(state.revision, compacted) {
            Error(_) -> Nil
            Ok(CommitReceipt(state: committed, ..)) ->
              run_loop(
                Active(committed, config, plugins),
                checkpointer,
                router,
                observe,
              )
          }
        }
      }
    None -> run_normal_loop(active, checkpointer, router, observe)
  }
}

fn run_normal_loop(
  active: Active,
  checkpointer: Checkpointer,
  router: CallbackRouter,
  observe: fn(Event) -> Result(Nil, Error),
) -> Nil {
  let Active(state:, config:, plugins:) = active
  case state.status {
    Waiting | Completed | Failed(_) -> Nil
    Ready ->
      case run_round(active, router, observe) {
        Error(error) -> {
          let failed = State(..state, status: Failed(string.inspect(error)))
          let Checkpointer(commit:) = checkpointer
          case commit(state.revision, failed) {
            Ok(CommitReceipt(state: committed, ..))
              if committed.status == Ready
            -> {
              run_loop(
                Active(committed, config, plugins),
                checkpointer,
                router,
                observe,
              )
            }
            _ -> Nil
          }
        }
        Ok(RoundResult(state: next_state, ..)) -> {
          let Checkpointer(commit:) = checkpointer
          case commit(state.revision, next_state) {
            Error(_) -> Nil
            Ok(CommitReceipt(state: committed, ..)) ->
              run_loop(
                Active(committed, config, plugins),
                checkpointer,
                router,
                observe,
              )
          }
        }
      }
  }
}

pub fn pid(handle: Handle) -> Pid {
  let Handle(pid:, ..) = handle
  pid
}

fn plugin_host_pid(host: PluginHost) -> Pid {
  let PluginHost(subject) = host
  let assert Ok(pid) = process.subject_owner(subject)
  pid
}

fn stop_plugin_host(host: PluginHost) -> Nil {
  let PluginHost(subject) = host
  let pid = plugin_host_pid(host)
  let monitor = process.monitor(pid)
  process.send(subject, StopPlugins)
  // Bounded: the coordinator calls this (via `discard`) inside its own message
  // handler, and a host busy in a long tool call would otherwise starve the
  // coordinator's lease renewal. Kill on timeout — the host's links then tear
  // down anything it still owns.
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(plugin_host_stop_milliseconds)
  case stopped {
    Ok(Nil) -> Nil
    Error(Nil) -> process.kill(pid)
  }
}

pub fn call_callback(
  handle: Handle,
  plugin_name: String,
  callback: String,
  input: String,
) -> Result(CallbackResult, Error) {
  let Handle(plugins: PluginHost(subject), router:, ..) = handle
  exception.rescue(fn() {
    process.call(subject, callback_timeout_milliseconds, fn(reply) {
      InvokeCallback(plugin_name, callback, input, router, reply)
    })
  })
  |> result.map_error(fn(_) {
    PluginError(plugin.HookFailed(
      plugin_name,
      callback,
      "cross-agent callback timed out",
    ))
  })
  |> result.flatten
}

pub fn stop(handle: Handle) -> Nil {
  let Handle(pid:, ..) = handle
  process.unlink(pid)
  process.kill(pid)
}

/// Stable JSON representation used by the agent-group snapshot.
pub fn encode_state(state: State) -> Json {
  json.object([
    #("id", json.string(state.id)),
    #("profile_id", json.string(state.profile_id)),
    #("revision", json.int(state.revision)),
    #("model_id", json.string(state.model_id)),
    #("round", json.int(state.round)),
    #("messages", json.array(state.messages, encode_message)),
    #(
      "context_messages",
      json.nullable(state.context_messages, fn(messages) {
        json.array(messages, encode_message)
      }),
    ),
    #("pending_messages", json.array(state.pending_messages, encode_message)),
    #("stats", encode_stats(state.stats)),
    #(
      "plugin_states",
      json.array(dict.to_list(state.plugin_states), fn(entry) {
        json.object([
          #("name", json.string(entry.0)),
          #("state", json.string(entry.1)),
        ])
      }),
    ),
    #("plugin_generation", json.int(state.plugin_generation)),
    #(
      "last_catalog_revision",
      json.nullable(state.last_catalog_revision, json.int),
    ),
    #("last_context_tokens", json.nullable(state.last_context_tokens, json.int)),
    #("compaction_requested", json.int(state.compaction_requested)),
    #("compaction_completed", json.int(state.compaction_completed)),
    #(
      "last_compaction_error",
      json.nullable(state.last_compaction_error, json.string),
    ),
    #("status", encode_status(state.status)),
  ])
}

pub fn state_decoder() -> decode.Decoder(State) {
  use id <- decode.field("id", decode.string)
  use profile_id <- decode.field("profile_id", decode.string)
  use revision <- decode.field("revision", decode.int)
  use model_id <- decode.field("model_id", decode.string)
  use round <- decode.field("round", decode.int)
  use messages <- decode.field("messages", decode.list(of: message_decoder()))
  use context_messages <- decode.optional_field(
    "context_messages",
    None,
    decode.optional(decode.list(of: message_decoder())),
  )
  use pending_messages <- decode.field(
    "pending_messages",
    decode.list(of: message_decoder()),
  )
  use stats <- decode.field("stats", stats_decoder())
  use plugin_states <- decode.field(
    "plugin_states",
    decode.list(of: {
      use name <- decode.field("name", decode.string)
      use state <- decode.field("state", decode.string)
      decode.success(#(name, state))
    }),
  )
  use plugin_generation <- decode.optional_field(
    "plugin_generation",
    0,
    decode.int,
  )
  use last_catalog_revision <- decode.optional_field(
    "last_catalog_revision",
    None,
    decode.optional(decode.int),
  )
  use last_context_tokens <- decode.optional_field(
    "last_context_tokens",
    None,
    decode.optional(decode.int),
  )
  use compaction_requested <- decode.optional_field(
    "compaction_requested",
    0,
    decode.int,
  )
  use compaction_completed <- decode.optional_field(
    "compaction_completed",
    0,
    decode.int,
  )
  use last_compaction_error <- decode.optional_field(
    "last_compaction_error",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.field("status", status_decoder())
  decode.success(State(
    id,
    profile_id,
    revision,
    model_id,
    round,
    messages,
    context_messages,
    pending_messages,
    stats,
    dict.from_list(plugin_states),
    plugin_generation,
    last_catalog_revision,
    last_context_tokens,
    compaction_requested,
    compaction_completed,
    last_compaction_error,
    status,
  ))
}

fn encode_stats(stats: llm.Stats) -> Json {
  let llm.Stats(
    input_tokens:,
    output_tokens:,
    cache_read_tokens:,
    cache_write_tokens:,
  ) = stats
  json.object([
    #("input_tokens", json.int(input_tokens)),
    #("output_tokens", json.int(output_tokens)),
    #("cache_read_tokens", json.int(cache_read_tokens)),
    #("cache_write_tokens", json.int(cache_write_tokens)),
  ])
}

fn stats_decoder() -> decode.Decoder(llm.Stats) {
  use input <- decode.field("input_tokens", decode.int)
  use output <- decode.field("output_tokens", decode.int)
  use cache_read <- decode.field("cache_read_tokens", decode.int)
  use cache_write <- decode.field("cache_write_tokens", decode.int)
  decode.success(llm.Stats(input, output, cache_read, cache_write))
}

fn encode_status(status: Status) -> Json {
  case status {
    Ready -> json.object([#("type", json.string("ready"))])
    Waiting -> json.object([#("type", json.string("waiting"))])
    Completed -> json.object([#("type", json.string("completed"))])
    Failed(reason) ->
      json.object([
        #("type", json.string("failed")),
        #("reason", json.string(reason)),
      ])
  }
}

fn status_decoder() -> decode.Decoder(Status) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "ready" -> decode.success(Ready)
    "waiting" -> decode.success(Waiting)
    "completed" -> decode.success(Completed)
    "failed" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Failed(reason))
    }
    _ -> decode.failure(Ready, "unknown agent status")
  }
}

fn encode_message(message: llm.Message) -> Json {
  let llm.Message(role:, content:) = message
  json.object([
    #("role", json.string(role_name(role))),
    #("content", json.array(content, encode_content)),
  ])
}

fn message_decoder() -> decode.Decoder(llm.Message) {
  use role <- decode.field("role", role_decoder())
  use content <- decode.field("content", decode.list(of: content_decoder()))
  decode.success(llm.Message(role, content))
}

fn role_name(role: llm.Role) -> String {
  case role {
    llm.System -> "system"
    llm.Developer -> "developer"
    llm.User -> "user"
    llm.Assistant -> "assistant"
    llm.ToolRole -> "tool"
  }
}

fn role_decoder() -> decode.Decoder(llm.Role) {
  decode.string
  |> decode.then(fn(value) {
    case value {
      "system" -> decode.success(llm.System)
      "developer" -> decode.success(llm.Developer)
      "user" -> decode.success(llm.User)
      "assistant" -> decode.success(llm.Assistant)
      "tool" -> decode.success(llm.ToolRole)
      _ -> decode.failure(llm.User, "unknown message role")
    }
  })
}

fn encode_content(content: llm.Content) -> Json {
  case content {
    llm.Text(text) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    llm.Image(source, detail) ->
      json.object([
        #("type", json.string("image")),
        #("source", encode_media_source(source)),
        #("detail", json.string(detail_name(detail))),
      ])
    llm.Document(source) ->
      json.object([
        #("type", json.string("document")),
        #("source", encode_media_source(source)),
      ])
    llm.Reasoning(summary, encrypted) ->
      json.object([
        #("type", json.string("reasoning")),
        #("summary", json.array(summary, json.string)),
        #("encrypted", json.nullable(encrypted, encode_encrypted_reasoning)),
      ])
    llm.ToolCall(id, name, arguments) ->
      json.object([
        #("type", json.string("tool_call")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("arguments", json.string(json.to_string(arguments))),
      ])
    llm.ToolResult(id, content, is_error) ->
      json.object([
        #("type", json.string("tool_result")),
        #("id", json.string(id)),
        #("content", json.array(content, encode_content)),
        #("is_error", json.bool(is_error)),
      ])
  }
}

fn content_decoder() -> decode.Decoder(llm.Content) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(llm.Text(text))
    }
    "image" -> {
      use source <- decode.field("source", media_source_decoder())
      use detail <- decode.field("detail", detail_decoder())
      decode.success(llm.Image(source, detail))
    }
    "document" -> {
      use source <- decode.field("source", media_source_decoder())
      decode.success(llm.Document(source))
    }
    "reasoning" -> {
      use summary <- decode.field("summary", decode.list(of: decode.string))
      use encrypted <- decode.optional_field(
        "encrypted",
        None,
        decode.optional(encrypted_reasoning_decoder()),
      )
      decode.success(llm.Reasoning(summary, encrypted))
    }
    "tool_call" -> {
      use id <- decode.field("id", decode.string)
      use name <- decode.field("name", decode.string)
      use arguments <- decode.field("arguments", json_document_decoder())
      decode.success(llm.ToolCall(id, name, arguments))
    }
    "tool_result" -> {
      use id <- decode.field("id", decode.string)
      use content <- decode.field("content", decode.list(of: content_decoder()))
      use is_error <- decode.field("is_error", decode.bool)
      decode.success(llm.ToolResult(id, content, is_error))
    }
    _ -> decode.failure(llm.Text(""), "unknown content type")
  }
}

fn json_document_decoder() -> decode.Decoder(Json) {
  decode.string
  |> decode.then(fn(value) {
    case json.parse(value, decode.dynamic) {
      Ok(_) -> decode.success(raw_json(value))
      Error(_) -> decode.failure(json.null(), "invalid JSON document")
    }
  })
}

fn encode_media_source(source: llm.MediaSource) -> Json {
  case source {
    llm.Url(url) ->
      json.object([
        #("type", json.string("url")),
        #("value", json.string(url)),
      ])
    llm.Base64(media_type, data) ->
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(media_type)),
        #("value", json.string(data)),
      ])
    llm.FileId(id) ->
      json.object([
        #("type", json.string("file_id")),
        #("value", json.string(id)),
      ])
  }
}

fn media_source_decoder() -> decode.Decoder(llm.MediaSource) {
  use kind <- decode.field("type", decode.string)
  use value <- decode.field("value", decode.string)
  case kind {
    "url" -> decode.success(llm.Url(value))
    "base64" -> {
      use media_type <- decode.field("media_type", decode.string)
      decode.success(llm.Base64(media_type, value))
    }
    "file_id" -> decode.success(llm.FileId(value))
    _ -> decode.failure(llm.Url(""), "unknown media source")
  }
}

fn detail_name(detail: llm.ImageDetail) -> String {
  case detail {
    llm.Auto -> "auto"
    llm.Low -> "low"
    llm.High -> "high"
  }
}

fn detail_decoder() -> decode.Decoder(llm.ImageDetail) {
  decode.string
  |> decode.then(fn(value) {
    case value {
      "auto" -> decode.success(llm.Auto)
      "low" -> decode.success(llm.Low)
      "high" -> decode.success(llm.High)
      _ -> decode.failure(llm.Auto, "unknown image detail")
    }
  })
}

fn encode_encrypted_reasoning(reasoning: llm.EncryptedReasoning) -> Json {
  case reasoning {
    llm.OpenAIEncryptedReasoning(id, content) ->
      json.object([
        #("type", json.string("openai")),
        #("id", json.string(id)),
        #("content", json.string(content)),
      ])
    llm.AnthropicSignedReasoning(signature) ->
      json.object([
        #("type", json.string("anthropic_signed")),
        #("content", json.string(signature)),
      ])
    llm.AnthropicRedactedReasoning(data) ->
      json.object([
        #("type", json.string("anthropic_redacted")),
        #("content", json.string(data)),
      ])
  }
}

fn encrypted_reasoning_decoder() -> decode.Decoder(llm.EncryptedReasoning) {
  use kind <- decode.field("type", decode.string)
  use content <- decode.field("content", decode.string)
  case kind {
    "openai" -> {
      use id <- decode.field("id", decode.string)
      decode.success(llm.OpenAIEncryptedReasoning(id, content))
    }
    "anthropic_signed" -> decode.success(llm.AnthropicSignedReasoning(content))
    "anthropic_redacted" ->
      decode.success(llm.AnthropicRedactedReasoning(content))
    _ ->
      decode.failure(
        llm.AnthropicRedactedReasoning(""),
        "unknown encrypted reasoning",
      )
  }
}
