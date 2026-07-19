import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Monitor, type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import harness3/agent
import harness3/agent_group
import harness3/llm
import harness3/model_catalog
import harness3/plugin
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

type GateMessage {
  Started(release: Subject(Nil))
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

fn crashing_gated_transport(gate: Subject(GateMessage)) -> agent.ModelTransport {
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
    |> process.selector_receive(5000)
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
  let assert Ok(registry) = plugin.registry([])
  let gate = process.new_subject()
  let definitions = [
    agent_group.AgentDefinition(
      id: "a",
      registry:,
      transport: gated_transport(gate, "A finished"),
      max_output_tokens: None,
      reasoning_effort: None,
      observe:,
    ),
    agent_group.AgentDefinition(
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
      catalog:,
      definitions:,
      lease_duration_seconds: 10,
    )
  let initial =
    agent_group.new("group", [
      agent.state("a", "model"),
      agent.state("b", "model"),
    ])
  let assert Ok(group) = agent_group.create(config, initial)
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
  let assert Ok(registry) = plugin.registry([])
  let crashing_gate = process.new_subject()
  let sibling_gate = process.new_subject()
  let config =
    agent_group.Config(
      storage:,
      object_key: "groups/crash",
      catalog:,
      definitions: [
        agent_group.AgentDefinition(
          id: "crashing",
          registry:,
          transport: crashing_gated_transport(crashing_gate),
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
        agent_group.AgentDefinition(
          id: "sibling",
          registry:,
          transport: gated_transport(sibling_gate, "never completed"),
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
    )
  let initial =
    agent_group.new("crash", [
      agent.state("crashing", "model"),
      agent.state("sibling", "model"),
    ])
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(started, agent_group.create(config, initial))
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
      catalog:,
      definitions: [
        agent_group.AgentDefinition(
          id: "agent",
          registry:,
          transport:,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
    )
  let assert Ok(group) =
    agent_group.create(
      config,
      agent_group.new("full-loop", [agent.state("agent", "model")]),
    )
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

  let receiver_plugin =
    plugin.new("receiver_plugin", "{\"calls\":0}")
    |> plugin.with_callback(
      plugin.callback_hook("ping", fn(state, context, input) {
        assert state == "{\"calls\":0}"
        assert input == "{}"
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
      catalog:,
      definitions: [
        agent_group.AgentDefinition(
          id: "caller",
          registry: caller_registry,
          transport: caller_transport,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
        agent_group.AgentDefinition(
          id: "receiver",
          registry: receiver_registry,
          transport: receiver_transport,
          max_output_tokens: None,
          reasoning_effort: None,
          observe:,
        ),
      ],
      lease_duration_seconds: 10,
    )
  let assert Ok(group) =
    agent_group.create(
      config,
      agent_group.new("cross-agent", [
        agent.state("caller", "model"),
        agent.state("receiver", "model"),
      ]),
    )
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
