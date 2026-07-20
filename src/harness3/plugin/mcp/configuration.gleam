import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The revision proposed during initialization.
pub const protocol_version = "2025-11-25"

/// Revisions this client accepts when a server negotiates down. The wire
/// shapes used here (initialize, tools/list paging, tools/call content) are
/// compatible across these revisions.
pub const supported_protocol_versions = [
  "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
]

pub type Value {
  Literal(value: String)
  EnvironmentVariable(name: String)
}

pub type Binding {
  Binding(name: String, value: Value)
}

pub type Transport {
  Stdio(
    executable: String,
    arguments: List(String),
    working_directory: Option(String),
    environment: List(Binding),
  )
  StreamableHttp(endpoint: String, headers: List(Binding))
}

pub type Server {
  Server(id: String, transport: Transport, timeout_milliseconds: Int)
}

pub type Tool {
  Tool(
    server_id: String,
    name: String,
    broker_name: String,
    description: Option(String),
    input_schema: json.Json,
    output_schema: Option(json.Json),
  )
}

pub type Configuration {
  Configuration(id: String, label: String, enabled: Bool, servers: List(Server))
}

pub type Error {
  InvalidConfiguration(reason: String)
  MissingEnvironmentVariable(name: String)
}

pub fn validate(configuration: Configuration) -> Result(Nil, Error) {
  use _ <- result.try(validate_id("configuration", configuration.id))
  use _ <- result.try(case string.trim(configuration.label) {
    "" -> Error(InvalidConfiguration("configuration label cannot be empty"))
    _ -> Ok(Nil)
  })
  use _ <- result.try(unique_server_ids(configuration.servers))
  list.try_each(configuration.servers, validate_server)
}

pub fn resolve_bindings(
  bindings: List(Binding),
  resolve_environment: fn(String) -> Result(String, Nil),
) -> Result(List(#(String, String)), Error) {
  list.try_map(bindings, fn(binding) {
    let Binding(name:, value:) = binding
    use value <- result.try(case value {
      Literal(value) -> Ok(value)
      EnvironmentVariable(variable) ->
        resolve_environment(variable)
        |> result.map_error(fn(_) { MissingEnvironmentVariable(variable) })
    })
    Ok(#(name, value))
  })
}

pub fn broker_tool_name(server_id: String, tool_name: String) -> String {
  let readable =
    "server_"
    <> snake_case_part(server_id)
    <> "_tool_"
    <> snake_case_part(tool_name)
  let digest =
    crypto.hash(
      crypto.Sha256,
      bit_array.from_string(server_id <> "\u{0}" <> tool_name),
    )
    |> bit_array.base16_encode
    |> string.lowercase
    |> string.slice(0, 12)
  "mcp." <> string.slice(readable, 0, 46) <> "_" <> digest
}

fn snake_case_part(value: String) -> String {
  value
  |> string.lowercase
  |> string.to_graphemes
  |> collapse_name_separators([], False)
  |> trim_trailing_separator
  |> string.concat
}

fn collapse_name_separators(
  remaining: List(String),
  accumulated: List(String),
  separated: Bool,
) -> List(String) {
  case remaining {
    [] -> accumulated
    [grapheme, ..rest] ->
      case is_snake_grapheme(grapheme), list.is_empty(accumulated), separated {
        True, _, _ ->
          collapse_name_separators(
            rest,
            list.append(accumulated, [grapheme]),
            False,
          )
        False, True, _ | False, _, True ->
          collapse_name_separators(rest, accumulated, separated)
        False, False, False ->
          collapse_name_separators(rest, list.append(accumulated, ["_"]), True)
      }
  }
}

fn trim_trailing_separator(value: List(String)) -> List(String) {
  case list.reverse(value) {
    ["_", ..rest] -> list.reverse(rest)
    _ -> value
  }
}

fn is_snake_grapheme(value: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz0123456789", value)
}

fn sanitize_name(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case is_safe_grapheme(grapheme) {
      True -> grapheme
      False -> "_"
    }
  })
  |> string.concat
}

fn is_safe_grapheme(value: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    value,
  )
}

fn validate_server(server: Server) -> Result(Nil, Error) {
  use _ <- result.try(validate_id("server", server.id))
  use _ <- result.try(
    case
      server.timeout_milliseconds > 0 && server.timeout_milliseconds <= 300_000
    {
      True -> Ok(Nil)
      False ->
        Error(InvalidConfiguration(
          "MCP server timeout must be between 1 and 300000 milliseconds: "
          <> server.id,
        ))
    },
  )
  case server.transport {
    Stdio(executable, _, working_directory, environment) -> {
      use _ <- result.try(case filepath.is_absolute(executable) {
        True -> Ok(Nil)
        False ->
          Error(InvalidConfiguration(
            "MCP executable must be absolute: " <> executable,
          ))
      })
      use _ <- result.try(case working_directory {
        None -> Ok(Nil)
        Some(path) ->
          case filepath.is_absolute(path) {
            True -> Ok(Nil)
            False ->
              Error(InvalidConfiguration(
                "MCP working directory must be absolute: " <> path,
              ))
          }
      })
      validate_bindings(environment)
    }
    StreamableHttp(endpoint, headers) -> {
      use _ <- result.try(
        case
          string.starts_with(endpoint, "https://")
          || string.starts_with(endpoint, "http://")
        {
          True -> Ok(Nil)
          False ->
            Error(InvalidConfiguration(
              "MCP HTTP endpoint must be absolute: " <> endpoint,
            ))
        },
      )
      validate_bindings(headers)
    }
  }
}

fn validate_bindings(bindings: List(Binding)) -> Result(Nil, Error) {
  bindings
  |> list.try_fold([], fn(names, binding) {
    let Binding(name:, value:) = binding
    use _ <- result.try(case string.trim(name) {
      "" -> Error(InvalidConfiguration("binding name cannot be empty"))
      _ -> Ok(Nil)
    })
    use _ <- result.try(case value {
      EnvironmentVariable("") ->
        Error(InvalidConfiguration(
          "environment variable reference cannot be empty",
        ))
      _ -> Ok(Nil)
    })
    case list.contains(names, name) {
      True -> Error(InvalidConfiguration("duplicate binding: " <> name))
      False -> Ok([name, ..names])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_id(kind: String, id: String) -> Result(Nil, Error) {
  case string.trim(id), sanitize_name(id) == id {
    "", _ -> Error(InvalidConfiguration(kind <> " ID cannot be empty"))
    _, False ->
      Error(InvalidConfiguration(
        kind
        <> " ID may contain only letters, digits, underscore, and hyphen: "
        <> id,
      ))
    _, True -> Ok(Nil)
  }
}

fn unique_server_ids(servers: List(Server)) -> Result(Nil, Error) {
  servers
  |> list.try_fold([], fn(ids, server) {
    case list.contains(ids, server.id) {
      True ->
        Error(InvalidConfiguration("duplicate MCP server ID: " <> server.id))
      False -> Ok([server.id, ..ids])
    }
  })
  |> result.map(fn(_) { Nil })
}

pub fn encode(configuration: Configuration) -> json.Json {
  json.object([
    #("id", json.string(configuration.id)),
    #("label", json.string(configuration.label)),
    #("enabled", json.bool(configuration.enabled)),
    #("servers", json.array(configuration.servers, encode_server)),
  ])
}

fn encode_server(server: Server) -> json.Json {
  json.object([
    #("id", json.string(server.id)),
    #("timeout_milliseconds", json.int(server.timeout_milliseconds)),
    #("transport", encode_transport(server.transport)),
  ])
}

fn encode_transport(transport: Transport) -> json.Json {
  case transport {
    Stdio(executable, arguments, working_directory, environment) ->
      json.object([
        #("type", json.string("stdio")),
        #("executable", json.string(executable)),
        #("arguments", json.array(arguments, json.string)),
        #("working_directory", json.nullable(working_directory, json.string)),
        #("environment", json.array(environment, encode_binding)),
      ])
    StreamableHttp(endpoint, headers) ->
      json.object([
        #("type", json.string("streamable_http")),
        #("endpoint", json.string(endpoint)),
        #("headers", json.array(headers, encode_binding)),
      ])
  }
}

fn encode_binding(binding: Binding) -> json.Json {
  let #(kind, value) = case binding.value {
    Literal(value) -> #("literal", value)
    EnvironmentVariable(name) -> #("environment_variable", name)
  }
  json.object([
    #("name", json.string(binding.name)),
    #(
      "value",
      json.object([
        #("type", json.string(kind)),
        #("value", json.string(value)),
      ]),
    ),
  ])
}

pub fn decoder() -> decode.Decoder(Configuration) {
  use id <- decode.field("id", decode.string)
  use label <- decode.optional_field("label", id, decode.string)
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  use servers <- decode.field("servers", decode.list(of: server_decoder()))
  decode.success(Configuration(id, label, enabled, servers))
}

pub fn server_decoder() -> decode.Decoder(Server) {
  use id <- decode.field("id", decode.string)
  use timeout <- decode.optional_field(
    "timeout_milliseconds",
    60_000,
    decode.int,
  )
  use transport <- decode.field("transport", transport_decoder())
  decode.success(Server(id, transport, timeout))
}

fn transport_decoder() -> decode.Decoder(Transport) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "stdio" -> {
      use executable <- decode.field("executable", decode.string)
      use arguments <- decode.optional_field(
        "arguments",
        [],
        decode.list(of: decode.string),
      )
      use working_directory <- decode.optional_field(
        "working_directory",
        None,
        decode.optional(decode.string),
      )
      use environment <- decode.optional_field(
        "environment",
        [],
        decode.list(of: binding_decoder()),
      )
      decode.success(Stdio(
        executable,
        arguments,
        working_directory,
        environment,
      ))
    }
    "streamable_http" -> {
      use endpoint <- decode.field("endpoint", decode.string)
      use headers <- decode.optional_field(
        "headers",
        [],
        decode.list(of: binding_decoder()),
      )
      decode.success(StreamableHttp(endpoint, headers))
    }
    _ -> decode.failure(Stdio("", [], None, []), "unknown MCP transport type")
  }
}

fn binding_decoder() -> decode.Decoder(Binding) {
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", value_decoder())
  decode.success(Binding(name, value))
}

fn value_decoder() -> decode.Decoder(Value) {
  use kind <- decode.field("type", decode.string)
  use value <- decode.field("value", decode.string)
  case kind {
    "literal" -> decode.success(Literal(value))
    "environment_variable" -> decode.success(EnvironmentVariable(value))
    _ -> decode.failure(Literal(""), "unknown MCP configuration value type")
  }
}
