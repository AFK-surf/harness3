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
    messages: List(llm.Message),
    pending_messages: List(llm.Message),
    stats: llm.Stats,
    plugin_states: Dict(String, String),
    plugin_generation: Int,
    last_catalog_revision: Option(Int),
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
    pending_messages: [],
    stats: llm.empty_stats(),
    plugin_states: plugin.empty_states(),
    plugin_generation: 0,
    last_catalog_revision: None,
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
    StopPlugins -> actor.stop()
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
  use accumulator <- result.try(start_accumulator(state.stats))
  let system_prompt = plugin_prompt(plugins)
  let messages = case system_prompt {
    "" -> state.messages
    prompt -> [llm.Message(llm.System, [llm.Text(prompt)]), ..state.messages]
  }
  let request =
    llm.Request(
      model: config.model_name,
      messages:,
      tools: plugin_tools(plugins),
      max_output_tokens: config.max_output_tokens,
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
  use assistant_content <- result.try(parts_to_content(accumulated.parts))
  let assistant = llm.Message(llm.Assistant, assistant_content)
  use tool_messages <- result.try(execute_tools(
    plugins,
    router,
    assistant_content,
    observe,
  ))
  let messages = list.append(state.messages, [assistant, ..tool_messages])
  let disposition = case tool_messages {
    [] -> Complete
    _ -> Continue
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
      stats: accumulated.stats,
      plugin_states: states,
      plugin_generation: generation,
      last_catalog_revision: Some(config.catalog_revision),
      status:,
    )
  let active = Active(state, config, plugins)
  Ok(RoundResult(active, state, disposition))
}

fn start_accumulator(
  initial_stats: llm.Stats,
) -> Result(Subject(AccumulatorMessage), Error) {
  actor.new(Accumulator(dict.new(), dict.new(), 0, initial_stats, None))
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
    llm.UsageReported(usage) ->
      Accumulator(..state, stats: llm.apply_usage(state.stats, usage))
    llm.ContentStop(index) ->
      Accumulator(..state, active_slots: dict.delete(state.active_slots, index))
    _ -> state
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
  let slot = state.next_slot
  Accumulator(
    ..state,
    parts: dict.insert(state.parts, slot, part),
    active_slots: dict.insert(state.active_slots, external_index, slot),
    next_slot: slot + 1,
  )
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
  let Active(state:, ..) = active
  case run_round(active, router, observe) {
    Error(error) -> {
      let failed = State(..state, status: Failed(string.inspect(error)))
      let Checkpointer(commit:) = checkpointer
      case commit(state.revision, failed) {
        Ok(CommitReceipt(state: committed, ..)) if committed.status == Ready -> {
          let Active(config:, plugins:, ..) = active
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
    Ok(RoundResult(active:, state: next_state, disposition:)) -> {
      let Checkpointer(commit:) = checkpointer
      case commit(state.revision, next_state) {
        Error(_) -> Nil
        Ok(CommitReceipt(state: committed, ..)) -> {
          let Active(config:, plugins:, ..) = active
          let active = Active(committed, config, plugins)
          case disposition, committed.status {
            _, Ready -> run_loop(active, checkpointer, router, observe)
            Continue, _ -> run_loop(active, checkpointer, router, observe)
            Complete, _ -> Nil
          }
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
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}

pub fn call_callback(
  handle: Handle,
  plugin_name: String,
  callback: String,
  input: String,
) -> Result(CallbackResult, Error) {
  let Handle(plugins: PluginHost(subject), router:, ..) = handle
  process.call_forever(subject, fn(reply) {
    InvokeCallback(plugin_name, callback, input, router, reply)
  })
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
  use status <- decode.field("status", status_decoder())
  decode.success(State(
    id,
    profile_id,
    revision,
    model_id,
    round,
    messages,
    pending_messages,
    stats,
    dict.from_list(plugin_states),
    plugin_generation,
    last_catalog_revision,
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
