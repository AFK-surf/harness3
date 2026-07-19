import exception
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import harness3/storage.{
  type BodySource, type Error, type Metadata, type Object, type PutCondition,
  type Storage, Backend, GcsGeneration, IfAbsent, IfUnchanged, InvalidCondition,
  LocalVersion, Metadata, NotFound, Object, PreconditionFailed, S3Etag,
  StreamAborted, Transport, Unconditional,
}
import harness3/storage/http_stream
import harness3/storage/retry

pub type Config {
  Config(bucket: String, access_token: String, endpoint: String)
}

/// Creates a configuration for the GCS JSON API using an OAuth access token.
pub fn config(bucket: String, access_token: String) -> Config {
  Config(bucket, access_token, "https://storage.googleapis.com")
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
}

type GcsObject {
  GcsObject(name: String, size: String, updated: String, generation: String)
}

type GcsPage {
  GcsPage(items: List(GcsObject), next_page_token: Option(String))
}

fn object_decoder() -> decode.Decoder(GcsObject) {
  use name <- decode.field("name", decode.string)
  use size <- decode.field("size", decode.string)
  use updated <- decode.field("updated", decode.string)
  use generation <- decode.field("generation", decode.string)
  decode.success(GcsObject(name, size, updated, generation))
}

fn page_decoder() -> decode.Decoder(GcsPage) {
  use items <- decode.optional_field(
    "items",
    [],
    decode.list(of: object_decoder()),
  )
  use next_page_token <- decode.optional_field(
    "nextPageToken",
    None,
    decode.optional(decode.string),
  )
  decode.success(GcsPage(items, next_page_token))
}

fn base_url(config: Config) -> String {
  let Config(endpoint:, ..) = config
  case string.ends_with(endpoint, "/") {
    True -> string.drop_end(endpoint, 1)
    False -> endpoint
  }
}

fn object_url(config: Config, key: String) -> String {
  let Config(bucket:, ..) = config
  base_url(config)
  <> "/storage/v1/b/"
  <> uri.percent_encode(bucket)
  <> "/o/"
  <> uri.percent_encode(key)
}

fn list_url(config: Config) -> String {
  let Config(bucket:, ..) = config
  base_url(config) <> "/storage/v1/b/" <> uri.percent_encode(bucket) <> "/o"
}

fn upload_url(config: Config) -> String {
  let Config(bucket:, ..) = config
  base_url(config)
  <> "/upload/storage/v1/b/"
  <> uri.percent_encode(bucket)
  <> "/o"
}

fn send(
  config: Config,
  method: http.Method,
  url: String,
  query: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), Error) {
  retry.http(fn() { send_once(config, method, url, query, body) })
}

fn send_once(
  config: Config,
  method: http.Method,
  url: String,
  query: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), Error) {
  let Config(access_token:, ..) = config
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Backend(0, "invalid GCS endpoint") }),
  )
  let req =
    req
    |> request.set_method(method)
    |> request.set_query(query)
    |> request.set_header("authorization", "Bearer " <> access_token)
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_body(body)
  httpc.send_bits(req)
  |> result.map_error(fn(error) { Transport(string.inspect(error)) })
}

fn body_message(body: BitArray) -> String {
  bit_array.to_string(body) |> result.unwrap(string.inspect(body))
}

fn status_error(response: Response(BitArray), key: String) -> Error {
  case response.status {
    404 -> NotFound(key)
    409 | 412 -> PreconditionFailed(key)
    status -> Backend(status, body_message(response.body))
  }
}

fn decoded_metadata(object: GcsObject) -> Result(Metadata, Error) {
  let GcsObject(name:, size:, updated:, generation:) = object
  case int.parse(size) {
    Ok(size) -> Ok(Metadata(name, size, updated, GcsGeneration(generation)))
    Error(_) -> Error(Backend(200, "GCS returned a non-integer object size"))
  }
}

fn decode_object(body: BitArray) -> Result(Metadata, Error) {
  use object <- result.try(
    json.parse_bits(body, object_decoder())
    |> result.map_error(fn(error) { Backend(200, string.inspect(error)) }),
  )
  decoded_metadata(object)
}

fn get_(config: Config, key: String) -> Result(Object, Error) {
  use response <- result.try(
    send(config, http.Get, object_url(config, key), [#("alt", "media")], <<>>),
  )
  case response.status {
    200 -> {
      // Media downloads expose HTTP-style metadata while `head` decodes the
      // canonical JSON resource. Use the latter for a backend-wide stable
      // Metadata representation.
      use metadata <- result.try(head_(config, key))
      Ok(Object(metadata, response.body))
    }
    _ -> Error(status_error(response, key))
  }
}

fn head_(config: Config, key: String) -> Result(Metadata, Error) {
  use response <- result.try(
    send(config, http.Get, object_url(config, key), [], <<>>),
  )
  case response.status {
    200 -> decode_object(response.body)
    _ -> Error(status_error(response, key))
  }
}

fn condition_query(
  condition: PutCondition,
) -> Result(List(#(String, String)), Error) {
  case condition {
    Unconditional -> Ok([])
    IfAbsent -> Ok([#("ifGenerationMatch", "0")])
    IfUnchanged(GcsGeneration(generation)) ->
      Ok([#("ifGenerationMatch", generation)])
    IfUnchanged(S3Etag(_)) -> Error(InvalidCondition("gcs", "s3"))
    IfUnchanged(LocalVersion(_, _)) -> Error(InvalidCondition("gcs", "local"))
  }
}

fn put_(
  config: Config,
  key: String,
  body: BitArray,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  use condition <- result.try(condition_query(condition))
  let query = [#("uploadType", "media"), #("name", key), ..condition]
  use response <- result.try(send(
    config,
    http.Post,
    upload_url(config),
    query,
    body,
  ))
  case response.status {
    200 -> decode_object(response.body)
    _ -> Error(status_error(response, key))
  }
}

fn list_(config: Config, prefix: String) -> Result(List(Metadata), Error) {
  list_pages(config, prefix, None, [])
}

fn list_pages(
  config: Config,
  prefix: String,
  page_token: Option(String),
  accumulator: List(Metadata),
) -> Result(List(Metadata), Error) {
  let query = add_optional_query([#("prefix", prefix)], "pageToken", page_token)
  use response <- result.try(
    send(config, http.Get, list_url(config), query, <<>>),
  )
  case response.status {
    200 -> {
      use page <- result.try(
        json.parse_bits(response.body, page_decoder())
        |> result.map_error(fn(error) { Backend(200, string.inspect(error)) }),
      )
      let GcsPage(items:, next_page_token:) = page
      use metadata <- result.try(list.try_map(items, decoded_metadata))
      let accumulator = list.append(accumulator, metadata)
      case next_page_token {
        Some(token) -> list_pages(config, prefix, Some(token), accumulator)
        None -> Ok(accumulator)
      }
    }
    _ -> Error(status_error(response, prefix))
  }
}

fn add_optional_query(
  query: List(#(String, String)),
  name: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    Some(value) -> [#(name, value), ..query]
    None -> query
  }
}

fn delete_(config: Config, key: String) -> Result(Nil, Error) {
  use response <- result.try(
    send(config, http.Delete, object_url(config, key), [], <<>>),
  )
  case response.status {
    204 | 404 -> Ok(Nil)
    _ -> Error(status_error(response, key))
  }
}

fn streaming_request(
  config: Config,
  method: http.Method,
  url: String,
  query: List(#(String, String)),
  size: Int,
) -> Result(Request(Nil), Error) {
  let Config(access_token:, ..) = config
  use request <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Backend(0, "invalid GCS endpoint") }),
  )
  Ok(
    request
    |> request.set_method(method)
    |> request.set_query(query)
    |> request.set_header("authorization", "Bearer " <> access_token)
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_header("content-length", int.to_string(size))
    |> request.set_body(Nil),
  )
}

fn stream_get_(
  config: Config,
  key: String,
  consume: fn(BitArray) -> Result(Nil, Error),
) -> Result(Metadata, Error) {
  use response <- result.try(
    http_stream.open_download(fn() {
      streaming_request(
        config,
        http.Get,
        object_url(config, key),
        [#("alt", "media")],
        0,
      )
    }),
  )
  let http_stream.StreamingResponse(connection:, ..) = response
  use <- exception.defer(fn() { http_stream.close(connection) })
  let http_stream.StreamingResponse(status:, headers:, ..) = response
  case status {
    200 -> {
      use _ <- result.try(http_stream.consume(response, consume))
      Ok(Metadata(
        key:,
        size: http_stream.header(headers, "content-length")
          |> int.parse
          |> result.unwrap(0),
        modified_at: http_stream.header(headers, "last-modified"),
        version: GcsGeneration(http_stream.header(headers, "x-goog-generation")),
      ))
    }
    _ -> {
      use body <- result.try(http_stream.collect(response))
      Error(status_error(Response(status, [], body), key))
    }
  }
}

fn stream_put_(
  config: Config,
  key: String,
  body: BodySource,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  let size = storage.body_source_size(body)
  case size < 0 {
    True -> Error(StreamAborted("stream size cannot be negative"))
    False -> {
      use condition <- result.try(condition_query(condition))
      let query = [#("uploadType", "media"), #("name", key), ..condition]
      use connection <- result.try(
        http_stream.connect_retry(fn() {
          streaming_request(config, http.Post, upload_url(config), query, size)
        }),
      )
      use <- exception.defer(fn() { http_stream.close(connection) })
      use _ <- result.try(send_source(connection, body, size, 0))
      use response <- result.try(http_stream.finish(connection))
      let http_stream.StreamingResponse(status:, ..) = response
      use response_body <- result.try(http_stream.collect(response))
      case status {
        200 -> decode_object(response_body)
        _ -> Error(status_error(Response(status, [], response_body), key))
      }
    }
  }
}

fn send_source(
  connection: http_stream.Connection,
  source: BodySource,
  expected_size: Int,
  sent: Int,
) -> Result(Nil, Error) {
  use next <- result.try(storage.read_body_chunk(source))
  case next {
    None ->
      case sent == expected_size {
        True -> Ok(Nil)
        False ->
          Error(StreamAborted(
            "stream ended after "
            <> int.to_string(sent)
            <> " bytes; expected "
            <> int.to_string(expected_size),
          ))
      }
    Some(chunk) -> {
      let sent = sent + bit_array.byte_size(chunk)
      case sent > expected_size {
        True -> Error(StreamAborted("stream exceeded its declared size"))
        False -> {
          use _ <- result.try(http_stream.send_chunk(connection, chunk))
          send_source(connection, source, expected_size, sent)
        }
      }
    }
  }
}
