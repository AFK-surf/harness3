import exception
import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import harness3/storage.{
  type Error, type Metadata, type Object, type PutCondition, type Storage,
  type TransferOperation, Backend, GcsGeneration, IfAbsent, IfUnchanged,
  InvalidCondition, InvalidKey, LocalVersion, Metadata, NotFound, Object,
  PreconditionFailed, S3Etag, StreamAborted, TransferUrl, Unconditional,
}
import simplifile

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
    stream_get: fn(key, consume) { stream_get_(config, key, consume) },
    stream_put: fn(key, body, condition) {
      stream_put_(config, key, body, condition)
    },
  )
  |> storage.with_transfer_urls(fn(key, operation, expires_in_seconds) {
    transfer_url_(config, key, operation, expires_in_seconds)
  })
}

type WriteOption {
  Read
  Write
  Raw
  Binary
  Sync
  Exclusive
}

type FileStatus

type FileDescriptor

@external(erlang, "file", "read_file")
fn file_read(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "file", "write_file")
fn file_write(
  path: String,
  body: BitArray,
  options: List(WriteOption),
) -> FileStatus

@external(erlang, "file", "open")
fn file_open(
  path: String,
  options: List(WriteOption),
) -> Result(FileDescriptor, Dynamic)

@external(erlang, "file", "close")
fn file_close(file: FileDescriptor) -> FileStatus

@external(erlang, "file", "read")
fn file_read_chunk(file: FileDescriptor, bytes: Int) -> Dynamic

@external(erlang, "file", "write")
fn file_write_chunk(file: FileDescriptor, chunk: BitArray) -> FileStatus

@external(erlang, "file", "sync")
fn file_sync(file: FileDescriptor) -> FileStatus

@external(erlang, "file", "rename")
fn file_rename(from: String, to: String) -> FileStatus

@external(erlang, "file", "delete")
fn file_delete(path: String) -> FileStatus

@external(erlang, "filelib", "ensure_dir")
fn ensure_dir(path: String) -> FileStatus

// `filelib:is_regular`, not `filelib:is_file`: the latter is true for
// directories, so with keys `docs/x` and `docs` the directory created for the
// former would read as an existing object named `docs` — false `IfAbsent`
// conflicts, `head` hits for nothing, and `eisdir` from `get`.
@external(erlang, "filelib", "is_regular")
fn is_file(path: String) -> Bool

@external(erlang, "filelib", "is_dir")
fn is_dir(path: String) -> Bool

@external(erlang, "filelib", "file_size")
fn file_size(path: String) -> Int

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

@external(erlang, "erlang", "is_atom")
fn is_atom(value: FileStatus) -> Bool

@external(erlang, "erlang", "is_tuple")
fn is_tuple(value: Dynamic) -> Bool

@external(erlang, "erlang", "tuple_size")
fn tuple_size(value: Dynamic) -> Int

@external(erlang, "erlang", "element")
fn tuple_element(position: Int, tuple: Dynamic) -> Dynamic

const lock_retry_ms = 10

const lock_attempts = 3000

const lock_stale_seconds = 15

const lock_heartbeat_ms = 2000

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

type HeartbeatEvent {
  HeartbeatStop(reply: process.Subject(Nil))
  HolderExited
}

fn lock_path(config: Config) -> String {
  join_path(root(config), ".harness3.lock")
}

/// Acquires the lock and stamps the holder's random token into the lock
/// file, so commits and cleanup can verify the lock was not broken and
/// re-acquired by someone else mid-transaction.
fn acquire_lock(path: String, attempts: Int) -> Result(String, Error) {
  use _ <- result.try(ensure_dir(path) |> status_result)
  case file_open(path, [Write, Raw, Exclusive]) {
    Ok(file) -> {
      use _ <- result.try(file_close(file) |> status_result)
      let token =
        crypto.strong_random_bytes(12) |> bit_array.base64_url_encode(False)
      // Only the holder writes here: everyone else backs off while the file
      // exists, and a fresh lock is never broken.
      use _ <- result.try(
        file_write(path, bit_array.from_string(token), [Raw, Binary, Sync])
        |> status_result,
      )
      Ok(token)
    }
    Error(reason) ->
      case string.inspect(reason), attempts > 0 {
        "Eexist", True -> {
          case stale_lock(path) {
            True -> {
              break_stale_lock(path)
              acquire_lock(path, attempts - 1)
            }
            False -> {
              process.sleep(lock_retry_ms)
              acquire_lock(path, attempts - 1)
            }
          }
        }
        "Eexist", False ->
          Error(Backend(0, "timed out waiting for local storage lock"))
        _, _ -> Error(Backend(0, string.inspect(reason)))
      }
  }
}

fn stale_lock(path: String) -> Bool {
  case simplifile.file_info(path) {
    Ok(info) -> system_time(Second) - info.mtime_seconds > lock_stale_seconds
    Error(_) -> False
  }
}

/// Breaks a stale lock by atomically renaming it aside before deleting it.
/// Deleting in place would race with other waiters: between our staleness
/// check and the delete, another waiter could break the same stale lock and
/// create a fresh one, which our delete would then destroy. The rename
/// captures one specific lock file — only one breaker can win it — and the
/// staleness verdict is re-checked on the captured file before it is
/// discarded.
fn break_stale_lock(path: String) -> Nil {
  let suffix =
    crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False)
  let victim = path <> ".break." <> suffix
  case simplifile.rename(at: path, to: victim) {
    // Someone else already broke or released it; go back to polling.
    Error(_) -> Nil
    Ok(Nil) ->
      case stale_lock(victim) {
        True -> {
          let _ = simplifile.delete(victim)
          Nil
        }
        False -> {
          // The lock was refreshed between the staleness check and the
          // rename, so we displaced a live holder. Restore the original file
          // (hard link back is atomic, preserves the holder's token, and
          // refuses to clobber a newer lock). If this loses the race to a
          // fresh acquirer, the displaced holder's token no longer matches
          // and its commit-site verification makes it abort cleanly.
          let _ = simplifile.create_link(to: victim, from: path)
          let _ = simplifile.delete(victim)
          Nil
        }
      }
  }
}

fn keep_lock_alive(
  path: String,
  token: String,
  stop: process.Subject(process.Subject(Nil)),
  holder: process.Monitor,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(stop, HeartbeatStop)
    |> process.select_specific_monitor(holder, fn(_) { HolderExited })
  heartbeat_loop(path, token, selector)
}

fn heartbeat_loop(
  path: String,
  token: String,
  selector: process.Selector(HeartbeatEvent),
) -> Nil {
  case process.selector_receive(selector, lock_heartbeat_ms) {
    Ok(HeartbeatStop(reply)) -> process.send(reply, Nil)
    Ok(HolderExited) -> {
      // The holder died without running its cleanup (for example it was
      // brutally killed mid-transaction). Release the lock on its behalf;
      // interrupted writes already invalidated their version tokens via the
      // sentinel-mtime protocol, so letting the next waiter in is safe.
      release_owned_lock(path, token)
    }
    Error(_) -> {
      // Touch only a lock that still carries this holder's token. A blind
      // touch inside a breaker's rename-aside window recreates the path as
      // an *empty* file: the breaker's hard-link restore then refuses to
      // clobber it, orphaning the token — every commit of the legitimate
      // holder fails verification and an ownerless lock blocks all waiters
      // until it goes stale. A missing or foreign lock means this holder has
      // (at least momentarily) lost it; verification at the commit sites
      // decides the outcome, not the heartbeat.
      case file_read(path) {
        Ok(content) ->
          case content == bit_array.from_string(token) {
            True -> {
              let _ = simplifile.touch(at: path)
              Nil
            }
            False -> Nil
          }
        Error(_) -> Nil
      }
      heartbeat_loop(path, token, selector)
    }
  }
}

/// Deletes the lock only while it still carries this holder's token. After a
/// stall long enough for a breaker to steal the lock, the file belongs to a
/// new holder — deleting it blindly would let a third holder in while the
/// second is mid-transaction.
fn release_owned_lock(path: String, token: String) -> Nil {
  case file_read(path) {
    Ok(content) ->
      case content == bit_array.from_string(token) {
        True -> {
          let _ = file_delete(path)
          Nil
        }
        False -> Nil
      }
    Error(_) -> Nil
  }
}

fn with_lock(
  config: Config,
  transaction: fn(String) -> Result(a, Error),
) -> Result(a, Error) {
  let path = lock_path(config)
  use token <- result.try(acquire_lock(path, lock_attempts))
  let holder = process.self()
  let heartbeat_ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      let monitor = process.monitor(holder)
      process.send(heartbeat_ready, stop)
      keep_lock_alive(path, token, stop, monitor)
    })
  let assert Ok(heartbeat) = process.receive(heartbeat_ready, within: 5000)
  exception.defer(
    fn() {
      // Stop the heartbeat synchronously so a concurrent touch cannot
      // re-create the lock file after it is deleted here.
      let ack = process.new_subject()
      process.send(heartbeat, ack)
      let _ = process.receive(ack, within: 5000)
      release_owned_lock(path, token)
    },
    fn() { transaction(token) },
  )
}

/// Confirms the lock file still carries this holder's token, immediately
/// before a destructive commit. A holder stalled past the staleness horizon
/// loses the lock to a breaker, and its commit must then fail instead of
/// silently overwriting the new holder's writes (a false CAS success).
/// Advisory: a steal between this check and the following operation remains
/// possible, but the window shrinks from the whole transaction to
/// microseconds.
fn verify_lock(config: Config, token: String) -> Result(Nil, Error) {
  case file_read(lock_path(config)) {
    Ok(content) ->
      case content == bit_array.from_string(token) {
        True -> Ok(Nil)
        False ->
          Error(Backend(0, "local storage lock was broken mid-transaction"))
      }
    Error(_) ->
      Error(Backend(0, "local storage lock was broken mid-transaction"))
  }
}

fn root(config: Config) -> String {
  let Config(root:) = config
  absname(root)
}

fn path_for(config: Config, key: String) -> Result(String, Error) {
  let segments = string.split(key, "/")
  case
    key == ""
    || string.starts_with(key, "/")
    || string.contains(key, "\\")
    || string.contains(key, "\u{0}")
    || list.any(segments, fn(segment) {
      segment == "" || segment == "." || segment == ".."
    })
    // `.harness3*` is this backend's own namespace (generation tombstones and
    // the lock file). A key reaching into it could overwrite another key's
    // generation counter and defeat CAS fencing.
    || string.starts_with(key, ".harness3")
  {
    True -> Error(InvalidKey(key))
    False -> Ok(join_path(root(config), key))
  }
}

fn transfer_url_(
  config: Config,
  key: String,
  _operation: TransferOperation,
  _expires_in_seconds: Int,
) -> Result(storage.TransferUrl, Error) {
  use path <- result.try(path_for(config, key))
  let encoded_path =
    path
    |> string.split("/")
    |> list.map(uri.percent_encode)
    |> string.join("/")
  Ok(TransferUrl("file://" <> encoded_path, None))
}

fn mtime_seconds(path: String) -> Int {
  case simplifile.file_info(path) {
    Ok(info) -> info.mtime_seconds
    // Preserve the conservative invalid-token behavior if a concurrent OS
    // mutation removes the file between checks.
    Error(_) -> 0
  }
}

fn generation_path(config: Config, key: String) -> String {
  let name =
    crypto.hash(crypto.Sha256, bit_array.from_string(key))
    |> bit_array.base16_encode
  join_path(root(config), ".harness3/generations/" <> name)
}

fn read_generation(config: Config, key: String) -> #(Int, Int) {
  case file_read(generation_path(config, key)) {
    Ok(body) ->
      case bit_array.to_string(body) {
        Ok(text) ->
          case string.split_once(text, ":") {
            Ok(#(mtime, generation)) ->
              case int.parse(mtime), int.parse(generation) {
                Ok(mtime), Ok(generation) -> #(mtime, generation)
                _, _ -> #(0, 0)
              }
            Error(_) -> #(0, 0)
          }
        Error(_) -> #(0, 0)
      }
    Error(_) -> #(0, 0)
  }
}

fn write_generation(
  config: Config,
  key: String,
  mtime: Int,
  generation: Int,
) -> Result(Nil, Error) {
  let path = generation_path(config, key)
  let temporary = path <> ".temporary"
  use _ <- result.try(ensure_dir(path) |> status_result)
  use _ <- result.try(
    file_write(
      temporary,
      bit_array.from_string(
        int.to_string(mtime) <> ":" <> int.to_string(generation),
      ),
      [Raw, Binary, Sync],
    )
    |> status_result,
  )
  file_rename(temporary, path) |> status_result
}

fn generation_for(
  config: Config,
  key: String,
  mtime: Int,
) -> Result(Int, Error) {
  let #(stored_mtime, stored_generation) = read_generation(config, key)
  case stored_mtime == mtime && stored_generation > 0 {
    True -> Ok(stored_generation)
    False -> {
      let generation = stored_generation + 1
      use _ <- result.try(write_generation(config, key, mtime, generation))
      Ok(generation)
    }
  }
}

fn metadata_locked(
  config: Config,
  key: String,
  path: String,
) -> Result(Metadata, Error) {
  case is_file(path) {
    False -> Error(NotFound(key))
    True -> {
      let mtime = mtime_seconds(path)
      use generation <- result.try(generation_for(config, key, mtime))
      Ok(Metadata(
        key:,
        size: file_size(path),
        modified_at_seconds: mtime,
        version: LocalVersion(mtime, generation),
      ))
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
  with_lock(config, fn(_token) {
    use metadata <- result.try(metadata_locked(config, key, path))
    file_read(path)
    |> result.map(fn(body) { Object(metadata, body) })
    |> result.map_error(dynamic_error)
  })
}

fn head_(config: Config, key: String) -> Result(Metadata, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(config, fn(_token) { metadata_locked(config, key, path) })
}

fn check_condition(
  config: Config,
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
      case metadata_locked(config, key, path) {
        Ok(Metadata(version: LocalVersion(actual_mtime, actual_generation), ..))
          if expected_mtime == actual_mtime
          && expected_generation == actual_generation
        -> Ok(Nil)
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
  with_lock(config, fn(token) {
    use _ <- result.try(check_condition(config, condition, key, path))
    let #(_, stored_generation) = read_generation(config, key)
    let generation = stored_generation + 1
    // The generation record is itself a destructive commit: writing it after
    // losing the lock would roll the per-key counter back below what a new
    // holder has already minted, resurrecting a retired version token.
    use _ <- result.try(verify_lock(config, token))
    // Persist an invalid mtime first. If the VM stops between replacement and
    // the final metadata write, a later reader will conservatively mint a new
    // generation instead of accepting a stale conditional token.
    use _ <- result.try(write_generation(config, key, -2, generation))
    use _ <- result.try(ensure_dir(path) |> status_result)
    let temporary =
      join_path(
        root(config),
        ".harness3/temporary/"
          <> bit_array.base16_encode(crypto.hash(
          crypto.Sha256,
          bit_array.from_string(key),
        )),
      )
    use _ <- result.try(ensure_dir(temporary) |> status_result)
    use _ <- result.try(
      file_write(temporary, body, [Raw, Binary, Sync])
      |> status_result,
    )
    use _ <- result.try(verify_lock(config, token))
    case file_rename(temporary, path) |> status_result {
      Error(error) -> {
        let _ = file_delete(temporary)
        Error(error)
      }
      Ok(Nil) -> {
        let mtime = mtime_seconds(path)
        use _ <- result.try(write_generation(config, key, mtime, generation))
        Ok(Metadata(
          key:,
          size: bit_array.byte_size(body),
          modified_at_seconds: mtime,
          version: LocalVersion(mtime, generation),
        ))
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
  with_lock(config, fn(_token) {
    let paths = case is_dir(base) {
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
    let paths =
      paths
      |> list.filter(fn(path) {
        let key = string.drop_start(path, string.length(base_prefix))
        // The whole `.harness3*` namespace is internal bookkeeping —
        // generations, temporaries, the lock file, and any `.break.` files a
        // crashed lock-breaker left behind. `path_for` rejects such keys, so
        // no legitimate object can be excluded here.
        !string.starts_with(key, ".harness3") && string.starts_with(key, prefix)
      })
    use metadata <- result.try(
      paths
      |> list.try_map(fn(path) {
        let key = string.drop_start(path, string.length(base_prefix))
        metadata_locked(config, key, path)
      }),
    )
    Ok(
      metadata
      |> list.sort(fn(left, right) {
        let Metadata(key: left_key, ..) = left
        let Metadata(key: right_key, ..) = right
        string.compare(left_key, right_key)
      }),
    )
  })
}

fn delete_(config: Config, key: String) -> Result(Nil, Error) {
  use path <- result.try(path_for(config, key))
  with_lock(config, fn(token) {
    case is_file(path) {
      False -> Ok(Nil)
      True -> {
        use _ <- result.try(verify_lock(config, token))
        // The bumped tombstone must always survive the delete. Garbage
        // collecting it when the object's mtime second has passed was tried
        // and is unsound: object mtimes are not monotonic (stream_put commits
        // temp files whose mtime predates taking the lock, and clocks can
        // step backwards), so a "no outstanding token can collide" premise
        // based on the deleted object's mtime does not hold. One small file
        // per deleted key is the accepted price of token uniqueness.
        let #(_, stored_generation) = read_generation(config, key)
        use _ <- result.try(write_generation(
          config,
          key,
          -1,
          stored_generation + 1,
        ))
        file_delete(path) |> status_result
      }
    }
  })
}

const stream_chunk_bytes = 65_536

fn stream_get_(
  config: Config,
  key: String,
  consume: fn(BitArray) -> Result(Nil, Error),
) -> Result(Metadata, Error) {
  use path <- result.try(path_for(config, key))
  use opened <- result.try(
    with_lock(config, fn(_token) {
      use metadata <- result.try(metadata_locked(config, key, path))
      use file <- result.try(
        file_open(path, [Read, Raw, Binary]) |> result.map_error(dynamic_error),
      )
      Ok(#(metadata, file))
    }),
  )
  let #(metadata, file) = opened
  use <- exception.defer(fn() { file_close(file) })
  use _ <- result.try(consume_file(file, consume))
  Ok(metadata)
}

fn consume_file(
  file: FileDescriptor,
  consume: fn(BitArray) -> Result(Nil, Error),
) -> Result(Nil, Error) {
  let reply = file_read_chunk(file, stream_chunk_bytes)
  case string.inspect(reply) {
    "Eof" -> Ok(Nil)
    _ ->
      case
        is_tuple(reply)
        && tuple_size(reply) == 2
        && string.inspect(tuple_element(1, reply)) == "Ok"
      {
        True -> {
          use chunk <- result.try(
            decode.run(tuple_element(2, reply), decode.bit_array)
            |> result.map_error(fn(error) { Backend(0, string.inspect(error)) }),
          )
          use _ <- result.try(consume(chunk))
          consume_file(file, consume)
        }
        False -> Error(Backend(0, string.inspect(reply)))
      }
  }
}

fn stream_put_(
  config: Config,
  key: String,
  body: storage.BodySource,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  use path <- result.try(path_for(config, key))
  let size = storage.body_source_size(body)
  case size < 0 {
    True -> Error(StreamAborted("stream size cannot be negative"))
    False -> {
      let temporary = unique_temporary_path(config, key)
      use _ <- result.try(ensure_dir(temporary) |> status_result)
      use file <- result.try(
        file_open(temporary, [Write, Raw, Binary])
        |> result.map_error(dynamic_error),
      )
      let streamed =
        exception.defer(fn() { file_close(file) }, fn() {
          use _ <- result.try(write_source(file, body, size, 0))
          file_sync(file) |> status_result
        })
      case streamed {
        Error(error) -> {
          let _ = file_delete(temporary)
          Error(error)
        }
        Ok(Nil) -> {
          let committed =
            with_lock(config, fn(token) {
              use _ <- result.try(check_condition(config, condition, key, path))
              let #(_, stored_generation) = read_generation(config, key)
              let generation = stored_generation + 1
              // As in `put_`: the generation write is destructive and must
              // not happen after the lock was lost.
              use _ <- result.try(verify_lock(config, token))
              use _ <- result.try(write_generation(config, key, -2, generation))
              use _ <- result.try(ensure_dir(path) |> status_result)
              use _ <- result.try(verify_lock(config, token))
              case file_rename(temporary, path) |> status_result {
                Error(error) -> {
                  let _ = file_delete(temporary)
                  Error(error)
                }
                Ok(Nil) -> {
                  let mtime = mtime_seconds(path)
                  use _ <- result.try(write_generation(
                    config,
                    key,
                    mtime,
                    generation,
                  ))
                  Ok(Metadata(
                    key:,
                    size:,
                    modified_at_seconds: mtime,
                    version: LocalVersion(mtime, generation),
                  ))
                }
              }
            })
          case committed {
            Ok(metadata) -> Ok(metadata)
            Error(error) -> {
              let _ = file_delete(temporary)
              Error(error)
            }
          }
        }
      }
    }
  }
}

fn write_source(
  file: FileDescriptor,
  source: storage.BodySource,
  expected_size: Int,
  written: Int,
) -> Result(Nil, Error) {
  use next <- result.try(storage.read_body_chunk(source))
  case next {
    None ->
      case written == expected_size {
        True -> Ok(Nil)
        False ->
          Error(StreamAborted(
            "stream ended after "
            <> int.to_string(written)
            <> " bytes; expected "
            <> int.to_string(expected_size),
          ))
      }
    Some(chunk) -> {
      let written = written + bit_array.byte_size(chunk)
      case written > expected_size {
        True -> Error(StreamAborted("stream exceeded its declared size"))
        False -> {
          use _ <- result.try(file_write_chunk(file, chunk) |> status_result)
          write_source(file, source, expected_size, written)
        }
      }
    }
  }
}

fn temporary_path(config: Config, key: String) -> String {
  join_path(
    root(config),
    ".harness3/temporary/"
      <> bit_array.base16_encode(crypto.hash(
      crypto.Sha256,
      bit_array.from_string(key),
    )),
  )
}

fn unique_temporary_path(config: Config, key: String) -> String {
  temporary_path(config, key)
  <> "-"
  <> bit_array.base64_url_encode(crypto.strong_random_bytes(12), False)
}
