import gleam/erlang/process
import gleam/http/response.{type Response}
import gleam/int
import harness3/storage.{type Error, Transport}

const initial_delay_ms = 100

const maximum_delay_ms = 10_000

/// Runs a storage HTTP operation until it either succeeds or produces a
/// non-transient response. Transport failures and transient HTTP responses are
/// deliberately never exposed to storage callers.
pub fn http(
  operation: fn() -> Result(Response(BitArray), Error),
) -> Result(Response(BitArray), Error) {
  retry_http(operation, initial_delay_ms)
}

fn retry_http(
  operation: fn() -> Result(Response(BitArray), Error),
  delay_ms: Int,
) -> Result(Response(BitArray), Error) {
  case operation() {
    Error(Transport(_)) -> retry_after(operation, delay_ms)
    Ok(response) ->
      case transient_status(response.status) {
        True -> retry_after(operation, delay_ms)
        False -> Ok(response)
      }
    Error(error) -> Error(error)
  }
}

fn retry_after(
  operation: fn() -> Result(Response(BitArray), Error),
  delay_ms: Int,
) -> Result(Response(BitArray), Error) {
  // Jitter prevents several cluster nodes recovering at once from repeatedly
  // synchronizing their requests against the same backend.
  process.sleep(delay_ms + int.random(int.max(1, delay_ms / 2)))
  retry_http(operation, int.min(maximum_delay_ms, delay_ms * 2))
}

fn transient_status(status: Int) -> Bool {
  status == 408
  || status == 421
  || status == 425
  || status == 429
  || { status >= 500 && status < 600 && status != 501 && status != 505 }
}
