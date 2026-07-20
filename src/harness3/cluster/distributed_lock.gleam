import gleam/bit_array
import gleam/crypto
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
    nonce: String,
    version: VersionToken,
  )
}

type LockRecord {
  LockRecord(owner: String, expires_at: Int, nonce: String)
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
  // The nonce makes an ambiguous-success read-back attributable to this
  // acquisition even when two attempts reuse an owner within the same second.
  let nonce = new_nonce()
  let body = lock_body(key, owner, expires_at, nonce)
  case storage.get(backend, object_key) {
    Error(storage.NotFound(_)) ->
      case storage.put(backend, object_key, body, storage.IfAbsent) {
        Ok(metadata) ->
          Ok(
            Some(make_lock(
              backend,
              object_key,
              key,
              owner,
              lease_seconds,
              nonce,
              metadata.version,
            )),
          )
        Error(storage.PreconditionFailed(_)) ->
          case confirm_lock_write(backend, object_key, nonce) {
            Ok(Some(metadata)) ->
              Ok(
                Some(make_lock(
                  backend,
                  object_key,
                  key,
                  owner,
                  lease_seconds,
                  nonce,
                  metadata.version,
                )),
              )
            Ok(None) -> do_try_acquire(backend, key, owner, lease_seconds)
            Error(error) -> Error(error)
          }
        Error(error) -> Error(StorageFailed(error))
      }
    Error(error) -> Error(StorageFailed(error))
    Ok(object) -> {
      case decode_record(object.body) {
        Ok(record) ->
          case record.expires_at > system_time(Second) {
            True ->
              // This may be an ambiguous successful IfAbsent from this
              // caller. Owner strings are not sufficient: they can be
              // reused; the nonce is unique to this acquisition attempt.
              case record.nonce == nonce {
                True ->
                  Ok(
                    Some(make_lock(
                      backend,
                      object_key,
                      key,
                      owner,
                      lease_seconds,
                      nonce,
                      object.metadata.version,
                    )),
                  )
                False -> Ok(None)
              }
            False ->
              replace_lock(
                backend,
                object_key,
                key,
                owner,
                lease_seconds,
                nonce,
                body,
                object.metadata.version,
              )
          }
        Error(CorruptLock(_)) ->
          replace_lock(
            backend,
            object_key,
            key,
            owner,
            lease_seconds,
            nonce,
            body,
            object.metadata.version,
          )
        Error(error) -> Error(error)
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
    nonce:,
    version:,
  ) = lock
  let expires_at = system_time(Second) + lease_seconds
  let body = lock_body(lock_key, owner, expires_at, nonce)
  case storage.put(backend, object_key, body, storage.IfUnchanged(version)) {
    Ok(metadata) -> Ok(Lock(..lock, version: metadata.version))
    Error(storage.PreconditionFailed(_)) ->
      case confirm_lock_write(backend, object_key, nonce) {
        Ok(Some(metadata)) -> Ok(Lock(..lock, version: metadata.version))
        Ok(None) -> Error(Lost)
        Error(error) -> Error(error)
      }
    Error(error) -> Error(lock_write_error(error))
  }
}

/// Releases a lock with CAS by replacing it with an immediately expired value.
pub fn release(lock: Lock) -> Result(Nil, Error) {
  let Lock(
    storage: backend,
    object_key:,
    lock_key:,
    owner:,
    nonce:,
    version:,
    ..,
  ) = lock
  let body = lock_body(lock_key, owner, 0, nonce)
  case storage.put(backend, object_key, body, storage.IfUnchanged(version)) {
    Ok(_) -> Ok(Nil)
    Error(storage.PreconditionFailed(_)) ->
      case confirm_lock_write(backend, object_key, nonce) {
        Ok(Some(_)) -> Ok(Nil)
        Ok(None) -> Error(Lost)
        Error(error) -> Error(error)
      }
    Error(error) -> Error(lock_write_error(error))
  }
}

fn replace_lock(
  backend: Storage,
  object_key: String,
  lock_key: String,
  owner: String,
  lease_seconds: Int,
  nonce: String,
  body: BitArray,
  version: VersionToken,
) -> Result(Option(Lock), Error) {
  case storage.put(backend, object_key, body, storage.IfUnchanged(version)) {
    Ok(metadata) ->
      Ok(
        Some(make_lock(
          backend,
          object_key,
          lock_key,
          owner,
          lease_seconds,
          nonce,
          metadata.version,
        )),
      )
    Error(storage.PreconditionFailed(_)) ->
      case confirm_lock_write(backend, object_key, nonce) {
        Ok(Some(metadata)) ->
          Ok(
            Some(make_lock(
              backend,
              object_key,
              lock_key,
              owner,
              lease_seconds,
              nonce,
              metadata.version,
            )),
          )
        Ok(None) -> do_try_acquire(backend, lock_key, owner, lease_seconds)
        Error(error) -> Error(error)
      }
    Error(error) -> Error(StorageFailed(error))
  }
}

/// Confirms whether a lock write that reported `PreconditionFailed` actually
/// belongs to this lock handle. Identity is the acquisition nonce, not body
/// equality: an applied-but-unacknowledged renew leaves a stored body whose
/// `expires_at` differs from the next attempt's, yet the lock is still ours
/// and must not be reported `Lost`.
fn confirm_lock_write(
  backend: Storage,
  object_key: String,
  nonce: String,
) -> Result(Option(storage.Metadata), Error) {
  case storage.get(backend, object_key) {
    Ok(object) ->
      case decode_record(object.body) {
        Ok(record) if record.nonce == nonce && nonce != "" ->
          Ok(Some(object.metadata))
        Ok(_) | Error(CorruptLock(_)) -> Ok(None)
        Error(error) -> Error(error)
      }
    Error(storage.NotFound(_)) -> Ok(None)
    Error(error) -> Error(StorageFailed(error))
  }
}

fn make_lock(
  backend: Storage,
  object_key: String,
  lock_key: String,
  owner: String,
  lease_seconds: Int,
  nonce: String,
  version: VersionToken,
) -> Lock {
  Lock(backend, object_key, lock_key, owner, lease_seconds, nonce, version)
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

fn new_nonce() -> String {
  crypto.strong_random_bytes(18) |> bit_array.base64_url_encode(False)
}

fn lock_body(
  key: String,
  owner: String,
  expires_at: Int,
  nonce: String,
) -> BitArray {
  json.object([
    #("schema_version", json.int(1)),
    #("key", json.string(key)),
    #("owner", json.string(owner)),
    #("expires_at", json.int(expires_at)),
    #("nonce", json.string(nonce)),
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
    use nonce <- decode.optional_field("nonce", "", decode.string)
    decode.success(LockRecord(owner, expires_at, nonce))
  })
  |> result.map_error(fn(error) { CorruptLock(string.inspect(error)) })
}

type TimeUnit {
  Second
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int
