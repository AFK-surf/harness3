import exception
import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response, Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{Uri}
import harness3/storage.{
  type BodySource, type Error, type Metadata, type Object, type PutCondition,
  type Storage, type TransferOperation, Backend, Download, GcsGeneration,
  IfAbsent, IfUnchanged, InvalidCondition, LocalVersion, Metadata, NotFound,
  Object, PreconditionFailed, S3Etag, StreamAborted, TransferUrl, Transport,
  Unconditional, Upload,
}
import harness3/storage/gcs_sign
import harness3/storage/gcs_xml
import harness3/storage/http_stream
import harness3/storage/retry
import harness3/storage/timestamp

pub type Config {
  Config(
    bucket: String,
    access_key_id: String,
    secret_access_key: String,
    endpoint: String,
  )
}

/// Creates a configuration for the GCS XML API using an interoperable HMAC
/// access ID and secret.
pub fn config(
  bucket: String,
  access_key_id: String,
  secret_access_key: String,
) -> Config {
  Config(
    bucket,
    access_key_id,
    secret_access_key,
    "https://storage.googleapis.com",
  )
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

type Endpoint {
  Endpoint(http.Scheme, String, Option(Int))
}

fn endpoint(config: Config) -> Result(Endpoint, Error) {
  let Config(endpoint: endpoint_url, ..) = config
  case uri.parse(endpoint_url) {
    Ok(Uri(scheme: Some(scheme), host: Some(host), port:, path:, ..))
      if path == "" || path == "/"
    ->
      case http.scheme_from_string(scheme) {
        Ok(scheme) -> Ok(Endpoint(scheme, host, port))
        Error(_) -> Error(Backend(0, "GCS endpoint must use http or https"))
      }
    _ -> Error(Backend(0, "invalid GCS endpoint"))
  }
}

fn signer(config: Config) -> gcs_sign.Signer {
  let Config(access_key_id:, secret_access_key:, ..) = config
  gcs_sign.signer(access_key_id, secret_access_key)
}

fn object_path(config: Config, key: String) -> String {
  let Config(bucket:, ..) = config
  "/" <> bucket <> "/" <> key
}

fn bucket_path(config: Config) -> String {
  let Config(bucket:, ..) = config
  "/" <> bucket
}

fn wire_path(path: String) -> String {
  gcs_sign.encode_path(path)
}

fn query_string(query: List(#(String, String))) -> Option(String) {
  case query {
    [] -> None
    query -> Some(gcs_sign.encode_query(query))
  }
}

fn request_(
  config: Config,
  method: http.Method,
  path: String,
  query: List(#(String, String)),
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Request(BitArray), Error) {
  use Endpoint(scheme, host, port) <- result.try(endpoint(config))
  let payload_hash =
    crypto.hash(crypto.Sha256, body)
    |> bit_array.base16_encode
    |> string.lowercase
  let signed =
    Request(
      method,
      [#("content-type", "application/octet-stream"), ..headers],
      body,
      scheme,
      host,
      port,
      path,
      query_string(query),
    )
    |> gcs_sign.sign(signer(config), _, payload_hash)
  Ok(Request(..signed, path: wire_path(path)))
}

fn send(
  make_request: fn() -> Result(Request(BitArray), Error),
) -> Result(Response(BitArray), Error) {
  retry.http(fn() {
    use request <- result.try(make_request())
    httpc.send_bits(request)
    |> result.map_error(fn(error) { Transport(string.inspect(error)) })
  })
}

fn response_header(response: Response(body), name: String) -> String {
  response.headers |> list.key_find(name) |> result.unwrap("")
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

fn response_metadata(
  response: Response(body),
  key: String,
  fallback_size: Int,
) -> Metadata {
  Metadata(
    key:,
    size: response_header(response, "content-length")
      |> int.parse
      |> result.unwrap(fallback_size),
    modified_at_seconds: timestamp.http_date_seconds(response_header(
      response,
      "last-modified",
    )),
    version: GcsGeneration(response_header(response, "x-goog-generation")),
  )
}

fn get_(config: Config, key: String) -> Result(Object, Error) {
  use response <- result.try(
    send(fn() {
      request_(config, http.Get, object_path(config, key), [], [], <<>>)
    }),
  )
  case response.status {
    200 ->
      Ok(Object(
        response_metadata(response, key, bit_array.byte_size(response.body)),
        response.body,
      ))
    _ -> Error(status_error(response, key))
  }
}

fn head_(config: Config, key: String) -> Result(Metadata, Error) {
  use response <- result.try(
    send(fn() {
      request_(config, http.Head, object_path(config, key), [], [], <<>>)
    }),
  )
  case response.status {
    200 -> Ok(response_metadata(response, key, 0))
    _ -> Error(status_error(response, key))
  }
}

fn condition_headers(
  condition: PutCondition,
) -> Result(List(#(String, String)), Error) {
  case condition {
    Unconditional -> Ok([])
    IfAbsent -> Ok([#("x-goog-if-generation-match", "0")])
    IfUnchanged(GcsGeneration(generation)) ->
      Ok([#("x-goog-if-generation-match", generation)])
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
  use headers <- result.try(condition_headers(condition))
  use response <- result.try(
    send(fn() {
      request_(config, http.Put, object_path(config, key), [], headers, body)
    }),
  )
  case response.status {
    // A PUT response's `content-length` describes its own (empty) response
    // body, not the stored object; the size written is authoritative.
    200 ->
      Ok(
        Metadata(
          ..response_metadata(response, key, 0),
          size: bit_array.byte_size(body),
        ),
      )
    _ -> Error(status_error(response, key))
  }
}

fn list_(config: Config, prefix: String) -> Result(List(Metadata), Error) {
  list_pages(config, prefix, None, [])
}

fn list_pages(
  config: Config,
  prefix: String,
  start_after: Option(String),
  accumulator: List(Metadata),
) -> Result(List(Metadata), Error) {
  let query =
    [#("list-type", "2"), #("prefix", prefix)]
    |> add_optional_query("start-after", start_after)
  use response <- result.try(
    send(fn() {
      request_(config, http.Get, bucket_path(config), query, [], <<>>)
    }),
  )
  use page <- result.try(case response.status {
    200 ->
      gcs_xml.decode_page(response.body)
      |> result.map_error(fn(error) { Backend(200, error) })
    _ -> Error(status_error(response, prefix))
  })
  let gcs_xml.Page(is_truncated:, objects:) = page
  let objects = list.reverse(objects)
  let metadata =
    list.map(objects, fn(object) {
      let gcs_xml.ListedObject(key:, generation:, last_modified:, size:) =
        object
      Metadata(
        key,
        size,
        timestamp.rfc3339_seconds(last_modified),
        GcsGeneration(generation),
      )
    })
  let accumulator = list.append(accumulator, metadata)
  case is_truncated, list.last(objects) {
    True, Ok(gcs_xml.ListedObject(key:, ..)) ->
      list_pages(config, prefix, Some(key), accumulator)
    True, Error(_) ->
      Error(Backend(200, "truncated GCS listing had no continuation key"))
    False, _ -> Ok(accumulator)
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
    send(fn() {
      request_(config, http.Delete, object_path(config, key), [], [], <<>>)
    }),
  )
  case response.status {
    204 | 404 -> Ok(Nil)
    _ -> Error(status_error(response, key))
  }
}

fn streaming_request(
  config: Config,
  method: http.Method,
  path: String,
  headers: List(#(String, String)),
  size: Int,
) -> Result(Request(Nil), Error) {
  use Endpoint(scheme, host, port) <- result.try(endpoint(config))
  let signed =
    Request(
      method,
      [
        #("content-length", int.to_string(size)),
        #("content-type", "application/octet-stream"),
        ..headers
      ],
      Nil,
      scheme,
      host,
      port,
      path,
      None,
    )
    |> gcs_sign.sign(signer(config), _, "UNSIGNED-PAYLOAD")
  Ok(Request(..signed, path: wire_path(path)))
}

fn stream_get_(
  config: Config,
  key: String,
  consume: fn(BitArray) -> Result(Nil, Error),
) -> Result(Metadata, Error) {
  use response <- result.try(
    http_stream.open_download(fn() {
      streaming_request(config, http.Get, object_path(config, key), [], 0)
    }),
  )
  let http_stream.StreamingResponse(connection:, ..) = response
  use <- exception.defer(fn() { http_stream.close(connection) })
  let http_stream.StreamingResponse(status:, headers:, ..) = response
  case status {
    200 -> {
      use _ <- result.try(http_stream.consume(response, consume))
      Ok(metadata_from_headers(headers, key, 0))
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
      use headers <- result.try(condition_headers(condition))
      use connection <- result.try(
        http_stream.connect_retry(fn() {
          streaming_request(
            config,
            http.Put,
            object_path(config, key),
            headers,
            size,
          )
        }),
      )
      use <- exception.defer(fn() { http_stream.close(connection) })
      use _ <- result.try(send_source(connection, body, size, 0))
      use response <- result.try(http_stream.finish(connection))
      let http_stream.StreamingResponse(status:, headers:, ..) = response
      use response_body <- result.try(http_stream.collect(response))
      case status {
        // As in `put_`: the PUT response's `content-length` is not the
        // object size; the streamed byte count is.
        200 -> Ok(Metadata(..metadata_from_headers(headers, key, 0), size:))
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

fn metadata_from_headers(
  headers: List(#(String, String)),
  key: String,
  fallback_size: Int,
) -> Metadata {
  Metadata(
    key:,
    size: http_stream.header(headers, "content-length")
      |> int.parse
      |> result.unwrap(fallback_size),
    modified_at_seconds: timestamp.http_date_seconds(http_stream.header(
      headers,
      "last-modified",
    )),
    version: GcsGeneration(http_stream.header(headers, "x-goog-generation")),
  )
}

fn transfer_url_(
  config: Config,
  key: String,
  operation: TransferOperation,
  expires_in_seconds: Int,
) -> Result(storage.TransferUrl, Error) {
  use _ <- result.try(
    case expires_in_seconds >= 1 && expires_in_seconds <= 604_800 {
      True -> Ok(Nil)
      False ->
        Error(Backend(0, "GCS signed URL expiry must be 1-604800 seconds"))
    },
  )
  use Endpoint(scheme, host, port) <- result.try(endpoint(config))
  let method = case operation {
    Upload -> http.Put
    Download -> http.Get
  }
  let signed =
    Request(
      method,
      [],
      <<>>,
      scheme,
      host,
      port,
      object_path(config, key),
      None,
    )
    |> gcs_sign.presign(signer(config), _, expires_in_seconds)
  let signed = Request(..signed, path: wire_path(signed.path))
  Ok(TransferUrl(
    signed |> request.to_uri |> uri.to_string,
    Some(expires_in_seconds),
  ))
}
