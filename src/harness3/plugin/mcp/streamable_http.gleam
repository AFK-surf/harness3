import exception
import gleam/erlang/process
import gleam/http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol

type State {
  State(
    endpoint: String,
    headers: List(#(String, String)),
    session_id: Option(String),
    next_id: Int,
  )
}

/// Bound for the best-effort session teardown on close.
const session_delete_milliseconds = 5000

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

type Message {
  Request(
    method: String,
    params: json.Json,
    deadline: Int,
    reply: process.Subject(Result(String, String)),
  )
  Notify(
    method: String,
    params: json.Json,
    deadline: Int,
    reply: process.Subject(Result(Nil, String)),
  )
  Stop
}

pub fn connect(
  server: configuration.Server,
  resolve_environment: fn(String) -> Result(String, Nil),
) -> Result(client.Connection, String) {
  let configuration.Server(transport:, ..) = server
  let assert configuration.StreamableHttp(endpoint, configured_headers) =
    transport
  use headers <- result.try(
    configuration.resolve_bindings(configured_headers, resolve_environment)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use started <- result.try(
    actor.new(State(endpoint, headers, None, 1))
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let subject = started.data
  Ok(
    client.connection(
      fn(method, params, timeout) {
        let deadline = monotonic_time(Millisecond) + timeout
        exception.rescue(fn() {
          process.call(subject, timeout + 1000, fn(reply) {
            Request(method, params, deadline, reply)
          })
        })
        |> result.map_error(fn(_) { "MCP HTTP client exited" })
        |> result.flatten
      },
      fn(method, params) {
        let timeout = 5000
        let deadline = monotonic_time(Millisecond) + timeout
        exception.rescue(fn() {
          process.call(subject, timeout + 1000, fn(reply) {
            Notify(method, params, deadline, reply)
          })
        })
        |> result.map_error(fn(_) { "MCP HTTP client exited" })
        |> result.flatten
      },
      fn() { process.send(subject, Stop) },
    )
    |> client.with_liveness(fn() {
      case process.subject_owner(subject) {
        Ok(pid) -> process.is_alive(pid)
        Error(_) -> False
      }
    }),
  )
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Request(method, params, deadline, reply) -> {
      let id = state.next_id
      let remaining = deadline - monotonic_time(Millisecond)
      let outcome = case remaining > 0 {
        True ->
          dispatch(
            state,
            protocol.request(id, method, params),
            remaining,
            False,
            id,
          )
        False ->
          Error(DispatchError(
            "MCP HTTP request timed out before dispatch",
            False,
          ))
      }
      let #(next, response) = case outcome {
        Ok(#(next, response)) -> #(next, Ok(response))
        Error(DispatchError(reason:, session_expired: True)) -> #(
          State(..state, session_id: None),
          Error(reason),
        )
        Error(DispatchError(reason:, ..)) -> #(state, Error(reason))
      }
      process.send(reply, response)
      actor.continue(State(..next, next_id: id + 1))
    }
    Notify(method, params, deadline, reply) -> {
      let remaining = deadline - monotonic_time(Millisecond)
      let outcome = case remaining > 0 {
        True ->
          dispatch(
            state,
            protocol.notification(method, params),
            remaining,
            True,
            0,
          )
        False ->
          Error(DispatchError(
            "MCP HTTP notification timed out before dispatch",
            False,
          ))
      }
      case outcome {
        Ok(#(next, _)) -> {
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
        Error(DispatchError(reason:, session_expired:)) -> {
          process.send(reply, Error(reason))
          case session_expired {
            True -> actor.continue(State(..state, session_id: None))
            False -> actor.continue(state)
          }
        }
      }
    }
    Stop -> {
      // Streamable HTTP sessions are server-side state: without an explicit
      // DELETE the peer keeps one per connection we ever opened, and
      // discovery opens a new one each time a manifest goes stale.
      delete_session(state)
      actor.stop()
    }
  }
}

fn delete_session(state: State) -> Nil {
  case state.session_id {
    None -> Nil
    Some(session) -> {
      let deleted = {
        use parsed <- result.try(
          uri.parse(state.endpoint) |> result.map_error(fn(_) { Nil }),
        )
        use request <- result.try(
          http_request.from_uri(parsed) |> result.map_error(fn(_) { Nil }),
        )
        let request =
          state.headers
          |> list.fold(request, fn(request, header) {
            http_request.set_header(request, header.0, header.1)
          })
          |> http_request.set_header("mcp-session-id", session)
          |> http_request.set_header(
            "mcp-protocol-version",
            configuration.protocol_version,
          )
          |> http_request.set_method(http.Delete)
          |> http_request.set_body("")
        httpc.configure()
        |> httpc.timeout(session_delete_milliseconds)
        |> httpc.dispatch(request)
        |> result.map_error(fn(_) { Nil })
      }
      // Best effort: the connection is going away regardless, and servers are
      // permitted to reject session termination.
      let _ = deleted
      Nil
    }
  }
}

/// `session_expired` marks a failure the caller recovers from by dropping the
/// session id, so the next request initializes a fresh session instead of
/// retrying against one the server has already discarded.
type DispatchError {
  DispatchError(reason: String, session_expired: Bool)
}

fn dispatch(
  state: State,
  body: String,
  timeout: Int,
  notification: Bool,
  request_id: Int,
) -> Result(#(State, String), DispatchError) {
  use parsed <- result.try(
    uri.parse(state.endpoint)
    |> result.map_error(fn(_) { DispatchError("invalid MCP URL", False) }),
  )
  use request <- result.try(
    http_request.from_uri(parsed)
    |> result.map_error(fn(_) { DispatchError("invalid MCP URL", False) }),
  )
  let request =
    state.headers
    |> list.fold(request, fn(request, header) {
      http_request.set_header(request, header.0, header.1)
    })
    |> http_request.set_header("accept", "application/json, text/event-stream")
    |> http_request.set_header("content-type", "application/json")
    |> http_request.set_header(
      "mcp-protocol-version",
      configuration.protocol_version,
    )
  let request = case state.session_id {
    Some(session) -> http_request.set_header(request, "mcp-session-id", session)
    None -> request
  }
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(timeout)
    |> httpc.dispatch(
      request
      |> http_request.set_method(http.Post)
      |> http_request.set_body(body),
    )
    |> result.map_error(fn(error) {
      DispatchError("MCP HTTP request failed: " <> string.inspect(error), False)
    }),
  )
  use _ <- result.try(case response.status {
    status if status >= 200 && status < 300 -> Ok(Nil)
    // The server dropped this session (expiry or restart). Flag it so the
    // caller clears the stale id rather than treating a recoverable state as
    // a dead server.
    404 if state.session_id != None ->
      Error(DispatchError(
        "MCP HTTP session expired: reinitialize required",
        True,
      ))
    status ->
      Error(DispatchError(
        "MCP HTTP request returned status "
          <> { status |> json.int |> json.to_string },
        False,
      ))
  })
  let next =
    State(
      ..state,
      session_id: case http_response.get_header(response, "mcp-session-id") {
        Ok(value) -> Some(value)
        Error(_) -> state.session_id
      },
    )
  case notification {
    True -> Ok(#(next, ""))
    False -> {
      let content_type =
        http_response.get_header(response, "content-type")
        |> result.unwrap("application/json")
      use document <- result.try(
        response_document(response.body, content_type, request_id)
        |> result.map_error(fn(reason) { DispatchError(reason, False) }),
      )
      Ok(#(next, document))
    }
  }
}

fn response_document(
  body: String,
  content_type: String,
  id: Int,
) -> Result(String, String) {
  let documents = case string.contains(content_type, "text/event-stream") {
    False -> [body]
    True ->
      body
      |> string.replace("\r\n", "\n")
      |> string.split("\n\n")
      |> list.filter_map(fn(frame) {
        let data =
          frame
          |> string.split("\n")
          |> list.filter_map(fn(line) {
            case line {
              "data:" <> value -> Ok(string.trim_start(value))
              _ -> Error(Nil)
            }
          })
          |> string.join("\n")
        case data {
          "" -> Error(Nil)
          _ -> Ok(data)
        }
      })
  }
  documents
  |> list.find(fn(document) { protocol.response_id(document) == Ok(id) })
  |> result.map_error(fn(_) {
    "MCP response did not contain the request result"
  })
}
