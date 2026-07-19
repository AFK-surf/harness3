import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/charlist.{type Charlist}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import harness3/storage.{
  type Error, type Metadata, type Object, type PutCondition, type Storage,
  Backend, GcsGeneration, IfAbsent, IfUnchanged, InvalidCondition, InvalidKey,
  LocalVersion, Metadata, NotFound, Object, PreconditionFailed, S3Etag,
  Unconditional,
}

pub type Config {
  Config(root: String)
}

pub fn config(root: String) -> Config {
  Config(root)
}

pub fn new(config: Config) -> Storage {
  storage.from_functions(
    get: fn(key) { get_(config, key) },
    head: fn(key) { head_(config, key) },
    put: fn(key, body, condition) { put_(config, key, body, condition) },
    list: fn(prefix) { list_(config, prefix) },
    delete: fn(key) { delete_(config, key) },
  )
}

type DateTime = #(#(Int, Int, Int), #(Int, Int, Int))

type WriteOption {
  Raw
  Binary
  Sync
  Exclusive
}

type UniqueIntegerOption {
  Positive
  Monotonic
}

type LockResource {
  Harness3LocalStorageLock
}

type GenerationStore {
  Harness3LocalStorageGenerations
}

type LocalState {
  LocalState(mtime_seconds: Int, generation: Int)
}

type FileStatus

@external(erlang, "file", "read_file")
fn file_read(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "write_file")
fn file_write(
  path: String,
  body: BitArray,
  options: List(WriteOption),
) -> FileStatus

@external(erlang, "file", "rename")
fn file_rename(from: String, to: String) -> FileStatus

@external(erlang, "file", "delete")
fn file_delete(path: String) -> FileStatus

@external(erlang, "filelib", "ensure_dir")
fn ensure_dir(path: String) -> FileStatus

@external(erlang, "filelib", "is_file")
fn is_file(path: String) -> Bool

@external(erlang, "filelib", "is_dir")
fn is_dir(path: String) -> Bool

@external(erlang, "filelib", "file_size")
fn file_size(path: String) -> Int

@external(erlang, "filelib", "last_modified")
fn last_modified(path: String) -> DateTime

@external(erlang, "filelib", "fold_files")
fn fold_files(
  directory: String,
  expression: Charlist,
  recursive: Bool,
  folder: fn(String, List(String)) -> List(String),
  initial: List(String),
) -> List(String)

@external(erlang, "filename", "absname")
fn absname(path: String) -> String

@external(erlang, "filename", "join")
fn join_path(left: String, right: String) -> String

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
fn gregorian_seconds(datetime: DateTime) -> Int

@external(erlang, "erlang", "self")
fn self() -> Dynamic

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueIntegerOption)) -> Int

@external(erlang, "erlang", "is_atom")
fn is_atom(value: FileStatus) -> Bool

@external(erlang, "global", "trans")
fn global_transaction(lock: #(LockResource, Dynamic), transaction: fn() -> a) -> a

@external(erlang, "persistent_term", "get")
fn persistent_get(key: GenerationStore, default: Dict(String, LocalState)) -> Dict(String, LocalState)

@external(erlang, "persistent_term", "put")
fn persistent_put(key: GenerationStore, value: Dict(String, LocalState)) -> Nil

fn with_lock(transaction: fn() -> a) -> a {
  global_transaction(#(Harness3LocalStorageLock, self()), transaction)
}

fn root(config: Config) -> String {
  let Config(root:) = config
  absname(root)
}

fn path_for(config: Config, key: String) -> Result(String, Error) {
  let segments = string.split(key, "/")
  case key == ""
    || string.starts_with(key, "/")
    || string.contains(key, "\\")
    || string.contains(key, "\u{0}")
    || list.any(segments, fn(segment) {
      segment == "" || segment == "." || segment == ".."
    }) {
    True -> Error(InvalidKey(key))
    False -> Ok(join_path(root(config), key))
  }
}

fn mtime_seconds(path: String) -> Int {
  // Erlang's Gregorian epoch precedes Unix's by this many seconds.
  gregorian_seconds(last_modified(path)) - 62_167_219_200
}

fn next_generation() -> Int {
  unique_integer([Positive, Monotonic])
}

fn generation_for(path: String, mtime: Int) -> Int {
  // Current and deleted entries remain for the node lifetime. This deliberately
  // exceeds the two-second minimum needed to disambiguate second-resolution
  // mtimes.
  let generations = persistent_get(Harness3LocalStorageGenerations, dict.new())
  case dict.get(generations, path) {
    Ok(LocalState(mtime_seconds: stored_mtime, generation:))
      if stored_mtime == mtime ->
      generation
    _ -> {
      let generation = next_generation()
      generations
      |> dict.insert(path, LocalState(mtime, generation))
      |> persistent_put(Harness3LocalStorageGenerations, _)
      generation
    }
  }
}

fn remember_deleted(path: String) -> Nil {
  let generations = persistent_get(Harness3LocalStorageGenerations, dict.new())
  generations
  |> dict.insert(path, LocalState(-1, next_generation()))
  |> persistent_put(Harness3LocalStorageGenerations, _)
}

fn metadata_locked(key: String, path: String) -> Result(Metadata, Error) {
  case is_file(path) {
    False -> Error(NotFound(key))
    True -> {
      let mtime = mtime_seconds(path)
      Ok(
        Metadata(
          key:,
          size: file_size(path),
          modified_at: int.to_string(mtime),
          version: LocalVersion(mtime, generation_for(path, mtime)),
        ),
      )
    }
  }
}

fn dynamic_error(error: Dynamic) -> Error {
  Backend(0, string.inspect(error))
}

fn status_result(status: FileStatus) -> Result(Nil, Error) {
  case is_atom(status) {
    True -> Ok(Nil)
    False -> Error(Backend(0, string.inspect(status)))
  }
}

fn get_(config: Config, key: String) -> Result(Object, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(fn() {
    use metadata <- result.try(metadata_locked(key, path))
    file_read(path)
    |> result.map(fn(body) { Object(metadata, body) })
    |> result.map_error(dynamic_error)
  })
}

fn head_(config: Config, key: String) -> Result(Metadata, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(fn() { metadata_locked(key, path) })
}

fn check_condition(
  condition: PutCondition,
  key: String,
  path: String,
) -> Result(Nil, Error) {
  case condition {
    Unconditional -> Ok(Nil)
    IfAbsent ->
      case is_file(path) {
        True -> Error(PreconditionFailed(key))
        False -> Ok(Nil)
      }
    IfUnchanged(LocalVersion(expected_mtime, expected_generation)) ->
      case metadata_locked(key, path) {
        Ok(Metadata(version: LocalVersion(actual_mtime, actual_generation), ..))
          if expected_mtime == actual_mtime
          && expected_generation == actual_generation ->
          Ok(Nil)
        Ok(_) | Error(NotFound(_)) -> Error(PreconditionFailed(key))
        Error(error) -> Error(error)
      }
    IfUnchanged(S3Etag(_)) -> Error(InvalidCondition("local", "s3"))
    IfUnchanged(GcsGeneration(_)) -> Error(InvalidCondition("local", "gcs"))
  }
}

fn put_(
  config: Config,
  key: String,
  body: BitArray,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(fn() {
    use _ <- result.try(check_condition(condition, key, path))
    use _ <- result.try(ensure_dir(path) |> status_result)
    let temporary = path <> ".harness3-" <> int.to_string(next_generation())
    use _ <- result.try(
      file_write(temporary, body, [Raw, Binary, Sync, Exclusive])
      |> status_result,
    )
    case file_rename(temporary, path) |> status_result {
      Error(error) -> {
        let _ = file_delete(temporary)
        Error(error)
      }
      Ok(Nil) -> {
        let mtime = mtime_seconds(path)
        let generation = next_generation()
        let generations =
          persistent_get(Harness3LocalStorageGenerations, dict.new())
          |> dict.insert(path, LocalState(mtime, generation))
        persistent_put(Harness3LocalStorageGenerations, generations)
        Ok(
          Metadata(
            key:,
            size: bit_array.byte_size(body),
            modified_at: int.to_string(mtime),
            version: LocalVersion(mtime, generation),
          ),
        )
      }
    }
  })
}

fn list_(config: Config, prefix: String) -> Result(List(Metadata), Error) {
  let base = root(config)
  let base_prefix = case base {
    "/" -> "/"
    _ -> base <> "/"
  }
  with_lock(fn() {
    let paths =
      case is_dir(base) {
        False -> []
        True ->
          fold_files(
            base,
            charlist.from_string(".*"),
            True,
            fn(path, paths) { [path, ..paths] },
            [],
          )
      }
    paths
    |> list.filter_map(fn(path) {
      let key = string.drop_start(path, string.length(base_prefix))
      case string.starts_with(key, prefix) {
        True -> metadata_locked(key, path)
        False -> Error(NotFound(key))
      }
    })
    |> list.sort(fn(left, right) {
      let Metadata(key: left_key, ..) = left
      let Metadata(key: right_key, ..) = right
      string.compare(left_key, right_key)
    })
    |> Ok
  })
}

fn delete_(config: Config, key: String) -> Result(Nil, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(fn() {
    case is_file(path) {
      False -> Ok(Nil)
      True ->
        case file_delete(path) |> status_result {
          Ok(Nil) -> {
            remember_deleted(path)
            Ok(Nil)
          }
          Error(error) -> Error(error)
        }
    }
  })
}
