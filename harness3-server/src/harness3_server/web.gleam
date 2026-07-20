import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/agent
import harness3/agent_group
import harness3/llm
import harness3/model_catalog
import harness3/plugin/mcp/configuration as mcp_configuration
import harness3_server/config
import harness3_server/service.{type Service, type Session}
import mist.{type ResponseData}
import simplifile

const max_request_bytes = 1_048_576

pub fn start(service: Service) -> Result(Nil, String) {
  let bind = config.environment_or("HARNESS3_BIND", "127.0.0.1")
  let port = config.environment_int("HARNESS3_PORT", 8080)
  let failure = error_response(413, "request body exceeds 1 MiB")
  mist.new(fn(request) { handle(service, request) })
  |> mist.bind(bind)
  |> mist.port(port)
  |> mist.read_request_body(
    bytes_limit: max_request_bytes,
    failure_response: failure,
  )
  |> mist.start
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn handle(
  service: Service,
  request: Request(BitArray),
) -> Response(ResponseData) {
  let segments =
    request.path |> string.split("/") |> list.filter(fn(s) { s != "" })
  case request.method, segments {
    http.Get, [] -> static_response("index.html", "text/html; charset=utf-8")
    http.Get, ["styles.css"] ->
      static_response("styles.css", "text/css; charset=utf-8")
    http.Get, ["app.js"] ->
      static_response("app.js", "text/javascript; charset=utf-8")
    http.Get, ["api", "health"] ->
      json_response(
        200,
        json.object([
          #("ok", json.bool(True)),
          #("workspace_root", json.string(service.workspace_root(service))),
        ]),
      )
    http.Get, ["api", "models"] ->
      json_response(
        200,
        json.object([
          #("models", json.array(service.models(service), model_json)),
        ]),
      )
    http.Get, ["api", "mcp", "configurations"] ->
      json_response(
        200,
        json.object([
          #(
            "configurations",
            json.array(
              service.mcp_configurations(service),
              mcp_configuration_json,
            ),
          ),
        ]),
      )
    http.Post, ["api", "mcp", "servers"] ->
      add_mcp_server(service, request.body)
    http.Delete,
      ["api", "mcp", "configurations", configuration_id, "servers", server_id]
    -> remove_mcp_server(service, configuration_id, server_id)
    http.Get, ["api", "sessions"] ->
      outcome(service.list_sessions(service), fn(sessions) {
        json.object([#("sessions", json.array(sessions, session_json))])
      })
    http.Post, ["api", "sessions"] -> create_session(service, request.body)
    http.Get, ["api", "sessions", id] ->
      case service.get_session(service, id) {
        Ok(session) -> json_response(200, session_json(session))
        Error(error) -> error_response(404, error)
      }
    http.Post, ["api", "sessions", id, "messages"] ->
      send_message(service, id, request.body)
    http.Post, ["api", "sessions", id, "agents", agent_id, "compact"] ->
      request_compaction(service, id, agent_id)
    http.Post, ["api", "sessions", id, "stop"] ->
      case service.stop_session(service, id) {
        Ok(Nil) -> json_response(200, json.object([#("ok", json.bool(True))]))
        Error(error) -> error_response(400, error)
      }
    _, ["api", ..] -> error_response(404, "API route not found")
    _, _ -> error_response(404, "not found")
  }
}

fn create_session(service: Service, body: BitArray) -> Response(ResponseData) {
  use input <- body_decoded(body, create_input_decoder())
  case service.create_session(service, input) {
    Ok(session) -> json_response(201, session_json(session))
    Error(error) -> error_response(400, error)
  }
}

fn send_message(
  service: Service,
  id: String,
  body: BitArray,
) -> Response(ResponseData) {
  use message <- body_decoded(body, message_decoder())
  case service.send_message(service, id, message.agent_id, message.message) {
    Ok(Nil) -> json_response(202, json.object([#("ok", json.bool(True))]))
    Error(error) -> error_response(400, error)
  }
}

fn request_compaction(
  service: Service,
  id: String,
  agent_id: String,
) -> Response(ResponseData) {
  case service.request_compaction(service, id, agent_id) {
    Ok(generation) ->
      json_response(
        202,
        json.object([
          #("ok", json.bool(True)),
          #("generation", json.int(generation)),
        ]),
      )
    Error(error) -> error_response(409, error)
  }
}

fn add_mcp_server(service: Service, body: BitArray) -> Response(ResponseData) {
  use input <- body_decoded(body, add_mcp_server_decoder())
  case
    service.add_mcp_server(
      service,
      input.configuration_id,
      input.configuration_label,
      input.server,
    )
  {
    Ok(configuration) ->
      json_response(201, mcp_configuration_json(configuration))
    Error(error) -> error_response(400, error)
  }
}

fn remove_mcp_server(
  service: Service,
  configuration_id: String,
  server_id: String,
) -> Response(ResponseData) {
  case service.remove_mcp_server(service, configuration_id, server_id) {
    Ok(configuration) ->
      json_response(200, mcp_configuration_json(configuration))
    Error(error) -> error_response(404, error)
  }
}

fn body_decoded(
  body: BitArray,
  decoder: decode.Decoder(value),
  continue: fn(value) -> Response(ResponseData),
) -> Response(ResponseData) {
  let decoded = {
    use text <- result.try(
      bit_array.to_string(body)
      |> result.map_error(fn(_) { "request body is not UTF-8" }),
    )
    json.parse(text, decoder)
    |> result.map_error(fn(error) {
      "invalid JSON request: " <> string.inspect(error)
    })
  }
  case decoded {
    Ok(value) -> continue(value)
    Error(error) -> error_response(400, error)
  }
}

fn outcome(
  value: Result(a, String),
  encode: fn(a) -> json.Json,
) -> Response(ResponseData) {
  case value {
    Ok(value) -> json_response(200, encode(value))
    Error(error) -> error_response(500, error)
  }
}

fn json_response(status: Int, value: json.Json) -> Response(ResponseData) {
  bytes_response(
    status,
    json.to_string(value),
    "application/json; charset=utf-8",
  )
}

fn error_response(status: Int, message: String) -> Response(ResponseData) {
  json_response(
    status,
    json.object([
      #("error", json.string(message)),
    ]),
  )
}

fn static_response(
  file: String,
  content_type: String,
) -> Response(ResponseData) {
  let body = {
    use directory <- result.try(
      application.priv_directory("harness3_server")
      |> result.map_error(fn(_) { "application priv directory is unavailable" }),
    )
    simplifile.read(directory <> "/static/" <> file)
    |> result.map_error(simplifile.describe_error)
  }
  case body {
    Ok(body) -> bytes_response(200, body, content_type)
    Error(error) -> error_response(500, error)
  }
}

fn bytes_response(
  status: Int,
  body: String,
  content_type: String,
) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("x-frame-options", "DENY")
  |> response.set_body(
    body |> bit_array.from_string |> bytes_tree.from_bit_array |> mist.Bytes,
  )
}

fn model_json(model: config.ModelConfig) -> json.Json {
  json.object([
    #("id", json.string(model.id)),
    #("provider_id", json.string(model.provider_id)),
    #("name", json.string(model.display_name)),
    #("remote_id", json.string(model.remote_id)),
    #("endpoint", json.string(model.endpoint)),
    #("type", json.string(model_type_name(model.model_type))),
    #("context_window_tokens", json.int(model.context_window_tokens)),
    #("max_tokens", option_int(model.max_output_tokens)),
  ])
}

fn model_type_name(model_type: model_catalog.ModelType) -> String {
  case model_type {
    model_catalog.OpenAIChatCompletions -> "openai_chat_completions"
    model_catalog.OpenAIResponses -> "openai_responses"
    model_catalog.AnthropicMessages -> "anthropic_messages"
  }
}

fn option_int(value: Option(Int)) -> json.Json {
  case value {
    Some(value) -> json.int(value)
    None -> json.null()
  }
}

fn session_json(session: Session) -> json.Json {
  let service.Session(metadata:, group:) = session
  json.object([
    #("id", json.string(metadata.id)),
    #("title", json.string(metadata.title)),
    #("prompt", json.string(metadata.prompt)),
    #("workspace", json.string(metadata.workspace)),
    #("model_id", json.string(metadata.model_id)),
    #("created_at", json.int(metadata.created_at)),
    #("revision", json.int(group.revision)),
    #("execution", execution_json(group.execution)),
    #(
      "agents",
      json.array(group.agents, fn(state) {
        let spec =
          metadata.agents
          |> list.find(fn(spec) { spec.id == state.id })
        let #(role, kind, mcp_configuration_id) = case spec {
          Error(_) -> #("", "coding", None)
          Ok(spec) ->
            case spec.kind {
              service.CodingAgent -> #(spec.role, "coding", None)
              service.ResearchAgent -> #(spec.role, "researcher", None)
              service.McpSpecialist(id) -> #(spec.role, "mcp", Some(id))
            }
        }
        agent_json(state, role, kind, mcp_configuration_id)
      }),
    ),
  ])
}

fn execution_json(execution: agent_group.ExecutionState) -> json.Json {
  case execution {
    agent_group.Idle(_) -> json.object([#("status", json.string("idle"))])
    agent_group.Completed(_) ->
      json.object([#("status", json.string("completed"))])
    agent_group.Claimed(owner, epoch, expires_at, _) ->
      json.object([
        #("status", json.string("running")),
        #("owner", json.string(owner)),
        #("epoch", json.int(epoch)),
        #("lease_expires_at", json.int(expires_at)),
      ])
  }
}

fn agent_json(
  state: agent.State,
  role: String,
  kind: String,
  mcp_configuration_id: Option(String),
) -> json.Json {
  let llm.Stats(
    input_tokens:,
    output_tokens:,
    cache_read_tokens:,
    cache_write_tokens:,
  ) = state.stats
  let #(status, failure) = case state.status {
    agent.Ready -> #("ready", None)
    agent.Waiting -> #("waiting", None)
    agent.Completed -> #("completed", None)
    agent.Failed(reason) -> #("failed", Some(reason))
  }
  json.object([
    #("id", json.string(state.id)),
    #("role", json.string(role)),
    #("kind", json.string(kind)),
    #("mcp_configuration_id", json.nullable(mcp_configuration_id, json.string)),
    #("status", json.string(status)),
    #("failure", option_string(failure)),
    #("round", json.int(state.round)),
    #("revision", json.int(state.revision)),
    #("model_id", json.string(state.model_id)),
    #("pending_messages", json.int(list.length(state.pending_messages))),
    #(
      "compaction",
      json.object([
        #("requested", json.int(state.compaction_requested)),
        #("completed", json.int(state.compaction_completed)),
        #(
          "pending",
          json.bool(state.compaction_requested > state.compaction_completed),
        ),
        #("error", option_string(state.last_compaction_error)),
        #("context_tokens", option_int(state.last_context_tokens)),
      ]),
    ),
    #(
      "stats",
      json.object([
        #("input_tokens", json.int(input_tokens)),
        #("output_tokens", json.int(output_tokens)),
        #("cache_read_tokens", json.int(cache_read_tokens)),
        #("cache_write_tokens", json.int(cache_write_tokens)),
      ]),
    ),
    #("messages", json.array(state.messages, message_json)),
  ])
}

fn option_string(value: Option(String)) -> json.Json {
  case value {
    Some(value) -> json.string(value)
    None -> json.null()
  }
}

fn message_json(message: llm.Message) -> json.Json {
  json.object([
    #("role", json.string(role_name(message.role))),
    #("content", json.array(message.content, content_json)),
  ])
}

fn role_name(role: llm.Role) -> String {
  case role {
    llm.System -> "system"
    llm.Developer -> "developer"
    llm.User -> "user"
    llm.Assistant -> "assistant"
    llm.ToolRole -> "tool"
  }
}

fn content_json(content: llm.Content) -> json.Json {
  case content {
    llm.Text(text) ->
      json.object([
        #("type", json.string("text")),
        #("text", json.string(text)),
      ])
    llm.Reasoning(summary, encrypted) ->
      json.object([
        #("type", json.string("reasoning")),
        #("summary", json.array(summary, json.string)),
        #("encrypted", json.bool(encrypted != None)),
      ])
    llm.ToolCall(id, name, arguments) ->
      json.object([
        #("type", json.string("tool_call")),
        #("id", json.string(id)),
        #("name", json.string(name)),
        #("arguments", arguments),
      ])
    llm.ToolResult(id, content, is_error) ->
      json.object([
        #("type", json.string("tool_result")),
        #("id", json.string(id)),
        #("is_error", json.bool(is_error)),
        #("content", json.array(content, content_json)),
      ])
    llm.Image(source, detail) ->
      json.object([
        #("type", json.string("image")),
        #("source", media_source_json(source)),
        #("detail", json.string(image_detail_name(detail))),
      ])
    llm.Document(source) ->
      json.object([
        #("type", json.string("document")),
        #("source", media_source_json(source)),
      ])
  }
}

fn media_source_json(source: llm.MediaSource) -> json.Json {
  case source {
    llm.Url(url) ->
      json.object([
        #("type", json.string("url")),
        #("value", json.string(url)),
      ])
    llm.FileId(id) ->
      json.object([
        #("type", json.string("file_id")),
        #("value", json.string(id)),
      ])
    llm.Base64(media_type, _) ->
      json.object([
        #("type", json.string("base64")),
        #("media_type", json.string(media_type)),
      ])
  }
}

fn image_detail_name(detail: llm.ImageDetail) -> String {
  case detail {
    llm.Auto -> "auto"
    llm.Low -> "low"
    llm.High -> "high"
  }
}

fn create_input_decoder() -> decode.Decoder(service.CreateInput) {
  use model_id <- decode.field("model_id", decode.string)
  use workspace <- decode.optional_field("workspace", "", decode.string)
  use team_size <- decode.optional_field("team_size", 3, decode.int)
  use mcp_configuration_id <- decode.optional_field(
    "mcp_configuration_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(service.CreateInput(
    model_id,
    workspace,
    team_size,
    mcp_configuration_id,
  ))
}

fn mcp_configuration_json(
  configuration: mcp_configuration.Configuration,
) -> json.Json {
  // Tools are discovered per agent, not per configuration, so there is no
  // configuration-wide tool list to report here.
  json.object([
    #("id", json.string(configuration.id)),
    #("label", json.string(configuration.label)),
    #("enabled", json.bool(configuration.enabled)),
    #("server_count", json.int(list.length(configuration.servers))),
    #("servers", json.array(configuration.servers, mcp_server_json)),
  ])
}

fn mcp_server_json(server: mcp_configuration.Server) -> json.Json {
  let transport = case server.transport {
    mcp_configuration.StreamableHttp(endpoint, headers) ->
      json.object([
        #("type", json.string("streamable_http")),
        #("endpoint", json.string(endpoint)),
        #("binding_count", json.int(list.length(headers))),
      ])
    mcp_configuration.Stdio(
      executable,
      arguments,
      working_directory,
      environment,
    ) ->
      json.object([
        #("type", json.string("stdio")),
        #("executable", json.string(executable)),
        #("argument_count", json.int(list.length(arguments))),
        #("working_directory", json.nullable(working_directory, json.string)),
        #("binding_count", json.int(list.length(environment))),
      ])
  }
  json.object([
    #("id", json.string(server.id)),
    #("timeout_milliseconds", json.int(server.timeout_milliseconds)),
    #("transport", transport),
  ])
}

type AddMcpServerRequest {
  AddMcpServerRequest(
    configuration_id: String,
    configuration_label: String,
    server: mcp_configuration.Server,
  )
}

fn add_mcp_server_decoder() -> decode.Decoder(AddMcpServerRequest) {
  use configuration_id <- decode.field("configuration_id", decode.string)
  use configuration_label <- decode.field("configuration_label", decode.string)
  use server <- decode.field("server", mcp_configuration.server_decoder())
  decode.success(AddMcpServerRequest(
    configuration_id,
    configuration_label,
    server,
  ))
}

type MessageRequest {
  MessageRequest(agent_id: String, message: String)
}

fn message_decoder() -> decode.Decoder(MessageRequest) {
  use agent_id <- decode.field("agent_id", decode.string)
  use message <- decode.field("message", decode.string)
  decode.success(MessageRequest(agent_id, message))
}
