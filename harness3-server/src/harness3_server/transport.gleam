import gleam/http
import gleam/http/request as http_request
import gleam/httpc
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import harness3/agent
import harness3/llm
import harness3/llm/retry_policy

pub fn buffered_http(timeout_milliseconds: Int) -> agent.ModelTransport {
  agent.model_transport(fn(provider, request, consume) {
    // The standard Erlang client buffers responses. Asking providers for a
    // non-streaming response keeps this transport small and deterministic;
    // harness3's provider decoders still normalize it into the same events.
    let request = llm.Request(..request, stream: False)
    use outbound <- result.try(
      llm.build_request(provider, request)
      |> result.map_error(fn(error) {
        agent.PermanentTransportError(
          "invalid model request: " <> string.inspect(error),
        )
      }),
    )
    use uri <- result.try(
      uri.parse(outbound.url)
      |> result.map_error(fn(_) {
        agent.PermanentTransportError("invalid model URL")
      }),
    )
    use http_request <- result.try(
      http_request.from_uri(uri)
      |> result.map_error(fn(_) {
        agent.PermanentTransportError("invalid model URL")
      }),
    )
    use method <- result.try(case outbound.method {
      "POST" -> Ok(http.Post)
      "GET" -> Ok(http.Get)
      _ -> Error(agent.PermanentTransportError("unsupported model HTTP method"))
    })
    let http_request =
      outbound.headers
      |> list.fold(http_request, fn(request, header) {
        http_request.set_header(request, header.0, header.1)
      })
      |> http_request.set_method(method)
      |> http_request.set_body(outbound.body)
    use response <- result.try(
      httpc.configure()
      |> httpc.timeout(timeout_milliseconds)
      |> httpc.dispatch(http_request)
      |> result.map_error(fn(error) {
        agent.RetryableTransportError(
          "model HTTP request failed: " <> string.inspect(error),
        )
      }),
    )
    use _ <- result.try(case retry_policy.status_is_retryable(response.status) {
      True ->
        Error(agent.RetryableTransportError(
          "model HTTP request returned retryable status "
          <> string.inspect(response.status),
        ))
      False -> Ok(Nil)
    })
    use events <- result.try(
      llm.decode_response(provider, response.status, response.body)
      |> result.map_error(fn(error) {
        let reason = "model response failed: " <> string.inspect(error)
        case retry_policy.response_error_is_retryable(response.status, error) {
          True -> agent.RetryableTransportError(reason)
          False -> agent.PermanentTransportError(reason)
        }
      }),
    )
    events
    |> list.try_each(consume)
    |> result.map_error(fn(error) {
      agent.PermanentTransportError(
        "model event consumer failed: " <> string.inspect(error),
      )
    })
  })
}
