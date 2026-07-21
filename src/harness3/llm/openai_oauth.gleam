import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/request as http_request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import gleam/uri
import harness3/plugin/mcp/json_document
import simplifile

/// Pi stores ChatGPT OAuth credentials in `auth.json` under this provider key.
pub const provider_id = "openai-codex"

const token_url = "https://auth.openai.com/oauth/token"

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

/// Refresh this long before the stored expiry so an in-flight request never
/// carries a token that lapses mid-flight.
const expiry_skew_milliseconds = 60_000

const refresh_timeout_milliseconds = 30_000

/// A conservative fallback lifetime when the token endpoint omits
/// `expires_in`; the next refresh is scheduled by the stored `expires`, so a
/// short fallback only costs an extra refresh.
const default_expires_in_seconds = 3600

pub type Credentials {
  Credentials(
    access: String,
    refresh: String,
    /// Epoch milliseconds after which the access token must be refreshed.
    expires: Int,
    account_id: String,
  )
}

pub type Error {
  ReadFailed(reason: String)
  DecodeFailed(reason: String)
  MissingCredentials
  RefreshFailed(reason: String)
  WriteFailed(reason: String)
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

/// A credentials resolver that reads and refreshes the OAuth file on every
/// call, suitable for long-lived providers whose access tokens rotate
/// independently of process lifetimes.
pub fn fresh_source(path: String) -> fn() -> Result(Credentials, Error) {
  fn() { ensure_fresh(path, system_time(Millisecond)) }
}

pub fn describe_error(error: Error) -> String {
  case error {
    ReadFailed(reason) -> "could not read OpenAI OAuth credentials: " <> reason
    DecodeFailed(reason) ->
      "could not decode OpenAI OAuth credentials: " <> reason
    MissingCredentials ->
      "no OAuth credentials for " <> provider_id <> " (log in with Pi first)"
    RefreshFailed(reason) -> "OpenAI OAuth token refresh failed: " <> reason
    WriteFailed(reason) ->
      "could not persist refreshed OpenAI OAuth credentials: " <> reason
  }
}

/// Reads the OAuth entry for `provider_id` from a Pi `auth.json` file.
pub fn load(path: String) -> Result(Credentials, Error) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      ReadFailed(simplifile.describe_error(error))
    }),
  )
  decode_credentials(body)
}

fn decode_credentials(body: String) -> Result(Credentials, Error) {
  use entries <- result.try(
    json.parse(body, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) }),
  )
  use entry <- result.try(
    dict.get(entries, provider_id)
    |> result.map_error(fn(_) { MissingCredentials }),
  )
  decode.run(entry, credentials_decoder())
  |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) })
}

fn credentials_decoder() -> decode.Decoder(Credentials) {
  use kind <- decode.field("type", decode.string)
  use access <- decode.field("access", decode.string)
  use refresh <- decode.field("refresh", decode.string)
  use expires <- decode.field("expires", decode.int)
  // The JWT claim is authoritative (see account_id/1); the stored field is
  // only a fallback and absent in older Pi auth files.
  use account_id <- decode.optional_field("accountId", "", decode.string)
  case kind {
    "oauth" -> decode.success(Credentials(access, refresh, expires, account_id))
    _ -> decode.failure(Credentials("", "", 0, ""), "expected oauth entry")
  }
}

/// True when the access token is expired or within the refresh skew of it.
pub fn expired(credentials: Credentials, now_milliseconds: Int) -> Bool {
  credentials.expires <= now_milliseconds + expiry_skew_milliseconds
}

/// The account id for the `chatgpt-account-id` header. Like Pi, the JWT
/// claim is authoritative and re-extracted on every request; the value
/// stored in auth.json is only a fallback for malformed tokens.
pub fn account_id(credentials: Credentials) -> String {
  case jwt_account_id(credentials.access) {
    Ok(account_id) -> account_id
    Error(_) -> credentials.account_id
  }
}

fn jwt_account_id(access: String) -> Result(String, Nil) {
  use payload <- result.try(case string.split(access, ".") {
    [_, payload, _] -> Ok(payload)
    _ -> Error(Nil)
  })
  use decoded <- result.try(
    bit_array.base64_url_decode(pad_base64(payload))
    |> result.map_error(fn(_) { Nil }),
  )
  use body <- result.try(
    bit_array.to_string(decoded)
    |> result.map_error(fn(_) { Nil }),
  )
  json.parse(body, {
    use auth <- decode.field(jwt_claim_path, {
      use account_id <- decode.field("chatgpt_account_id", decode.string)
      decode.success(account_id)
    })
    decode.success(auth)
  })
  |> result.map_error(fn(_) { Nil })
}

const jwt_claim_path = "https://api.openai.com/auth"

/// JWT segments are unpadded base64url; the decoder requires padding.
fn pad_base64(segment: String) -> String {
  case string.length(segment) % 4 {
    2 -> segment <> "=="
    3 -> segment <> "="
    _ -> segment
  }
}

/// The token endpoint's answer; a rotated refresh token replaces the stored
/// one, while a missing one means the old refresh token stays valid.
pub type Refreshed {
  Refreshed(access: String, refresh: Option(String), expires_in: Option(Int))
}

/// Loads credentials from `path`, refreshing and persisting them when the
/// access token is expired. Call this before every request: providers are
/// constructed once but tokens rotate independently of process lifetimes.
pub fn ensure_fresh(
  path: String,
  now_milliseconds: Int,
) -> Result(Credentials, Error) {
  ensure_fresh_with(path, now_milliseconds, refresh_token)
}

/// The refresh HTTP call is an explicit dependency so the expiry, merge, and
/// persistence logic is testable without a token endpoint.
pub fn ensure_fresh_with(
  path: String,
  now_milliseconds: Int,
  do_refresh: fn(String) -> Result(Refreshed, Error),
) -> Result(Credentials, Error) {
  use credentials <- result.try(load(path))
  case expired(credentials, now_milliseconds) {
    False -> Ok(credentials)
    True ->
      case do_refresh(credentials.refresh) {
        Ok(refreshed) -> {
          let merged = merge(credentials, refreshed, now_milliseconds)
          use _ <- result.try(persist(path, merged))
          Ok(merged)
        }
        Error(error) ->
          // A concurrent Pi or harness process may have already rotated the
          // refresh token: re-read the file and accept credentials that are
          // newer than the ones that just failed.
          case load(path) {
            Ok(reloaded) ->
              case
                reloaded.access != credentials.access
                && !expired(reloaded, now_milliseconds)
              {
                True -> Ok(reloaded)
                False -> Error(error)
              }
            Error(_) -> Error(error)
          }
      }
  }
}

fn merge(
  credentials: Credentials,
  refreshed: Refreshed,
  now_milliseconds: Int,
) -> Credentials {
  let expires_in =
    option.unwrap(refreshed.expires_in, default_expires_in_seconds)
  Credentials(
    access: refreshed.access,
    refresh: option.unwrap(refreshed.refresh, credentials.refresh),
    expires: now_milliseconds + expires_in * 1000,
    account_id: credentials.account_id,
  )
}

/// Writes the refreshed credentials back, preserving every other provider
/// entry in the file. The file is re-read first so a concurrent writer's
/// unrelated changes survive; the openai-codex entry itself is last-writer-
/// wins, which is safe because both writers hold valid rotated tokens.
pub fn persist(path: String, credentials: Credentials) -> Result(Nil, Error) {
  use body <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      ReadFailed(simplifile.describe_error(error))
    }),
  )
  use entries <- result.try(
    json.parse(body, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(error) { DecodeFailed(string.inspect(error)) }),
  )
  let encoded =
    entries
    |> dict.to_list
    |> list.map(fn(entry) { #(entry.0, json_document.from_dynamic(entry.1)) })
    |> dict.from_list
    |> dict.insert(provider_id, encode_credentials(credentials))
    |> dict.to_list
    |> json.object
    |> json.to_string
  use _ <- result.try(
    simplifile.write(path, encoded)
    |> result.map_error(fn(error) {
      WriteFailed(simplifile.describe_error(error))
    }),
  )
  // OAuth files hold bearer tokens; keep them owner-only like Pi does.
  simplifile.set_permissions_octal(path, 0o600)
  |> result.map_error(fn(error) {
    WriteFailed(simplifile.describe_error(error))
  })
}

fn encode_credentials(credentials: Credentials) -> json.Json {
  json.object([
    #("type", json.string("oauth")),
    #("access", json.string(credentials.access)),
    #("refresh", json.string(credentials.refresh)),
    #("expires", json.int(credentials.expires)),
    #("accountId", json.string(credentials.account_id)),
  ])
}

/// Builds the refresh-token grant request. Public so tests can assert the
/// exact wire shape Pi's backend expects.
pub fn refresh_request(refresh_token: String) -> http_request.Request(String) {
  let body =
    [
      #("grant_type", "refresh_token"),
      #("refresh_token", refresh_token),
      #("client_id", client_id),
    ]
    |> list.map(fn(field) { field.0 <> "=" <> form_encode(field.1) })
    |> string.join("&")
  let assert Ok(request) = http_request.to(token_url)
  request
  |> http_request.set_method(http.Post)
  |> http_request.set_header(
    "content-type",
    "application/x-www-form-urlencoded",
  )
  |> http_request.set_body(body)
}

/// gleam's percent_encode keeps `+`, which a form decoder reads back as a
/// space — corrupting any token that contains one. URLSearchParams (what Pi
/// uses) encodes it.
fn form_encode(value: String) -> String {
  value
  |> uri.percent_encode
  |> string.replace("+", "%2B")
}

/// Decodes the token endpoint response. Public for tests.
pub fn decode_token_response(
  status: Int,
  body: String,
) -> Result(Refreshed, Error) {
  case status >= 200 && status < 300 {
    False ->
      Error(RefreshFailed(
        "token endpoint returned status "
        <> int.to_string(status)
        <> ": "
        <> body,
      ))
    True -> {
      use refreshed <- result.try(
        json.parse(body, refreshed_decoder())
        |> result.map_error(fn(error) {
          RefreshFailed("invalid token response: " <> string.inspect(error))
        }),
      )
      case refreshed.access {
        "" -> Error(RefreshFailed("token response has no access_token"))
        _ -> Ok(refreshed)
      }
    }
  }
}

fn refreshed_decoder() -> decode.Decoder(Refreshed) {
  use access <- decode.field("access_token", decode.string)
  use refresh <- decode.optional_field(
    "refresh_token",
    None,
    decode.optional(decode.string),
  )
  use expires_in <- decode.optional_field(
    "expires_in",
    None,
    decode.optional(decode.int),
  )
  decode.success(Refreshed(access, refresh, expires_in))
}

fn refresh_token(refresh: String) -> Result(Refreshed, Error) {
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(refresh_timeout_milliseconds)
    |> httpc.dispatch(refresh_request(refresh))
    |> result.map_error(fn(error) {
      RefreshFailed("token request failed: " <> string.inspect(error))
    }),
  )
  decode_token_response(response.status, response.body)
}
