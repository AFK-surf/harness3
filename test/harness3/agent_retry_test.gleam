import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/otp/actor
import gleam/string
import harness3/agent
import harness3/llm
import harness3/model_catalog
import harness3/plugin

fn test_model() -> model_catalog.Model {
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

fn config(transport: agent.ModelTransport) -> agent.Config {
  let model = test_model()
  let assert Ok(registry) = plugin.registry([])
  agent.Config(
    provider: model_catalog.provider(model),
    model_name: model.name,
    catalog_revision: 0,
    registry:,
    transport:,
    max_output_tokens: None,
    reasoning_effort: None,
    context_window_tokens: model.context_window_tokens,
    group_context: agent.solo_group_context(),
  )
}

fn callback_router() -> agent.CallbackRouter {
  agent.callback_router(fn(_, _, _, _) { Ok("") })
}

fn observe(_event: agent.Event) -> Result(Nil, agent.Error) {
  Ok(Nil)
}

type OutcomeMessage {
  NextOutcome(reply: Subject(Bool))
}

/// Serves a scripted list of transport outcomes. The transport runs in the
/// worker process, so it cannot receive on a test-owned subject; an actor
/// answers calls from any process.
fn outcome_server(outcomes: List(Bool)) -> Subject(OutcomeMessage) {
  let assert Ok(started) =
    actor.new(outcomes)
    |> actor.on_message(fn(state, message) {
      let NextOutcome(reply) = message
      case state {
        [head, ..rest] -> {
          process.send(reply, head)
          actor.continue(rest)
        }
        [] -> {
          process.send(reply, True)
          actor.continue([])
        }
      }
    })
    |> actor.start
  started.data
}

/// Runs a worker over the given active agent with an in-memory checkpointer
/// until it exits, and returns the last committed state.
fn run_to_exit(active: agent.Active, commits: Subject(agent.State)) -> Nil {
  let exits = process.new_subject()
  let checkpoint =
    agent.checkpointer(fn(expected, state) {
      let committed = agent.State(..state, revision: expected + 1)
      process.send(commits, committed)
      Ok(agent.CommitReceipt(committed, expected + 1))
    })
  let handle =
    agent.start(active, checkpoint, callback_router(), observe, fn() {
      process.send(exits, Nil)
    })
  agent.release(handle)
  let assert Ok(Nil) = process.receive(exits, within: 5000)
  Nil
}

pub fn retryable_transport_errors_retry_until_the_call_succeeds_test() {
  let outcomes = outcome_server([False, False, True])
  let attempts = process.new_subject()

  let transport =
    agent.model_transport(fn(_, request, consume) {
      process.send(attempts, request)
      let succeeds = process.call_forever(outcomes, NextOutcome)
      case succeeds {
        False -> Error(agent.RetryableTransportError("temporary outage"))
        True -> {
          let assert Ok(Nil) =
            consume(llm.MessageStart("message", "test-model"))
          let assert Ok(Nil) = consume(llm.TextDelta(0, "finished"))
          let assert Ok(Nil) = consume(llm.Finished(llm.Stop))
          let assert Ok(Nil) = consume(llm.MessageStop)
          Ok(Nil)
        }
      }
    })
  let initial =
    agent.State(..agent.state("agent", "model"), messages: [
      llm.Message(llm.User, [llm.Text("task")]),
    ])
  let assert Ok(active) = agent.activate(initial, config(transport))

  let commits = process.new_subject()
  run_to_exit(active, commits)
  let assert Ok(state) = process.receive(commits, within: 1000)
  assert state.status == agent.Completed
  let assert [
    llm.Message(llm.User, [llm.Text("task")]),
    llm.Message(llm.Assistant, [llm.Text("finished")]),
  ] = state.messages

  let assert Ok(first) = process.receive(attempts, within: 1000)
  let assert Ok(second) = process.receive(attempts, within: 1000)
  let assert Ok(third) = process.receive(attempts, within: 1000)
  assert first == second
  assert second == third
}

pub fn permanent_transport_errors_are_not_retried_test() {
  let attempts = process.new_subject()
  let transport =
    agent.model_transport(fn(_, _, _) {
      process.send(attempts, Nil)
      Error(agent.PermanentTransportError("bad credentials"))
    })
  let assert Ok(active) =
    agent.activate(agent.state("agent", "model"), config(transport))

  let commits = process.new_subject()
  run_to_exit(active, commits)
  let assert Ok(state) = process.receive(commits, within: 1000)
  let assert agent.Failed(reason) = state.status
  assert string.contains(reason, "ModelTransportFailed")
  assert string.contains(reason, "bad credentials")
  let assert Ok(Nil) = process.receive(attempts, within: 1000)
  assert process.receive(attempts, within: 100) == Error(Nil)
}
