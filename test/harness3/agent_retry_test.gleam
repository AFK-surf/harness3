import exception
import gleam/erlang/process
import gleam/option.{None}
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
  )
}

fn callback_router() -> agent.CallbackRouter {
  agent.callback_router(fn(_, _, _, _) { Ok("") })
}

fn observe(_event: agent.Event) -> Result(Nil, agent.Error) {
  Ok(Nil)
}

pub fn retryable_transport_errors_retry_until_the_call_succeeds_test() {
  let outcomes = process.new_subject()
  let attempts = process.new_subject()
  process.send(outcomes, False)
  process.send(outcomes, False)
  process.send(outcomes, True)

  let transport =
    agent.model_transport(fn(_, request, consume) {
      process.send(attempts, request)
      let assert Ok(succeeds) = process.receive(outcomes, within: 1000)
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
  use <- exception.defer(fn() { agent.discard(active) })

  let assert Ok(agent.RoundResult(state:, disposition:, ..)) =
    agent.run_round(active, callback_router(), observe)
  assert disposition == agent.Complete
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
  use <- exception.defer(fn() { agent.discard(active) })

  let assert Error(agent.ModelTransportFailed("bad credentials")) =
    agent.run_round(active, callback_router(), observe)
  let assert Ok(Nil) = process.receive(attempts, within: 1000)
  assert process.receive(attempts, within: 100) == Error(Nil)
}
