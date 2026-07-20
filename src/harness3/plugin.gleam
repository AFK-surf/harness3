import exception
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness3/llm

/// A named section contributed to an agent's system prompt.
pub type SystemPromptSection {
  SystemPromptSection(name: String, body: String)
}

/// Arguments supplied by the model to a plugin tool. `arguments` is a JSON
/// document and `id` is suitable for use as an idempotency key.
pub type ToolInvocation {
  ToolInvocation(id: String, arguments: String)
}

pub type ToolOutput {
  ToolOutput(content: List(llm.Content), is_error: Bool)
}

pub type Error {
  DuplicatePlugin(name: String)
  MissingDependency(plugin: String, dependency: String)
  DependencyCycle(plugins: List(String))
  DuplicateTool(name: String)
  DuplicateCallback(plugin: String, name: String)
  InvalidState(plugin: String, reason: String)
  UnknownTool(name: String)
  UnknownPlugin(name: String)
  UndeclaredDependency(plugin: String, dependency: String)
  UnknownCallback(plugin: String, callback: String)
  HookFailed(plugin: String, hook: String, reason: String)
  AgentCallbacksUnavailable
  AgentCallbackFailed(reason: String)
}

/// The result of a stateful hook. The context must be threaded through hook
/// calls so changes made by dependency callbacks are retained.
pub type HookResult(value) {
  HookResult(state: String, context: Context, value: value)
}

pub opaque type Context {
  Context(
    registry: Registry,
    states: Dict(String, String),
    resources: Dict(String, Dynamic),
    current: String,
    agent_callback: Option(AgentCallback),
  )
}

pub type AgentCallback =
  fn(String, String, String, String) -> Result(String, Error)

pub opaque type Tool {
  Tool(
    definition: llm.Tool,
    run: fn(String, Context, ToolInvocation) ->
      Result(HookResult(ToolOutput), Error),
  )
}

pub fn tool(
  definition: llm.Tool,
  run: fn(String, Context, ToolInvocation) ->
    Result(HookResult(ToolOutput), Error),
) -> Tool {
  Tool(definition, run)
}

pub opaque type CallbackHook {
  CallbackHook(
    name: String,
    run: fn(String, Context, String) -> Result(HookResult(String), Error),
  )
}

pub fn callback_hook(
  name: String,
  run: fn(String, Context, String) -> Result(HookResult(String), Error),
) -> CallbackHook {
  CallbackHook(name, run)
}

pub opaque type ActivationHook {
  ActivationHook(run: fn(String, Context) -> Result(HookResult(Nil), Error))
}

pub fn activation_hook(
  run: fn(String, Context) -> Result(HookResult(Nil), Error),
) -> ActivationHook {
  ActivationHook(run)
}

/// Best-effort cleanup for a plugin's ephemeral resources, run when the
/// agent's plugin host stops. Cleanup must not block: a linked process is not
/// taken down by its owner's *normal* exit, so anything the plugin owns has to
/// be told to stop here, not left to the link.
pub opaque type ReleaseHook {
  ReleaseHook(run: fn(String, Context) -> Nil)
}

pub fn release_hook(run: fn(String, Context) -> Nil) -> ReleaseHook {
  ReleaseHook(run)
}

pub opaque type Plugin {
  Plugin(
    name: String,
    dependencies: List(String),
    initial_state: String,
    system_prompt_sections: List(SystemPromptSection),
    tools: List(Tool),
    callback_hooks: List(CallbackHook),
    activation_hooks: List(ActivationHook),
    release_hooks: List(ReleaseHook),
  )
}

pub fn new(name: String, initial_state: String) -> Plugin {
  Plugin(name, [], initial_state, [], [], [], [], [])
}

pub fn depends_on(plugin: Plugin, dependency: String) -> Plugin {
  Plugin(..plugin, dependencies: list.append(plugin.dependencies, [dependency]))
}

pub fn with_system_prompt(
  plugin: Plugin,
  section: SystemPromptSection,
) -> Plugin {
  Plugin(
    ..plugin,
    system_prompt_sections: list.append(plugin.system_prompt_sections, [section]),
  )
}

pub fn with_tool(plugin: Plugin, value: Tool) -> Plugin {
  Plugin(..plugin, tools: list.append(plugin.tools, [value]))
}

pub fn with_callback(plugin: Plugin, hook: CallbackHook) -> Plugin {
  Plugin(..plugin, callback_hooks: list.append(plugin.callback_hooks, [hook]))
}

pub fn on_activate(plugin: Plugin, hook: ActivationHook) -> Plugin {
  Plugin(
    ..plugin,
    activation_hooks: list.append(plugin.activation_hooks, [hook]),
  )
}

pub fn on_release(plugin: Plugin, hook: ReleaseHook) -> Plugin {
  Plugin(..plugin, release_hooks: list.append(plugin.release_hooks, [hook]))
}

/// Runs every plugin's release hooks, in reverse activation order. Called by
/// the agent's plugin host before it stops.
pub fn release(runtime: Runtime) -> Nil {
  let Runtime(context:) = runtime
  let Context(registry: Registry(ordered:, ..), ..) = context
  ordered
  |> list.reverse
  |> list.each(fn(plugin) {
    let plugin_context = Context(..context, current: plugin.name)
    case current_state(plugin_context) {
      Error(_) -> Nil
      Ok(state) ->
        list.each(plugin.release_hooks, fn(hook) {
          let ReleaseHook(run:) = hook
          // Hooks are caller-supplied. A raising hook would make the plugin
          // host exit abnormally — which, unlike its normal exit, propagates
          // over the link and kills the coordinator or the agent worker — and
          // would skip every remaining plugin's cleanup.
          let _ = exception.rescue(fn() { run(state, plugin_context) })
          Nil
        })
    }
  })
}

pub fn name(plugin: Plugin) -> String {
  plugin.name
}

pub opaque type Registry {
  Registry(ordered: List(Plugin), by_name: Dict(String, Plugin))
}

pub fn registry(plugins: List(Plugin)) -> Result(Registry, Error) {
  use by_name <- result.try(index_plugins(plugins))
  use _ <- result.try(validate_plugins(plugins, by_name))
  use ordered <- result.try(topological_order(plugins, by_name))
  use _ <- result.try(validate_tools(ordered))
  Ok(Registry(ordered, by_name))
}

fn index_plugins(plugins: List(Plugin)) -> Result(Dict(String, Plugin), Error) {
  list.try_fold(plugins, dict.new(), fn(index, plugin) {
    case dict.has_key(index, plugin.name) {
      True -> Error(DuplicatePlugin(plugin.name))
      False -> Ok(dict.insert(index, plugin.name, plugin))
    }
  })
}

fn validate_plugins(
  plugins: List(Plugin),
  index: Dict(String, Plugin),
) -> Result(Nil, Error) {
  list.try_each(plugins, fn(plugin) {
    use _ <- result.try(
      list.try_each(plugin.dependencies, fn(dependency) {
        case dict.has_key(index, dependency) {
          True -> Ok(Nil)
          False -> Error(MissingDependency(plugin.name, dependency))
        }
      }),
    )
    use _ <- result.try(validate_callback_names(plugin))
    validate_json_state(plugin.name, plugin.initial_state)
  })
}

fn validate_callback_names(plugin: Plugin) -> Result(Nil, Error) {
  plugin.callback_hooks
  |> list.try_fold([], fn(names, hook) {
    let CallbackHook(name:, ..) = hook
    case list.contains(names, name) {
      True -> Error(DuplicateCallback(plugin.name, name))
      False -> Ok([name, ..names])
    }
  })
  |> result.map(fn(_) { Nil })
}

fn validate_json_state(
  plugin_name: String,
  state: String,
) -> Result(Nil, Error) {
  json.parse(state, decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    InvalidState(plugin_name, string.inspect(error))
  })
}

fn topological_order(
  plugins: List(Plugin),
  _index: Dict(String, Plugin),
) -> Result(List(Plugin), Error) {
  order_remaining(plugins, [], [])
}

fn order_remaining(
  remaining: List(Plugin),
  resolved: List(String),
  ordered: List(Plugin),
) -> Result(List(Plugin), Error) {
  case remaining {
    [] -> Ok(ordered)
    _ -> {
      let ready =
        list.filter(remaining, fn(plugin) {
          list.all(plugin.dependencies, fn(dependency) {
            list.contains(resolved, dependency)
          })
        })
      case ready {
        [] ->
          Error(
            DependencyCycle(list.map(remaining, fn(plugin) { plugin.name })),
          )
        _ -> {
          let ready_names = list.map(ready, fn(plugin) { plugin.name })
          let next =
            list.filter(remaining, fn(plugin) {
              !list.contains(ready_names, plugin.name)
            })
          order_remaining(
            next,
            list.append(resolved, ready_names),
            list.append(ordered, ready),
          )
        }
      }
    }
  }
}

fn validate_tools(plugins: List(Plugin)) -> Result(Nil, Error) {
  plugins
  |> list.flat_map(fn(plugin) { plugin.tools })
  |> list.try_fold([], fn(names, tool) {
    let Tool(definition: llm.Tool(name:, ..), ..) = tool
    case list.contains(names, name) {
      True -> Error(DuplicateTool(name))
      False -> Ok([name, ..names])
    }
  })
  |> result.map(fn(_) { Nil })
}

pub opaque type Runtime {
  Runtime(context: Context)
}

pub fn activate(
  registry: Registry,
  persisted_states: Dict(String, String),
) -> Result(Runtime, Error) {
  let Registry(ordered:, ..) = registry
  // Keep state belonging to unavailable plugins as opaque dormant data. This
  // lets a group pass through a node with an older plugin set without losing
  // state needed when the plugin becomes available again.
  use states <- result.try(
    list.try_fold(ordered, persisted_states, fn(states, plugin) {
      let state =
        dict.get(persisted_states, plugin.name)
        |> result.unwrap(plugin.initial_state)
      use _ <- result.try(validate_json_state(plugin.name, state))
      Ok(dict.insert(states, plugin.name, state))
    }),
  )
  let context = Context(registry, states, dict.new(), "", None)
  use context <- result.try(list.try_fold(ordered, context, activate_plugin))
  Ok(Runtime(context))
}

fn activate_plugin(context: Context, plugin: Plugin) -> Result(Context, Error) {
  let context = Context(..context, current: plugin.name)
  list.try_fold(plugin.activation_hooks, context, fn(context, hook) {
    let ActivationHook(run:) = hook
    use state <- result.try(current_state(context))
    use outcome <- result.try(run(state, context))
    let HookResult(state:, context:, ..) = outcome
    use _ <- result.try(validate_json_state(plugin.name, state))
    Ok(put_state(context, plugin.name, state))
  })
}

pub fn hook_result(
  state: String,
  context: Context,
  value: value,
) -> HookResult(value) {
  HookResult(state, context, value)
}

/// Reads the calling plugin's ephemeral resource, if it has set one.
///
/// Unlike `state`, a resource is never persisted and never leaves the agent:
/// it holds live values such as process handles whose lifetime is the agent's
/// plugin host. Resources are created inside a tool or callback hook, so the
/// processes they refer to are linked to that host and die with the agent.
/// Each plugin sees only its own resource.
pub fn resource(context: Context) -> Result(Dynamic, Nil) {
  let Context(resources:, current:, ..) = context
  dict.get(resources, current)
}

/// Stores the calling plugin's ephemeral resource, replacing any previous one.
/// The returned context must be threaded back through the `HookResult` for the
/// value to be retained for later hooks.
pub fn set_resource(context: Context, value: Dynamic) -> Context {
  let Context(resources:, current:, ..) = context
  Context(..context, resources: dict.insert(resources, current, value))
}

pub fn current_state(context: Context) -> Result(String, Error) {
  let Context(states:, current:, ..) = context
  dict.get(states, current)
  |> result.map_error(fn(_) { UnknownPlugin(current) })
}

pub fn call_dependency(
  context: Context,
  dependency: String,
  callback: String,
  input: String,
) -> Result(#(Context, String), Error) {
  let Context(registry: Registry(by_name:, ..), current:, ..) = context
  use caller <- result.try(
    dict.get(by_name, current)
    |> result.map_error(fn(_) { UnknownPlugin(current) }),
  )
  case list.contains(caller.dependencies, dependency) {
    False -> Error(UndeclaredDependency(current, dependency))
    True -> {
      use target <- result.try(
        dict.get(by_name, dependency)
        |> result.map_error(fn(_) { UnknownPlugin(dependency) }),
      )
      use hook <- result.try(
        find_callback(target.callback_hooks, callback)
        |> result.map_error(fn(_) { UnknownCallback(dependency, callback) }),
      )
      let CallbackHook(run:, ..) = hook
      let dependency_context = Context(..context, current: dependency)
      use state <- result.try(current_state(dependency_context))
      use outcome <- result.try(run(state, dependency_context, input))
      let HookResult(state:, context: updated, value:) = outcome
      use _ <- result.try(validate_json_state(dependency, state))
      let updated = put_state(updated, dependency, state)
      Ok(#(Context(..updated, current: current), value))
    }
  }
}

/// Calls a callback hook in another agent. A dispatcher is installed only
/// while a tool (or a callback caused by that tool) is being handled, so this
/// operation is unavailable during activation.
pub fn call_agent_callback(
  context: Context,
  agent_id: String,
  plugin_name: String,
  callback: String,
  input: String,
) -> Result(#(Context, String), Error) {
  let Context(agent_callback:, ..) = context
  case agent_callback {
    None -> Error(AgentCallbacksUnavailable)
    Some(dispatch) -> {
      use output <- result.try(dispatch(agent_id, plugin_name, callback, input))
      Ok(#(context, output))
    }
  }
}

fn find_callback(
  hooks: List(CallbackHook),
  name: String,
) -> Result(CallbackHook, Nil) {
  list.find(hooks, fn(hook) {
    let CallbackHook(name: hook_name, ..) = hook
    hook_name == name
  })
}

fn put_state(context: Context, plugin_name: String, state: String) -> Context {
  let Context(states:, ..) = context
  Context(..context, states: dict.insert(states, plugin_name, state))
}

pub fn tools(runtime: Runtime) -> List(llm.Tool) {
  let Runtime(context: Context(registry: Registry(ordered:, ..), ..)) = runtime
  ordered
  |> list.flat_map(fn(plugin) { plugin.tools })
  |> list.map(fn(tool) {
    let Tool(definition:, ..) = tool
    definition
  })
}

pub fn system_prompt_sections(runtime: Runtime) -> List(SystemPromptSection) {
  let Runtime(context: Context(registry: Registry(ordered:, ..), ..)) = runtime
  list.flat_map(ordered, fn(plugin) { plugin.system_prompt_sections })
}

pub fn system_prompt(runtime: Runtime) -> String {
  system_prompt_sections(runtime)
  |> list.map(fn(section) {
    let SystemPromptSection(name:, body:) = section
    "## " <> name <> "\n\n" <> body
  })
  |> string.join("\n\n")
}

pub fn invoke_tool(
  runtime: Runtime,
  name: String,
  invocation: ToolInvocation,
) -> Result(#(Runtime, ToolOutput), Error) {
  invoke_tool_with_agent_callbacks(runtime, name, invocation, None)
}

pub fn invoke_tool_with_agent_callbacks(
  runtime: Runtime,
  name: String,
  invocation: ToolInvocation,
  agent_callback: Option(AgentCallback),
) -> Result(#(Runtime, ToolOutput), Error) {
  let Runtime(context:) = runtime
  let Context(registry: Registry(ordered:, ..), ..) = context
  use #(owner, tool) <- result.try(find_tool(ordered, name))
  let Tool(run:, ..) = tool
  let context =
    Context(..context, current: owner.name, agent_callback: agent_callback)
  use state <- result.try(current_state(context))
  use outcome <- result.try(run(state, context, invocation))
  let HookResult(state:, context:, value:) = outcome
  use _ <- result.try(validate_json_state(owner.name, state))
  let context = put_state(context, owner.name, state)
  Ok(#(Runtime(Context(..context, current: "", agent_callback: None)), value))
}

/// Invokes a callback as an external agent-group dispatch target.
pub fn invoke_callback(
  runtime: Runtime,
  plugin_name: String,
  callback: String,
  input: String,
  agent_callback: AgentCallback,
) -> Result(#(Runtime, String), Error) {
  let Runtime(context:) = runtime
  let Context(registry: Registry(by_name:, ..), ..) = context
  use target <- result.try(
    dict.get(by_name, plugin_name)
    |> result.map_error(fn(_) { UnknownPlugin(plugin_name) }),
  )
  use hook <- result.try(
    find_callback(target.callback_hooks, callback)
    |> result.map_error(fn(_) { UnknownCallback(plugin_name, callback) }),
  )
  let CallbackHook(run:, ..) = hook
  let context =
    Context(
      ..context,
      current: plugin_name,
      agent_callback: Some(agent_callback),
    )
  use state <- result.try(current_state(context))
  use outcome <- result.try(run(state, context, input))
  let HookResult(state:, context:, value:) = outcome
  use _ <- result.try(validate_json_state(plugin_name, state))
  let context = put_state(context, plugin_name, state)
  Ok(#(Runtime(Context(..context, current: "", agent_callback: None)), value))
}

fn find_tool(
  plugins: List(Plugin),
  name: String,
) -> Result(#(Plugin, Tool), Error) {
  plugins
  |> list.flat_map(fn(plugin) {
    plugin.tools
    |> list.filter_map(fn(tool) {
      let Tool(definition: llm.Tool(tool_name, ..), ..) = tool
      case tool_name == name {
        True -> Ok(#(plugin, tool))
        False -> Error(Nil)
      }
    })
  })
  |> list.first
  |> result.map_error(fn(_) { UnknownTool(name) })
}

pub fn encoded_states(runtime: Runtime) -> Dict(String, String) {
  let Runtime(context: Context(states:, ..)) = runtime
  states
}

pub fn empty_states() -> Dict(String, String) {
  dict.new()
}
