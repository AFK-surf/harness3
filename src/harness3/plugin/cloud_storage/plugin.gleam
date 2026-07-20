import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import harness3/llm
import harness3/plugin
import harness3/plugin/cloud_storage/cursor
import harness3/plugin/cloud_storage/scope.{type Scope}
import harness3/storage.{type Metadata, type Storage}

const plugin_name = "cloud_storage"

const default_page_size = 100

const maximum_page_size = 1000

const transfer_url_ttl_seconds = 300

type KeyArguments {
  KeyArguments(key: String)
}

type WriteArguments {
  WriteArguments(key: String, content: String)
}

type ListArguments {
  ListArguments(prefix: Option(String), cursor: Option(String), limit: Int)
}

type UrlArguments {
  UrlArguments(key: String, operation: String)
}

type PagePosition {
  PagePosition(prefix: String, after: Option(String))
}

type ListedObject {
  ListedObject(key: String, size: Int, modified_at_seconds: Int)
}

pub fn new(storage: Storage, group_id: String) -> plugin.Plugin {
  let group_scope = scope.new(group_id)
  plugin.new(plugin_name, "{}")
  |> plugin.with_system_prompt(plugin.SystemPromptSection(
    "Cloud storage",
    "You have durable UTF-8 text-object storage shared by every agent in this agent group. Keys are safe relative paths. Use cloud_storage_list repeatedly with its opaque cursor until next_cursor is null. Writes replace existing content, deletes are idempotent, and cloud_storage_get_url provides direct upload or download access.",
  ))
  |> plugin.with_tool(read_tool(storage, group_scope))
  |> plugin.with_tool(write_tool(storage, group_scope))
  |> plugin.with_tool(list_tool(storage, group_scope))
  |> plugin.with_tool(delete_tool(storage, group_scope))
  |> plugin.with_tool(url_tool(storage, group_scope))
}

fn read_tool(storage: Storage, group_scope: Scope) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "cloud_storage_read",
      Some("Read a UTF-8 text object from agent-group cloud storage."),
      object_schema([property("key", "string", "Group-relative object key")], [
        "key",
      ]),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case json.parse(arguments, key_arguments_decoder()) {
        Error(error) ->
          error_output(
            "Invalid cloud_storage_read arguments: " <> string.inspect(error),
          )
        Ok(KeyArguments(key)) ->
          case scope.object_key(group_scope, key) {
            Error(error) -> error_output("Invalid cloud storage key: " <> error)
            Ok(backend_key) ->
              case storage.get(storage, backend_key) {
                Error(error) -> error_output(storage_error("read", key, error))
                Ok(object) ->
                  case bit_array.to_string(object.body) {
                    Error(_) ->
                      error_output(
                        "Cloud storage object `" <> key <> "` is not UTF-8 text",
                      )
                    Ok(content) -> plugin.ToolOutput([llm.Text(content)], False)
                  }
              }
          }
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

fn write_tool(storage: Storage, group_scope: Scope) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "cloud_storage_write",
      Some(
        "Create or replace a UTF-8 text object in agent-group cloud storage.",
      ),
      object_schema(
        [
          property("key", "string", "Group-relative object key"),
          property("content", "string", "Complete new object contents"),
        ],
        ["key", "content"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case json.parse(arguments, write_arguments_decoder()) {
        Error(error) ->
          error_output(
            "Invalid cloud_storage_write arguments: " <> string.inspect(error),
          )
        Ok(WriteArguments(key, content)) ->
          case scope.object_key(group_scope, key) {
            Error(error) -> error_output("Invalid cloud storage key: " <> error)
            Ok(backend_key) ->
              case
                storage.put(
                  storage,
                  backend_key,
                  bit_array.from_string(content),
                  storage.Unconditional,
                )
              {
                Error(error) -> error_output(storage_error("write", key, error))
                Ok(metadata) -> metadata_output(key, metadata)
              }
          }
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

fn list_tool(storage: Storage, group_scope: Scope) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "cloud_storage_list",
      Some(
        "List agent-group cloud storage in lexicographic key order. Follow next_cursor until it is null; cursors are opaque.",
      ),
      object_schema(
        [
          property(
            "prefix",
            "string",
            "Optional raw key prefix. Omit when continuing with a cursor.",
          ),
          property(
            "cursor",
            "string",
            "Opaque next_cursor from a previous result",
          ),
          integer_property(
            "limit",
            "Maximum objects to return (default 100, maximum 1000)",
            1,
            maximum_page_size,
          ),
        ],
        [],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case json.parse(arguments, list_arguments_decoder()) {
        Error(error) ->
          error_output(
            "Invalid cloud_storage_list arguments: " <> string.inspect(error),
          )
        Ok(arguments) -> list_objects(storage, group_scope, arguments)
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

fn delete_tool(storage: Storage, group_scope: Scope) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "cloud_storage_delete",
      Some("Idempotently delete a text object from agent-group cloud storage."),
      object_schema([property("key", "string", "Group-relative object key")], [
        "key",
      ]),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case json.parse(arguments, key_arguments_decoder()) {
        Error(error) ->
          error_output(
            "Invalid cloud_storage_delete arguments: " <> string.inspect(error),
          )
        Ok(KeyArguments(key)) ->
          case scope.object_key(group_scope, key) {
            Error(error) -> error_output("Invalid cloud storage key: " <> error)
            Ok(backend_key) ->
              case storage.delete(storage, backend_key) {
                Error(error) ->
                  error_output(storage_error("delete", key, error))
                Ok(Nil) ->
                  plugin.ToolOutput(
                    [
                      llm.Text(
                        json.object([
                          #("key", json.string(key)),
                          #("deleted", json.bool(True)),
                        ])
                        |> json.to_string,
                      ),
                    ],
                    False,
                  )
              }
          }
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

fn url_tool(storage: Storage, group_scope: Scope) -> plugin.Tool {
  plugin.tool(
    llm.Tool(
      "cloud_storage_get_url",
      Some(
        "Get a direct upload or download URL for an agent-group cloud storage object. Cloud URLs expire after five minutes.",
      ),
      object_schema(
        [
          property("key", "string", "Group-relative object key"),
          enum_property("operation", "Operation the URL authorizes", [
            "upload",
            "download",
          ]),
        ],
        ["key", "operation"],
      ),
    ),
    fn(state, context, invocation) {
      let plugin.ToolInvocation(arguments:, ..) = invocation
      let output = case json.parse(arguments, url_arguments_decoder()) {
        Error(error) ->
          error_output(
            "Invalid cloud_storage_get_url arguments: " <> string.inspect(error),
          )
        Ok(UrlArguments(key, operation)) ->
          case
            scope.object_key(group_scope, key),
            transfer_operation(operation)
          {
            Error(error), _ ->
              error_output("Invalid cloud storage key: " <> error)
            _, Error(error) -> error_output(error)
            Ok(backend_key), Ok(transfer_operation) ->
              case
                storage.transfer_url(
                  storage,
                  backend_key,
                  transfer_operation,
                  transfer_url_ttl_seconds,
                )
              {
                Error(error) ->
                  error_output(storage_error("get a URL for", key, error))
                Ok(storage.TransferUrl(url:, expires_in_seconds:)) ->
                  plugin.ToolOutput(
                    [
                      llm.Text(
                        json.object([
                          #("key", json.string(key)),
                          #("operation", json.string(operation)),
                          #("url", json.string(url)),
                          #(
                            "expires_in_seconds",
                            json.nullable(expires_in_seconds, json.int),
                          ),
                        ])
                        |> json.to_string,
                      ),
                    ],
                    False,
                  )
              }
          }
      }
      Ok(plugin.hook_result(state, context, output))
    },
  )
}

fn list_objects(
  storage: Storage,
  group_scope: Scope,
  arguments: ListArguments,
) -> plugin.ToolOutput {
  case validate_page_size(arguments.limit) {
    Error(error) -> error_output(error)
    Ok(Nil) ->
      case page_position(arguments.prefix, arguments.cursor) {
        Error(error) -> error_output(error)
        Ok(position) ->
          case validate_position(position) {
            Error(error) -> error_output(error)
            Ok(Nil) ->
              case scope.list_prefix(group_scope, position.prefix) {
                Error(error) ->
                  error_output("Invalid cloud storage prefix: " <> error)
                Ok(backend_prefix) ->
                  case storage.list(storage, backend_prefix) {
                    Error(error) ->
                      error_output(storage_error("list", position.prefix, error))
                    Ok(metadata) ->
                      page_output(
                        group_scope,
                        position,
                        arguments.limit,
                        metadata,
                      )
                  }
              }
          }
      }
  }
}

fn page_position(
  requested_prefix: Option(String),
  encoded_cursor: Option(String),
) -> Result(PagePosition, String) {
  case encoded_cursor {
    None -> Ok(PagePosition(requested_prefix |> option_unwrap(""), None))
    Some(value) -> {
      use decoded <- result.try(
        cursor.decode(value)
        |> result.map_error(fn(error) {
          "Invalid cloud storage cursor: " <> error
        }),
      )
      let cursor.Cursor(prefix:, after:) = decoded
      case requested_prefix {
        Some(requested) if requested != prefix ->
          Error("Cloud storage cursor does not match the requested prefix")
        _ -> Ok(PagePosition(prefix, Some(after)))
      }
    }
  }
}

fn validate_position(position: PagePosition) -> Result(Nil, String) {
  use _ <- result.try(
    scope.validate_prefix(position.prefix)
    |> result.map_error(fn(error) { "Invalid cloud storage prefix: " <> error }),
  )
  case position.after {
    None -> Ok(Nil)
    Some(after) -> {
      use _ <- result.try(
        scope.validate_key(after)
        |> result.map_error(fn(_) {
          "Cloud storage cursor contains an invalid key"
        }),
      )
      case string.starts_with(after, position.prefix) {
        True -> Ok(Nil)
        False -> Error("Cloud storage cursor key is outside its prefix")
      }
    }
  }
}

fn page_output(
  group_scope: Scope,
  position: PagePosition,
  limit: Int,
  metadata: List(Metadata),
) -> plugin.ToolOutput {
  let candidates =
    metadata
    |> list.filter_map(fn(item) {
      let storage.Metadata(key:, size:, modified_at_seconds:, ..) = item
      case scope.logical_key(group_scope, key) {
        Error(_) -> Error(Nil)
        Ok(logical_key) ->
          case string.starts_with(logical_key, position.prefix) {
            True -> Ok(ListedObject(logical_key, size, modified_at_seconds))
            False -> Error(Nil)
          }
      }
    })
    |> list.sort(fn(left, right) { string.compare(left.key, right.key) })
    |> list.filter(fn(item) {
      case position.after {
        None -> True
        Some(after) -> string.compare(item.key, after) == order.Gt
      }
    })
    |> list.take(limit + 1)
  let has_more = list.length(candidates) > limit
  let page = list.take(candidates, limit)
  let next_cursor = case has_more, list.last(page) {
    True, Ok(last) -> Some(cursor.encode(position.prefix, last.key))
    _, _ -> None
  }
  let document =
    json.object([
      #("objects", json.array(page, encode_listed_object)),
      #("next_cursor", json.nullable(next_cursor, json.string)),
    ])
    |> json.to_string
  plugin.ToolOutput([llm.Text(document)], False)
}

fn validate_page_size(limit: Int) -> Result(Nil, String) {
  case limit >= 1 && limit <= maximum_page_size {
    True -> Ok(Nil)
    False ->
      Error(
        "Cloud storage list limit must be between 1 and "
        <> int.to_string(maximum_page_size),
      )
  }
}

fn encode_listed_object(item: ListedObject) -> json.Json {
  json.object([
    #("key", json.string(item.key)),
    #("size", json.int(item.size)),
    #("modified_at_seconds", json.int(item.modified_at_seconds)),
  ])
}

fn metadata_output(key: String, metadata: Metadata) -> plugin.ToolOutput {
  plugin.ToolOutput(
    [
      llm.Text(
        json.object([
          #("key", json.string(key)),
          #("size", json.int(metadata.size)),
          #("modified_at_seconds", json.int(metadata.modified_at_seconds)),
        ])
        |> json.to_string,
      ),
    ],
    False,
  )
}

fn error_output(message: String) -> plugin.ToolOutput {
  plugin.ToolOutput([llm.Text(message)], True)
}

fn storage_error(
  operation: String,
  logical_key: String,
  error: storage.Error,
) -> String {
  let subject = case logical_key {
    "" -> "cloud storage"
    key -> "cloud storage `" <> key <> "`"
  }
  case error {
    storage.NotFound(_) ->
      "Cloud storage object `" <> logical_key <> "` was not found"
    storage.PreconditionFailed(_) ->
      "Cloud storage precondition failed for `" <> logical_key <> "`"
    storage.InvalidKey(_) -> "Cloud storage rejected the scoped backend key"
    storage.InvalidCondition(expected_backend, actual_backend) ->
      "Cloud storage condition expected "
      <> expected_backend
      <> " but used "
      <> actual_backend
    storage.Transport(reason) ->
      "Could not " <> operation <> " " <> subject <> ": " <> reason
    storage.Backend(status, message) ->
      "Could not "
      <> operation
      <> " "
      <> subject
      <> ": backend status "
      <> int.to_string(status)
      <> ": "
      <> message
    storage.StreamAborted(reason) ->
      "Could not " <> operation <> " " <> subject <> ": " <> reason
  }
}

fn key_arguments_decoder() -> decode.Decoder(KeyArguments) {
  use key <- decode.field("key", decode.string)
  decode.success(KeyArguments(key))
}

fn write_arguments_decoder() -> decode.Decoder(WriteArguments) {
  use key <- decode.field("key", decode.string)
  use content <- decode.field("content", decode.string)
  decode.success(WriteArguments(key, content))
}

fn list_arguments_decoder() -> decode.Decoder(ListArguments) {
  use prefix <- decode.optional_field(
    "prefix",
    None,
    decode.optional(decode.string),
  )
  use cursor <- decode.optional_field(
    "cursor",
    None,
    decode.optional(decode.string),
  )
  use limit <- decode.optional_field("limit", default_page_size, decode.int)
  decode.success(ListArguments(prefix, cursor, limit))
}

fn url_arguments_decoder() -> decode.Decoder(UrlArguments) {
  use key <- decode.field("key", decode.string)
  use operation <- decode.field("operation", decode.string)
  decode.success(UrlArguments(key, operation))
}

fn transfer_operation(
  value: String,
) -> Result(storage.TransferOperation, String) {
  case value {
    "upload" -> Ok(storage.Upload)
    "download" -> Ok(storage.Download)
    _ -> Error("Cloud storage URL operation must be `upload` or `download`")
  }
}

fn option_unwrap(value: Option(String), default: String) -> String {
  case value {
    Some(value) -> value
    None -> default
  }
}

fn property(
  name: String,
  kind: String,
  description: String,
) -> #(String, json.Json) {
  #(
    name,
    json.object([
      #("type", json.string(kind)),
      #("description", json.string(description)),
    ]),
  )
}

fn integer_property(
  name: String,
  description: String,
  minimum: Int,
  maximum: Int,
) -> #(String, json.Json) {
  #(
    name,
    json.object([
      #("type", json.string("integer")),
      #("description", json.string(description)),
      #("minimum", json.int(minimum)),
      #("maximum", json.int(maximum)),
    ]),
  )
}

fn enum_property(
  name: String,
  description: String,
  values: List(String),
) -> #(String, json.Json) {
  #(
    name,
    json.object([
      #("type", json.string("string")),
      #("description", json.string(description)),
      #("enum", json.array(values, json.string)),
    ]),
  )
}

fn object_schema(
  properties: List(#(String, json.Json)),
  required: List(String),
) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("properties", json.object(properties)),
    #("required", json.array(required, json.string)),
    #("additionalProperties", json.bool(False)),
  ])
}
