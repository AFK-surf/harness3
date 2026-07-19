//// Shared storage backend contract tests.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process.{type Subject}
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
    Some(endpoint),
      Some(bucket),
      Some(region),
      Some(access_key_id),
      Some(secret_access_key)
    -> {
      let backend =
        s3.new(s3.Config(
          bucket:,
          region:,
          access_key_id:,
          secret_access_key:,
          session_token: None,
          endpoint:,
        ))
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
  // Reserved characters exercise S3's distinction between the raw key used
  // for SigV4 canonicalization and the percent-encoded HTTP wire path.
  let prefix = key <> "-list prefix:+%25"
  let key = prefix <> "/item"

  let assert Ok(created) =
    storage.put(backend, key, <<"first":utf8>>, storage.IfAbsent)
  let assert storage.Metadata(size: 5, version: first_version, ..) = created

  let assert Ok(storage.Object(metadata:, body:)) = storage.get(backend, key)
  assert body == <<"first":utf8>>
  assert metadata.version == first_version

  let assert Ok(head) = storage.head(backend, key)
  assert head == metadata

  let assert Ok(listed) = storage.list(backend, prefix)
  let assert Ok(listed_metadata) =
    list.find(listed, fn(item) { item.key == key })
  assert listed_metadata.size == metadata.size
  assert listed_metadata.version == metadata.version

  exercise_streaming(backend, prefix <> "/stream")

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
  let assert Error(storage.PreconditionFailed(cas_key)) =
    storage.put(
      backend,
      key,
      <<"missing":utf8>>,
      storage.IfUnchanged(updated.version),
    )
  assert cas_key == key
}

type CollectorMessage {
  Collect(chunk: BitArray)
  Collected(reply_to: Subject(BitArray))
}

fn exercise_streaming(backend: storage.Storage, key: String) {
  let source_chunks = process.new_subject()
  process.send(source_chunks, Some(<<"stream-":utf8>>))
  process.send(source_chunks, Some(<<"body":utf8>>))
  process.send(source_chunks, None)
  let source =
    storage.body_source(11, fn() { Ok(process.receive_forever(source_chunks)) })

  let assert Ok(created) =
    storage.put_stream(backend, key, source, storage.IfAbsent)
  assert created.size == 11

  let collector = start_collector()
  let assert Ok(downloaded) =
    storage.get_stream(backend, key, fn(chunk) {
      process.send(collector, Collect(chunk))
      Ok(Nil)
    })
  assert downloaded == created

  let reply = process.new_subject()
  process.send(collector, Collected(reply))
  let body = process.receive_forever(reply)
  assert body == <<"stream-body":utf8>>

  let assert Ok(Nil) = storage.delete(backend, key)
  Nil
}

fn start_collector() -> Subject(CollectorMessage) {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    collect_chunks(subject, [])
  })
  process.receive_forever(ready)
}

fn collect_chunks(
  subject: Subject(CollectorMessage),
  chunks: List(BitArray),
) -> Nil {
  case process.receive_forever(subject) {
    Collect(chunk) -> collect_chunks(subject, [chunk, ..chunks])
    Collected(reply_to) -> {
      chunks
      |> list.reverse
      |> bit_array.concat
      |> process.send(reply_to, _)
      Nil
    }
  }
}
