import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import harness3/storage.{type Storage, type VersionToken}

pub type Error {
  InvalidLease
  CorruptLock(reason: String)
  Lost
  StorageFailed(error: storage.Error)
}

pub opaque type Lock {
  Lock(
    storage: Storage,
    object_key: String,
    lock_key: String,
    owner: String,
    lease_seconds: Int,
    version: VersionToken,
  )
}

type LockRecord {
  LockRecord(owner: String, expires_at: Int)
}

/// Attempts to acquire a keyed lock without waiting for another owner.
pub fn try_acquire(
  backend: Storage,
  key: String,
  owner: String,
  lease_seconds: Int,
) -> Result(Option(Lock), Error) {
  case lease_seconds > 0 {
    False -> Error(InvalidLease)
    True -> do_try_acquire(backend, key, owner, lease_seconds)
  }
}

fn do_try_acquire(
  backend: Storage,
  key: String,
  owner: String,
  lease_seconds: Int,
) -> Result(Option(Lock), Error) {
  let object_key = lock_object_key(key)
  let expires_at = system_time(Second) + lease_seconds
  case storage.get(backend, object_key) {
    Error(storage.NotFound(_)) ->
      case
        storage.put(
          backend,
          object_key,
          lock_body(key, owner, expires_at),
          storage.IfAbsent,
        )
      {
        Ok(metadata) ->
          Ok(
            Some(Lock(
              backend,
              object_key,
              key,
              owner,
              lease_seconds,
              metadata.version,
            )),
          )
        Error(storage.PreconditionFailed(_)) ->
          do_try_acquire(backend, key, owner, lease_seconds)
        Error(error) -> Error(StorageFailed(error))
      }
    Error(error) -> Error(StorageFailed(error))
    Ok(object) -> {
      use record <- result.try(decode_record(object.body))
      case record.expires_at > system_time(Second) {
        True -> Ok(None)
        False ->
          case
            storage.put(
              backend,
              object_key,
              lock_body(key, owner, expires_at),
              storage.IfUnchanged(object.metadata.version),
            )
          {
            Ok(metadata) ->
              Ok(
                Some(Lock(
                  backend,
                  object_key,
                  key,
                  owner,
                  lease_seconds,
                  metadata.version,
                )),
              )
            Error(storage.PreconditionFailed(_)) ->
              do_try_acquire(backend, key, owner, lease_seconds)
            Error(error) -> Error(StorageFailed(error))
          }
      }
    }
  }
}

/// Extends a lock if no other writer has replaced its storage version.
pub fn renew(lock: Lock) -> Result(Lock, Error) {
  let Lock(
    storage: backend,
    object_key:,
    lock_key:,
    owner:,
    lease_seconds:,
    version:,
  ) = lock
  let expires_at = system_time(Second) + lease_seconds
  storage.put(
    backend,
    object_key,
    lock_body(lock_key, owner, expires_at),
    storage.IfUnchanged(version),
  )
  |> result.map(fn(metadata) { Lock(..lock, version: metadata.version) })
  |> result.map_error(lock_write_error)
}

/// Releases a lock with CAS by replacing it with an immediately expired value.
pub fn release(lock: Lock) -> Result(Nil, Error) {
  let Lock(storage: backend, object_key:, lock_key:, owner:, version:, ..) =
    lock
  storage.put(
    backend,
    object_key,
    lock_body(lock_key, owner, 0),
    storage.IfUnchanged(version),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(lock_write_error)
}

pub fn owner(lock: Lock) -> String {
  let Lock(owner:, ..) = lock
  owner
}

fn lock_write_error(error: storage.Error) -> Error {
  case error {
    storage.PreconditionFailed(_) -> Lost
    error -> StorageFailed(error)
  }
}

fn lock_object_key(key: String) -> String {
  "cluster/locks/" <> uri.percent_encode(key)
}

fn lock_body(key: String, owner: String, expires_at: Int) -> BitArray {
  json.object([
    #("schema_version", json.int(1)),
    #("key", json.string(key)),
    #("owner", json.string(owner)),
    #("expires_at", json.int(expires_at)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn decode_record(body: BitArray) -> Result(LockRecord, Error) {
  use body <- result.try(
    bit_array.to_string(body)
    |> result.map_error(fn(_) { CorruptLock("lock is not UTF-8 JSON") }),
  )
  json.parse(body, {
    use owner <- decode.field("owner", decode.string)
    use expires_at <- decode.field("expires_at", decode.int)
    decode.success(LockRecord(owner, expires_at))
  })
  |> result.map_error(fn(error) { CorruptLock(string.inspect(error)) })
}

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int
