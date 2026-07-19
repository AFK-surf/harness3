import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/agent
import harness3/agent_group
import harness3/agent_group_registry
import harness3/agent_profile
import harness3/llm
import harness3/model_catalog
import harness3/plugin
import harness3/storage
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

type GateMessage {
  Started(release: Subject(Nil))
}

type AmbiguityMessage {
  Ambiguate(
    body: BitArray,
    condition: storage.PutCondition,
    reply: Subject(Bool),
  )
}

type CallbackGateState {
  CallbackGateState(signaled: Bool, waiters: List(Subject(Nil)))
}

type CallbackGateMessage {
  WaitForCallback(reply: Subject(Nil))
  CallbackRan
}

fn handle_callback_gate(
  state: CallbackGateState,
  message: CallbackGateMessage,
) -> actor.Next(CallbackGateState, CallbackGateMessage) {
  case message {
    CallbackRan -> {
      list.each(state.waiters, fn(reply) { process.send(reply, Nil) })
      actor.continue(CallbackGateState(True, []))
    }
    WaitForCallback(reply) ->
      case state.signaled {
        True -> {
          process.send(reply, Nil)
          actor.continue(state)
        }
        False ->
          actor.continue(
            CallbackGateState(..state, waiters: [reply, ..state.waiters]),
          )
      }
  }
}

fn handle_ambiguity(
  triggered: Bool,
  message: AmbiguityMessage,
) -> actor.Next(Bool, AmbiguityMessage) {
  let Ambiguate(body, condition, reply) = message
  let body = bit_array.to_string(body) |> result.unwrap("")
  let should_ambiguate = case condition {
    storage.IfUnchanged(_) -> !triggered && string.contains(body, "\"round\":1")
    _ -> False
  }
  process.send(reply, should_ambiguate)
  actor.continue(triggered || should_ambiguate)
}

fn ambiguous_commit_storage(backend: storage.Storage) -> storage.Storage {
  let assert Ok(started) =
    actor.new(False)
    |> actor.on_message(handle_ambiguity)
    |> actor.start
  let control = started.data
  storage.from_functions(
    get: fn(key) { storage.get(backend, key) },
    head: fn(key) { storage.head(backend, key) },
    put: fn(key, body, condition) {
      let ambiguous =
        process.call_forever(control, fn(reply) {
          Ambiguate(body, condition, reply)
        })
      case storage.put(backend, key, body, condition), ambiguous {
        Ok(_), True -> Error(storage.PreconditionFailed(key))
        result, _ -> result
      }
    },
    list: fn(prefix) { storage.list(backend, prefix) },
    delete: fn(key) { storage.delete(backend, key) },
    stream_get: fn(key, consume) { storage.get_stream(backend, key, consume) },
    stream_put: fn(key, source, condition) {
      storage.put_stream(backend, key, source, condition)
    },
  )
}

fn ambiguous_index_storage(backend: storage.Storage) -> storage.Storage {
  storage.from_functions(
    get: fn(key) { storage.get(backend, key) },
    head: fn(key) { storage.head(backend, key) },
    put: fn(key, body, condition) {
      case storage.put(backend, key, body, condition), condition {
        Ok(metadata), storage.IfAbsent ->
          case string.starts_with(key, agent_group.running_index_prefix()) {
            True -> Error(storage.PreconditionFailed(key))
            False -> Ok(metadata)
          }
        outcome, _ -> outcome
      }
    },
    list: fn(prefix) { storage.list(backend, prefix) },
    delete: fn(key) { storage.delete(backend, key) },
    stream_get: fn(key, consume) { storage.get_stream(backend, key, consume) },
    stream_put: fn(key, source, condition) {
      storage.put_stream(backend, key, source, condition)
    },
  )
}

fn temporary_root(label: String) -> String {
  let suffix =
    crypto.strong_random_bytes(12) |> bit_array.base64_url_encode(False)
  "/tmp/harness3-" <> label <> "-" <> suffix
}

fn gated_transport(
  gate: Subject(GateMessage),
  text: String,
) -> agent.ModelTransport {
  agent.model_transport(fn(_, _, consume) {
    let release = process.new_subject()
    process.send(gate, Started(release))
    let assert Ok(Nil) = process.receive(release, within: 5000)
    let assert Ok(Nil) = consume(llm.MessageStart("message", "test-model"))
    let assert Ok(Nil) = consume(llm.TextDelta(0, text))
    let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
    let assert Ok(Nil) = consume(llm.MessageStop)
    Ok(Nil)
  })
}

fn crashing_gated_transport(
  gate: Subject(GateMessage),
) -> agent.ModelTransport {
  agent.model_transport(fn(_, _, _) {
    let release = process.new_subject()
    process.send(gate, Started(release))
    let assert Ok(Nil) = process.receive(release, within: 5000)
    panic as "intentional agent crash"
  })
}

fn observe(_event: agent.Event) -> Result(Nil, agent.Error) {
  Ok(Nil)
}

fn await_down(monitor: Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(15_000)
  Nil
}

pub fn parallel_agents_commit_through_group_test() {
  let root = temporary_root("agent-group-test")
  let storage = local.new(local.config(root))
  let model =
    model_catalog.Model(
      id: "model",
      name: "test-model",
      endpoint: "https://example.test",
      model_type: model_catalog.OpenAIResponses,
      credentials: model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(storage, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profiles = [
    agent_profile.AgentProfile(
      id: "a",
      registry:,
      transport: gated_transport(gate, "A finished"),
      max_output_tokens: None,
      reasoning_effort: None,
      observe:,
    ),
    agent_profile.AgentProfile(
      id: "b",
      registry:,
      transport: gated_transport(gate, "B finished"),
      max_output_tokens: None,
      reasoning_effort: None,
      observe:,
    ),
  ]
  let config =
    agent_group.Config(
      storage:,
      object_key: "groups/group",
      profiles:,
      lease_duration_seconds: 10,
      minimum_lifetime_milliseconds: 100,
    )
  let initial =
    agent_group.new("group", "catalog", [
      agent.state("a", "model"),
      agent.state("b", "model"),
    ])
  let assert Ok(loaded) = agent_group.create(config, initial)
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let agent_monitors =
    agent_group.agent_pids(group)
    |> list.map(fn(entry) { process.monitor(entry.1) })

  // Both workers must reach the transport before either is released.
  let assert Ok(Started(release_a)) = process.receive(gate, within: 5000)
  let assert Ok(Started(release_b)) = process.receive(gate, within: 5000)
  process.send(release_a, Nil)
  process.send(release_b, Nil)

  list.each(agent_monitors, await_down)
  await_down(group_monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  assert snapshot.revision >= 3
  assert list.all(snapshot.agents, fn(state) {
    state.status == agent.Completed && state.revision == 1
  })
  let assert agent_group.Completed = snapshot.execution

  remove_directory(root)
}

pub fn linked_agent_crash_terminates_process_tree_test() {
  let root = temporary_root("agent-group-crash-test")
  let storage = local.new(local.config(root))
  let model =
    model_catalog.Model(
      id: "model",
      name: "test-model",
      endpoint: "https://example.test",
      model_type: model_catalog.OpenAIResponses,
      credentials: model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(storage, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let crashing_gate = process.new_subject()
  let sibling_gate = process.new_subject()
  let config =
    agent_group.Config(
      storage:,
      object_key: "groups/crash",
      profiles: [
        agent_profile.AgentProfile(
          id: "crashing",
          registry:,
          transport: crashing_gated_transport(crashing_gate),
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
        agent_profile.AgentProfile(
          id: "sibling",
          registry:,
          transport: gated_transport(sibling_gate, "never completed"),
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
      minimum_lifetime_milliseconds: 100,
    )
  let initial =
    agent_group.new("crash", "catalog", [
      agent.state("crashing", "model"),
      agent.state("sibling", "model"),
    ])
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let started_group = case agent_group.create(config, initial) {
        Ok(loaded) -> agent_group.wake(loaded)
        Error(error) -> Error(error)
      }
      process.send(started, started_group)
      process.sleep_forever()
    })
  let assert Ok(Ok(group)) = process.receive(started, within: 5000)
  let agent_pids = agent_group.agent_pids(group)
  assert list.length(agent_pids) == 2
  let group_monitor = process.monitor(agent_group.pid(group))
  let owner_monitor = process.monitor(owner)
  let agent_monitors =
    list.map(agent_pids, fn(entry) { process.monitor(entry.1) })

  let assert Ok(Started(crash)) = process.receive(crashing_gate, within: 5000)
  let assert Ok(Started(_sibling)) = process.receive(sibling_gate, within: 5000)
  process.send(crash, Nil)

  list.each(agent_monitors, await_down)
  await_down(group_monitor)
  await_down(owner_monitor)

  remove_directory(root)
}

pub fn encrypted_reasoning_state_round_trip_test() {
  let original =
    agent.State(
      id: "agent",
      profile_id: "agent",
      revision: 2,
      model_id: "model",
      round: 3,
      messages: [
        llm.Message(llm.Assistant, [
          llm.Reasoning(
            ["summary"],
            Some(llm.OpenAIEncryptedReasoning("rs_1", "ciphertext")),
          ),
          llm.Text("answer"),
        ]),
      ],
      pending_messages: [],
      stats: llm.Stats(10, 5, 2, 1),
      plugin_states: dict.from_list([#("plugin", "{\"count\":1}")]),
      plugin_generation: 3,
      last_catalog_revision: Some(4),
      status: agent.Ready,
    )
  let encoded = agent.encode_state(original) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, agent.state_decoder())
  assert decoded.id == "agent"
  assert decoded.revision == 2
  assert decoded.stats == llm.Stats(10, 5, 2, 1)
  let assert [
    llm.Message(
      llm.Assistant,
      [
        llm.Reasoning(
          ["summary"],
          Some(llm.OpenAIEncryptedReasoning("rs_1", "ciphertext")),
        ),
        llm.Text("answer"),
      ],
    ),
  ] = decoded.messages
  assert dict.get(decoded.plugin_states, "plugin") == Ok("{\"count\":1}")
}

pub fn full_agent_loop_with_mocked_llm_test() {
  let root = temporary_root("full-agent-loop-test")
  let storage = local.new(local.config(root))
  let model =
    model_catalog.Model(
      id: "model",
      name: "test-model",
      endpoint: "https://example.test",
      model_type: model_catalog.OpenAIResponses,
      credentials: model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(storage, "catalog", catalog)

  let tool =
    plugin.tool(
      llm.Tool(
        "record_call",
        None,
        json.object([#("type", json.string("object"))]),
      ),
      fn(state, context, invocation) {
        assert state == "{\"calls\":0}"
        assert invocation.id == "call_1"
        assert invocation.arguments == "{}"
        Ok(plugin.hook_result(
          "{\"calls\":1}",
          context,
          plugin.ToolOutput([llm.Text("tool completed")], False),
        ))
      },
    )
  let stateful_plugin =
    plugin.new("stateful", "{\"calls\":0}")
    |> plugin.with_system_prompt(plugin.SystemPromptSection(
      "Stateful tool",
      "Call record_call once.",
    ))
    |> plugin.with_tool(tool)
  let assert Ok(registry) = plugin.registry([stateful_plugin])

  let transport =
    agent.model_transport(fn(_, request, consume) {
      let llm.Request(messages:, tools:, ..) = request
      assert list.length(tools) == 1
      let assert [llm.Message(llm.System, [llm.Text(system_prompt)]), ..] =
        messages
      assert system_prompt == "## Stateful tool\n\nCall record_call once."
      case contains_tool_result(messages) {
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
          let assert Ok(Nil) =
            consume(llm.ToolCallStart(0, "call_1", "record_call"))
          let assert Ok(Nil) = consume(llm.ToolCallArgumentsDelta(0, "{}"))
          let assert Ok(Nil) = consume(llm.ContentStop(0))
          let assert Ok(Nil) = consume(llm.Finished(llm.ToolUse))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Nil
        }
        True -> {
          let assert Ok(Nil) = consume(llm.MessageStart("second", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "final answer"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Nil
        }
      }
      Ok(Nil)
    })
  let config =
    agent_group.Config(
      storage:,
      object_key: "groups/full-loop",
      profiles: [
        agent_profile.AgentProfile(
          id: "agent",
          registry:,
          transport:,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
      minimum_lifetime_milliseconds: 100,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("full-loop", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  await_down(group_monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.round == 2
  assert completed.revision == 2
  assert dict.get(completed.plugin_states, "stateful") == Ok("{\"calls\":1}")
  assert contains_tool_result(completed.messages)
  let assert Ok(llm.Message(llm.Assistant, [llm.Text("final answer")])) =
    list.last(completed.messages)

  // The completed state is read from the single persisted group object.
  let assert Ok(resumed_snapshot) = agent_group.load(config)
  let assert [resumed_agent] = resumed_snapshot.agents
  assert resumed_agent.round == 2
  assert resumed_agent.revision == 2
  assert dict.get(resumed_agent.plugin_states, "stateful")
    == Ok("{\"calls\":1}")

  remove_directory(root)
}

fn contains_tool_result(messages: List(llm.Message)) -> Bool {
  list.any(messages, fn(message) {
    let llm.Message(content:, ..) = message
    list.any(content, fn(part) {
      case part {
        llm.ToolResult(..) -> True
        _ -> False
      }
    })
  })
}

fn contains_user_text(messages: List(llm.Message), expected: String) -> Bool {
  list.any(messages, fn(message) {
    case message {
      llm.Message(llm.User, content) ->
        list.any(content, fn(part) {
          case part {
            llm.Text(text) -> text == expected
            _ -> False
          }
        })
      _ -> False
    }
  })
}

pub fn message_sent_to_active_agent_is_injected_after_current_call_test() {
  let root = temporary_root("active-agent-message-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let first_call = process.new_subject()
  let second_call = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let _ = case contains_user_text(request.messages, "during-call") {
        False -> {
          let release = process.new_subject()
          process.send(first_call, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "first answer"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
        True -> {
          process.send(second_call, Nil)
          let assert Ok(Nil) = consume(llm.MessageStart("second", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "second answer"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
      }
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/active-message", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("active-message", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(release)) = process.receive(first_call, within: 5000)

  let assert Ok(Nil) = agent_group.send_message(group, "agent", "during-call")
  let assert Ok(queued) = agent_group.load(config)
  let assert [queued_agent] = queued.agents
  assert contains_user_text(queued_agent.pending_messages, "during-call")
  assert !contains_user_text(queued_agent.messages, "during-call")

  process.send(release, Nil)
  let assert Ok(Nil) = process.receive(second_call, within: 5000)
  await_down(group_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
  assert list.is_empty(completed_agent.pending_messages)
  assert contains_user_text(completed_agent.messages, "during-call")
  assert completed_agent.round == 2
  assert completed_agent.status == agent.Completed
  remove_directory(root)
}

pub fn message_sent_to_inactive_agent_persists_and_starts_it_test() {
  let root = temporary_root("inactive-agent-message-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "message handled"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/inactive-message", [profile], 10, 100)
  let inactive =
    agent.State(..agent.state("agent", "model"), status: agent.Completed)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("inactive-message", "catalog", [inactive]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  assert list.is_empty(agent_group.agent_pids(group))

  let assert Ok(Nil) = agent_group.send_message(group, "agent", "wake up")
  let assert Ok(Started(release)) = process.receive(gate, within: 5000)
  let assert Ok(injected) = agent_group.load(config)
  let assert [injected_agent] = injected.agents
  assert list.is_empty(injected_agent.pending_messages)
  assert contains_user_text(injected_agent.messages, "wake up")

  process.send(release, Nil)
  await_down(group_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
  assert list.is_empty(completed_agent.pending_messages)
  assert contains_user_text(completed_agent.messages, "wake up")
  assert completed_agent.round == 1
  assert completed_agent.status == agent.Completed
  remove_directory(root)
}

pub fn plugin_callback_between_agents_test() {
  let root = temporary_root("cross-agent-callback-test")
  let storage = local.new(local.config(root))
  let model =
    model_catalog.Model(
      id: "model",
      name: "test-model",
      endpoint: "https://example.test",
      model_type: model_catalog.OpenAIResponses,
      credentials: model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(storage, "catalog", catalog)

  let assert Ok(callback_gate) =
    actor.new(CallbackGateState(False, []))
    |> actor.on_message(handle_callback_gate)
    |> actor.start

  let receiver_plugin =
    plugin.new("receiver_plugin", "{\"calls\":0}")
    |> plugin.with_callback(
      plugin.callback_hook("ping", fn(state, context, input) {
        assert state == "{\"calls\":0}"
        assert input == "{}"
        process.send(callback_gate.data, CallbackRan)
        Ok(plugin.hook_result("{\"calls\":1}", context, "{\"reply\":\"pong\"}"))
      }),
    )
  let assert Ok(receiver_registry) = plugin.registry([receiver_plugin])

  let caller_plugin =
    plugin.new("caller_plugin", "{\"remote_calls\":0}")
    |> plugin.with_tool(
      plugin.tool(
        llm.Tool(
          "call_receiver",
          None,
          json.object([#("type", json.string("object"))]),
        ),
        fn(_, context, _) {
          let assert Ok(#(context, "{\"reply\":\"pong\"}")) =
            plugin.call_agent_callback(
              context,
              "receiver",
              "receiver_plugin",
              "ping",
              "{}",
            )
          Ok(plugin.hook_result(
            "{\"remote_calls\":1}",
            context,
            plugin.ToolOutput([llm.Text("pong received")], False),
          ))
        },
      ),
    )
  let assert Ok(caller_registry) = plugin.registry([caller_plugin])

  let caller_transport =
    agent.model_transport(fn(_, request, consume) {
      let llm.Request(messages:, ..) = request
      case contains_tool_result(messages) {
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("call", "test-model"))
          let assert Ok(Nil) =
            consume(llm.ToolCallStart(0, "remote_1", "call_receiver"))
          let assert Ok(Nil) = consume(llm.ToolCallArgumentsDelta(0, "{}"))
          let assert Ok(Nil) = consume(llm.ContentStop(0))
          let assert Ok(Nil) = consume(llm.Finished(llm.ToolUse))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Nil
        }
        True -> {
          let assert Ok(Nil) = consume(llm.MessageStart("done", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "all done"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Nil
        }
      }
      Ok(Nil)
    })
  let receiver_transport =
    agent.model_transport(fn(_, _, consume) {
      process.call_forever(callback_gate.data, WaitForCallback)
      let assert Ok(Nil) = consume(llm.MessageStart("receiver", "test-model"))
      let assert Ok(Nil) = consume(llm.TextDelta(0, "receiver ready"))
      let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
      let assert Ok(Nil) = consume(llm.MessageStop)
      Ok(Nil)
    })
  let config =
    agent_group.Config(
      storage:,
      object_key: "groups/cross-agent",
      profiles: [
        agent_profile.AgentProfile(
          id: "caller",
          registry: caller_registry,
          transport: caller_transport,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
        agent_profile.AgentProfile(
          id: "receiver",
          registry: receiver_registry,
          transport: receiver_transport,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
      minimum_lifetime_milliseconds: 100,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("cross-agent", "catalog", [
        agent.state("caller", "model"),
        agent.state("receiver", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  await_down(group_monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert Ok(caller) =
    list.find(snapshot.agents, fn(state) { state.id == "caller" })
  let assert Ok(receiver) =
    list.find(snapshot.agents, fn(state) { state.id == "receiver" })
  assert caller.round == 2
  assert caller.revision == 2
  assert dict.get(caller.plugin_states, "caller_plugin")
    == Ok("{\"remote_calls\":1}")
  assert caller.plugin_generation == 1
  assert receiver.round == 1
  assert receiver.revision == 1
  assert dict.get(receiver.plugin_states, "receiver_plugin")
    == Ok("{\"calls\":1}")
  assert receiver.plugin_generation == 1
  assert snapshot.revision >= 5

  remove_directory(root)
}

pub fn create_is_dormant_and_wake_registers_and_indexes_until_stop_test() {
  let root = temporary_root("agent-group-lifecycle-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "shared-profile",
      registry,
      gated_transport(gate, "done"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/lifecycle", [profile], 10, 100)
  let state =
    agent.State(
      ..agent.state("agent-instance", "model"),
      profile_id: "shared-profile",
    )
  let assert Ok(loaded) =
    agent_group.create(config, agent_group.new("lifecycle", "catalog", [state]))
  assert agent_group.loaded_state(loaded).execution == agent_group.Idle
  assert !list.contains(agent_group_registry.alive_ids(), "lifecycle")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.is_empty(index)

  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(_)) = process.receive(gate, within: 2000)
  assert list.contains(agent_group_registry.alive_ids(), "lifecycle")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1
  assert agent_group.stop(group) == Ok(Nil)
  await_down(group_monitor)

  assert !list.contains(agent_group_registry.alive_ids(), "lifecycle")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.is_empty(index)
  let assert Ok(snapshot) = agent_group.load(config)
  assert snapshot.execution == agent_group.Idle
  let assert [preserved] = snapshot.agents
  assert preserved.profile_id == "shared-profile"
  assert preserved.round == 0
  remove_directory(root)
}

pub fn wake_loads_the_model_catalog_on_demand_test() {
  let root = temporary_root("agent-group-catalog-test")
  let backend = local.new(local.config(root))
  let old_model =
    model_catalog.Model(
      "model",
      "old-name",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), old_model)
  let assert Ok(catalog_session) =
    model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport =
    agent.model_transport(fn(_, request, consume) {
      assert request.model == "new-name"
      let assert Ok(Nil) = consume(llm.MessageStart("message", "new-name"))
      let assert Ok(Nil) = consume(llm.TextDelta(0, "done"))
      let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
      let assert Ok(Nil) = consume(llm.MessageStop)
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let config = agent_group.Config(backend, "groups/catalog", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("catalog-group", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let new_model = model_catalog.Model(..old_model, name: "new-name")
  let assert Ok(updated_catalog) = model_catalog.put_model(catalog, new_model)
  let assert Ok(_) = model_catalog.commit(catalog_session, updated_catalog)

  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.last_catalog_revision == Some(1)
  remove_directory(root)
}

pub fn concurrent_storage_update_terminates_and_unregisters_coordinator_test() {
  let root = temporary_root("agent-group-fencing-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let config =
    agent_group.Config(
      backend,
      "groups/fenced",
      [
        agent_profile.AgentProfile(
          "agent",
          registry,
          gated_transport(gate, "will conflict"),
          None,
          None,
          observe,
        ),
      ],
      10,
      100,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("fenced", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(release)) = process.receive(gate, within: 2000)
  let assert Ok(claimed) = storage.get(backend, "groups/fenced")
  let assert Ok(claimed_body) = bit_array.to_string(claimed.body)
  let assert Ok(_) =
    storage.put(
      backend,
      "groups/fenced",
      bit_array.from_string(claimed_body <> " "),
      storage.IfUnchanged(claimed.metadata.version),
    )
  process.send(release, Nil)
  await_down(group_monitor)

  assert !list.contains(agent_group_registry.alive_ids(), "fenced")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1
  remove_directory(root)
}

pub fn expired_lease_terminates_and_unregisters_coordinator_test() {
  let root = temporary_root("agent-group-expired-lease-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let config =
    agent_group.Config(
      backend,
      "groups/expired",
      [
        agent_profile.AgentProfile(
          "agent",
          registry,
          gated_transport(gate, "never committed"),
          None,
          None,
          observe,
        ),
      ],
      1,
      100,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("expired", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(_)) = process.receive(gate, within: 2000)
  await_down(monitor)
  assert !list.contains(agent_group_registry.alive_ids(), "expired")
  let assert Ok(index) =
    storage.list(backend, agent_group.running_index_prefix())
  assert list.length(index) == 1
  remove_directory(root)
}

pub fn ambiguous_successful_cas_is_idempotent_and_fences_next_commit_test() {
  let root = temporary_root("agent-group-ambiguous-cas-test")
  let local_backend = local.new(local.config(root))
  let backend = ambiguous_commit_storage(local_backend)
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)

  let tool =
    plugin.tool(
      llm.Tool(
        "continue_once",
        None,
        json.object([#("type", json.string("object"))]),
      ),
      fn(state, context, _) {
        Ok(plugin.hook_result(
          state,
          context,
          plugin.ToolOutput([llm.Text("continue")], False),
        ))
      },
    )
  let assert Ok(registry) =
    plugin.registry([plugin.new("tool", "{}") |> plugin.with_tool(tool)])
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let _ = case contains_tool_result(request.messages) {
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
          let assert Ok(Nil) =
            consume(llm.ToolCallStart(0, "call", "continue_once"))
          let assert Ok(Nil) = consume(llm.ToolCallArgumentsDelta(0, "{}"))
          let assert Ok(Nil) = consume(llm.ContentStop(0))
          let assert Ok(Nil) = consume(llm.Finished(llm.ToolUse))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
        True -> {
          let assert Ok(Nil) = consume(llm.MessageStart("second", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "done"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
      }
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/ambiguous", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("ambiguous", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.round == 2
  assert completed.revision == 2
  remove_directory(root)
}

fn test_model() -> model_catalog.Model {
  model_catalog.Model(
    "model",
    "test-model",
    "https://example.test",
    model_catalog.OpenAIResponses,
    model_catalog.api_key("secret"),
  )
}

fn completing_transport(text: String) -> agent.ModelTransport {
  agent.model_transport(fn(_, _, consume) {
    let assert Ok(Nil) = consume(llm.MessageStart("message", "test-model"))
    let assert Ok(Nil) = consume(llm.TextDelta(0, text))
    let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
    let assert Ok(Nil) = consume(llm.MessageStop)
    Ok(Nil)
  })
}

pub fn resume_registered_deduplicates_and_loads_dormant_profiles_test() {
  let root = temporary_root("resume-shared-profile-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let shared =
    agent_profile.AgentProfile(
      "shared",
      registry,
      completing_transport("done"),
      None,
      None,
      observe,
    )
  let waiting_a =
    agent.State(
      ..agent.state("a", "model"),
      profile_id: "shared",
      status: agent.Waiting,
    )
  let waiting_b =
    agent.State(
      ..agent.state("b", "model"),
      profile_id: "shared",
      status: agent.Waiting,
    )
  let config = agent_group.Config(backend, "groups/shared", [shared], 10, 100)
  let assert Ok(_) =
    agent_group.create(
      config,
      agent_group.new("shared", "catalog", [waiting_a, waiting_b]),
    )

  let assert Ok(loaded) =
    agent_group.resume_registered(backend, "groups/shared", 10)
  let assert Ok(group) = agent_group.wake(loaded)
  let assert Ok(Nil) = agent_group.send_message(group, "a", "work on A")
  let assert Ok(Nil) = agent_group.send_message(group, "b", "work on B")
  process.sleep(100)
  let assert Ok(snapshot) = agent_group.snapshot(group)
  assert list.all(snapshot.agents, fn(state) {
    state.status == agent.Completed && state.round == 1
  })
  let assert Ok(Nil) = agent_group.stop(group)
  remove_directory(root)
}

pub fn ambiguous_running_index_write_is_confirmed_test() {
  let root = temporary_root("ambiguous-index-test")
  let backend = local.new(local.config(root)) |> ambiguous_index_storage
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      completing_transport("done"),
      None,
      None,
      observe,
    )
  let config = agent_group.Config(backend, "groups/index", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("index", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  remove_directory(root)
}

pub fn paused_turn_resumes_and_usage_accumulates_test() {
  let root = temporary_root("paused-usage-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let has_history = !list.is_empty(request.messages)
      let assert Ok(Nil) = consume(llm.MessageStart("message", "test-model"))
      let assert Ok(Nil) =
        consume(
          llm.TextDelta(0, case has_history {
            True -> "final"
            False -> "partial"
          }),
        )
      let assert Ok(Nil) =
        consume(
          llm.UsageReported(llm.Usage(
            input_tokens: Some(case has_history {
              True -> 3
              False -> 2
            }),
            output_tokens: Some(case has_history {
              True -> 2
              False -> 1
            }),
            cache_read_tokens: None,
            cache_write_tokens: None,
          )),
        )
      let assert Ok(Nil) =
        consume(
          llm.Finished(case has_history {
            True -> llm.Stop
            False -> llm.Paused
          }),
        )
      let assert Ok(Nil) = consume(llm.MessageStop)
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let config = agent_group.Config(backend, "groups/paused", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("paused", "catalog", [agent.state("agent", "model")]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.round == 2
  assert completed.stats == llm.Stats(5, 3, 0, 0)
  remove_directory(root)
}

pub fn truncated_turn_fails_instead_of_completing_test() {
  let root = temporary_root("truncated-turn-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport =
    agent.model_transport(fn(_, _, consume) {
      let assert Ok(Nil) = consume(llm.TextDelta(0, "incomplete"))
      let assert Ok(Nil) = consume(llm.Finished(llm.Length))
      Ok(Nil)
    })
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/truncated", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("truncated", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [failed] = snapshot.agents
  let assert agent.Failed(reason) = failed.status
  assert string.contains(reason, "truncated")
  remove_directory(root)
}
