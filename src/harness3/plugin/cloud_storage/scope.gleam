import gleam/list
import gleam/string

/// A backend-key namespace rooted at one configurable storage prefix.
pub opaque type Scope {
  Scope(prefix: String)
}

/// Scopes object keys under an explicit storage prefix. The prefix must be a
/// non-empty safe relative path; a trailing slash is implied. An empty prefix
/// is rejected so a scope can never cover unrelated objects in the backend.
pub fn new(prefix: String) -> Result(Scope, String) {
  case prefix {
    "" -> Error("prefix must be a safe relative path")
    _ ->
      case validate_prefix(prefix) {
        Ok(Nil) -> Ok(Scope(ensure_trailing_slash(prefix)))
        Error(error) -> Error(error)
      }
  }
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

fn ensure_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> value
    False -> value <> "/"
  }
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
