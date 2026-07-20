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
    <> encode_path(request.path)
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

/// Signs a request using SigV4 query authentication. The returned request can
/// be converted directly to a presigned URL and uses `UNSIGNED-PAYLOAD`, as
/// required when the body of a future upload is not yet known.
pub fn presign(
  signer: Signer,
  request: Request(body),
  expires_in_seconds: Int,
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
  let scope = date <> "/" <> region <> "/" <> service <> "/aws4_request"
  let host = case request.port {
    None -> request.host
    Some(port) -> request.host <> ":" <> int.to_string(port)
  }
  let existing_query = case request.query {
    Some(value) -> uri.parse_query(value) |> result.unwrap([])
    None -> []
  }
  let query = [
    #("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
    #("X-Amz-Credential", access_key_id <> "/" <> scope),
    #("X-Amz-Date", date_time_text),
    #("X-Amz-Expires", int.to_string(expires_in_seconds)),
    #("X-Amz-SignedHeaders", "host"),
    ..existing_query
  ]
  let query = case session_token {
    Some(token) -> [#("X-Amz-Security-Token", token), ..query]
    None -> query
  }
  let canonical_query = encode_query(query)
  let canonical_request =
    string.uppercase(http.method_to_string(request.method))
    <> "\n"
    <> encode_path(request.path)
    <> "\n"
    <> canonical_query
    <> "\nhost:"
    <> host
    <> "\n\nhost\nUNSIGNED-PAYLOAD"
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
  Request(
    ..request,
    query: Some(canonical_query <> "&X-Amz-Signature=" <> signature),
  )
}

fn add_session_token(headers, token) {
  case token {
    None -> headers
    Some(token) -> [#("x-amz-security-token", token), ..headers]
  }
}

/// Percent-encodes a path for SigV4. `uri.percent_encode` is not usable here:
/// it passes sub-delimiters (`! $ \' ( ) * +`) through unencoded, so the
/// canonical request would disagree with what the service computes — and with
/// the wire path, which must use this same encoding.
pub fn encode_path(path: String) -> String {
  case path {
    "" -> "/"
    _ ->
      path
      |> string.split("/")
      |> list.map(sigv4_encode)
      |> string.join("/")
  }
}

fn canonical_query(query: Option(String)) -> String {
  let query = case query {
    Some(value) -> value
    None -> ""
  }
  // SigV4 requires each parameter name and value to be percent-encoded with
  // only RFC 3986 unreserved characters passed through (space as %20, `+` as
  // %2B, uppercase hex). Neither query_to_string (form encoding, space as +)
  // nor uri.percent_encode (passes through sub-delims like `!$'()*+`)
  // matches what the service computes for such values. Callers that ever set
  // a query must also build the wire query with this same encoding.
  query |> uri.parse_query |> result.unwrap([]) |> encode_query
}

fn encode_query(query: List(#(String, String))) -> String {
  query
  |> list.map(fn(pair) { #(sigv4_encode(pair.0), sigv4_encode(pair.1)) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
  |> string.join("&")
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

@external(erlang, "os", "system_time")
fn system_time(unit: Int) -> Int

@external(erlang, "calendar", "system_time_to_universal_time")
fn system_time_to_universal_time(time: Int, unit: Int) -> DateTime

fn now() -> DateTime {
  system_time(1000) |> system_time_to_universal_time(1000)
}
