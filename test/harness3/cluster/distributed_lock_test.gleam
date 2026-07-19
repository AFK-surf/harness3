import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/option.{None, Some}
import harness3/cluster/distributed_lock
import harness3/storage
import harness3/storage/local

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

fn temporary_root() -> String {
  let suffix =
    crypto.strong_random_bytes(10) |> bit_array.base64_url_encode(False)
  "/tmp/harness3-lock-test-" <> suffix
}

pub fn storage_cas_lock_excludes_owners_and_fences_stale_handles_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let assert Ok(Some(first)) =
    distributed_lock.try_acquire(backend, "shared/key", "owner-a", 10)
  assert distributed_lock.owner(first) == "owner-a"
  assert distributed_lock.try_acquire(backend, "shared/key", "owner-b", 10)
    == Ok(None)

  let assert Ok(renewed) = distributed_lock.renew(first)
  assert distributed_lock.release(renewed) == Ok(Nil)
  let assert Ok(Some(second)) =
    distributed_lock.try_acquire(backend, "shared/key", "owner-b", 10)
  assert distributed_lock.owner(second) == "owner-b"
  assert distributed_lock.renew(renewed) == Error(distributed_lock.Lost)
  assert distributed_lock.try_acquire(backend, "invalid", "owner", 0)
    == Error(distributed_lock.InvalidLease)
  let assert Ok(Nil) = distributed_lock.release(second)
  remove_directory(root)
}

fn ambiguous_conditional_storage(backend: storage.Storage) -> storage.Storage {
  storage.from_functions(
    get: fn(key) { storage.get(backend, key) },
    head: fn(key) { storage.head(backend, key) },
    put: fn(key, body, condition) {
      case storage.put(backend, key, body, condition), condition {
        Ok(_), storage.IfAbsent | Ok(_), storage.IfUnchanged(_) ->
          Error(storage.PreconditionFailed(key))
        outcome, _ -> outcome
      }
    },
    list: fn(prefix) { storage.list(backend, prefix) },
    delete: fn(key) { storage.delete(backend, key) },
    stream_get: fn(key, consume) { storage.get_stream(backend, key, consume) },
    stream_put: fn(key, source, condition) {
      storage.put_stream(backend, key, source, condition)
    },
  )
}

pub fn ambiguous_successes_are_confirmed_for_lock_lifecycle_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root)) |> ambiguous_conditional_storage
  let assert Ok(Some(lock)) =
    distributed_lock.try_acquire(backend, "ambiguous", "owner", 10)
  let assert Ok(lock) = distributed_lock.renew(lock)
  assert distributed_lock.release(lock) == Ok(Nil)
  remove_directory(root)
}

pub fn corrupt_lock_is_replaced_with_a_fenced_write_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let assert Ok(_) =
    storage.put(
      backend,
      "cluster/locks/corrupt",
      <<"not-json":utf8>>,
      storage.IfAbsent,
    )
  let assert Ok(Some(lock)) =
    distributed_lock.try_acquire(backend, "corrupt", "owner", 10)
  assert distributed_lock.release(lock) == Ok(Nil)
  remove_directory(root)
}
