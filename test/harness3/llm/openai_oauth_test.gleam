import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request as http_request
import gleam/option.{None, Some}
import gleam/string
import harness3/llm/openai_oauth
import simplifile

fn temporary_path(label: String) -> String {
  "/tmp/"
  <> label
  <> "-"
  <> { crypto.strong_random_bytes(9) |> bit_array.base64_url_encode(False) }
}

fn auth_json(access: String, refresh: String, expires: Int) -> String {
  "{\"zai\":{\"type\":\"api_key\",\"key\":\"zai-secret\"},\"openai-codex\":{\"type\":\"oauth\",\"access\":\""
  <> access
  <> "\",\"refresh\":\""
  <> refresh
  <> "\",\"expires\":"
  <> string.inspect(expires)
  <> ",\"accountId\":\"acct-1\"}}"
}

fn write_auth(path: String, access: String, refresh: String, expires: Int) -> Nil {
  let assert Ok(Nil) =
    simplifile.write(to: path, contents: auth_json(access, refresh, expires))
  Nil
}

pub fn load_reads_oauth_entry_test() {
  let path = temporary_path("harness3-oauth-load")
  write_auth(path, "access-1", "refresh-1", 1_000_000)
  let assert Ok(credentials) = openai_oauth.load(path)
  assert credentials.access == "access-1"
  assert credentials.refresh == "refresh-1"
  assert credentials.expires == 1_000_000
  assert credentials.account_id == "acct-1"
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn load_reports_missing_entry_test() {
  let path = temporary_path("harness3-oauth-missing")
  let assert Ok(Nil) =
    simplifile.write(to: path, contents: "{\"zai\":{\"type\":\"api_key\",\"key\":\"x\"}}")
  assert openai_oauth.load(path) == Error(openai_oauth.MissingCredentials)
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn ensure_fresh_keeps_valid_token_test() {
  let path = temporary_path("harness3-oauth-valid")
  write_auth(path, "access-1", "refresh-1", 1_000_000)
  let refresh = fn(_) { Error(openai_oauth.RefreshFailed("must not refresh")) }
  let assert Ok(credentials) = openai_oauth.ensure_fresh_with(path, 0, refresh)
  assert credentials.access == "access-1"
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn ensure_fresh_refreshes_and_persists_test() {
  let path = temporary_path("harness3-oauth-refresh")
  write_auth(path, "access-1", "refresh-1", 1000)
  let refresh = fn(token) {
    assert token == "refresh-1"
    Ok(openai_oauth.Refreshed("access-2", Some("refresh-2"), Some(3600)))
  }
  let assert Ok(credentials) = openai_oauth.ensure_fresh_with(path, 1000, refresh)
  assert credentials.access == "access-2"
  assert credentials.refresh == "refresh-2"
  assert credentials.expires == 1000 + 3_600_000
  // The rotated credentials replaced the stored ones...
  let assert Ok(reloaded) = openai_oauth.load(path)
  assert reloaded.access == "access-2"
  assert reloaded.refresh == "refresh-2"
  // ...and unrelated providers survived the rewrite.
  let assert Ok(body) = simplifile.read(path)
  assert string.contains(body, "zai-secret")
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn ensure_fresh_keeps_old_refresh_when_not_rotated_test() {
  let path = temporary_path("harness3-oauth-keep-refresh")
  write_auth(path, "access-1", "refresh-1", 1000)
  let refresh = fn(_) { Ok(openai_oauth.Refreshed("access-2", None, None)) }
  let assert Ok(credentials) = openai_oauth.ensure_fresh_with(path, 1000, refresh)
  assert credentials.refresh == "refresh-1"
  assert credentials.expires == 1000 + 3_600_000
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn ensure_fresh_accepts_concurrent_refresh_test() {
  let path = temporary_path("harness3-oauth-concurrent")
  write_auth(path, "access-1", "refresh-1", 1000)
  // Another process rotated the token before our refresh landed: the fake
  // fails but leaves fresh credentials on disk, which must be adopted.
  let refresh = fn(_) {
    write_auth(path, "access-2", "refresh-2", 9_999_999_999_999)
    Error(openai_oauth.RefreshFailed("refresh token already used"))
  }
  let assert Ok(credentials) = openai_oauth.ensure_fresh_with(path, 1000, refresh)
  assert credentials.access == "access-2"
  assert credentials.refresh == "refresh-2"
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn ensure_fresh_surfaces_refresh_failure_test() {
  let path = temporary_path("harness3-oauth-failure")
  write_auth(path, "access-1", "refresh-1", 1000)
  let refresh = fn(_) { Error(openai_oauth.RefreshFailed("invalid_grant")) }
  assert openai_oauth.ensure_fresh_with(path, 1000, refresh)
    == Error(openai_oauth.RefreshFailed("invalid_grant"))
  // A failed refresh leaves the stored credentials untouched.
  let assert Ok(reloaded) = openai_oauth.load(path)
  assert reloaded.access == "access-1"
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn refresh_request_shape_test() {
  let request = openai_oauth.refresh_request("rt.1.token/with+special=chars")
  assert request.method == http.Post
  assert request.host == "auth.openai.com"
  assert request.path == "/oauth/token"
  assert http_request.get_header(request, "content-type")
    == Ok("application/x-www-form-urlencoded")
  assert request.body
    == "grant_type=refresh_token&refresh_token=rt.1.token%2Fwith%2Bspecial%3Dchars&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
}

pub fn decode_token_response_test() {
  let assert Ok(refreshed) =
    openai_oauth.decode_token_response(
      200,
      "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":3600}",
    )
  assert refreshed.access == "a"
  assert refreshed.refresh == Some("r")
  assert refreshed.expires_in == Some(3600)

  let assert Ok(minimal) =
    openai_oauth.decode_token_response(200, "{\"access_token\":\"a\"}")
  assert minimal.refresh == None
  assert minimal.expires_in == None

  let assert Error(openai_oauth.RefreshFailed(reason)) =
    openai_oauth.decode_token_response(200, "{\"id_token\":\"x\"}")
  assert string.contains(reason, "invalid token response")

  let assert Error(openai_oauth.RefreshFailed(reason)) =
    openai_oauth.decode_token_response(401, "{\"error\":\"invalid_grant\"}")
  assert string.contains(reason, "401")
}
