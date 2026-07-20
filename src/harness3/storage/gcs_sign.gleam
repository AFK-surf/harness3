import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/uri

type DateTime =
  #(#(Int, Int, Int), #(Int, Int, Int))

pub opaque type Signer {
  Signer(
    date_time: Option(DateTime),
    access_key_id: String,
    secret_access_key: String,
    location: String,
  )
}

pub fn signer(access_key_id: String, secret_access_key: String) -> Signer {
  Signer(None, access_key_id, secret_access_key, "auto")
}

pub fn with_date_time(
  signer: Signer,
  date_time: #(#(Int, Int, Int), #(Int, Int, Int)),
) -> Signer {
  Signer(..signer, date_time: Some(date_time))
}

pub fn sign(
  signer: Signer,
  request: Request(body),
  payload_hash: String,
) -> Request(body) {
  let Signer(access_key_id:, location:, ..) = signer
  let #(date, date_time) = signing_time(signer)
  let credential_scope = date <> "/" <> location <> "/storage/goog4_request"
  let request =
    request
    |> request.set_header("host", host_header(request))
    |> request.set_header("x-goog-date", date_time)
    |> request.set_header("x-goog-content-sha256", payload_hash)
  let signed_headers =
    request.headers
    |> list.filter(fn(header) {
      let name = string.lowercase(header.0)
      name == "host" || string.starts_with(name, "x-goog-")
    })
    |> list.map(fn(header) {
      #(string.lowercase(header.0), string.trim(header.1))
    })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  let signed_header_names =
    signed_headers |> list.map(fn(header) { header.0 }) |> string.join(";")
  let canonical_headers =
    signed_headers
    |> list.map(fn(header) { header.0 <> ":" <> header.1 })
    |> string.join("\n")
  let canonical_request =
    string.uppercase(http.method_to_string(request.method))
    <> "\n"
    <> encode_path(request.path)
    <> "\n"
    <> canonical_query(request.query)
    <> "\n"
    <> canonical_headers
    <> "\n\n"
    <> signed_header_names
    <> "\n"
    <> payload_hash
  let string_to_sign =
    "GOOG4-HMAC-SHA256\n"
    <> date_time
    <> "\n"
    <> credential_scope
    <> "\n"
    <> sha256_hex(bit_array.from_string(canonical_request))
  let signature = signature(signer, date, string_to_sign)
  let authorization =
    "GOOG4-HMAC-SHA256 Credential="
    <> access_key_id
    <> "/"
    <> credential_scope
    <> ",SignedHeaders="
    <> signed_header_names
    <> ",Signature="
    <> signature
  request.set_header(request, "authorization", authorization)
}

pub fn presign(
  signer: Signer,
  request: Request(body),
  expires_in_seconds: Int,
) -> Request(body) {
  let Signer(access_key_id:, location:, ..) = signer
  let #(date, date_time) = signing_time(signer)
  let credential_scope = date <> "/" <> location <> "/storage/goog4_request"
  let existing_query = case request.query {
    Some(query) -> uri.parse_query(query) |> result.unwrap([])
    None -> []
  }
  let canonical_query =
    encode_query([
      #("X-Goog-Algorithm", "GOOG4-HMAC-SHA256"),
      #("X-Goog-Credential", access_key_id <> "/" <> credential_scope),
      #("X-Goog-Date", date_time),
      #("X-Goog-Expires", int.to_string(expires_in_seconds)),
      #("X-Goog-SignedHeaders", "host"),
      ..existing_query
    ])
  let canonical_request =
    string.uppercase(http.method_to_string(request.method))
    <> "\n"
    <> encode_path(request.path)
    <> "\n"
    <> canonical_query
    <> "\nhost:"
    <> host_header(request)
    <> "\n\nhost\nUNSIGNED-PAYLOAD"
  let string_to_sign =
    "GOOG4-HMAC-SHA256\n"
    <> date_time
    <> "\n"
    <> credential_scope
    <> "\n"
    <> sha256_hex(bit_array.from_string(canonical_request))
  let signature = signature(signer, date, string_to_sign)
  Request(
    ..request,
    query: Some(canonical_query <> "&X-Goog-Signature=" <> signature),
  )
}

pub fn encode_path(path: String) -> String {
  case path {
    "" -> "/"
    path ->
      path
      |> string.split("/")
      |> list.map(sigv4_encode)
      |> string.join("/")
  }
}

pub fn encode_query(query: List(#(String, String))) -> String {
  query
  |> list.map(fn(pair) { #(sigv4_encode(pair.0), sigv4_encode(pair.1)) })
  |> list.sort(fn(left, right) {
    case string.compare(left.0, right.0) {
      order.Eq -> string.compare(left.1, right.1)
      ordering -> ordering
    }
  })
  |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
  |> string.join("&")
}

fn canonical_query(query: Option(String)) -> String {
  case query {
    Some(query) -> query |> uri.parse_query |> result.unwrap([]) |> encode_query
    None -> ""
  }
}

fn host_header(request: Request(body)) -> String {
  case request.port {
    None -> request.host
    Some(port) -> request.host <> ":" <> int.to_string(port)
  }
}

fn signature(signer: Signer, date: String, string_to_sign: String) -> String {
  let Signer(secret_access_key:, location:, ..) = signer
  let key =
    <<"GOOG4":utf8, secret_access_key:utf8>>
    |> crypto.hmac(<<date:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<location:utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<"storage":utf8>>, crypto.Sha256, _)
    |> crypto.hmac(<<"goog4_request":utf8>>, crypto.Sha256, _)
  crypto.hmac(bit_array.from_string(string_to_sign), crypto.Sha256, key)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn sigv4_encode(value: String) -> String {
  encode_sigv4_bytes(bit_array.from_string(value), "")
}

fn encode_sigv4_bytes(bytes: BitArray, encoded: String) -> String {
  case bytes {
    <<byte, rest:bytes>> ->
      encode_sigv4_bytes(rest, encoded <> encode_sigv4_byte(byte))
    _ -> encoded
  }
}

fn encode_sigv4_byte(byte: Int) -> String {
  let unreserved =
    { byte >= 0x41 && byte <= 0x5A }
    || { byte >= 0x61 && byte <= 0x7A }
    || { byte >= 0x30 && byte <= 0x39 }
    || byte == 0x2D
    || byte == 0x2E
    || byte == 0x5F
    || byte == 0x7E
  case unreserved, string.utf_codepoint(byte) {
    True, Ok(codepoint) -> string.from_utf_codepoints([codepoint])
    _, _ -> "%" <> string.pad_start(int.to_base16(byte), 2, "0")
  }
}

fn sha256_hex(data: BitArray) -> String {
  crypto.hash(crypto.Sha256, data)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn signing_time(signer: Signer) -> #(String, String) {
  let Signer(date_time:, ..) = signer
  let #(#(year, month, day), #(hour, minute, second)) = case date_time {
    Some(value) -> value
    None -> now()
  }
  let date =
    string.pad_start(int.to_string(year), 4, "0")
    <> string.pad_start(int.to_string(month), 2, "0")
    <> string.pad_start(int.to_string(day), 2, "0")
  let date_time =
    date
    <> "T"
    <> string.pad_start(int.to_string(hour), 2, "0")
    <> string.pad_start(int.to_string(minute), 2, "0")
    <> string.pad_start(int.to_string(second), 2, "0")
    <> "Z"
  #(date, date_time)
}

@external(erlang, "os", "system_time")
fn system_time(unit: Int) -> Int

@external(erlang, "calendar", "system_time_to_universal_time")
fn system_time_to_universal_time(time: Int, unit: Int) -> DateTime

fn now() -> DateTime {
  system_time(1000) |> system_time_to_universal_time(1000)
}
