//// Conversions from wire timestamp formats to Unix epoch seconds, used to
//// normalize `Metadata.modified_at_seconds` across storage backends.

import exception
import gleam/dynamic.{type Dynamic}
import gleam/erlang/charlist.{type Charlist}
import gleam/result

const unix_epoch_gregorian_seconds = 62_167_219_200

/// Parses an HTTP-date header value (RFC 7231, e.g.
/// `Tue, 03 Jun 2025 12:00:00 GMT`) into Unix epoch seconds. Returns 0 for a
/// missing or unparseable value; the field is informational and 0 uniformly
/// marks "unknown".
pub fn http_date_seconds(value: String) -> Int {
  exception.rescue(fn() {
    // `convert_request_date` returns the atom `bad_date` on failure, which
    // makes `datetime_to_gregorian_seconds` raise; the rescue turns both
    // failure shapes into the 0 sentinel.
    gregorian_seconds(convert_request_date(charlist.from_string(value)))
    - unix_epoch_gregorian_seconds
  })
  |> result.unwrap(0)
}

/// Parses an RFC 3339 timestamp (e.g. `2025-06-03T12:00:00.000Z`, as returned
/// by the S3 list XML and the GCS JSON API) into Unix epoch seconds. Returns 0
/// for a missing or unparseable value.
pub fn rfc3339_seconds(value: String) -> Int {
  exception.rescue(fn() {
    rfc3339_to_system_time(charlist.from_string(value), [Unit(Millisecond)])
    / 1000
  })
  |> result.unwrap(0)
}

type Rfc3339Option {
  Unit(TimeUnit)
}

type TimeUnit {
  Millisecond
}

@external(erlang, "httpd_util", "convert_request_date")
fn convert_request_date(value: Charlist) -> Dynamic

@external(erlang, "calendar", "datetime_to_gregorian_seconds")
fn gregorian_seconds(datetime: Dynamic) -> Int

@external(erlang, "calendar", "rfc3339_to_system_time")
fn rfc3339_to_system_time(value: Charlist, options: List(Rfc3339Option)) -> Int
