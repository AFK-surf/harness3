import aws4_request
import bucket/list_objects
import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri.{Uri}
import harness3/storage.{
  type Error, type Metadata, type Object, type PutCondition, type Storage,
  Backend, GcsGeneration, IfAbsent, IfUnchanged, InvalidCondition, LocalVersion,
  Metadata, NotFound, Object, PreconditionFailed, S3Etag, Transport,
  Unconditional,
}

pub type Config {
  Config(
    bucket: String,
    region: String,
    access_key_id: String,
    secret_access_key: String,
    session_token: Option(String),
    endpoint: String,
  )
}

/// Creates a configuration for AWS S3 using its regional endpoint.
pub fn config(
  bucket: String,
  region: String,
  access_key_id: String,
  secret_access_key: String,
) -> Config {
  Config(
    bucket,
    region,
    access_key_id,
    secret_access_key,
    None,
    "https://s3." <> region <> ".amazonaws.com",
  )
}

pub fn new(config: Config) -> Storage {
  storage.from_functions(
    get: fn(key) { get_(config, key) },
    head: fn(key) { head_(config, key) },
    put: fn(key, body, condition) { put_(config, key, body, condition) },
    list: fn(prefix) { list_(config, prefix) },
    delete: fn(key) { delete_(config, key) },
  )
}

type Endpoint {
  Endpoint(http.Scheme, String, Option(Int))
}

fn endpoint(config: Config) -> Result(Endpoint, Error) {
  let Config(endpoint: endpoint_url, ..) = config
  case uri.parse(endpoint_url) {
    Ok(Uri(scheme: Some(scheme), host: Some(host), port:, path:, ..))
      if path == "" || path == "/" ->
      case http.scheme_from_string(scheme) {
        Ok(scheme) -> Ok(Endpoint(scheme, host, port))
        Error(_) -> Error(Backend(0, "S3 endpoint must use http or https"))
      }
    _ -> Error(Backend(0, "invalid S3 endpoint"))
  }
}

fn signer(config: Config) -> aws4_request.Signer {
  let Config(
    region:,
    access_key_id:,
    secret_access_key:,
    session_token:,
    ..
  ) = config
  let signer =
    aws4_request.signer(access_key_id, secret_access_key, region, "s3")
  case session_token {
    Some(token) -> aws4_request.with_session_token(signer, token)
    None -> signer
  }
}

fn request(
  config: Config,
  method: http.Method,
  path: String,
  query: Option(String),
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Request(BitArray), Error) {
  use endpoint <- result.try(endpoint(config))
  let Endpoint(scheme, host, port) = endpoint
  Ok(
    Request(method, headers, body, scheme, host, port, path, query)
    |> aws4_request.sign_bits(signer(config), _),
  )
}

fn object_path(config: Config, key: String) -> String {
  let Config(bucket:, ..) = config
  "/" <> bucket <> "/" <> key
}

fn send(req: Request(BitArray)) -> Result(Response(BitArray), Error) {
  httpc.send_bits(req)
  |> result.map_error(fn(error) { Transport(string.inspect(error)) })
}

fn response_header(response: Response(body), name: String) -> String {
  response.headers
  |> list.key_find(name)
  |> result.unwrap("")
}

fn response_metadata(
  response: Response(body),
  key: String,
  fallback_size: Int,
) -> Metadata {
  let size =
    response_header(response, "content-length")
    |> int.parse
    |> result.unwrap(fallback_size)
  Metadata(
    key:,
    size:,
    modified_at: response_header(response, "last-modified"),
    version: S3Etag(response_header(response, "etag")),
  )
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

fn get_(config: Config, key: String) -> Result(Object, Error) {
  use req <- result.try(
    request(config, http.Get, object_path(config, key), None, [], <<>>),
  )
  use response <- result.try(send(req))
  case response.status {
    200 ->
      Ok(Object(response_metadata(response, key, bit_array.byte_size(response.body)), response.body))
    _ -> Error(status_error(response, key))
  }
}

fn head_(config: Config, key: String) -> Result(Metadata, Error) {
  use req <- result.try(
    request(config, http.Head, object_path(config, key), None, [], <<>>),
  )
  use response <- result.try(send(req))
  case response.status {
    200 -> Ok(response_metadata(response, key, 0))
    _ -> Error(status_error(response, key))
  }
}

fn condition_headers(condition: PutCondition) -> Result(List(#(String, String)), Error) {
  case condition {
    Unconditional -> Ok([])
    IfAbsent -> Ok([#("if-none-match", "*")])
    IfUnchanged(S3Etag(etag)) -> Ok([#("if-match", etag)])
    IfUnchanged(GcsGeneration(_)) -> Error(InvalidCondition("s3", "gcs"))
    IfUnchanged(LocalVersion(_, _)) -> Error(InvalidCondition("s3", "local"))
  }
}

fn put_(
  config: Config,
  key: String,
  body: BitArray,
  condition: PutCondition,
) -> Result(Metadata, Error) {
  use headers <- result.try(condition_headers(condition))
  use req <- result.try(
    request(config, http.Put, object_path(config, key), None, headers, body),
  )
  use response <- result.try(send(req))
  case response.status {
    200 ->
      Ok(
        Metadata(
          key:,
          size: bit_array.byte_size(body),
          modified_at: response_header(response, "date"),
          version: S3Etag(response_header(response, "etag")),
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
  let Config(bucket:, ..) = config
  let query =
    [#("list-type", "2"), #("prefix", prefix)]
    |> add_optional_query("start-after", start_after)
    |> uri.query_to_string
  use req <- result.try(
    request(config, http.Get, "/" <> bucket, Some(query), [], <<>>),
  )
  use response <- result.try(send(req))
  case list_objects.response(response) {
    Ok(list_objects.ListObjectsResult(is_truncated:, contents:)) -> {
      let contents = list.reverse(contents)
      let metadata =
        contents
        |> list.map(fn(object) {
          let list_objects.Object(key:, last_modified:, etag:, size:) = object
          Metadata(key, size, last_modified, S3Etag(etag))
        })
      let accumulator = list.append(accumulator, metadata)
      case is_truncated, list.last(contents) {
        True, Ok(list_objects.Object(key:, ..)) ->
          list_pages(config, prefix, Some(key), accumulator)
        True, Error(_) -> Error(Backend(200, "truncated S3 listing had no continuation key"))
        False, _ -> Ok(accumulator)
      }
    }
    Error(error) -> Error(Backend(response.status, string.inspect(error)))
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
  use req <- result.try(
    request(config, http.Delete, object_path(config, key), None, [], <<>>),
  )
  use response <- result.try(send(req))
  case response.status {
    204 -> Ok(Nil)
    _ -> Error(status_error(response, key))
  }
}
