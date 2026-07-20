import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import harness3/plugin/mcp/configuration.{type Configuration}
import harness3/storage.{type Storage, type VersionToken}

pub type Catalog {
  Catalog(revision: Int, configurations: List(Configuration))
}

pub fn new() -> Catalog {
  Catalog(0, [])
}

pub type Error {
  InvalidConfiguration(error: configuration.Error)
  DuplicateConfiguration(id: String)
  UnknownConfiguration(id: String)
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

pub fn revision(catalog: Catalog) -> Int {
  catalog.revision
}

pub fn configurations(catalog: Catalog) -> List(Configuration) {
  catalog.configurations
}

pub fn lookup(catalog: Catalog, id: String) -> Result(Configuration, Error) {
  list.find(catalog.configurations, fn(configuration) { configuration.id == id })
  |> result.map_error(fn(_) { UnknownConfiguration(id) })
}

pub fn put_configuration(
  catalog: Catalog,
  value: Configuration,
) -> Result(Catalog, Error) {
  use _ <- result.try(
    configuration.validate(value) |> result.map_error(InvalidConfiguration),
  )
  let existing =
    list.any(catalog.configurations, fn(item) { item.id == value.id })
  let configurations = case existing {
    True ->
      list.map(catalog.configurations, fn(item) {
        case item.id == value.id {
          True -> value
          False -> item
        }
      })
    False -> list.append(catalog.configurations, [value])
  }
  Ok(Catalog(..catalog, configurations:))
}

pub fn remove_configuration(
  catalog: Catalog,
  id: String,
) -> Result(Catalog, Error) {
  use _ <- result.try(lookup(catalog, id))
  Ok(
    Catalog(
      ..catalog,
      configurations: list.filter(catalog.configurations, fn(item) {
        item.id != id
      }),
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
      // storage-level retry sees its own object and reports a conflict. Confirm
      // by read-back like `create` does, or an ambiguous success would fail
      // server startup on a write that actually landed.
      Error(storage.PreconditionFailed(_)) ->
        confirm_write(session.storage, session.key, body)
      Error(error) -> Error(storage_error(error))
    },
  )
  Ok(Session(session.storage, session.key, next, metadata.version))
}

pub fn validate(catalog: Catalog) -> Result(Nil, Error) {
  catalog.configurations
  |> list.try_fold([], fn(ids, value) {
    use _ <- result.try(
      configuration.validate(value) |> result.map_error(InvalidConfiguration),
    )
    case list.contains(ids, value.id) {
      True -> Error(DuplicateConfiguration(value.id))
      False -> Ok([value.id, ..ids])
    }
  })
  |> result.map(fn(_) { Nil })
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
    #(
      "configurations",
      json.array(catalog.configurations, configuration.encode),
    ),
  ])
}

fn decoder() -> decode.Decoder(Catalog) {
  use schema <- decode.field("schema_version", decode.int)
  use revision <- decode.field("revision", decode.int)
  use configurations <- decode.field(
    "configurations",
    decode.list(of: configuration.decoder()),
  )
  case schema {
    1 -> decode.success(Catalog(revision, configurations))
    _ -> decode.failure(Catalog(0, []), "unsupported MCP catalog schema")
  }
}
