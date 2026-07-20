import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import harness3/llm
import harness3/plugin
import harness3/plugin/cloud_storage
import harness3/plugin/cloud_storage/cursor
import harness3/plugin/cloud_storage/scope
import harness3/storage
import harness3/storage/local
import simplifile

type ListedObject {
  ListedObject(key: String, size: Int, modified_at_seconds: Int)
}

type Page {
  Page(objects: List(ListedObject), next_cursor: Option(String))
}

type UrlResult {
  UrlResult(
    key: String,
    operation: String,
    url: String,
    expires_in_seconds: Option(Int),
  )
}

fn temporary_root() -> String {
  "/tmp/harness3-cloud-storage-test-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn activate(backend: storage.Storage, group_id: String) -> plugin.Runtime {
  let assert Ok(registry) =
    plugin.registry([cloud_storage.new(backend, group_id)])
  let assert Ok(runtime) = plugin.activate(registry, plugin.empty_states())
  runtime
}

fn invocation(fields: List(#(String, json.Json))) -> plugin.ToolInvocation {
  plugin.ToolInvocation("call", json.object(fields) |> json.to_string)
}

fn invoke(
  runtime: plugin.Runtime,
  name: String,
  fields: List(#(String, json.Json)),
) -> #(plugin.Runtime, plugin.ToolOutput) {
  let assert Ok(result) = plugin.invoke_tool(runtime, name, invocation(fields))
  result
}

fn output_text(output: plugin.ToolOutput) -> String {
  let plugin.ToolOutput(content:, ..) = output
  let assert [llm.Text(text)] = content
  text
}

fn assert_success(output: plugin.ToolOutput) -> Nil {
  let plugin.ToolOutput(is_error:, ..) = output
  assert !is_error
}

fn assert_error(output: plugin.ToolOutput) -> Nil {
  let plugin.ToolOutput(is_error:, ..) = output
  assert is_error
}

fn page(output: plugin.ToolOutput) -> Page {
  assert_success(output)
  let assert Ok(value) = json.parse(output_text(output), page_decoder())
  value
}

fn page_decoder() -> decode.Decoder(Page) {
  use objects <- decode.field(
    "objects",
    decode.list(of: listed_object_decoder()),
  )
  use next_cursor <- decode.field("next_cursor", decode.optional(decode.string))
  decode.success(Page(objects, next_cursor))
}

fn listed_object_decoder() -> decode.Decoder(ListedObject) {
  use key <- decode.field("key", decode.string)
  use size <- decode.field("size", decode.int)
  use modified_at_seconds <- decode.field("modified_at_seconds", decode.int)
  decode.success(ListedObject(key, size, modified_at_seconds))
}

fn object_keys(objects: List(ListedObject)) -> List(String) {
  list.map(objects, fn(object) { object.key })
}

fn write(
  runtime: plugin.Runtime,
  key: String,
  content: String,
) -> plugin.Runtime {
  let #(runtime, output) =
    invoke(runtime, "cloud_storage.write", [
      #("key", json.string(key)),
      #("content", json.string(content)),
    ])
  assert_success(output)
  runtime
}

pub fn cloud_storage_exposes_scoped_text_crud_tools_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let runtime = activate(backend, "group/../with arbitrary id")
  let tool_names =
    plugin.tools(runtime)
    |> list.map(fn(tool) {
      let llm.Tool(name:, ..) = tool
      name
    })
  assert tool_names
    == [
      "cloud_storage.read",
      "cloud_storage.write",
      "cloud_storage.list",
      "cloud_storage.delete",
      "cloud_storage.get_url",
    ]
  assert string.contains(plugin.system_prompt(runtime), "shared")
  assert dict.get(plugin.encoded_states(runtime), "cloud_storage") == Ok("{}")

  let runtime = write(runtime, "notes/計畫.txt", "first")
  let #(runtime, read) =
    invoke(runtime, "cloud_storage.read", [
      #("key", json.string("notes/計畫.txt")),
    ])
  assert_success(read)
  assert output_text(read) == "first"

  let runtime = write(runtime, "notes/計畫.txt", "replacement")
  let #(runtime, read) =
    invoke(runtime, "cloud_storage.read", [
      #("key", json.string("notes/計畫.txt")),
    ])
  assert output_text(read) == "replacement"

  let #(runtime, direct_url) =
    invoke(runtime, "cloud_storage.get_url", [
      #("key", json.string("notes/計畫.txt")),
      #("operation", json.string("download")),
    ])
  assert_success(direct_url)
  let assert Ok(UrlResult(
    key: "notes/計畫.txt",
    operation: "download",
    url:,
    expires_in_seconds: None,
  )) = json.parse(output_text(direct_url), url_result_decoder())
  assert string.starts_with(url, "file:///")
  assert string.contains(url, "plugins/cloud_storage/groups/g-")
  assert string.ends_with(url, "/notes/%E8%A8%88%E7%95%AB.txt")

  let #(runtime, deleted) =
    invoke(runtime, "cloud_storage.delete", [
      #("key", json.string("notes/計畫.txt")),
    ])
  assert_success(deleted)
  let #(runtime, deleted_again) =
    invoke(runtime, "cloud_storage.delete", [
      #("key", json.string("notes/計畫.txt")),
    ])
  assert_success(deleted_again)
  let #(_, missing) =
    invoke(runtime, "cloud_storage.read", [
      #("key", json.string("notes/計畫.txt")),
    ])
  assert_error(missing)
  assert string.contains(output_text(missing), "not found")

  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn listing_is_sorted_paginated_live_and_group_scoped_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let runtime_a = activate(backend, "../group/A")
  let runtime_b = activate(backend, "../group/B")
  let runtime_a = write(runtime_a, "notes/z.txt", "z")
  let runtime_a = write(runtime_a, "notes/a.txt", "a")
  let runtime_a = write(runtime_a, "notes/m.txt", "middle")
  let runtime_a = write(runtime_a, "other.txt", "other")
  let runtime_b = write(runtime_b, "notes/a.txt", "private B")

  let #(runtime_a, first_output) =
    invoke(runtime_a, "cloud_storage.list", [
      #("prefix", json.string("notes/")),
      #("limit", json.int(2)),
    ])
  let assert Page(objects: first_objects, next_cursor: Some(next_cursor)) =
    page(first_output)
  assert object_keys(first_objects) == ["notes/a.txt", "notes/m.txt"]
  let assert [first, second] = first_objects
  assert first.size == 1
  assert second.size == 6
  assert first.modified_at_seconds > 0

  // Keyset pagination must keep working if the boundary object is deleted.
  let #(runtime_a, deleted) =
    invoke(runtime_a, "cloud_storage.delete", [
      #("key", json.string("notes/m.txt")),
    ])
  assert_success(deleted)
  let #(runtime_a, second_output) =
    invoke(runtime_a, "cloud_storage.list", [
      #("cursor", json.string(next_cursor)),
      #("limit", json.int(1)),
    ])
  let assert Page(objects: second_objects, next_cursor: None) =
    page(second_output)
  assert object_keys(second_objects) == ["notes/z.txt"]

  let #(_, conflict) =
    invoke(runtime_a, "cloud_storage.list", [
      #("prefix", json.string("other")),
      #("cursor", json.string(next_cursor)),
    ])
  assert_error(conflict)
  assert string.contains(output_text(conflict), "does not match")

  let #(runtime_b, group_b_page) =
    invoke(runtime_b, "cloud_storage.list", [
      #("prefix", json.string("notes/")),
    ])
  let Page(objects: group_b_objects, ..) = page(group_b_page)
  assert object_keys(group_b_objects) == ["notes/a.txt"]

  let #(_, group_a_read) =
    invoke(runtime_a, "cloud_storage.read", [
      #("key", json.string("notes/a.txt")),
    ])
  let #(_, group_b_read) =
    invoke(runtime_b, "cloud_storage.read", [
      #("key", json.string("notes/a.txt")),
    ])
  assert output_text(group_a_read) == "a"
  assert output_text(group_b_read) == "private B"

  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn invalid_keys_cursors_limits_and_non_utf8_objects_are_tool_errors_test() {
  let root = temporary_root()
  let backend = local.new(local.config(root))
  let group_id = "validation-group"
  let runtime = activate(backend, group_id)

  list.each(
    ["", "/absolute", "../outside", "a//b", "a/./b", "a/../b", "a\\b", "a/"],
    fn(key) {
      let #(_, output) =
        invoke(runtime, "cloud_storage.write", [
          #("key", json.string(key)),
          #("content", json.string("no")),
        ])
      assert_error(output)
    },
  )

  let #(_, bad_prefix) =
    invoke(runtime, "cloud_storage.list", [
      #("prefix", json.string("a//")),
    ])
  assert_error(bad_prefix)
  let #(_, bad_cursor) =
    invoke(runtime, "cloud_storage.list", [
      #("cursor", json.string("not-a-cursor")),
    ])
  assert_error(bad_cursor)
  let #(_, small_limit) =
    invoke(runtime, "cloud_storage.list", [#("limit", json.int(0))])
  assert_error(small_limit)
  let #(_, large_limit) =
    invoke(runtime, "cloud_storage.list", [#("limit", json.int(1001))])
  assert_error(large_limit)
  let #(_, forged_cursor) =
    invoke(runtime, "cloud_storage.list", [
      #("cursor", json.string(cursor.encode("notes/", "elsewhere.txt"))),
    ])
  assert_error(forged_cursor)
  let #(_, bad_operation) =
    invoke(runtime, "cloud_storage.get_url", [
      #("key", json.string("object.txt")),
      #("operation", json.string("delete")),
    ])
  assert_error(bad_operation)

  let assert Ok(#(_, malformed_arguments)) =
    plugin.invoke_tool(
      runtime,
      "cloud_storage.read",
      plugin.ToolInvocation("bad-json", "[]"),
    )
  assert_error(malformed_arguments)

  let group_scope = scope.new(group_id)
  let assert Ok(backend_key) = scope.object_key(group_scope, "binary.dat")
  let assert Ok(_) =
    storage.put(backend, backend_key, <<255, 254>>, storage.Unconditional)
  let #(_, binary_read) =
    invoke(runtime, "cloud_storage.read", [
      #("key", json.string("binary.dat")),
    ])
  assert_error(binary_read)
  assert string.contains(output_text(binary_read), "not UTF-8")

  // Empty prefix is valid and lists the complete logical group namespace.
  let #(_, all_objects) = invoke(runtime, "cloud_storage.list", [])
  let Page(objects:, ..) = page(all_objects)
  assert object_keys(objects) == ["binary.dat"]

  let assert Ok(Nil) = simplifile.delete(root)
}

pub fn storage_backend_failures_are_recoverable_tool_errors_test() {
  let backend = failing_storage()
  let runtime = activate(backend, "offline-group")
  let operations = [
    #("cloud_storage.read", [#("key", json.string("object.txt"))]),
    #("cloud_storage.write", [
      #("key", json.string("object.txt")),
      #("content", json.string("body")),
    ]),
    #("cloud_storage.list", []),
    #("cloud_storage.delete", [#("key", json.string("object.txt"))]),
    #("cloud_storage.get_url", [
      #("key", json.string("object.txt")),
      #("operation", json.string("download")),
    ]),
  ]
  list.each(operations, fn(operation) {
    let #(_, output) = invoke(runtime, operation.0, operation.1)
    assert_error(output)
    assert string.contains(output_text(output), "offline")
  })
}

fn failing_storage() -> storage.Storage {
  storage.from_functions(
    get: fn(_) { Error(storage.Transport("offline")) },
    head: fn(_) { Error(storage.Transport("offline")) },
    put: fn(_, _, _) { Error(storage.Transport("offline")) },
    list: fn(_) { Error(storage.Transport("offline")) },
    delete: fn(_) { Error(storage.Transport("offline")) },
    stream_get: fn(_, _) { Error(storage.Transport("offline")) },
    stream_put: fn(_, _, _) { Error(storage.Transport("offline")) },
  )
  |> storage.with_transfer_urls(fn(_, _, _) {
    Error(storage.Transport("offline"))
  })
}

pub fn cloud_transfer_urls_are_requested_with_five_minute_ttl_test() {
  let backend =
    failing_storage()
    |> storage.with_transfer_urls(fn(key, operation, expires_in_seconds) {
      assert string.ends_with(key, "/objects/export.txt")
      assert operation == storage.Upload
      assert expires_in_seconds == 300
      Ok(storage.TransferUrl(
        "https://storage.example.test/upload",
        Some(expires_in_seconds),
      ))
    })
  let runtime = activate(backend, "url-group")
  let #(_, output) =
    invoke(runtime, "cloud_storage.get_url", [
      #("key", json.string("export.txt")),
      #("operation", json.string("upload")),
    ])
  assert_success(output)
  let assert Ok(UrlResult(
    key: "export.txt",
    operation: "upload",
    url: "https://storage.example.test/upload",
    expires_in_seconds: Some(300),
  )) = json.parse(output_text(output), url_result_decoder())
  Nil
}

fn url_result_decoder() -> decode.Decoder(UrlResult) {
  use key <- decode.field("key", decode.string)
  use operation <- decode.field("operation", decode.string)
  use url <- decode.field("url", decode.string)
  use expires_in_seconds <- decode.field(
    "expires_in_seconds",
    decode.optional(decode.int),
  )
  decode.success(UrlResult(key, operation, url, expires_in_seconds))
}
