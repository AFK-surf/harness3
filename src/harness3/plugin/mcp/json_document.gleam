import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

pub fn from_dynamic(value: Dynamic) -> json.Json {
  encode_dynamic(value)
}

pub fn to_string(value: Dynamic) -> String {
  value |> from_dynamic |> json.to_string
}

pub fn object_decoder() -> decode.Decoder(json.Json) {
  decode.dynamic
  |> decode.then(fn(value) {
    case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
      Ok(_) -> decode.success(from_dynamic(value))
      Error(_) -> decode.failure(json.object([]), "expected a JSON object")
    }
  })
}

pub fn parse_object(document: String) -> Result(json.Json, String) {
  json.parse(document, object_decoder())
  |> result.map_error(fn(error) {
    "expected a JSON object: " <> string.inspect(error)
  })
}

fn encode_dynamic(value: Dynamic) -> json.Json {
  case decode.run(value, decode.string) {
    Ok(value) -> json.string(value)
    Error(_) -> encode_non_string(value)
  }
}

fn encode_non_string(value: Dynamic) -> json.Json {
  case decode.run(value, decode.bool) {
    Ok(value) -> json.bool(value)
    Error(_) -> encode_non_bool(value)
  }
}

fn encode_non_bool(value: Dynamic) -> json.Json {
  case decode.run(value, decode.int) {
    Ok(value) -> json.int(value)
    Error(_) -> encode_non_int(value)
  }
}

fn encode_non_int(value: Dynamic) -> json.Json {
  case decode.run(value, decode.float) {
    Ok(value) -> json.float(value)
    Error(_) -> encode_non_number(value)
  }
}

fn encode_non_number(value: Dynamic) -> json.Json {
  case decode.run(value, decode.list(of: decode.dynamic)) {
    Ok(values) -> json.array(values, encode_dynamic)
    Error(_) -> encode_non_list(value)
  }
}

fn encode_non_list(value: Dynamic) -> json.Json {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(values) ->
      values
      |> dict.to_list
      |> list.map(fn(entry) { #(entry.0, encode_dynamic(entry.1)) })
      |> json.object
    Error(_) -> {
      let assert Ok(None) = decode.run(value, decode.optional(decode.dynamic))
      json.null()
    }
  }
}
