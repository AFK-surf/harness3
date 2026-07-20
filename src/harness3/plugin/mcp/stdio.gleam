import child_process
import child_process/stdio as process_stdio
import exception
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import harness3/plugin/mcp/client
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/protocol

type Pending {
  Pending(id: Int, reply: Subject(Result(String, String)))
}

type State {
  State(
    process: child_process.Process,
    self: Subject(Message),
    next_id: Int,
    pending: List(Pending),
  )
}

type Message {
  Request(
    method: String,
    params: json.Json,
    timeout: Int,
    reply: Subject(Result(String, String)),
  )
  Notify(method: String, params: json.Json, reply: Subject(Result(Nil, String)))
  Received(line: String)
  Exited(status: Int)
  TimedOut(id: Int)
  Stop
}

pub fn connect(
  server: configuration.Server,
  resolve_environment: fn(String) -> Result(String, Nil),
) -> Result(client.Connection, String) {
  let configuration.Server(transport:, ..) = server
  let assert configuration.Stdio(
    executable,
    arguments,
    working_directory,
    environment,
  ) = transport
  use environment <- result.try(
    configuration.resolve_bindings(environment, resolve_environment)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let started =
    actor.new_with_initialiser(5000, fn(subject) {
      let output =
        process_stdio.lines(fn(line) { process.send(subject, Received(line)) })
        |> process_stdio.capture_stderr(False)
        |> process_stdio.on_exit(fn(status) {
          process.send(subject, Exited(status))
        })
      let builder =
        child_process.from_file(executable)
        |> child_process.args(arguments)
        |> child_process.envs(environment)
      let builder = case working_directory {
        Some(directory) -> child_process.cwd(builder, directory)
        None -> builder
      }
      use child <- result.try(
        child_process.spawn(builder, stdio: output)
        |> result.map_error(child_process.describe_start_error),
      )
      Ok(
        actor.initialised(State(child, subject, 1, []))
        |> actor.returning(subject),
      )
    })
    |> actor.on_message(handle_message)
    |> actor.start
  use actor <- result.try(
    started |> result.map_error(fn(error) { string.inspect(error) }),
  )
  let subject = actor.data
  Ok(
    client.connection(
      fn(method, params, timeout) {
        exception.rescue(fn() {
          process.call(subject, timeout + 1000, fn(reply) {
            Request(method, params, timeout, reply)
          })
        })
        |> result.map_error(fn(_) { "MCP stdio request process exited" })
        |> result.flatten
      },
      fn(method, params) {
        exception.rescue(fn() {
          process.call(subject, 5000, fn(reply) {
            Notify(method, params, reply)
          })
        })
        |> result.map_error(fn(_) { "MCP stdio process exited" })
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
    Request(method, params, timeout, reply) -> {
      let id = state.next_id
      case
        child_process.writeln(
          state.process,
          protocol.request(id, method, params),
        )
      {
        Ok(Nil) -> {
          process.send_after(state.self, timeout, TimedOut(id))
          actor.continue(
            State(..state, next_id: id + 1, pending: [
              Pending(id, reply),
              ..state.pending
            ]),
          )
        }
        Error(error) -> {
          process.send(reply, Error(child_process.describe_write_error(error)))
          actor.continue(state)
        }
      }
    }
    Notify(method, params, reply) -> {
      let outcome =
        child_process.writeln(
          state.process,
          protocol.notification(method, params),
        )
        |> result.map_error(child_process.describe_write_error)
      process.send(reply, outcome)
      actor.continue(state)
    }
    Received(line) -> {
      let document = string.trim(line)
      case protocol.response_id(document) {
        Error(_) -> actor.continue(state)
        Ok(id) ->
          case take_pending(state.pending, id, []) {
            None -> actor.continue(state)
            Some(#(pending, remaining)) -> {
              process.send(pending.reply, Ok(document))
              actor.continue(State(..state, pending: remaining))
            }
          }
      }
    }
    TimedOut(id) ->
      case take_pending(state.pending, id, []) {
        None -> actor.continue(state)
        Some(#(pending, remaining)) -> {
          process.send(pending.reply, Error("MCP stdio request timed out"))
          let _ =
            child_process.writeln(
              state.process,
              protocol.notification(
                "notifications/cancelled",
                json.object([#("requestId", json.int(id))]),
              ),
            )
          actor.continue(State(..state, pending: remaining))
        }
      }
    Exited(status) -> {
      list.each(state.pending, fn(pending) {
        process.send(
          pending.reply,
          Error("MCP stdio server exited with status " <> int_string(status)),
        )
      })
      actor.stop()
    }
    Stop -> {
      child_process.close(state.process)
      child_process.stop(state.process)
      actor.stop()
    }
  }
}

fn take_pending(
  pending: List(Pending),
  id: Int,
  before: List(Pending),
) -> Option(#(Pending, List(Pending))) {
  case pending {
    [] -> None
    [item, ..rest] if item.id == id -> Some(#(item, list.append(before, rest)))
    [item, ..rest] -> take_pending(rest, id, [item, ..before])
  }
}

fn int_string(value: Int) -> String {
  value |> json.int |> json.to_string
}
