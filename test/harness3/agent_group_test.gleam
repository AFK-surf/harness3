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

/// Reports the first IfUnchanged put — the wake's claim CAS — as failed even
/// though it was applied, imitating a lost response plus a storage-level
/// retry observing its own write.
fn ambiguous_claim_storage(backend: storage.Storage) -> storage.Storage {
  let assert Ok(started) =
    actor.new(False)
    |> actor.on_message(fn(triggered: Bool, message: AmbiguityMessage) {
      let Ambiguate(_, condition, reply) = message
      let should_ambiguate = case condition {
        storage.IfUnchanged(_) -> !triggered
        _ -> False
      }
      process.send(reply, should_ambiguate)
      actor.continue(triggered || should_ambiguate)
    })
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
      context_window_tokens: 100_000,
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
  let assert agent_group.Completed(_) = snapshot.execution

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
      context_window_tokens: 100_000,
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
      context_messages: None,
      pending_messages: [],
      stats: llm.Stats(10, 5, 2, 1),
      plugin_states: dict.from_list([#("plugin", "{\"count\":1}")]),
      plugin_generation: 3,
      last_catalog_revision: Some(4),
      last_context_tokens: Some(15),
      compaction_requested: 2,
      compaction_completed: 1,
      last_compaction_error: Some("retry"),
      attributes: dict.from_list([#("role", "lead engineer")]),
      status: agent.Ready,
    )
  let encoded = agent.encode_state(original) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, agent.state_decoder())
  assert decoded.id == "agent"
  assert decoded.revision == 2
  assert decoded.stats == llm.Stats(10, 5, 2, 1)
  assert decoded.last_context_tokens == Some(15)
  assert decoded.compaction_requested == 2
  assert decoded.compaction_completed == 1
  assert decoded.last_compaction_error == Some("retry")
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
      context_window_tokens: 100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(storage, "catalog", catalog)

  let tool =
    plugin.tool(
      llm.Tool(
        "stateful.record_call",
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
      "Call stateful.record_call once.",
    ))
    |> plugin.with_tool(tool)
  let assert Ok(registry) = plugin.registry([stateful_plugin])

  let transport =
    agent.model_transport(fn(_, request, consume) {
      let llm.Request(messages:, tools:, ..) = request
      assert list.length(tools) == 1
      let assert [llm.Message(llm.System, [llm.Text(system_prompt)]), ..] =
        messages
      assert system_prompt
        == "## Stateful tool\n\nCall stateful.record_call once."
      case contains_tool_result(messages) {
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
          let assert Ok(Nil) =
            consume(llm.ToolCallStart(0, "call_1", "stateful.record_call"))
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
      100_000,
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
      100_000,
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

fn synthetic_call_present(
  messages: List(llm.Message),
  tool_name: String,
  response: String,
) -> Bool {
  list.any(messages, fn(message) {
    case message {
      llm.Message(llm.Assistant, content) ->
        list.any(content, fn(part) {
          case part {
            llm.ToolCall(call_id, name, _) if name == tool_name ->
              synthetic_result_present(messages, call_id, response)
            _ -> False
          }
        })
      _ -> False
    }
  })
}

fn synthetic_result_present(
  messages: List(llm.Message),
  call_id: String,
  response: String,
) -> Bool {
  list.any(messages, fn(message) {
    case message {
      llm.Message(llm.ToolRole, content) ->
        list.any(content, fn(part) {
          case part {
            llm.ToolResult(id, result_content, False) if id == call_id ->
              list.any(result_content, fn(result_part) {
                case result_part {
                  llm.Text(text) -> text == response
                  _ -> False
                }
              })
            _ -> False
          }
        })
      _ -> False
    }
  })
}

pub fn tool_call_injected_into_inactive_agent_persists_and_starts_it_test() {
  let root = temporary_root("inactive-agent-inject-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "tool call handled"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/inactive-inject", [profile], 10, 100)
  let inactive =
    agent.State(..agent.state("agent", "model"), status: agent.Completed)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("inactive-inject", "catalog", [inactive]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  assert list.is_empty(agent_group.agent_pids(group))

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "please review the diff",
    )
  let assert Ok(Started(release)) = process.receive(gate, within: 5000)
  let assert Ok(injected) = agent_group.load(config)
  let assert [injected_agent] = injected.agents
  assert list.is_empty(injected_agent.pending_messages)
  // The conversation was empty, so a user hint precedes the pair: a tool call
  // must not start a conversation.
  let assert [hint, call, result] = injected_agent.messages
  let assert llm.Message(llm.User, [llm.Text(_)]) = hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = call
  let assert llm.Message(llm.ToolRole, [llm.ToolResult(_, _, False)]) = result
  assert synthetic_call_present(
    injected_agent.messages,
    "team.receive_message",
    "please review the diff",
  )

  process.send(release, Nil)
  await_down(group_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
  assert list.is_empty(completed_agent.pending_messages)
  assert synthetic_call_present(
    completed_agent.messages,
    "team.receive_message",
    "please review the diff",
  )
  assert completed_agent.round == 1
  assert completed_agent.status == agent.Completed
  remove_directory(root)
}

pub fn tool_call_injected_after_assistant_tail_gets_user_hint_test() {
  let root = temporary_root("assistant-tail-inject-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "handled"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/assistant-tail", [profile], 10, 100)
  let inactive =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [
        llm.Message(llm.User, [llm.Text("initial task")]),
        llm.Message(llm.Assistant, [llm.Text("work complete")]),
      ],
      status: agent.Completed,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("assistant-tail", "catalog", [inactive]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "one more thing",
    )
  let assert Ok(Started(release)) = process.receive(gate, within: 5000)
  let assert Ok(injected) = agent_group.load(config)
  let assert [injected_agent] = injected.agents
  // The assistant tail must not directly abut the synthetic assistant call.
  let assert [_, _, hint, call, result] = injected_agent.messages
  let assert llm.Message(llm.User, [llm.Text(_)]) = hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = call
  let assert llm.Message(llm.ToolRole, [llm.ToolResult(_, _, False)]) = result

  process.send(release, Nil)
  await_down(group_monitor)
  remove_directory(root)
}

pub fn tool_call_injected_after_user_tail_needs_no_hint_test() {
  let root = temporary_root("user-tail-inject-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "handled"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/user-tail", [profile], 10, 100)
  let inactive =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [llm.Message(llm.User, [llm.Text("initial task")])],
      status: agent.Completed,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("user-tail", "catalog", [inactive]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "follow-up",
    )
  let assert Ok(Started(release)) = process.receive(gate, within: 5000)
  let assert Ok(injected) = agent_group.load(config)
  let assert [injected_agent] = injected.agents
  // The pair already follows a user message, so no hint is inserted.
  let assert [_, call, result] = injected_agent.messages
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = call
  let assert llm.Message(llm.ToolRole, [llm.ToolResult(_, _, False)]) = result

  process.send(release, Nil)
  await_down(group_monitor)
  remove_directory(root)
}

pub fn tool_call_injected_into_active_agent_is_queued_test() {
  let root = temporary_root("active-agent-inject-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let first_call = process.new_subject()
  let second_call = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let _ = case
        synthetic_call_present(
          request.messages,
          "team.receive_message",
          "mid-round",
        )
      {
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
    agent_group.Config(backend, "groups/active-inject", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("active-inject", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(release)) = process.receive(first_call, within: 5000)

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "mid-round",
    )
  let assert Ok(queued) = agent_group.load(config)
  let assert [queued_agent] = queued.agents
  // The in-flight round may end with a bare assistant message, so the queued
  // pair gets a user hint in front of it.
  let assert [hint, queued_call, queued_result] = queued_agent.pending_messages
  let assert llm.Message(llm.User, [llm.Text(_)]) = hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = queued_call
  let assert llm.Message(llm.ToolRole, [llm.ToolResult(_, _, False)]) =
    queued_result
  assert synthetic_call_present(
    queued_agent.pending_messages,
    "team.receive_message",
    "mid-round",
  )
  assert !synthetic_call_present(
    queued_agent.messages,
    "team.receive_message",
    "mid-round",
  )

  process.send(release, Nil)
  let assert Ok(Nil) = process.receive(second_call, within: 5000)
  await_down(group_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
  assert list.is_empty(completed_agent.pending_messages)
  // The folded sequence preserves role alternation across the round boundary:
  // assistant answer, user hint, synthetic call, its result, next answer.
  let assert [first, folded_hint, folded_call, folded_result, _second] =
    completed_agent.messages
  let assert llm.Message(llm.Assistant, [llm.Text("first answer")]) = first
  let assert llm.Message(llm.User, [llm.Text(_)]) = folded_hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = folded_call
  let assert llm.Message(llm.ToolRole, [llm.ToolResult(_, _, False)]) =
    folded_result
  assert synthetic_call_present(
    completed_agent.messages,
    "team.receive_message",
    "mid-round",
  )
  assert completed_agent.round == 2
  assert completed_agent.status == agent.Completed
  remove_directory(root)
}

pub fn tool_call_injection_validates_its_shape_test() {
  let root = temporary_root("inject-validation-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "never reached"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/inject-validation", [profile], 10, 100)
  let inactive =
    agent.State(..agent.state("agent", "model"), status: agent.Completed)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("inject-validation", "catalog", [inactive]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))

  let assert Error(agent_group.InvalidMessage(_)) =
    agent_group.inject_tool_call(group, "agent", "", "{}", "response")
  let assert Error(agent_group.InvalidMessage(_)) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{}",
      "",
    )
  let assert Error(agent_group.InvalidMessage(_)) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "not json",
      "response",
    )
  // Arguments must be a JSON object: provider APIs reject any other shape
  // for tool-use input.
  let assert Error(agent_group.InvalidMessage(_)) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "[1,2]",
      "response",
    )
  let assert Error(agent_group.MissingAgent("nobody")) =
    agent_group.inject_tool_call(
      group,
      "nobody",
      "team.receive_message",
      "{}",
      "response",
    )
  let assert Ok(snapshot) = agent_group.snapshot(group)
  let assert [unchanged] = snapshot.agents
  assert list.is_empty(unchanged.messages)
  assert list.is_empty(unchanged.pending_messages)

  let assert Ok(Nil) = agent_group.stop(group)
  await_down(group_monitor)
  remove_directory(root)
}

pub fn second_tool_call_injection_is_queued_without_hint_test() {
  let root = temporary_root("second-injection-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let first_call = process.new_subject()
  let second_call = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let _ = case
        synthetic_call_present(
          request.messages,
          "team.receive_message",
          "second update",
        )
      {
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
    agent_group.Config(backend, "groups/second-injection", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("second-injection", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let group_monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(release)) = process.receive(first_call, within: 5000)

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "first update",
    )
  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"researcher\"}",
      "second update",
    )
  let assert Ok(queued) = agent_group.load(config)
  let assert [queued_agent] = queued.agents
  // Only the first injection gets the hint: the queued inbox already ends
  // with a tool result, which never abuts the second pair's assistant call.
  let assert [
    hint,
    first_call_msg,
    first_result,
    second_call_msg,
    second_result,
  ] = queued_agent.pending_messages
  let assert llm.Message(llm.User, [llm.Text(_)]) = hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = first_call_msg
  let assert llm.Message(
    llm.ToolRole,
    [llm.ToolResult(_, [llm.Text("first update")], False)],
  ) = first_result
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = second_call_msg
  let assert llm.Message(
    llm.ToolRole,
    [llm.ToolResult(_, [llm.Text("second update")], False)],
  ) = second_result

  process.send(release, Nil)
  let assert Ok(Nil) = process.receive(second_call, within: 5000)
  await_down(group_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
  assert list.is_empty(completed_agent.pending_messages)
  assert synthetic_call_present(
    completed_agent.messages,
    "team.receive_message",
    "first update",
  )
  assert synthetic_call_present(
    completed_agent.messages,
    "team.receive_message",
    "second update",
  )
  assert completed_agent.round == 2
  assert completed_agent.status == agent.Completed
  remove_directory(root)
}

pub fn queued_tool_call_pair_folds_into_history_on_wake_after_crash_test() {
  let root = temporary_root("crash-fold-inject-test")
  let backend = local.new(local.config(root))
  let model =
    model_catalog.Model(
      "model",
      "test-model",
      "https://example.test",
      model_catalog.OpenAIResponses,
      model_catalog.api_key("secret"),
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let first_call = process.new_subject()
  let replay_call = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      case
        synthetic_call_present(
          request.messages,
          "team.receive_message",
          "crash update",
        )
      {
        False -> {
          let release = process.new_subject()
          process.send(first_call, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          panic as "intentional agent crash"
        }
        True -> {
          let release = process.new_subject()
          process.send(replay_call, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          let assert Ok(Nil) = consume(llm.MessageStart("replay", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "recovered"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
      }
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
  // One-second lease so the crashed claim expires quickly enough to re-wake.
  let config =
    agent_group.Config(backend, "groups/crash-fold", [profile], 1, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("crash-fold", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  // Wake from an owner process: the crashing worker takes the whole linked
  // process tree down with it.
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(started, agent_group.wake(loaded))
      process.sleep_forever()
    })
  let assert Ok(Ok(group)) = process.receive(started, within: 5000)
  let group_monitor = process.monitor(agent_group.pid(group))
  let owner_monitor = process.monitor(owner)
  let assert Ok(Started(crash)) = process.receive(first_call, within: 5000)

  let assert Ok(Nil) =
    agent_group.inject_tool_call(
      group,
      "agent",
      "team.receive_message",
      "{\"from\":\"lead\"}",
      "crash update",
    )
  let assert Ok(queued) = agent_group.load(config)
  let assert [queued_agent] = queued.agents
  let assert [_, _, _] = queued_agent.pending_messages

  process.send(crash, Nil)
  await_down(group_monitor)
  await_down(owner_monitor)

  // The claim expires, the group is resumed, and claim-time injection folds
  // the queued pair (with its hint) into the conversation before the round.
  process.sleep(1100)
  let assert Ok(resumed) = agent_group.resume(config)
  let assert Ok(revived) = agent_group.wake(resumed)
  let revived_monitor = process.monitor(agent_group.pid(revived))
  let assert Ok(Started(replay)) = process.receive(replay_call, within: 5000)
  let assert Ok(folded) = agent_group.load(config)
  let assert [folded_agent] = folded.agents
  assert list.is_empty(folded_agent.pending_messages)
  let assert [hint, call, result] = folded_agent.messages
  let assert llm.Message(llm.User, [llm.Text(_)]) = hint
  let assert llm.Message(
    llm.Assistant,
    [llm.ToolCall(_, "team.receive_message", _)],
  ) = call
  let assert llm.Message(
    llm.ToolRole,
    [llm.ToolResult(_, [llm.Text("crash update")], False)],
  ) = result

  process.send(replay, Nil)
  await_down(revived_monitor)
  let assert Ok(completed) = agent_group.load(config)
  let assert [completed_agent] = completed.agents
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
      context_window_tokens: 100_000,
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
          "caller_plugin.call_receiver",
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
            consume(llm.ToolCallStart(
              0,
              "remote_1",
              "caller_plugin.call_receiver",
            ))
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
      100_000,
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
  assert agent_group.loaded_state(loaded).execution == agent_group.Idle(0)
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
  // The epoch survives release: resetting it would let a later claim reuse a
  // running-index key that a stale entry still occupies.
  let assert agent_group.Idle(released_epoch) = snapshot.execution
  assert released_epoch == 1
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
      100_000,
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
      100_000,
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
      100_000,
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
      100_000,
    )
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)

  let tool =
    plugin.tool(
      llm.Tool(
        "tool.continue_once",
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
            consume(llm.ToolCallStart(0, "call", "tool.continue_once"))
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
    100_000,
  )
}

pub fn wake_applied_update_replaces_roster_and_preserves_survivors_test() {
  let root = temporary_root("reconfigure-agent-group-test")
  let backend = local.new(local.config(root))
  let other_model =
    model_catalog.Model(..test_model(), id: "other-model", name: "other")
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(catalog) = model_catalog.put_model(catalog, other_model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport = completing_transport("unused")
  let lead_profile =
    agent_profile.AgentProfile(
      "lead-profile",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let removed_profile =
    agent_profile.AgentProfile(
      "removed-profile",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let added_profile =
    agent_profile.AgentProfile(
      "added-profile",
      registry,
      transport,
      None,
      None,
      observe,
    )
  let historic = llm.Message(llm.User, [llm.Text("preserve this")])
  let lead =
    agent.State(
      ..agent.state("lead", "model"),
      profile_id: "lead-profile",
      messages: [historic],
      status: agent.Waiting,
    )
  let removed =
    agent.State(
      ..agent.state("removed", "model"),
      profile_id: "removed-profile",
      status: agent.Waiting,
    )
  let original_config =
    agent_group.Config(
      backend,
      "groups/reconfigure",
      [lead_profile, removed_profile],
      10,
      100,
    )
  let assert Ok(_) =
    agent_group.create(
      original_config,
      agent_group.new("reconfigure", "catalog", [lead, removed]),
    )
  let next_config =
    agent_group.Config(
      backend,
      "groups/reconfigure",
      [lead_profile, added_profile],
      10,
      100,
    )
  // A declarative command: the surviving lead's state is preserved by the
  // applier, not shipped by the caller.
  let update =
    agent_group.GroupUpdate(
      attributes: dict.from_list([#("title", "Edited team")]),
      agent_attributes: dict.new(),
      roster: Some([
        agent_group.RosterEntry(
          "lead",
          "lead-profile",
          "other-model",
          dict.new(),
          agent.Waiting,
        ),
        agent_group.RosterEntry(
          "added",
          "added-profile",
          "model",
          dict.new(),
          agent.Waiting,
        ),
      ]),
    )
  let assert Ok(loaded) = agent_group.resume(next_config)
  let assert Ok(running) =
    agent_group.wake_detached_updated(loaded, "owner-a", update, fn() { Nil })
  let assert Ok(snapshot) = agent_group.snapshot(running)
  let assert [survivor, newcomer] = snapshot.agents
  assert survivor.id == "lead"
  assert survivor.model_id == "other-model"
  assert survivor.messages == [historic]
  assert newcomer.id == "added"
  assert newcomer.status == agent.Waiting
  assert dict.get(snapshot.attributes, "title") == Ok("Edited team")

  // A claimed group rejects a second wake-applied update: the roster of a
  // live group can only change after the owner releases it.
  let assert Ok(reloaded) = agent_group.resume(next_config)
  let assert Error(agent_group.AlreadyClaimed(_, _)) =
    agent_group.wake_detached_updated(reloaded, "owner-b", update, fn() { Nil })

  // Attribute upserts on the live group go through its coordinator instead.
  let assert Ok(Nil) =
    agent_group.update_group(
      running,
      agent_group.GroupUpdate(
        attributes: dict.from_list([#("prompt", "hello")]),
        agent_attributes: dict.from_list([
          #("added", dict.from_list([#("role", "newcomer")])),
        ]),
        roster: None,
      ),
    )
  let assert Error(agent_group.InvalidGroup(_)) =
    agent_group.update_group(
      running,
      agent_group.GroupUpdate(
        attributes: dict.new(),
        agent_attributes: dict.new(),
        roster: Some([
          agent_group.RosterEntry(
            "lead",
            "lead-profile",
            "model",
            dict.new(),
            agent.Waiting,
          ),
        ]),
      ),
    )
  let assert Ok(Nil) = agent_group.stop(running)

  // The roster replacement and both attribute updates are durable.
  let assert Ok(peeked) = agent_group.peek(backend, "groups/reconfigure")
  assert list.map(peeked.agents, fn(state) { state.id }) == ["lead", "added"]
  assert dict.get(peeked.attributes, "title") == Ok("Edited team")
  assert dict.get(peeked.attributes, "prompt") == Ok("hello")
  let assert [_, peeked_added] = peeked.agents
  assert dict.get(peeked_added.attributes, "role") == Ok("newcomer")
  remove_directory(root)
}

pub fn failed_wake_never_leaves_a_stranded_claim_test() {
  let root = temporary_root("wake-claim-leak-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let transport = completing_transport("unused")

  // A dormant agent with a queued inbox is promoted to Ready by the claim, so
  // its unknown model must fail the wake *before* the claim CAS commits.
  let assert Ok(empty_registry) = plugin.registry([])
  let profile =
    agent_profile.AgentProfile(
      "leak-profile",
      empty_registry,
      transport,
      None,
      None,
      observe,
    )
  let dormant =
    agent.State(
      ..agent.state("agent", "missing-model"),
      profile_id: "leak-profile",
      status: agent.Completed,
      pending_messages: [llm.Message(llm.User, [llm.Text("revive")])],
    )
  let config = agent_group.Config(backend, "groups/leak", [profile], 10, 100)
  let assert Ok(_) =
    agent_group.create(config, agent_group.new("leak", "catalog", [dormant]))
  let assert Ok(loaded) = agent_group.resume(config)
  let assert Error(agent_group.UnknownModel("agent", "missing-model")) =
    agent_group.wake_as(loaded, "owner-a")
  let assert Ok(untouched) = agent_group.peek(backend, "groups/leak")
  assert untouched.revision == 0
  assert untouched.execution == agent_group.Idle(0)

  // A failure after the claim CAS (here: a raising activation hook) must
  // release the claim, or the group is unwakeable until the lease expires and
  // invisible to recovery.
  let failing =
    plugin.new("boom", "{}")
    |> plugin.on_activate(
      plugin.activation_hook(fn(_, _) {
        Error(plugin.HookFailed("boom", "activate", "always fails"))
      }),
    )
  let assert Ok(failing_registry) = plugin.registry([failing])
  let failing_profile =
    agent_profile.AgentProfile(
      "boom-profile",
      failing_registry,
      transport,
      None,
      None,
      observe,
    )
  let ready =
    agent.State(..agent.state("agent", "model"), profile_id: "boom-profile")
  let failing_config =
    agent_group.Config(backend, "groups/leak-boom", [failing_profile], 10, 100)
  let assert Ok(_) =
    agent_group.create(
      failing_config,
      agent_group.new("leak-boom", "catalog", [ready]),
    )
  let assert Ok(loaded) = agent_group.resume(failing_config)
  let assert Error(agent_group.AgentActivationFailed("agent", _)) =
    agent_group.wake_as(loaded, "owner-a")
  let assert Ok(released) = agent_group.peek(backend, "groups/leak-boom")
  assert released.execution == agent_group.Idle(1)
  remove_directory(root)
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

fn contains_text_fragment(
  messages: List(llm.Message),
  fragment: String,
) -> Bool {
  list.any(messages, fn(message) {
    let llm.Message(content:, ..) = message
    list.any(content, fn(part) {
      case part {
        llm.Text(text) -> string.contains(text, fragment)
        _ -> False
      }
    })
  })
}

pub fn automatic_compaction_reuses_prefix_and_preserves_full_history_test() {
  let root = temporary_root("automatic-compaction-test")
  let backend = local.new(local.config(root))
  let model = model_catalog.Model(..test_model(), context_window_tokens: 100)
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let inert_tool =
    plugin.tool(
      llm.Tool(
        "cache_prefix.inert",
        None,
        json.object([#("type", json.string("object"))]),
      ),
      fn(state, context, _) {
        Ok(plugin.hook_result(state, context, plugin.ToolOutput([], False)))
      },
    )
  let cache_plugin =
    plugin.new("cache_prefix", "{}")
    |> plugin.with_system_prompt(plugin.SystemPromptSection(
      "Cache prefix",
      "Stable system prompt.",
    ))
    |> plugin.with_tool(inert_tool)
  let assert Ok(registry) = plugin.registry([cache_plugin])
  let calls = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let release = process.new_subject()
      process.send(calls, #(request, release))
      let assert Ok(Nil) = process.receive(release, within: 5000)
      let compacting =
        contains_text_fragment(request.messages, "Create a handover summary")
      let assert Ok(Nil) = consume(llm.MessageStart("message", "test-model"))
      let assert Ok(Nil) =
        consume(
          llm.TextDelta(0, case compacting {
            True -> "<handover>preserved summary</handover>"
            False -> "normal answer"
          }),
        )
      let assert Ok(Nil) =
        consume(
          llm.UsageReported(llm.Usage(
            input_tokens: Some(case compacting {
              True -> 82
              False -> 79
            }),
            output_tokens: Some(case compacting {
              True -> 4
              False -> 1
            }),
            cache_read_tokens: None,
            cache_write_tokens: None,
          )),
        )
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
  let config =
    agent_group.Config(backend, "groups/compact-auto", [profile], 10, 100)
  let initial =
    agent.State(..agent.state("agent", "model"), messages: [
      llm.Message(llm.User, [llm.Text("original task")]),
    ])
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("compact-auto", "catalog", [initial]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let monitor = process.monitor(agent_group.pid(group))

  let assert Ok(#(normal_request, normal_release)) =
    process.receive(calls, within: 2000)
  let system =
    llm.Message(llm.System, [
      llm.Text("## Cache prefix\n\nStable system prompt."),
    ])
  assert normal_request.messages == [system, ..initial.messages]
  assert list.length(normal_request.tools) == 1
  process.send(normal_release, Nil)

  let assert Ok(#(compaction_request, compaction_release)) =
    process.receive(calls, within: 2000)
  let assert Ok(during_compaction) = agent_group.snapshot(group)
  let assert [uncompacted] = during_compaction.agents
  assert list.take(
      compaction_request.messages,
      list.length(compaction_request.messages) - 1,
    )
    == [system, ..uncompacted.messages]
  assert compaction_request.tools == normal_request.tools
  assert compaction_request.max_output_tokens == Some(10)
  process.send(compaction_release, Nil)

  await_down(monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [compacted] = snapshot.agents
  assert compacted.messages
    == [
      llm.Message(llm.User, [llm.Text("original task")]),
      llm.Message(llm.Assistant, [llm.Text("normal answer")]),
    ]
  let assert Some([llm.Message(llm.User, [llm.Text(active_context)])]) =
    compacted.context_messages
  assert string.contains(
    active_context,
    "<handover>\npreserved summary\n</handover>",
  )
  assert compacted.compaction_requested == 1
  assert compacted.compaction_completed == 1
  assert compacted.last_context_tokens == None
  assert compacted.round == 1
  assert compacted.stats == llm.Stats(161, 5, 0, 0)
  remove_directory(root)
}

pub fn automatic_compaction_waits_until_eighty_percent_test() {
  let root = temporary_root("compaction-threshold-test")
  let backend = local.new(local.config(root))
  let model = model_catalog.Model(..test_model(), context_window_tokens: 100)
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let calls = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      process.send(calls, request)
      let assert Ok(Nil) = consume(llm.TextDelta(0, "below threshold"))
      let assert Ok(Nil) =
        consume(
          llm.UsageReported(llm.Usage(
            input_tokens: Some(78),
            output_tokens: Some(1),
            cache_read_tokens: None,
            cache_write_tokens: None,
          )),
        )
      let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
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
    agent_group.Config(backend, "groups/compact-threshold", [profile], 10, 20)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("compact-threshold", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(_) = process.receive(calls, within: 1000)
  let assert Error(_) = process.receive(calls, within: 50)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.context_messages == None
  assert completed.last_context_tokens == Some(79)
  assert completed.compaction_completed == 0
  remove_directory(root)
}

pub fn manual_compaction_runs_for_dormant_agent_in_awake_group_test() {
  let root = temporary_root("manual-compaction-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let calls = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let release = process.new_subject()
      process.send(calls, #(request, release))
      let assert Ok(Nil) = process.receive(release, within: 5000)
      let compacting =
        contains_text_fragment(request.messages, "Create a handover summary")
      let assert Ok(Nil) =
        consume(
          llm.TextDelta(0, case compacting {
            True -> "<handover>manual summary</handover>"
            False -> "handled after handover"
          }),
        )
      let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
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
    agent_group.Config(backend, "groups/compact-manual", [profile], 10, 100)
  let historic = llm.Message(llm.User, [llm.Text("historic request")])
  let initial =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [historic],
      status: agent.Waiting,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("compact-manual", "catalog", [initial]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let monitor = process.monitor(agent_group.pid(group))
  assert agent_group.request_compaction(group, "agent") == Ok(1)
  let assert Ok(#(request, release)) = process.receive(calls, within: 2000)
  assert list.take(request.messages, list.length(request.messages) - 1)
    == [historic]
  let assert Ok(Nil) =
    agent_group.send_message(group, "agent", "arrived during compaction")
  let assert Ok(in_flight) = agent_group.snapshot(group)
  let assert [in_flight_agent] = in_flight.agents
  assert list.length(in_flight_agent.pending_messages) == 1
  process.send(release, Nil)
  let assert Ok(#(continued_request, continued_release)) =
    process.receive(calls, within: 2000)
  assert contains_text_fragment(continued_request.messages, "manual summary")
  assert contains_text_fragment(
    continued_request.messages,
    "arrived during compaction",
  )
  process.send(continued_release, Nil)
  await_down(monitor)

  let assert Ok(snapshot) = agent_group.load(config)
  let assert [compacted] = snapshot.agents
  assert compacted.messages
    == [
      historic,
      llm.Message(llm.User, [llm.Text("arrived during compaction")]),
      llm.Message(llm.Assistant, [llm.Text("handled after handover")]),
    ]
  assert compacted.status == agent.Completed
  assert compacted.round == 1
  assert compacted.compaction_completed == 1
  let assert Some(context) = compacted.context_messages
  assert contains_text_fragment(context, "manual summary")
  remove_directory(root)
}

pub fn malformed_compaction_keeps_full_history_and_records_error_test() {
  let root = temporary_root("failed-compaction-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport =
    agent.model_transport(fn(_, _, consume) {
      let assert Ok(Nil) = consume(llm.TextDelta(0, "summary without tags"))
      let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
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
    agent_group.Config(backend, "groups/compact-failed", [profile], 10, 20)
  let historic = llm.Message(llm.User, [llm.Text("must survive")])
  let state =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [historic],
      status: agent.Waiting,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("compact-failed", "catalog", [state]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  let monitor = process.monitor(agent_group.pid(group))
  assert agent_group.request_compaction(group, "agent") == Ok(1)
  await_down(monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [failed] = snapshot.agents
  assert failed.messages == [historic]
  assert failed.context_messages == None
  assert failed.compaction_requested == 1
  assert failed.compaction_completed == 0
  let assert Some(error) = failed.last_compaction_error
  assert string.contains(error, "<handover> tags")
  remove_directory(root)
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

pub fn resume_registered_tolerates_missing_terminal_profiles_test() {
  let root = temporary_root("resume-missing-profile-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let installed =
    agent_profile.AgentProfile(
      "missing-test-installed",
      registry,
      completing_transport("revived"),
      None,
      None,
      observe,
    )
  let revivable =
    agent.State(
      ..agent.state("a", "model"),
      profile_id: "missing-test-installed",
      status: agent.Completed,
    )
  let orphaned =
    agent.State(
      ..agent.state("b", "model"),
      profile_id: "missing-test-gone",
      status: agent.Completed,
    )
  let config =
    agent_group.Config(
      backend,
      "groups/missing-profile",
      [installed],
      10,
      60_000,
    )
  let assert Ok(_) =
    agent_group.create(
      config,
      agent_group.new("missing-profile", "catalog", [revivable, orphaned]),
    )

  // A terminal agent whose profile is not installed must not block resuming.
  let assert Ok(loaded) =
    agent_group.resume_registered(backend, "groups/missing-profile", 10)
  let assert Ok(group) = agent_group.wake(loaded)

  // Messaging the orphaned agent fails only when actually attempted…
  let assert Error(agent_group.MissingProfile("missing-test-gone")) =
    agent_group.send_message(group, "b", "hello")
  // …while the dormant agent with an installed profile can still be revived.
  let assert Ok(Nil) = agent_group.send_message(group, "a", "wake up")
  process.sleep(100)
  let assert Ok(snapshot) = agent_group.snapshot(group)
  let assert Ok(revived) =
    list.find(snapshot.agents, fn(state) { state.id == "a" })
  assert revived.status == agent.Completed && revived.round == 1
  let assert Ok(Nil) = agent_group.stop(group)
  remove_directory(root)
}

pub fn ambiguous_claim_write_is_confirmed_test() {
  let root = temporary_root("ambiguous-claim-test")
  let backend = local.new(local.config(root)) |> ambiguous_claim_storage
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      completing_transport("claimed anyway"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/ambiguous-claim", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("ambiguous-claim", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  // The claim CAS reports PreconditionFailed although it was applied; the
  // wake must confirm its own write by read-back and start the group instead
  // of leaving it durably claimed with no coordinator.
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.round == 1
  let assert agent_group.Completed(_) = snapshot.execution
  remove_directory(root)
}

pub fn concurrent_same_owner_wakes_admit_only_one_claim_test() {
  let root = temporary_root("duplicate-claim-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let profile =
    agent_profile.AgentProfile(
      "agent",
      registry,
      gated_transport(gate, "single claimant"),
      None,
      None,
      observe,
    )
  let config =
    agent_group.Config(backend, "groups/duplicate-claim", [profile], 10, 100)
  let assert Ok(loaded_a) =
    agent_group.create(
      config,
      agent_group.new("duplicate-claim", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  // A second loaded snapshot at the same storage version, as produced by a
  // concurrent request racing the first wake.
  let assert Ok(loaded_b) = agent_group.resume(config)

  let assert Ok(group) = agent_group.wake_as(loaded_a, "stable-owner")
  let monitor = process.monitor(agent_group.pid(group))
  let assert Ok(Started(release)) = process.receive(gate, within: 2000)
  // Same owner, same epoch, possibly the same wall-clock second: without the
  // per-claim nonce the loser's read-back would match the winner's claim body
  // and a second coordinator would start for the same group.
  let assert Error(agent_group.ConcurrentGroupUpdate) =
    agent_group.wake_as(loaded_b, "stable-owner")

  process.send(release, Nil)
  await_down(monitor)
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [completed] = snapshot.agents
  assert completed.status == agent.Completed
  assert completed.round == 1
  remove_directory(root)
}

pub fn failed_compaction_still_processes_messages_queued_during_it_test() {
  let root = temporary_root("failed-compaction-message-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      case
        contains_text_fragment(request.messages, "Create a handover summary")
      {
        True -> {
          let release = process.new_subject()
          process.send(gate, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          // Malformed handover: the compaction attempt must fail.
          let assert Ok(Nil) = consume(llm.MessageStart("c", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "not a handover"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("m", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "processed anyway"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
      }
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
    agent_group.Config(
      backend,
      "groups/failed-compaction",
      [profile],
      10,
      60_000,
    )
  let dormant =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [llm.Message(llm.User, [llm.Text("original task")])],
      status: agent.Completed,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("failed-compaction", "catalog", [dormant]),
    )
  let assert Ok(group) = agent_group.wake(loaded)

  let assert Ok(1) = agent_group.request_compaction(group, "agent")
  let assert Ok(Started(release)) = process.receive(gate, within: 2000)
  // Delivered while the compaction LLM call is in flight: lands in the
  // durable inbox and is folded into the conversation by the compaction
  // worker's next commit — even a failing one.
  let assert Ok(Nil) =
    agent_group.send_message(group, "agent", "queued during compaction")
  process.send(release, Nil)

  process.sleep(500)
  let assert Ok(snapshot) = agent_group.snapshot(group)
  let assert [state] = snapshot.agents
  // The failed compaction is recorded, and the queued message was processed
  // by a normal round instead of being stranded with no worker.
  let assert Some(_) = state.last_compaction_error
  assert state.compaction_completed == 0
  assert contains_user_text(state.messages, "queued during compaction")
  assert contains_text_fragment(state.messages, "processed anyway")
  assert state.status == agent.Completed
  let assert Ok(Nil) = agent_group.stop(group)
  remove_directory(root)
}

pub fn compaction_rerequest_survives_stale_worker_error_test() {
  let root = temporary_root("compaction-rerequest-test")
  let backend = local.new(local.config(root))
  let assert Ok(catalog) =
    model_catalog.put_model(model_catalog.new(), test_model())
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let compaction_gate = process.new_subject()
  let round_gate = process.new_subject()
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let compacting =
        contains_text_fragment(request.messages, "Create a handover summary")
      let after_round =
        contains_text_fragment(request.messages, "processed anyway")
      case compacting, after_round {
        // First compaction attempt: held open, then malformed → fails.
        True, False -> {
          let release = process.new_subject()
          process.send(compaction_gate, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          let assert Ok(Nil) = consume(llm.MessageStart("c1", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "not a handover"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
        // Second compaction attempt (the re-request): succeeds.
        True, True -> {
          let assert Ok(Nil) = consume(llm.MessageStart("c2", "test-model"))
          let assert Ok(Nil) =
            consume(llm.TextDelta(0, "<handover>second attempt</handover>"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
        // The normal round processing the queued message: held open so the
        // re-request lands while this worker is mid-round.
        False, _ -> {
          let release = process.new_subject()
          process.send(round_gate, Started(release))
          let assert Ok(Nil) = process.receive(release, within: 5000)
          let assert Ok(Nil) = consume(llm.MessageStart("m", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "processed anyway"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
      }
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
    agent_group.Config(
      backend,
      "groups/compaction-rerequest",
      [profile],
      10,
      60_000,
    )
  let dormant =
    agent.State(
      ..agent.state("agent", "model"),
      messages: [llm.Message(llm.User, [llm.Text("original task")])],
      status: agent.Completed,
    )
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("compaction-rerequest", "catalog", [dormant]),
    )
  let assert Ok(group) = agent_group.wake(loaded)

  let assert Ok(1) = agent_group.request_compaction(group, "agent")
  let assert Ok(Started(release_compaction)) =
    process.receive(compaction_gate, within: 2000)
  let assert Ok(Nil) =
    agent_group.send_message(group, "agent", "please continue")
  process.send(release_compaction, Nil)

  // The failed compaction folded the queued message in; the worker is now
  // held mid-round. A re-request accepted here durably clears the failure —
  // and the worker's round commit must not resurrect its stale error, or the
  // acknowledged request would never execute.
  let assert Ok(Started(release_round)) =
    process.receive(round_gate, within: 2000)
  let assert Ok(2) = agent_group.request_compaction(group, "agent")
  process.send(release_round, Nil)

  process.sleep(500)
  let assert Ok(snapshot) = agent_group.snapshot(group)
  let assert [state] = snapshot.agents
  assert state.compaction_completed == 2
  assert state.last_compaction_error == None
  let assert Some(context) = state.context_messages
  assert contains_text_fragment(context, "second attempt")
  assert contains_user_text(state.messages, "please continue")
  let assert Ok(Nil) = agent_group.stop(group)
  remove_directory(root)
}

pub fn automatic_compaction_counts_cached_context_test() {
  let root = temporary_root("cached-compaction-test")
  let backend = local.new(local.config(root))
  let model = model_catalog.Model(..test_model(), context_window_tokens: 100)
  let assert Ok(catalog) = model_catalog.put_model(model_catalog.new(), model)
  let assert Ok(_) = model_catalog.create(backend, "catalog", catalog)
  let assert Ok(registry) = plugin.registry([])
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let compacting =
        contains_text_fragment(request.messages, "Create a handover summary")
      let assert Ok(Nil) = consume(llm.MessageStart("m", "test-model"))
      let assert Ok(Nil) =
        consume(
          llm.TextDelta(0, case compacting {
            True -> "<handover>cached summary</handover>"
            False -> "answer"
          }),
        )
      let assert Ok(Nil) = case compacting {
        True -> Ok(Nil)
        False ->
          // input_tokens excludes cached tokens: only 8 new tokens, but the
          // cached prefix means the context is really 83/100 full.
          consume(
            llm.UsageReported(llm.Usage(
              input_tokens: Some(5),
              output_tokens: Some(3),
              cache_read_tokens: Some(60),
              cache_write_tokens: Some(15),
            )),
          )
      }
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
  let config =
    agent_group.Config(backend, "groups/cached-compaction", [profile], 10, 100)
  let assert Ok(loaded) =
    agent_group.create(
      config,
      agent_group.new("cached-compaction", "catalog", [
        agent.state("agent", "model"),
      ]),
    )
  let assert Ok(group) = agent_group.wake(loaded)
  await_down(process.monitor(agent_group.pid(group)))
  let assert Ok(snapshot) = agent_group.load(config)
  let assert [compacted] = snapshot.agents
  // Occupancy counts cache reads/writes, so automatic compaction fired even
  // though only 8 non-cached tokens were reported.
  assert compacted.compaction_completed == 1
  let assert Some(context) = compacted.context_messages
  assert contains_text_fragment(context, "cached summary")
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
