import gleam/dict
import gleam/json
import gleam/option.{None}
import harness3/llm
import harness3/plugin

pub fn dependency_activation_and_tool_test() {
  let dependency =
    plugin.new("dependency", "{\"phase\":\"initial\"}")
    |> plugin.on_activate(
      plugin.activation_hook(fn(_, context) {
        Ok(plugin.hook_result("{\"phase\":\"activated\"}", context, Nil))
      }),
    )
    |> plugin.with_callback(
      plugin.callback_hook("touch", fn(state, context, _) {
        assert state == "{\"phase\":\"activated\"}"
        Ok(plugin.hook_result(
          "{\"phase\":\"called\"}",
          context,
          "{\"ok\":true}",
        ))
      }),
    )

  let caller =
    plugin.new("caller", "{\"phase\":\"initial\"}")
    |> plugin.depends_on("dependency")
    |> plugin.with_system_prompt(plugin.SystemPromptSection(
      "Caller",
      "Use the caller tool.",
    ))
    |> plugin.on_activate(
      plugin.activation_hook(fn(_, context) {
        let assert Ok(#(context, "{\"ok\":true}")) =
          plugin.call_dependency(context, "dependency", "touch", "null")
        Ok(plugin.hook_result("{\"phase\":\"active\"}", context, Nil))
      }),
    )
    |> plugin.with_tool(
      plugin.tool(
        llm.Tool(
          "caller_tool",
          None,
          json.object([#("type", json.string("object"))]),
        ),
        fn(_state, context, _) {
          Ok(plugin.hook_result(
            "{\"phase\":\"used\"}",
            context,
            plugin.ToolOutput([llm.Text("done")], False),
          ))
        },
      ),
    )

  let assert Ok(registry) = plugin.registry([caller, dependency])
  let assert Ok(runtime) = plugin.activate(registry, dict.new())
  assert plugin.system_prompt(runtime) == "## Caller\n\nUse the caller tool."
  assert plugin.tools(runtime)
    == [
      llm.Tool(
        "caller_tool",
        None,
        json.object([#("type", json.string("object"))]),
      ),
    ]
  let states = plugin.encoded_states(runtime)
  assert dict.get(states, "dependency") == Ok("{\"phase\":\"called\"}")
  assert dict.get(states, "caller") == Ok("{\"phase\":\"active\"}")

  let assert Ok(#(runtime, plugin.ToolOutput([llm.Text("done")], False))) =
    plugin.invoke_tool(
      runtime,
      "caller_tool",
      plugin.ToolInvocation("call_1", "{}"),
    )
  assert dict.get(plugin.encoded_states(runtime), "caller")
    == Ok("{\"phase\":\"used\"}")
}

pub fn invalid_dependency_graph_test() {
  let first = plugin.new("first", "null") |> plugin.depends_on("second")
  let second = plugin.new("second", "null") |> plugin.depends_on("first")
  let assert Error(plugin.DependencyCycle(_)) = plugin.registry([first, second])
}

pub fn agent_callbacks_are_unavailable_during_activation_test() {
  let value =
    plugin.new("plugin", "null")
    |> plugin.on_activate(
      plugin.activation_hook(fn(state, context) {
        let assert Error(plugin.AgentCallbacksUnavailable) =
          plugin.call_agent_callback(
            context,
            "other-agent",
            "other-plugin",
            "callback",
            "null",
          )
        Ok(plugin.hook_result(state, context, Nil))
      }),
    )
  let assert Ok(registry) = plugin.registry([value])
  let assert Ok(_) = plugin.activate(registry, dict.new())
}
