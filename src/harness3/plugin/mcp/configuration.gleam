import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/plugin/mcp/json_document

pub const protocol_version = "2025-11-25"

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
    exposed_name: String,
    description: Option(String),
    input_schema: json.Json,
    output_schema: Option(json.Json),
  )
}

pub type Manifest {
  Manifest(refreshed_at_seconds: Int, tools: List(Tool))
}

pub type Configuration {
  Configuration(
    id: String,
    label: String,
    enabled: Bool,
    servers: List(Server),
    manifest: Option(Manifest),
  )
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
  use _ <- result.try(list.try_each(configuration.servers, validate_server))
  case configuration.manifest {
    None -> Ok(Nil)
    Some(manifest) -> validate_manifest(configuration, manifest)
  }
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

pub fn exposed_tool_name(server_id: String, tool_name: String) -> String {
  let readable =
    "mcp__" <> sanitize_name(server_id) <> "__" <> sanitize_name(tool_name)
  let digest =
    crypto.hash(
      crypto.Sha256,
      bit_array.from_string(server_id <> "\u{0}" <> tool_name),
    )
    |> bit_array.base16_encode
    |> string.slice(0, 12)
  string.slice(readable, 0, 49) <> "__" <> digest
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

fn validate_manifest(
  configuration: Configuration,
  manifest: Manifest,
) -> Result(Nil, Error) {
  let server_ids = list.map(configuration.servers, fn(server) { server.id })
  manifest.tools
  |> list.try_fold([], fn(names, tool) {
    use _ <- result.try(case list.contains(server_ids, tool.server_id) {
      True -> Ok(Nil)
      False ->
        Error(InvalidConfiguration(
          "manifest references unknown MCP server: " <> tool.server_id,
        ))
    })
    use _ <- result.try(validate_json_object(
      "input schema for " <> tool.name,
      tool.input_schema,
    ))
    use _ <- result.try(case tool.output_schema {
      None -> Ok(Nil)
      Some(schema) ->
        validate_json_object("output schema for " <> tool.name, schema)
    })
    case list.contains(names, tool.exposed_name) {
      True ->
        Error(InvalidConfiguration(
          "duplicate exposed MCP tool name: " <> tool.exposed_name,
        ))
      False -> Ok([tool.exposed_name, ..names])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_json_object(
  label: String,
  document: json.Json,
) -> Result(Nil, Error) {
  json.parse(
    json.to_string(document),
    decode.dict(decode.string, decode.dynamic),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(_) {
    InvalidConfiguration(label <> " must be a JSON object")
  })
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
    #("manifest", json.nullable(configuration.manifest, encode_manifest)),
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

fn encode_manifest(manifest: Manifest) -> json.Json {
  json.object([
    #("refreshed_at_seconds", json.int(manifest.refreshed_at_seconds)),
    #("tools", json.array(manifest.tools, encode_tool)),
  ])
}

fn encode_tool(tool: Tool) -> json.Json {
  json.object([
    #("server_id", json.string(tool.server_id)),
    #("name", json.string(tool.name)),
    #("exposed_name", json.string(tool.exposed_name)),
    #("description", json.nullable(tool.description, json.string)),
    #("input_schema", tool.input_schema),
    #("output_schema", json.nullable(tool.output_schema, fn(value) { value })),
  ])
}

pub fn decoder() -> decode.Decoder(Configuration) {
  use id <- decode.field("id", decode.string)
  use label <- decode.optional_field("label", id, decode.string)
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  use servers <- decode.field("servers", decode.list(of: server_decoder()))
  use manifest <- decode.optional_field(
    "manifest",
    None,
    decode.optional(manifest_decoder()),
  )
  decode.success(Configuration(id, label, enabled, servers, manifest))
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

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use refreshed <- decode.field("refreshed_at_seconds", decode.int)
  use tools <- decode.field("tools", decode.list(of: tool_decoder()))
  decode.success(Manifest(refreshed, tools))
}

fn tool_decoder() -> decode.Decoder(Tool) {
  use server_id <- decode.field("server_id", decode.string)
  use name <- decode.field("name", decode.string)
  use exposed_name <- decode.field("exposed_name", decode.string)
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use input_schema <- decode.field("input_schema", json_document_decoder())
  use output_schema <- decode.optional_field(
    "output_schema",
    None,
    decode.optional(json_document_decoder()),
  )
  decode.success(Tool(
    server_id,
    name,
    exposed_name,
    description,
    input_schema,
    output_schema,
  ))
}

fn json_document_decoder() -> decode.Decoder(json.Json) {
  json_document.object_decoder()
}
