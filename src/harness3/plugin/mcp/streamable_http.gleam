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
    ),
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
        False -> Error("MCP HTTP request timed out before dispatch")
      }
      let #(next, response) = case outcome {
        Ok(#(next, response)) -> #(next, Ok(response))
        Error(error) -> #(state, Error(error))
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
        False -> Error("MCP HTTP notification timed out before dispatch")
      }
      case outcome {
        Ok(#(next, _)) -> {
          process.send(reply, Ok(Nil))
          actor.continue(next)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Stop -> actor.stop()
  }
}

fn dispatch(
  state: State,
  body: String,
  timeout: Int,
  notification: Bool,
  request_id: Int,
) -> Result(#(State, String), String) {
  use parsed <- result.try(
    uri.parse(state.endpoint) |> result.map_error(fn(_) { "invalid MCP URL" }),
  )
  use request <- result.try(
    http_request.from_uri(parsed)
    |> result.map_error(fn(_) { "invalid MCP URL" }),
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
      "MCP HTTP request failed: " <> string.inspect(error)
    }),
  )
  use _ <- result.try(case response.status >= 200 && response.status < 300 {
    True -> Ok(Nil)
    False ->
      Error(
        "MCP HTTP request returned status "
        <> { response.status |> json.int |> json.to_string },
      )
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
      use document <- result.try(response_document(
        response.body,
        content_type,
        request_id,
      ))
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
