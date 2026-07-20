import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import harness3/storage.{type Error, Transport}

pub type Connection

pub type StreamingResponse {
  StreamingResponse(
    status: Int,
    headers: List(#(String, String)),
    connection: Connection,
  )
}

type RequestBody {
  Stream
}

@external(erlang, "hackney", "request")
fn hackney_request(
  method: method,
  url: BitArray,
  headers: List(#(BitArray, BitArray)),
  body: RequestBody,
  options: List(Nil),
) -> Result(Connection, Dynamic)

@external(erlang, "hackney", "send_body")
fn hackney_send_body(connection: Connection, chunk: BitArray) -> Dynamic

@external(erlang, "hackney", "finish_send_body")
fn hackney_finish_body(connection: Connection) -> Dynamic

@external(erlang, "hackney", "start_response")
fn hackney_start_response(connection: Connection) -> Dynamic

@external(erlang, "hackney", "stream_body")
fn hackney_stream_body(connection: Connection) -> Dynamic

@external(erlang, "hackney", "close")
fn hackney_close(connection: Connection) -> Dynamic

@external(erlang, "erlang", "element")
fn tuple_element(position: Int, tuple: Dynamic) -> Dynamic

@external(erlang, "erlang", "is_tuple")
fn is_tuple(value: Dynamic) -> Bool

@external(erlang, "erlang", "tuple_size")
fn tuple_size(value: Dynamic) -> Int

pub fn connect(request: Request(body)) -> Result(Connection, Error) {
  let url =
    request
    |> request.to_uri
    |> uri.to_string
    |> bit_array.from_string
  let headers =
    list.map(request.headers, fn(header) {
      #(bit_array.from_string(header.0), bit_array.from_string(header.1))
    })
  hackney_request(request.method, url, headers, Stream, [])
  |> result.map_error(fn(error) { Transport(string.inspect(error)) })
}

/// Bounded like `retry.http`: a persistent outage must surface as an error
/// rather than block the calling process forever.
const maximum_attempts = 8

pub fn connect_retry(
  make_request: fn() -> Result(Request(body), Error),
) -> Result(Connection, Error) {
  connect_retry_loop(make_request, 100, maximum_attempts - 1)
}

fn connect_retry_loop(
  make_request: fn() -> Result(Request(body), Error),
  delay_ms: Int,
  remaining: Int,
) -> Result(Connection, Error) {
  use request <- result.try(make_request())
  case connect(request) {
    Ok(connection) -> Ok(connection)
    Error(Transport(_)) as failure ->
      case remaining > 0 {
        True -> {
          let next_delay = wait(delay_ms)
          connect_retry_loop(make_request, next_delay, remaining - 1)
        }
        False -> failure
      }
    Error(error) -> Error(error)
  }
}

/// Opens a download, retrying only before a successful response body begins.
pub fn open_download(
  make_request: fn() -> Result(Request(body), Error),
) -> Result(StreamingResponse, Error) {
  open_download_loop(make_request, 100, maximum_attempts - 1)
}

fn open_download_loop(
  make_request: fn() -> Result(Request(body), Error),
  delay_ms: Int,
  remaining: Int,
) -> Result(StreamingResponse, Error) {
  use connection <- result.try(connect_retry_loop(
    make_request,
    delay_ms,
    remaining,
  ))
  case finish(connection) {
    Error(Transport(_)) as failure -> {
      close(connection)
      case remaining > 0 {
        True -> {
          let next_delay = wait(delay_ms)
          open_download_loop(make_request, next_delay, remaining - 1)
        }
        False -> failure
      }
    }
    Error(error) -> {
      close(connection)
      Error(error)
    }
    Ok(StreamingResponse(status:, ..) as response) ->
      case transient_status(status) && remaining > 0 {
        True -> {
          close(connection)
          let next_delay = wait(delay_ms)
          open_download_loop(make_request, next_delay, remaining - 1)
        }
        False -> Ok(response)
      }
  }
}

fn wait(delay_ms: Int) -> Int {
  process.sleep(delay_ms + int.random(int.max(1, delay_ms / 2)))
  int.min(10_000, delay_ms * 2)
}

fn transient_status(status: Int) -> Bool {
  status == 408
  || status == 421
  || status == 425
  || status == 429
  || { status >= 500 && status < 600 && status != 501 && status != 505 }
}

pub fn send_chunk(
  connection: Connection,
  chunk: BitArray,
) -> Result(Nil, Error) {
  status_result(hackney_send_body(connection, chunk))
}

pub fn finish(connection: Connection) -> Result(StreamingResponse, Error) {
  use _ <- result.try(status_result(hackney_finish_body(connection)))
  let reply = hackney_start_response(connection)
  case is_tuple(reply) && tuple_size(reply) == 4 {
    False -> Error(Transport(string.inspect(reply)))
    True -> {
      use status <- result.try(
        decode.run(tuple_element(2, reply), decode.int)
        |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
      )
      use raw_headers <- result.try(
        decode.run(tuple_element(3, reply), decode.list(of: decode.dynamic))
        |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
      )
      use headers <- result.try(list.try_map(raw_headers, decode_header))
      Ok(StreamingResponse(
        status,
        list.map(headers, fn(header) {
          #(
            bit_array.to_string(header.0) |> result.unwrap(""),
            bit_array.to_string(header.1) |> result.unwrap(""),
          )
        }),
        connection,
      ))
    }
  }
}

fn decode_header(value: Dynamic) -> Result(#(BitArray, BitArray), Error) {
  case is_tuple(value) && tuple_size(value) == 2 {
    False -> Error(Transport("invalid streaming HTTP response header"))
    True -> {
      use name <- result.try(
        decode.run(tuple_element(1, value), decode.bit_array)
        |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
      )
      use value <- result.try(
        decode.run(tuple_element(2, value), decode.bit_array)
        |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
      )
      Ok(#(name, value))
    }
  }
}

pub fn consume(
  response: StreamingResponse,
  consumer: fn(BitArray) -> Result(Nil, Error),
) -> Result(Nil, Error) {
  let StreamingResponse(connection:, ..) = response
  consume_connection(connection, consumer)
}

fn consume_connection(
  connection: Connection,
  consumer: fn(BitArray) -> Result(Nil, Error),
) -> Result(Nil, Error) {
  let reply = hackney_stream_body(connection)
  case string.inspect(reply) {
    "Done" -> Ok(Nil)
    _ ->
      case is_tuple(reply) && tuple_size(reply) == 2 {
        False -> Error(Transport(string.inspect(reply)))
        True ->
          case string.inspect(tuple_element(1, reply)) {
            "Ok" -> {
              use chunk <- result.try(
                decode.run(tuple_element(2, reply), decode.bit_array)
                |> result.map_error(fn(error) {
                  Transport(string.inspect(error))
                }),
              )
              use _ <- result.try(consumer(chunk))
              consume_connection(connection, consumer)
            }
            _ -> Error(Transport(string.inspect(tuple_element(2, reply))))
          }
      }
  }
}

pub fn collect(response: StreamingResponse) -> Result(BitArray, Error) {
  collect_chunks(response, [])
}

fn collect_chunks(
  response: StreamingResponse,
  chunks: List(BitArray),
) -> Result(BitArray, Error) {
  let StreamingResponse(connection:, ..) = response
  let reply = hackney_stream_body(connection)
  case string.inspect(reply) {
    "Done" -> Ok(bit_array.concat(list.reverse(chunks)))
    _ ->
      case
        is_tuple(reply)
        && tuple_size(reply) == 2
        && string.inspect(tuple_element(1, reply)) == "Ok"
      {
        True -> {
          use chunk <- result.try(
            decode.run(tuple_element(2, reply), decode.bit_array)
            |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
          )
          collect_chunks(response, [chunk, ..chunks])
        }
        False -> Error(Transport(string.inspect(reply)))
      }
  }
}

pub fn close(connection: Connection) -> Nil {
  let _ = hackney_close(connection)
  Nil
}

pub fn header(headers: List(#(String, String)), name: String) -> String {
  headers
  |> list.find(fn(header) { string.lowercase(header.0) == name })
  |> result.map(fn(header) { header.1 })
  |> result.unwrap("")
}

fn status_result(status: Dynamic) -> Result(Nil, Error) {
  case string.inspect(status) {
    "Ok" -> Ok(Nil)
    _ -> Error(Transport(string.inspect(status)))
  }
}
