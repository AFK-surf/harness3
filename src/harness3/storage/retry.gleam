import gleam/erlang/process
import gleam/http/response.{type Response}
import gleam/int
import harness3/storage.{type Error, Transport}

const initial_delay_ms = 100

const maximum_delay_ms = 10_000

/// Bounded so a persistent outage surfaces as an error instead of blocking
/// the caller forever: coordinators perform storage writes inside their
/// message handlers, and every entry point behind them waits with no timeout,
/// so an unbounded retry here would wedge commits, message delivery, RPCs and
/// lease renewal cluster-wide. Eight attempts is ~13 s of backoff for
/// fast-failing errors. Worst case is larger: each attempt can additionally
/// spend the HTTP client's ~30 s response timeout against a hung-but-connected
/// backend (~4–5 min total), which can outlive a lease — safety then rests on
/// CAS fencing (the stalled owner's next write loses), not on this bound.
const maximum_attempts = 8

/// Runs a storage HTTP operation until it succeeds, produces a non-transient
/// response, or exhausts the retry budget. On exhaustion the last transient
/// outcome is returned (a transport error, or the transient HTTP response for
/// the backend to map to a status error).
pub fn http(
  operation: fn() -> Result(Response(BitArray), Error),
) -> Result(Response(BitArray), Error) {
  retry_http(operation, initial_delay_ms, maximum_attempts - 1)
}

fn retry_http(
  operation: fn() -> Result(Response(BitArray), Error),
  delay_ms: Int,
  remaining: Int,
) -> Result(Response(BitArray), Error) {
  case operation() {
    Error(Transport(_)) as failure ->
      case remaining > 0 {
        True -> retry_after(operation, delay_ms, remaining)
        False -> failure
      }
    Ok(response) ->
      case transient_status(response.status) && remaining > 0 {
        True -> retry_after(operation, delay_ms, remaining)
        False -> Ok(response)
      }
    Error(error) -> Error(error)
  }
}

fn retry_after(
  operation: fn() -> Result(Response(BitArray), Error),
  delay_ms: Int,
  remaining: Int,
) -> Result(Response(BitArray), Error) {
  // Jitter prevents several cluster nodes recovering at once from repeatedly
  // synchronizing their requests against the same backend.
  process.sleep(delay_ms + int.random(int.max(1, delay_ms / 2)))
  retry_http(operation, int.min(maximum_delay_ms, delay_ms * 2), remaining - 1)
}

fn transient_status(status: Int) -> Bool {
  status == 408
  || status == 421
  || status == 425
  || status == 429
  || { status >= 500 && status < 600 && status != 501 && status != 505 }
}
