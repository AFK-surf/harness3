import gleam/bit_array
import gleam/list
import gleam/string

const namespace = "plugins/cloud_storage/groups/"

/// A backend-key namespace belonging to one agent group.
pub opaque type Scope {
  Scope(prefix: String)
}

pub fn new(group_id: String) -> Scope {
  let encoded_group_id =
    group_id
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  Scope(namespace <> "g-" <> encoded_group_id <> "/objects/")
}

pub fn object_key(scope: Scope, key: String) -> Result(String, String) {
  case validate_key(key) {
    Ok(Nil) -> Ok(prefix(scope) <> key)
    Error(error) -> Error(error)
  }
}

pub fn list_prefix(
  scope: Scope,
  logical_prefix: String,
) -> Result(String, String) {
  case validate_prefix(logical_prefix) {
    Ok(Nil) -> Ok(prefix(scope) <> logical_prefix)
    Error(error) -> Error(error)
  }
}

pub fn logical_key(scope: Scope, backend_key: String) -> Result(String, Nil) {
  let prefix = prefix(scope)
  case string.starts_with(backend_key, prefix) {
    True -> Ok(string.drop_start(backend_key, string.length(prefix)))
    False -> Error(Nil)
  }
}

pub fn validate_key(key: String) -> Result(Nil, String) {
  validate_path(key, False)
}

pub fn validate_prefix(value: String) -> Result(Nil, String) {
  validate_path(value, True)
}

fn prefix(scope: Scope) -> String {
  let Scope(prefix:) = scope
  prefix
}

fn validate_path(value: String, allow_empty: Bool) -> Result(Nil, String) {
  case value == "" && allow_empty {
    True -> Ok(Nil)
    False -> {
      let trimmed = case string.ends_with(value, "/") {
        True -> string.drop_end(value, 1)
        False -> value
      }
      let segments = string.split(trimmed, "/")
      case
        value == ""
        || string.starts_with(value, "/")
        || { string.ends_with(value, "/") && !allow_empty }
        || string.contains(value, "\\")
        || string.contains(value, "\u{0}")
        || list.any(segments, invalid_segment)
      {
        True -> Error("key must be a safe relative path")
        False -> Ok(Nil)
      }
    }
  }
}

fn invalid_segment(segment: String) -> Bool {
  segment == "" || segment == "." || segment == ".."
}
