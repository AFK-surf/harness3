import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request as http_request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import harness3/agent_group
import harness3/agent_group_registry
import harness3/cluster/recovery
import harness3/storage.{type Storage}
import mist.{type ResponseData}

const refresh_interval_ms = 10_000

const default_max_request_bytes = 8_388_608

pub type Config {
  Config(
    storage: Storage,
    node_ip: String,
    node_port: Int,
    rpc_plugins: List(RpcPlugin),
    max_request_bytes: Int,
  )
}

pub fn config(storage: Storage, node_ip: String, node_port: Int) -> Config {
  Config(
    storage:,
    node_ip:,
    node_port:,
    rpc_plugins: [],
    max_request_bytes: default_max_request_bytes,
  )
}

pub fn with_rpc_plugin(config: Config, plugin: RpcPlugin) -> Config {
  Config(..config, rpc_plugins: [plugin, ..config.rpc_plugins])
}

pub fn with_max_request_bytes(config: Config, bytes: Int) -> Config {
  Config(..config, max_request_bytes: bytes)
}

pub type RpcError {
  Unauthorized
  UnknownMethod(name: String)
  InvalidTerm(reason: String)
  InvalidArguments(reason: String)
  HandlerError(code: String, message: String)
  InternalError(reason: String)
}

pub opaque type Method {
  Method(name: String, invoke: fn(Dynamic) -> Result(BitArray, RpcError))
}

/// Defines a typed RPC method. The decoder validates the decoded Erlang term;
/// the handler's successful return value is encoded with `term_to_binary/1`.
pub fn method(
  name: String,
  decoder: decode.Decoder(request),
  handler: fn(request) -> Result(response, RpcError),
) -> Method {
  Method(name, fn(term) {
    use request <- result.try(
      decode.run(term, decoder)
      |> result.map_error(fn(errors) {
        InvalidArguments(string.inspect(errors))
      }),
    )
    handler(request) |> result.map(term_to_binary)
  })
}

/// Defines a method that receives the decoded term directly.
pub fn raw_method(
  name: String,
  handler: fn(Dynamic) -> Result(Dynamic, RpcError),
) -> Method {
  Method(name, fn(term) { handler(term) |> result.map(term_to_binary) })
}

pub opaque type RpcPlugin {
  RpcPlugin(methods: List(Method))
}

pub fn rpc_plugin(methods: List(Method)) -> RpcPlugin {
  RpcPlugin(methods)
}

pub type StartError {
  InvalidConfiguration(reason: String)
  DuplicateMethod(name: String)
  ListenerFailed(reason: String)
  ListenerAddressUnavailable
  MembershipWriteFailed(error: storage.Error)
  RefresherFailed(reason: String)
  RecoveryLeaderFailed(reason: String)
}

pub type CallError {
  Transport(reason: String)
  InvalidResponse(reason: String)
  RemoteResponse(status: Int, error: Dynamic)
}

pub opaque type Cluster {
  Cluster(
    token: String,
    node_ip: String,
    node_port: Int,
    membership_key: String,
    listener: Pid,
    refresher: Subject(Control),
    recovery: recovery.Handle,
  )
}

pub fn token(cluster: Cluster) -> String {
  let Cluster(token:, ..) = cluster
  token
}

pub fn node(cluster: Cluster) -> #(String, Int) {
  let Cluster(node_ip:, node_port:, ..) = cluster
  #(node_ip, node_port)
}

pub fn membership_key(cluster: Cluster) -> String {
  let Cluster(membership_key:, ..) = cluster
  membership_key
}

/// Makes an authenticated RPC call and decodes its successful Erlang term.
pub fn call(
  node_ip: String,
  node_port: Int,
  token: String,
  method_name: String,
  payload: request,
  decoder: decode.Decoder(response),
) -> Result(response, CallError) {
  let host = case string.contains(node_ip, ":") {
    True -> "[" <> node_ip <> "]"
    False -> node_ip
  }
  let url =
    "http://"
    <> host
    <> ":"
    <> int.to_string(node_port)
    <> "/rpc/"
    <> uri.percent_encode(method_name)
  use request <- result.try(
    http_request.to(url)
    |> result.map_error(fn(_) { Transport("invalid RPC endpoint") }),
  )
  let request =
    request
    |> http_request.set_method(http.Post)
    |> http_request.set_header("authorization", "Bearer " <> token)
    |> http_request.set_header("content-type", "application/x-erlang-binary")
    |> http_request.set_body(term_to_binary(payload))
  use response <- result.try(
    httpc.send_bits(request)
    |> result.map_error(fn(error) { Transport(string.inspect(error)) }),
  )
  use term <- result.try(
    decode_term(response.body)
    |> result.map_error(fn(error) { InvalidResponse(string.inspect(error)) }),
  )
  case response.status >= 200 && response.status < 300 {
    True ->
      decode.run(term, decoder)
      |> result.map_error(fn(errors) { InvalidResponse(string.inspect(errors)) })
    False -> Error(RemoteResponse(response.status, term))
  }
}

type BinaryToTermOption {
  Safe
}

@external(erlang, "erlang", "term_to_binary")
fn term_to_binary(term: anything) -> BitArray

@external(erlang, "erlang", "binary_to_term")
fn binary_to_term(data: BitArray, options: List(BinaryToTermOption)) -> Dynamic

@external(erlang, "erlang", "system_time")
fn system_time(unit: TimeUnit) -> Int

type TimeUnit {
  Second
}

type Registry =
  Dict(String, Method)

type ListenerInfo {
  ListenerInfo(ip: String, port: Int)
}

type Control {
  Refresh(subject: Subject(Control), reply: Option(Subject(Nil)))
  Shutdown
}

type RefreshState {
  RefreshState(
    storage: Storage,
    key: String,
    token: String,
    ip: String,
    port: Int,
  )
}

pub fn start(config: Config) -> Result(Cluster, StartError) {
  use _ <- result.try(validate_config(config))
  use registry <- result.try(build_registry(config.rpc_plugins))

  let token =
    crypto.strong_random_bytes(32)
    |> bit_array.base64_url_encode(False)
  let listener_info = process.new_subject()
  let failure =
    rpc_response(413, InvalidTerm("request body exceeds configured limit"))
  let handler = fn(request) {
    handle_request(request, token, registry, config.max_request_bytes)
  }

  let listener =
    mist.new(handler)
    |> mist.bind(config.node_ip)
    |> mist.port(config.node_port)
    |> mist.after_start(fn(port, _scheme, ip) {
      process.send(
        listener_info,
        ListenerInfo(mist.ip_address_to_string(ip), port),
      )
    })
    |> mist.read_request_body(
      bytes_limit: config.max_request_bytes,
      failure_response: failure,
    )
    |> mist.start

  use listener <- result.try(
    listener
    |> result.map_error(fn(error) { ListenerFailed(string.inspect(error)) }),
  )
  let actor.Started(pid: listener_pid, ..) = listener

  use info <- result.try(
    process.receive(listener_info, within: 1000)
    |> result.map_error(fn(_) {
      process.send_exit(listener_pid)
      ListenerAddressUnavailable
    }),
  )
  let ListenerInfo(ip:, port:) = info
  let key = membership_object_key(ip, port)

  use _ <- result.try(
    write_membership(config.storage, key, token, ip, port)
    |> result.map_error(fn(error) {
      process.send_exit(listener_pid)
      MembershipWriteFailed(error)
    }),
  )

  let refresh_state = RefreshState(config.storage, key, token, ip, port)
  let refresher =
    actor.new(refresh_state)
    |> actor.on_message(handle_control)
    |> actor.start
  use refresher <- result.try(
    refresher
    |> result.map_error(fn(error) {
      process.send_exit(listener_pid)
      let _ = storage.delete(config.storage, key)
      RefresherFailed(string.inspect(error))
    }),
  )
  let actor.Started(data: refresh_subject, ..) = refresher
  let _ =
    process.send_after(
      refresh_subject,
      refresh_interval_ms,
      Refresh(refresh_subject, None),
    )

  use recovery_handle <- result.try(
    recovery.start(config.storage, token, fn(ip, port, token, group_key) {
      call(ip, port, token, "resume_agent_group", group_key, decode.string)
      |> result.map(fn(_) { Nil })
      |> result.map_error(string.inspect)
    })
    |> result.map_error(fn(error) {
      process.send(refresh_subject, Shutdown)
      process.send_exit(listener_pid)
      RecoveryLeaderFailed(string.inspect(error))
    }),
  )

  Ok(Cluster(
    token,
    ip,
    port,
    key,
    listener_pid,
    refresh_subject,
    recovery_handle,
  ))
}

pub fn stop(cluster: Cluster) -> Nil {
  let Cluster(listener:, refresher:, recovery: recovery_handle, ..) = cluster
  recovery.stop(recovery_handle)
  process.send(refresher, Shutdown)
  process.send_exit(listener)
}

/// Publishes the current membership immediately and returns after storage has
/// acknowledged the write.
pub fn refresh(cluster: Cluster) -> Nil {
  let Cluster(refresher:, ..) = cluster
  process.call_forever(refresher, fn(reply) { Refresh(refresher, Some(reply)) })
}

pub fn recovery_candidates(
  cluster: Cluster,
) -> List(agent_group.RunningIndexEntry) {
  let Cluster(recovery: recovery_handle, ..) = cluster
  recovery.candidates(recovery_handle)
}

fn validate_config(config: Config) -> Result(Nil, StartError) {
  case config.node_ip, config.node_port, config.max_request_bytes {
    "", _, _ -> Error(InvalidConfiguration("node_ip cannot be empty"))
    _, port, _ if port < 0 || port > 65_535 ->
      Error(InvalidConfiguration("node_port must be between 0 and 65535"))
    _, _, bytes if bytes <= 0 ->
      Error(InvalidConfiguration("max_request_bytes must be positive"))
    _, _, _ -> Ok(Nil)
  }
}

fn build_registry(plugins: List(RpcPlugin)) -> Result(Registry, StartError) {
  plugins
  |> list.reverse
  |> list.flat_map(fn(plugin) {
    let RpcPlugin(methods) = plugin
    methods
  })
  |> insert_methods(dict.new())
}

fn insert_methods(
  methods: List(Method),
  registry: Registry,
) -> Result(Registry, StartError) {
  case methods {
    [] -> Ok(registry)
    [Method(name:, ..) as method, ..rest] ->
      case name == "" || string.contains(name, "/") {
        True ->
          Error(InvalidConfiguration(
            "RPC method names must be non-empty path segments",
          ))
        False ->
          case dict.has_key(registry, name) {
            True -> Error(DuplicateMethod(name))
            False -> insert_methods(rest, dict.insert(registry, name, method))
          }
      }
  }
}

fn handle_request(
  request: http_request.Request(BitArray),
  token: String,
  registry: Registry,
  _max_request_bytes: Int,
) -> Response(ResponseData) {
  case authenticated(request, token) {
    False -> rpc_response(401, Unauthorized)
    True ->
      case request.method, http_request.path_segments(request) {
        http.Post, ["rpc", method_name] ->
          invoke(registry, method_name, request.body)
        _, ["rpc", _] ->
          rpc_response(405, InvalidTerm("RPC requests must use POST"))
        _, _ -> rpc_response(404, UnknownMethod(""))
      }
  }
}

fn authenticated(request: http_request.Request(body), token: String) -> Bool {
  case http_request.get_header(request, "authorization") {
    Ok(header) ->
      crypto.secure_compare(
        bit_array.from_string(header),
        bit_array.from_string("Bearer " <> token),
      )
    Error(_) -> False
  }
}

fn invoke(
  registry: Registry,
  method_name: String,
  body: BitArray,
) -> Response(ResponseData) {
  case dict.get(registry, method_name) {
    Error(_) -> rpc_response(404, UnknownMethod(method_name))
    Ok(Method(invoke:, ..)) ->
      case decode_term(body) {
        Error(error) -> rpc_response(400, error)
        Ok(term) ->
          case exception.rescue(fn() { invoke(term) }) {
            Error(error) ->
              rpc_response(500, InternalError(string.inspect(error)))
            Ok(Error(error)) -> rpc_response(error_status(error), error)
            Ok(Ok(response)) -> binary_response(200, response)
          }
      }
  }
}

fn decode_term(body: BitArray) -> Result(Dynamic, RpcError) {
  exception.rescue(fn() { binary_to_term(body, [Safe]) })
  |> result.map_error(fn(error) { InvalidTerm(string.inspect(error)) })
}

fn error_status(error: RpcError) -> Int {
  case error {
    Unauthorized -> 401
    UnknownMethod(_) -> 404
    InvalidTerm(_) | InvalidArguments(_) -> 400
    HandlerError(_, _) | InternalError(_) -> 500
  }
}

fn rpc_response(status: Int, error: RpcError) -> Response(ResponseData) {
  binary_response(status, term_to_binary(error))
}

fn binary_response(status: Int, body: BitArray) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/x-erlang-binary")
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
}

fn membership_object_key(ip: String, port: Int) -> String {
  "cluster/membership/" <> ip <> "_" <> int.to_string(port)
}

fn membership_body(token: String, ip: String, port: Int) -> BitArray {
  let agent_groups = agent_group_registry.alive_ids()
  json.object([
    #("token", json.string(token)),
    #("ip", json.string(ip)),
    #("port", json.int(port)),
    #("agent_groups", json.array(agent_groups, json.string)),
    #("refreshed_at", json.int(system_time(Second))),
  ])
  |> json.to_string
  |> bit_array.from_string
}

fn write_membership(
  backend: Storage,
  key: String,
  token: String,
  ip: String,
  port: Int,
) -> Result(storage.Metadata, storage.Error) {
  storage.put(
    backend,
    key,
    membership_body(token, ip, port),
    storage.Unconditional,
  )
}

fn handle_control(
  state: RefreshState,
  message: Control,
) -> actor.Next(RefreshState, Control) {
  let RefreshState(storage: backend, key:, token:, ip:, port:) = state
  case message {
    Refresh(subject, reply) -> {
      let written = write_membership(backend, key, token, ip, port)
      case written, reply {
        Ok(_), Some(reply) -> process.send(reply, Nil)
        _, _ -> Nil
      }
      let _ =
        process.send_after(subject, refresh_interval_ms, Refresh(subject, None))
      actor.continue(state)
    }
    Shutdown -> {
      let _ = storage.delete(backend, key)
      actor.stop()
    }
  }
}
