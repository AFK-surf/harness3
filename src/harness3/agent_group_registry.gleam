import exception
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string

type TableName {
  Harness3AgentGroups
}

type TableOption {
  NamedTable
  Public
  Set
}

pub type StopHandle =
  fn() -> Result(Nil, String)

pub type MessageHandle =
  fn(String, String) -> Result(Nil, String)

pub type InjectToolCallHandle =
  fn(String, String, String, String) -> Result(Nil, String)

pub type CompactionHandle =
  fn(String) -> Result(Int, String)

pub type Error {
  NotFound(id: String)
  StopFailed(reason: String)
  MessageFailed(reason: String)
  InjectFailed(reason: String)
  CompactionFailed(reason: String)
}

type Entry =
  #(
    String,
    Pid,
    StopHandle,
    MessageHandle,
    InjectToolCallHandle,
    CompactionHandle,
  )

/// Registers a running agent group in the node-wide registry.
pub fn register(
  id: String,
  pid: Pid,
  stop: StopHandle,
  send_message: MessageHandle,
  inject_tool_call: InjectToolCallHandle,
  request_compaction: CompactionHandle,
) -> Nil {
  ensure_table()
  case
    exception.rescue(fn() {
      ets_insert(Harness3AgentGroups, #(
        id,
        pid,
        stop,
        send_message,
        inject_tool_call,
        request_compaction,
      ))
    })
  {
    Ok(_) -> Nil
    Error(_) ->
      register(
        id,
        pid,
        stop,
        send_message,
        inject_tool_call,
        request_compaction,
      )
  }
}

/// Removes this exact registration without disturbing a newer PID for the ID.
pub fn unregister(id: String, pid: Pid) -> Nil {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Ok([#(_, registered_pid, _, _, _, _) as entry]) if registered_pid == pid -> {
      let _ =
        exception.rescue(fn() { ets_delete_object(Harness3AgentGroups, entry) })
      Nil
    }
    Ok(_) -> Nil
    Error(_) -> unregister(id, pid)
  }
}

pub fn force_stop(id: String) -> Result(Nil, Error) {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Error(_) -> force_stop(id)
    Ok([]) -> Error(NotFound(id))
    Ok([#(_, pid, stop, _, _, _) as entry]) ->
      case process.is_alive(pid) {
        False -> {
          let _ = ets_delete_object(Harness3AgentGroups, entry)
          Error(NotFound(id))
        }
        True ->
          case exception.rescue(stop) {
            Error(error) -> Error(StopFailed(string.inspect(error)))
            Ok(Error(reason)) -> Error(StopFailed(reason))
            Ok(Ok(Nil)) -> Ok(Nil)
          }
      }
    Ok(_) -> Error(NotFound(id))
  }
}

pub fn send_message(
  id: String,
  agent_id: String,
  message: String,
) -> Result(Nil, Error) {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Error(_) -> send_message(id, agent_id, message)
    Ok([]) -> Error(NotFound(id))
    Ok([#(_, pid, _, send, _, _) as entry]) ->
      case process.is_alive(pid) {
        False -> {
          let _ = ets_delete_object(Harness3AgentGroups, entry)
          Error(NotFound(id))
        }
        True ->
          case exception.rescue(fn() { send(agent_id, message) }) {
            Error(error) -> Error(MessageFailed(string.inspect(error)))
            Ok(Error(reason)) -> Error(MessageFailed(reason))
            Ok(Ok(Nil)) -> Ok(Nil)
          }
      }
    Ok(_) -> Error(NotFound(id))
  }
}

/// Injects a synthetic tool call and its result into a running group's agent.
pub fn inject_tool_call(
  id: String,
  agent_id: String,
  tool_name: String,
  arguments: String,
  response: String,
) -> Result(Nil, Error) {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Error(_) -> inject_tool_call(id, agent_id, tool_name, arguments, response)
    Ok([]) -> Error(NotFound(id))
    Ok([#(_, pid, _, _, inject, _) as entry]) ->
      case process.is_alive(pid) {
        False -> {
          let _ = ets_delete_object(Harness3AgentGroups, entry)
          Error(NotFound(id))
        }
        True ->
          case
            exception.rescue(fn() {
              inject(agent_id, tool_name, arguments, response)
            })
          {
            Error(error) -> Error(InjectFailed(string.inspect(error)))
            Ok(Error(reason)) -> Error(InjectFailed(reason))
            Ok(Ok(Nil)) -> Ok(Nil)
          }
      }
    Ok(_) -> Error(NotFound(id))
  }
}

pub fn request_compaction(id: String, agent_id: String) -> Result(Int, Error) {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Error(_) -> request_compaction(id, agent_id)
    Ok([]) -> Error(NotFound(id))
    Ok([#(_, pid, _, _, _, compact) as entry]) ->
      case process.is_alive(pid) {
        False -> {
          let _ = ets_delete_object(Harness3AgentGroups, entry)
          Error(NotFound(id))
        }
        True ->
          case exception.rescue(fn() { compact(agent_id) }) {
            Error(error) -> Error(CompactionFailed(string.inspect(error)))
            Ok(Error(reason)) -> Error(CompactionFailed(reason))
            Ok(Ok(generation)) -> Ok(generation)
          }
      }
    Ok(_) -> Error(NotFound(id))
  }
}

/// Returns live group IDs and removes records whose processes have exited.
pub fn alive_ids() -> List(String) {
  ensure_table()
  case exception.rescue(fn() { ets_entries(Harness3AgentGroups) }) {
    Error(_) -> alive_ids()
    Ok(entries) ->
      entries
      |> list.filter_map(fn(entry) {
        case process.is_alive(entry.1) {
          True -> Ok(entry.0)
          False -> {
            unregister(entry.0, entry.1)
            Error(Nil)
          }
        }
      })
      |> list.sort(string.compare)
  }
}

fn ensure_table() -> Nil {
  case table_exists() {
    True -> Nil
    False -> {
      let _ =
        process.spawn_unlinked(fn() {
          case
            exception.rescue(fn() {
              ets_new(Harness3AgentGroups, [NamedTable, Public, Set])
            })
          {
            Ok(_) -> process.sleep_forever()
            Error(_) -> Nil
          }
        })
      wait_for_table()
    }
  }
}

fn wait_for_table() -> Nil {
  case table_exists() {
    True -> Nil
    False -> {
      process.sleep(1)
      wait_for_table()
    }
  }
}

fn table_exists() -> Bool {
  case
    exception.rescue(fn() {
      let _ = ets_entries(Harness3AgentGroups)
      Nil
    })
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

@external(erlang, "ets", "new")
fn ets_new(name: TableName, options: List(TableOption)) -> Dynamic

@external(erlang, "ets", "insert")
fn ets_insert(table: TableName, entry: Entry) -> Bool

@external(erlang, "ets", "delete_object")
fn ets_delete_object(table: TableName, entry: Entry) -> Bool

@external(erlang, "ets", "lookup")
fn lookup(table: TableName, id: String) -> List(Entry)

@external(erlang, "ets", "tab2list")
fn ets_entries(table: TableName) -> List(Entry)
