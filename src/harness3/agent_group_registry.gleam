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

pub type Error {
  NotFound(id: String)
  StopFailed(reason: String)
}

/// Registers a running agent group in the node-wide registry.
pub fn register(id: String, pid: Pid, stop: StopHandle) -> Nil {
  ensure_table()
  case
    exception.rescue(fn() { ets_insert(Harness3AgentGroups, #(id, pid, stop)) })
  {
    Ok(_) -> Nil
    Error(_) -> register(id, pid, stop)
  }
}

/// Removes this exact registration without disturbing a newer PID for the ID.
pub fn unregister(id: String, pid: Pid) -> Nil {
  ensure_table()
  case exception.rescue(fn() { lookup(Harness3AgentGroups, id) }) {
    Ok([#(_, registered_pid, _) as entry]) if registered_pid == pid -> {
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
    Ok([#(_, pid, stop) as entry]) ->
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
fn ets_insert(table: TableName, entry: #(String, Pid, StopHandle)) -> Bool

@external(erlang, "ets", "delete_object")
fn ets_delete_object(
  table: TableName,
  entry: #(String, Pid, StopHandle),
) -> Bool

@external(erlang, "ets", "lookup")
fn lookup(table: TableName, id: String) -> List(#(String, Pid, StopHandle))

@external(erlang, "ets", "tab2list")
fn ets_entries(table: TableName) -> List(#(String, Pid, StopHandle))
