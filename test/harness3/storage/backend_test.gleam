//// Shared storage backend contract tests.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/charlist.{type Charlist}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import harness3/storage
import harness3/storage/local
import harness3/storage/s3

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "file", "del_dir_r")
fn remove_directory(path: String) -> Dynamic

@external(erlang, "os", "getenv")
fn getenv(name: Charlist) -> Dynamic

pub fn local_backend_test() {
  let root = "/tmp/harness3-local-test-" <> int.to_string(unique_integer())
  let backend = local.new(local.config(root))
  exercise_backend(backend, "objects/item")
  remove_directory(root)
}

pub fn s3_backend_test() {
  case
    env("TEST_S3_ENDPOINT"),
    env("TEST_S3_BUCKET"),
    env("TEST_S3_REGION"),
    env("TEST_S3_ACCESS_KEY_ID"),
    env("TEST_S3_SECRET_ACCESS_KEY")
  {
    Some(endpoint), Some(bucket), Some(region), Some(access_key_id), Some(secret_access_key) -> {
      let backend =
        s3.new(
          s3.Config(
            bucket:,
            region:,
            access_key_id:,
            secret_access_key:,
            session_token: None,
            endpoint:,
          ),
        )
      let key = "harness3-test/" <> int.to_string(unique_integer()) <> "/item"
      exercise_backend(backend, key)
    }
    _, _, _, _, _ -> Nil
  }
}

fn env(name: String) -> Option(String) {
  case decode.run(getenv(charlist.from_string(name)), decode.string) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn exercise_backend(backend: storage.Storage, key: String) {
  let prefix = key <> "-list-prefix"
  let key = prefix <> "/item"

  let assert Ok(created) =
    storage.put(backend, key, <<"first":utf8>>, storage.IfAbsent)
  let assert storage.Metadata(size: 5, version: first_version, ..) = created

  let assert Ok(storage.Object(metadata:, body:)) =
    storage.get(backend, key)
  assert body == <<"first":utf8>>
  assert metadata.version == first_version

  let assert Ok(head) = storage.head(backend, key)
  assert head == metadata

  let assert Ok(listed) = storage.list(backend, prefix)
  let assert Ok(listed_metadata) =
    list.find(listed, fn(item) { item.key == key })
  assert listed_metadata.size == metadata.size
  assert listed_metadata.version == metadata.version

  let assert Ok(updated) =
    storage.put(
      backend,
      key,
      <<"second":utf8>>,
      storage.IfUnchanged(first_version),
    )
  assert updated.version != first_version

  let assert Error(storage.PreconditionFailed(failed_key)) =
    storage.put(
      backend,
      key,
      <<"stale":utf8>>,
      storage.IfUnchanged(first_version),
    )
  assert failed_key == key

  let assert Ok(Nil) = storage.delete(backend, key)
  let assert Error(storage.NotFound(missing_key)) = storage.get(backend, key)
  assert missing_key == key
}
