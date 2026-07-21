import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness3/agent
import harness3/llm
import harness3/model_catalog
import harness3/plugin

type JournalEvent {
  Checkpoint(agent.CommitMode, agent.State)
  ToolInvoked
  WorkerExited
}

fn model() -> model_catalog.Model {
  model_catalog.Model(
    id: "model",
    name: "test-model",
    endpoint: "https://example.test",
    model_type: model_catalog.OpenAIResponses,
    credentials: model_catalog.api_key("secret"),
    context_window_tokens: 100_000,
    max_output_tokens: None,
  )
}

pub fn tool_journal_round_trips_and_recovers_running_calls_test() {
  let original =
    agent.State(
      ..agent.state("agent", "model"),
      tool_journal: Some(
        agent.ToolJournal([
          agent.ToolCompleted(
            "done",
            "test.done",
            "{}",
            [llm.Text("kept")],
            False,
            False,
          ),
          agent.ToolRunning("running", "test.running", "{\"value\":1}"),
          agent.ToolPending("later", "test.later", "{}"),
        ]),
      ),
    )
  let encoded = agent.encode_state(original) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, agent.state_decoder())
  assert decoded == original

  let recovered = agent.recover_tool_journal(decoded)
  let assert Some(agent.ToolJournal([
    agent.ToolCompleted(
      "done",
      "test.done",
      "{}",
      [llm.Text("kept")],
      False,
      False,
    ),
    agent.ToolCompleted(
      "running",
      "test.running",
      "{\"value\":1}",
      [llm.Text(unknown)],
      True,
      True,
    ),
    agent.ToolCompleted(
      "later",
      "test.later",
      "{}",
      [llm.Text(cancelled)],
      True,
      True,
    ),
  ])) = recovered.tool_journal
  assert string.contains(unknown, "outcome is unknown and may be partial")
  assert string.contains(cancelled, "This tool was not run")
}

pub fn pending_journal_is_unchanged_by_crash_recovery_test() {
  let state =
    agent.State(
      ..agent.state("agent", "model"),
      tool_journal: Some(
        agent.ToolJournal([
          agent.ToolPending("pending", "test.pending", "{}"),
        ]),
      ),
    )
  assert agent.recover_tool_journal(state) == state
}

pub fn worker_checkpoints_tool_call_and_running_before_invocation_test() {
  let events = process.new_subject()
  let tool =
    plugin.tool(
      llm.Tool(
        "test.effect",
        None,
        json.object([#("type", json.string("object"))]),
      ),
      fn(state, context, invocation) {
        process.send(events, ToolInvoked)
        assert invocation.id == "call-1"
        assert invocation.arguments == "{}"
        Ok(plugin.hook_result(
          state,
          context,
          plugin.ToolOutput([llm.Text("effect complete")], False),
        ))
      },
    )
  let assert Ok(registry) =
    plugin.registry(
      [plugin.new("effect", "{}")]
      |> list.map(fn(value) { plugin.with_tool(value, tool) }),
    )
  let transport =
    agent.model_transport(fn(_, request, consume) {
      let llm.Request(messages:, ..) = request
      let _ = case has_tool_result(messages) {
        False -> {
          let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
          let assert Ok(Nil) =
            consume(llm.ToolCallStart(0, "call-1", "test.effect"))
          let assert Ok(Nil) = consume(llm.ToolCallArgumentsDelta(0, "{}"))
          let assert Ok(Nil) = consume(llm.ContentStop(0))
          let assert Ok(Nil) = consume(llm.Finished(llm.ToolUse))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
        True -> {
          let assert Ok(Nil) = consume(llm.MessageStart("last", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "finished"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
        }
      }
      Ok(Nil)
    })
  let current_model = model()
  let config =
    agent.Config(
      provider: model_catalog.provider(current_model),
      model_name: current_model.name,
      catalog_revision: 0,
      registry:,
      transport:,
      max_output_tokens: None,
      reasoning_effort: None,
      context_window_tokens: current_model.context_window_tokens,
      group_context: agent.solo_group_context(),
    )
  let initial =
    agent.State(..agent.state("agent", "model"), messages: [
      llm.Message(llm.User, [llm.Text("run the effect")]),
    ])
  let assert Ok(active) = agent.activate(initial, config)
  let checkpointer =
    agent.checkpointer_with_mode(fn(expected, state, mode) {
      process.send(events, Checkpoint(mode, state))
      Ok(agent.CommitReceipt(
        agent.State(..state, revision: expected + 1),
        expected + 1,
      ))
    })
  let handle =
    agent.start(
      active,
      checkpointer,
      agent.callback_router(fn(_, _, _, _) { Ok("") }),
      fn(_) { Ok(Nil) },
      fn() { process.send(events, WorkerExited) },
    )
  agent.release(handle)

  let assert Ok(Checkpoint(agent.ToolProgressCommit, pending)) =
    process.receive(events, within: 1000)
  let assert Some(agent.ToolJournal([
    agent.ToolPending("call-1", "test.effect", "{}"),
  ])) = pending.tool_journal
  let assert [
    llm.Message(llm.User, _),
    llm.Message(llm.Assistant, [llm.ToolCall("call-1", "test.effect", _)]),
  ] = pending.messages

  let assert Ok(Checkpoint(agent.ToolProgressCommit, running)) =
    process.receive(events, within: 1000)
  let assert Some(agent.ToolJournal([
    agent.ToolRunning("call-1", "test.effect", "{}"),
  ])) = running.tool_journal
  assert process.receive(events, within: 1000) == Ok(ToolInvoked)

  let assert Ok(Checkpoint(agent.ToolProgressCommit, completed)) =
    process.receive(events, within: 1000)
  let assert Some(agent.ToolJournal([
    agent.ToolCompleted(
      "call-1",
      "test.effect",
      "{}",
      [llm.Text("effect complete")],
      False,
      False,
    ),
  ])) = completed.tool_journal

  let assert Ok(Checkpoint(agent.RoundCommit, finalized)) =
    process.receive(events, within: 1000)
  assert finalized.tool_journal == None
  let assert Ok(llm.Message(
    llm.ToolRole,
    [llm.ToolResult("call-1", [llm.Text("effect complete")], False)],
  )) = list.last(finalized.messages)

  let assert Ok(Checkpoint(agent.RoundCommit, finished)) =
    process.receive(events, within: 1000)
  assert finished.status == agent.Completed
  assert process.receive(events, within: 1000) == Ok(WorkerExited)
}

fn has_tool_result(messages: List(llm.Message)) -> Bool {
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

pub fn tool_started_observer_failure_closes_journal_and_fails_test() {
  assert_observer_failure_is_durable(False)
}

pub fn tool_finished_observer_failure_closes_journal_and_fails_test() {
  assert_observer_failure_is_durable(True)
}

fn assert_observer_failure_is_durable(fail_on_finished: Bool) {
  let events = process.new_subject()
  let tool =
    plugin.tool(
      llm.Tool(
        "test.effect",
        None,
        json.object([#("type", json.string("object"))]),
      ),
      fn(state, context, _) {
        process.send(events, ToolInvoked)
        Ok(plugin.hook_result(
          state,
          context,
          plugin.ToolOutput([llm.Text("effect complete")], False),
        ))
      },
    )
  let assert Ok(registry) =
    plugin.registry([plugin.new("effect", "{}") |> plugin.with_tool(tool)])
  let transport =
    agent.model_transport(fn(_, _, consume) {
      let assert Ok(Nil) = consume(llm.MessageStart("first", "test-model"))
      let assert Ok(Nil) =
        consume(llm.ToolCallStart(0, "call-1", "test.effect"))
      let assert Ok(Nil) = consume(llm.ToolCallArgumentsDelta(0, "{}"))
      let assert Ok(Nil) = consume(llm.ContentStop(0))
      let assert Ok(Nil) = consume(llm.Finished(llm.ToolUse))
      let assert Ok(Nil) = consume(llm.MessageStop)
      Ok(Nil)
    })
  let current_model = model()
  let config =
    agent.Config(
      provider: model_catalog.provider(current_model),
      model_name: current_model.name,
      catalog_revision: 0,
      registry:,
      transport:,
      max_output_tokens: None,
      reasoning_effort: None,
      context_window_tokens: current_model.context_window_tokens,
      group_context: agent.solo_group_context(),
    )
  let initial =
    agent.State(..agent.state("agent", "model"), messages: [
      llm.Message(llm.User, [llm.Text("run the effect")]),
    ])
  let assert Ok(active) = agent.activate(initial, config)
  let checkpointer =
    agent.checkpointer_with_mode(fn(expected, state, mode) {
      process.send(events, Checkpoint(mode, state))
      Ok(agent.CommitReceipt(
        agent.State(..state, revision: expected + 1),
        expected + 1,
      ))
    })
  let observe = fn(event) {
    case event, fail_on_finished {
      agent.ToolStarted(_, _), False ->
        Error(agent.ObserverFailed("started observer failed"))
      agent.ToolFinished(_, _, _), True ->
        Error(agent.ObserverFailed("finished observer failed"))
      _, _ -> Ok(Nil)
    }
  }
  let handle =
    agent.start(
      active,
      checkpointer,
      agent.callback_router(fn(_, _, _, _) { Ok("") }),
      observe,
      fn() { process.send(events, WorkerExited) },
    )
  agent.release(handle)

  let assert Ok(Checkpoint(agent.ToolProgressCommit, _)) =
    process.receive(events, within: 1000)
  let assert Ok(Checkpoint(agent.ToolProgressCommit, _)) =
    process.receive(events, within: 1000)
  case fail_on_finished {
    True -> {
      assert process.receive(events, within: 1000) == Ok(ToolInvoked)
      Nil
    }
    False -> Nil
  }
  let assert Ok(Checkpoint(agent.ToolProgressCommit, completed)) =
    process.receive(events, within: 1000)
  let assert Some(agent.ToolJournal([
    agent.ToolCompleted("call-1", "test.effect", "{}", content, is_error, False),
  ])) = completed.tool_journal
  case fail_on_finished {
    True -> {
      assert content == [llm.Text("effect complete")]
      assert is_error == False
      Nil
    }
    False -> {
      let assert [llm.Text(message)] = content
      assert is_error == True
      assert string.contains(message, "observer failed before invocation")
    }
  }
  let assert Ok(Checkpoint(agent.RoundCommit, failed)) =
    process.receive(events, within: 1000)
  assert failed.tool_journal == None
  let assert agent.Failed(reason) = failed.status
  assert string.contains(reason, "observer failed")
  assert process.receive(events, within: 1000) == Ok(WorkerExited)
  case fail_on_finished {
    True -> Nil
    False -> {
      assert process.receive(events, within: 20) == Error(Nil)
      Nil
    }
  }
}
