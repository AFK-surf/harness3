import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import harness3/plugin/cloud_storage/scope
import harness3/storage.{type Storage, type VersionToken}

/// A named, independently configurable cloud storage prefix that agent groups
/// can be associated with. The prefix is normalized to end with `/`.
pub type Workspace {
  Workspace(id: String, label: String, prefix: String)
}

pub type Catalog {
  Catalog(revision: Int, workspaces: List(Workspace))
}

pub type Error {
  InvalidWorkspace(reason: String)
  DuplicateWorkspace(id: String)
  UnknownWorkspace(id: String)
  StorageFailed(error: storage.Error)
  InvalidStoredCatalog(reason: String)
  ConcurrentUpdate
}

pub opaque type Session {
  Session(
    storage: Storage,
    key: String,
    catalog: Catalog,
    version: VersionToken,
  )
}

/// Namespaces that carry harness3 control-plane objects. A workspace prefix
/// overlapping one of them would hand agent tools raw access to group state,
/// catalogs, locks, and membership records, so it is rejected.
const reserved_prefixes = ["cluster/", "harness3-server/"]

pub fn new() -> Catalog {
  Catalog(0, [])
}

/// The prefix suggested for a new workspace. Workspace IDs are restricted to
/// URL-safe characters, so the ID can be embedded readably; operators may
/// still point a workspace at any other safe prefix.
pub fn default_prefix(id: String) -> String {
  "plugins/cloud_storage/workspaces/" <> id <> "/objects/"
}

pub fn create(
  storage: Storage,
  key: String,
  catalog: Catalog,
) -> Result(Session, Error) {
  use _ <- result.try(validate(catalog))
  let body = encode(catalog) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case storage.put(storage, key, body, storage.IfAbsent) {
      Ok(metadata) -> Ok(metadata)
      Error(storage.PreconditionFailed(_)) -> confirm_write(storage, key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(Session(storage, key, catalog, metadata.version))
}

pub fn resume(storage: Storage, key: String) -> Result(Session, Error) {
  use object <- result.try(
    storage.get(storage, key) |> result.map_error(StorageFailed),
  )
  use body <- result.try(
    bit_array.to_string(object.body)
    |> result.map_error(fn(_) { InvalidStoredCatalog("catalog is not UTF-8") }),
  )
  use catalog <- result.try(
    json.parse(body, decoder())
    |> result.map_error(fn(error) {
      InvalidStoredCatalog(string.inspect(error))
    }),
  )
  use _ <- result.try(validate(catalog))
  Ok(Session(storage, key, catalog, object.metadata.version))
}

pub fn catalog(session: Session) -> Catalog {
  session.catalog
}

pub fn workspaces(catalog: Catalog) -> List(Workspace) {
  catalog.workspaces
}

pub fn lookup(catalog: Catalog, id: String) -> Result(Workspace, Error) {
  list.find(catalog.workspaces, fn(workspace) { workspace.id == id })
  |> result.map_error(fn(_) { UnknownWorkspace(id) })
}

pub fn put_workspace(
  catalog: Catalog,
  value: Workspace,
) -> Result(Catalog, Error) {
  use value <- result.try(validate_workspace(value))
  let existing = list.any(catalog.workspaces, fn(item) { item.id == value.id })
  let workspaces = case existing {
    True ->
      list.map(catalog.workspaces, fn(item) {
        case item.id == value.id {
          True -> value
          False -> item
        }
      })
    False -> list.append(catalog.workspaces, [value])
  }
  Ok(Catalog(..catalog, workspaces:))
}

pub fn remove_workspace(
  catalog: Catalog,
  id: String,
) -> Result(Catalog, Error) {
  use _ <- result.try(lookup(catalog, id))
  Ok(
    Catalog(
      ..catalog,
      workspaces: list.filter(catalog.workspaces, fn(item) { item.id != id }),
    ),
  )
}

pub fn commit(session: Session, catalog: Catalog) -> Result(Session, Error) {
  use _ <- result.try(validate(catalog))
  let next = Catalog(..catalog, revision: session.catalog.revision + 1)
  let body = encode(next) |> json.to_string |> bit_array.from_string
  use metadata <- result.try(
    case
      storage.put(
        session.storage,
        session.key,
        body,
        storage.IfUnchanged(session.version),
      )
    {
      Ok(metadata) -> Ok(metadata)
      // A conditional write can apply remotely and lose its response, so the
      // storage-level retry sees its own object and reports a conflict.
      // Confirm by read-back like `create` does.
      Error(storage.PreconditionFailed(_)) ->
        confirm_write(session.storage, session.key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(Session(session.storage, session.key, next, metadata.version))
}

pub fn validate(catalog: Catalog) -> Result(Nil, Error) {
  catalog.workspaces
  |> list.try_fold([], fn(ids, value) {
    use _ <- result.try(validate_workspace(value))
    case list.contains(ids, value.id) {
      True -> Error(DuplicateWorkspace(value.id))
      False -> Ok([value.id, ..ids])
    }
  })
  |> result.map(fn(_) { Nil })
}

/// Validates a workspace and returns it with trimmed label and normalized
/// prefix, so every stored workspace compares equal regardless of how the
/// caller spelled it.
pub fn validate_workspace(value: Workspace) -> Result(Workspace, Error) {
  use _ <- result.try(case value.id {
    "" -> Error(InvalidWorkspace("workspace ID cannot be empty"))
    _ ->
      case valid_id(value.id) {
        True -> Ok(Nil)
        False ->
          Error(InvalidWorkspace(
            "workspace ID may contain only letters, digits, underscore, and hyphen: "
            <> value.id,
          ))
      }
  })
  let label = string.trim(value.label)
  use _ <- result.try(case label {
    "" -> Error(InvalidWorkspace("workspace label cannot be empty"))
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    scope.new(value.prefix)
    |> result.map_error(fn(_) {
      InvalidWorkspace(
        "workspace prefix must be a non-empty safe relative path: "
        <> value.prefix,
      )
    }),
  )
  let prefix = ensure_trailing_slash(value.prefix)
  use _ <- result.try(case reserved_overlap(prefix) {
    Ok(reserved) ->
      Error(InvalidWorkspace(
        "workspace prefix overlaps harness-internal namespace `"
        <> reserved
        <> "`",
      ))
    Error(_) -> Ok(Nil)
  })
  Ok(Workspace(id: value.id, label:, prefix:))
}

fn valid_id(id: String) -> Bool {
  id != "" && id == sanitize(id)
}

fn sanitize(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.filter(fn(character) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
      character,
    )
  })
  |> string.join("")
}

fn reserved_overlap(prefix: String) -> Result(String, Nil) {
  // `prefix` is slash-normalized by the caller, so `cluster` has already
  // become `cluster/`; a plain starts-with covers exact and nested overlaps
  // while leaving lookalikes such as `clusters/` allowed.
  list.find(reserved_prefixes, fn(reserved) {
    string.starts_with(prefix, reserved)
  })
}

fn ensure_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") {
    True -> value
    False -> value <> "/"
  }
}

fn confirm_write(
  backend: Storage,
  key: String,
  body: BitArray,
) -> Result(storage.Metadata, Error) {
  case storage.get(backend, key) {
    Ok(object) if object.body == body -> Ok(object.metadata)
    Ok(_) | Error(storage.PreconditionFailed(_)) -> Error(ConcurrentUpdate)
    Error(error) -> Error(storage_error(error))
  }
}

fn storage_error(error: storage.Error) -> Error {
  case error {
    storage.PreconditionFailed(_) -> ConcurrentUpdate
    other -> StorageFailed(other)
  }
}

fn encode(catalog: Catalog) -> json.Json {
  json.object([
    #("schema_version", json.int(1)),
    #("revision", json.int(catalog.revision)),
    #("workspaces", json.array(catalog.workspaces, encode_workspace)),
  ])
}

fn encode_workspace(workspace: Workspace) -> json.Json {
  json.object([
    #("id", json.string(workspace.id)),
    #("label", json.string(workspace.label)),
    #("prefix", json.string(workspace.prefix)),
  ])
}

fn decoder() -> decode.Decoder(Catalog) {
  use schema <- decode.field("schema_version", decode.int)
  use revision <- decode.field("revision", decode.int)
  use workspaces <- decode.field(
    "workspaces",
    decode.list(of: workspace_decoder()),
  )
  case schema {
    1 -> decode.success(Catalog(revision, workspaces))
    _ -> decode.failure(Catalog(0, []), "unsupported workspace catalog schema")
  }
}

fn workspace_decoder() -> decode.Decoder(Workspace) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  use prefix <- decode.field("prefix", decode.string)
  decode.success(Workspace(id, label, prefix))
}
