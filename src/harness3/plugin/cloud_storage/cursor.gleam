import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Cursor {
  Cursor(prefix: String, after: String)
}

pub fn encode(prefix: String, after: String) -> String {
  json.object([
    #("schema_version", json.int(1)),
    #("prefix", json.string(prefix)),
    #("after", json.string(after)),
  ])
  |> json.to_string
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

pub fn decode(value: String) -> Result(Cursor, String) {
  use bytes <- result.try(
    bit_array.base64_url_decode(value)
    |> result.map_error(fn(_) { "cursor is not valid base64url" }),
  )
  use document <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { "cursor is not valid UTF-8" }),
  )
  json.parse(document, decoder())
  |> result.map_error(fn(_) { "cursor has an invalid payload" })
}

fn decoder() -> decode.Decoder(Cursor) {
  use schema_version <- decode.field("schema_version", decode.int)
  use prefix <- decode.field("prefix", decode.string)
  use after <- decode.field("after", decode.string)
  case schema_version {
    1 -> decode.success(Cursor(prefix, after))
    _ -> decode.failure(Cursor("", ""), "unsupported cursor schema")
  }
}
