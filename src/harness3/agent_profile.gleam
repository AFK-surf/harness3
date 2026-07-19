import exception
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import harness3/agent
import harness3/plugin

pub type AgentProfile {
  AgentProfile(
    id: String,
    registry: plugin.Registry,
    transport: agent.ModelTransport,
    max_output_tokens: Option(Int),
    reasoning_effort: Option(String),
    observe: fn(agent.Event) -> Result(Nil, agent.Error),
  )
}

pub type Error {
  MissingProfile(id: String)
}

type ProfilesTable {
  Harness3AgentProfiles
}

type TableOption {
  NamedTable
  Public
  Set
}

/// Installs agent profiles on this node, keyed by their persisted IDs.
pub fn install(profiles: List(AgentProfile)) -> Nil {
  ensure_tables()
  list.each(profiles, fn(profile) {
    insert_profile(Harness3AgentProfiles, #(profile.id, profile))
  })
}

pub fn profiles(ids: List(String)) -> Result(List(AgentProfile), Error) {
  ensure_tables()
  list.try_map(ids, fn(id) {
    case lookup_profile(Harness3AgentProfiles, id) {
      [#(_, profile)] -> Ok(profile)
      _ -> Error(MissingProfile(id))
    }
  })
}

fn ensure_tables() -> Nil {
  case tables_exist() {
    True -> Nil
    False -> {
      let _ =
        process.spawn_unlinked(fn() {
          case
            exception.rescue(fn() {
              new_profiles_table(Harness3AgentProfiles, [
                NamedTable,
                Public,
                Set,
              ])
            })
          {
            Ok(_) -> process.sleep_forever()
            Error(_) -> Nil
          }
        })
      wait_for_tables()
    }
  }
}

fn wait_for_tables() -> Nil {
  case tables_exist() {
    True -> Nil
    False -> {
      process.sleep(1)
      wait_for_tables()
    }
  }
}

fn tables_exist() -> Bool {
  case
    exception.rescue(fn() {
      let _ = profile_entries(Harness3AgentProfiles)
      Nil
    })
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

@external(erlang, "ets", "new")
fn new_profiles_table(
  name: ProfilesTable,
  options: List(TableOption),
) -> Dynamic

@external(erlang, "ets", "insert")
fn insert_profile(table: ProfilesTable, entry: #(String, AgentProfile)) -> Bool

@external(erlang, "ets", "lookup")
fn lookup_profile(
  table: ProfilesTable,
  id: String,
) -> List(#(String, AgentProfile))

@external(erlang, "ets", "tab2list")
fn profile_entries(table: ProfilesTable) -> List(#(String, AgentProfile))
