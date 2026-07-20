import gleam/int
import gleam/list
import harness3/llm

const initial_delay_ms = 100

const maximum_delay_ms = 10_000

/// Initial delay before retrying a transient LLM call failure.
pub fn initial_delay_milliseconds() -> Int {
  initial_delay_ms
}

/// Doubles an LLM retry delay while enforcing the ten-second cap.
pub fn next_delay_milliseconds(current: Int) -> Int {
  int.min(maximum_delay_ms, int.max(initial_delay_ms, current * 2))
}

/// Whether an HTTP response status represents a transient LLM service error.
pub fn status_is_retryable(status: Int) -> Bool {
  status == 408
  || status == 409
  || status == 421
  || status == 425
  || status == 429
  || { status >= 500 && status < 600 && status != 501 && status != 505 }
}

/// Classifies a provider decoder failure using both the HTTP response and the
/// structured provider error. Malformed successful responses are transient;
/// malformed permanent HTTP errors are not.
pub fn response_error_is_retryable(
  response_status: Int,
  error: llm.Error,
) -> Bool {
  case error {
    llm.ApiError(status, kind, _) ->
      status_is_retryable(response_status)
      || status_is_retryable(status)
      || list.contains(retryable_error_kinds, kind)
    llm.InvalidResponse(_) ->
      status_is_retryable(response_status)
      || { response_status >= 200 && response_status < 300 }
    llm.InvalidRequest(_) | llm.Unsupported(_) -> False
  }
}

const retryable_error_kinds = [
  "overloaded_error",
  "rate_limit_error",
  "server_error",
  "service_unavailable",
  "timeout_error",
]
