import aws4_request.{type Signer, Signer}
import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

type DateTime =
  #(#(Int, Int, Int), #(Int, Int, Int))

/// Signs a request with a caller-supplied payload hash. S3 permits
/// `UNSIGNED-PAYLOAD` for TLS-protected streaming requests.
pub fn sign(
  signer: Signer,
  request: Request(body),
  payload_hash: String,
) -> Request(body) {
  let Signer(
    date_time:,
    access_key_id:,
    secret_access_key:,
    region:,
    service:,
    session_token:,
  ) = signer
  let current_time = case date_time {
    Some(value) -> value
    None -> now()
  }
  let #(#(year, month, day), #(hour, minute, second)) = current_time
  let date =
    string.pad_start(int.to_string(year), 4, "0")
    <> string.pad_start(int.to_string(month), 2, "0")
    <> string.pad_start(int.to_string(day), 2, "0")
  let date_time_text =
    date
    <> "T"
    <> string.pad_start(int.to_string(hour), 2, "0")
    <> string.pad_start(int.to_string(minute), 2, "0")
    <> string.pad_start(int.to_string(second), 2, "0")
    <> "Z"
  let request =
    request.set_header(request, "host", case request.port {
      None -> request.host
      Some(port) -> request.host <> ":" <> int.to_string(port)
    })
  let headers =
    request.headers
    |> add_session_token(session_token)
    |> list.prepend(#("x-amz-date", date_time_text))
    |> list.prepend(#("x-amz-content-sha256", payload_hash))
    |> list.map(fn(header) { #(string.lowercase(header.0), header.1) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let header_names = headers |> list.map(fn(h) { h.0 }) |> string.join(";")
  let canonical_request =
    string.uppercase(http.method_to_string(request.method))
    <> "\n"
    <> canonical_path(request.path)
    <> "\n"
    <> canonical_query(request.query)
    <> "\n"
    <> {
      headers
      |> list.map(fn(h) { h.0 <> ":" <> string.trim(h.1) })
      |> string.join("\n")
    }
    <> "\n\n"
    <> header_names
    <> "\n"
    <> payload_hash
  let scope = date <> "/" <> region <> "/" <> service <> "/aws4_request"
  let to_sign =
    "AWS4-HMAC-SHA256\n"
    <> date_time_text
    <> "\n"
    <> scope
    <> "\n"
    <> sha256_hex(bit_array.from_string(canonical_request))
  let key =
    <<"AWS4":utf8, secret_access_key:utf8>>
    |> crypto.hmac(<<date:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<region:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<service:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<"aws4_request":utf8>>, crypto.Sha256, _)
  let signature =
    crypto.hmac(bit_array.from_string(to_sign), crypto.Sha256, key)
    |> bit_array.base16_encode
    |> string.lowercase
  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> access_key_id
    <> "/"
    <> scope
    <> ",SignedHeaders="
    <> header_names
    <> ",Signature="
    <> signature
  Request(..request, headers: [#("authorization", authorization), ..headers])
}

fn add_session_token(headers, token) {
  case token {
    None -> headers
    Some(token) -> [#("x-amz-security-token", token), ..headers]
  }
}

fn canonical_path(path: String) -> String {
  case path {
    "" -> "/"
    _ ->
      path
      |> string.split("/")
      |> list.map(uri.percent_encode)
      |> string.join("/")
  }
}

fn canonical_query(query: Option(String)) -> String {
  let query = case query {
    Some(value) -> value
    None -> ""
  }
  query
  |> uri.parse_query
  |> result.unwrap([])
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> uri.query_to_string
}

fn sha256_hex(data: BitArray) -> String {
  crypto.hash(crypto.Sha256, data)
  |> bit_array.base16_encode
  |> string.lowercase
}

@external(erlang, "os", "system_time")
fn system_time(unit: Int) -> Int

@external(erlang, "calendar", "system_time_to_universal_time")
fn system_time_to_universal_time(time: Int, unit: Int) -> DateTime

fn now() -> DateTime {
  system_time(1000) |> system_time_to_universal_time(1000)
}
