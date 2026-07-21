import gleam/dict
import gleam/erlang/process
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
          "caller.tool",
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
        "caller.tool",
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
      "caller.tool",
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

pub fn missing_plugin_state_survives_until_plugin_returns_test() {
  let available =
    plugin.new("available", "{\"count\":0}")
    |> plugin.on_activate(
      plugin.activation_hook(fn(state, context) {
        assert state == "{\"count\":2}"
        Ok(plugin.hook_result("{\"count\":3}", context, Nil))
      }),
    )
  let persisted =
    dict.from_list([
      #("available", "{\"count\":2}"),
      #("temporarily_missing", "{\"count\":9}"),
    ])
  let assert Ok(registry) = plugin.registry([available])
  let assert Ok(runtime) = plugin.activate(registry, persisted)
  let states = plugin.encoded_states(runtime)
  assert dict.get(states, "available") == Ok("{\"count\":3}")
  assert dict.get(states, "temporarily_missing") == Ok("{\"count\":9}")

  let restored =
    plugin.new("temporarily_missing", "{\"count\":0}")
    |> plugin.on_activate(
      plugin.activation_hook(fn(state, context) {
        assert state == "{\"count\":9}"
        Ok(plugin.hook_result("{\"count\":10}", context, Nil))
      }),
    )
  let assert Ok(restored_registry) = plugin.registry([restored])
  let assert Ok(restored_runtime) = plugin.activate(restored_registry, states)
  let restored_states = plugin.encoded_states(restored_runtime)
  assert dict.get(restored_states, "temporarily_missing")
    == Ok("{\"count\":10}")
  assert dict.get(restored_states, "available") == Ok("{\"count\":3}")
}

pub fn a_raising_release_hook_does_not_stop_other_plugins_test() {
  // Release hooks are caller-supplied. One that raises must not skip the
  // cleanup of the plugins after it, and must not escape to the plugin host
  // (an abnormal host exit propagates over its link and kills the coordinator
  // or the agent worker).
  let released = process.new_subject()
  let raising =
    plugin.new("raising", "null")
    |> plugin.on_release(
      plugin.release_hook(fn(_state, _context) {
        panic as "release hooks must be isolated"
      }),
    )
  let clean =
    plugin.new("clean", "null")
    |> plugin.on_release(
      plugin.release_hook(fn(_state, _context) { process.send(released, Nil) }),
    )
  // `clean` releases after `raising`: hooks run in reverse activation order.
  let assert Ok(registry) = plugin.registry([clean, raising])
  let assert Ok(runtime) = plugin.activate(registry, plugin.empty_states())
  plugin.release(runtime)
  let assert Ok(Nil) = process.receive(released, within: 1000)
}

pub fn dynamic_prompt_sections_see_state_and_host_test() {
  let host =
    plugin.Host(
      group_id: "group-1",
      agent_id: "lead",
      agent_attributes: dict.from_list([#("role", "Lead engineer")]),
      group_attributes: dict.from_list([#("workspace", "/tmp/ws")]),
      peers: [#("researcher", dict.new())],
    )
  let dynamic =
    plugin.new("dynamic", "{\"topic\":\"storage\"}")
    |> plugin.with_system_prompt(plugin.SystemPromptSection("Static", "fixed"))
    |> plugin.with_dynamic_system_prompt(fn(state, context) {
      let plugin.Host(group_id:, agent_id:, group_attributes:, peers:, ..) =
        plugin.host(context)
      let assert Ok(workspace) = dict.get(group_attributes, "workspace")
      let assert [#(peer, _)] = peers
      plugin.SystemPromptSection(
        "Dynamic",
        group_id
          <> "/"
          <> agent_id
          <> "@"
          <> workspace
          <> " with "
          <> peer
          <> " state="
          <> state,
      )
    })
  let assert Ok(registry) = plugin.registry([dynamic])
  let assert Ok(runtime) =
    plugin.activate_hosted(registry, plugin.empty_states(), host)
  assert plugin.system_prompt(runtime)
    == "## Static\n\nfixed\n\n## Dynamic\n\ngroup-1/lead@/tmp/ws with researcher state={\"topic\":\"storage\"}"
}

pub fn tools_read_the_host_from_their_context_test() {
  let hosted =
    plugin.new("hosted", "{}")
    |> plugin.with_tool(
      plugin.tool(
        llm.Tool("hosted.whoami", None, json.object([])),
        fn(state, context, _invocation) {
          let plugin.Host(agent_id:, ..) = plugin.host(context)
          Ok(plugin.hook_result(
            state,
            context,
            plugin.ToolOutput([llm.Text(agent_id)], False),
          ))
        },
      ),
    )
  let assert Ok(registry) = plugin.registry([hosted])
  let assert Ok(runtime) =
    plugin.activate_hosted(
      registry,
      plugin.empty_states(),
      plugin.Host(
        group_id: "g",
        agent_id: "researcher",
        agent_attributes: dict.new(),
        group_attributes: dict.new(),
        peers: [],
      ),
    )
  let assert Ok(#(
    _,
    plugin.ToolOutput(content: [llm.Text(id)], is_error: False),
  )) =
    plugin.invoke_tool(
      runtime,
      "hosted.whoami",
      plugin.ToolInvocation("whoami", "{}"),
    )
  assert id == "researcher"

  // Plain activation provides an empty host.
  let assert Ok(bare) = plugin.activate(registry, plugin.empty_states())
  let assert Ok(#(_, plugin.ToolOutput(content: [llm.Text(empty)], ..))) =
    plugin.invoke_tool(bare, "hosted.whoami", plugin.ToolInvocation("w", "{}"))
  assert empty == ""
}
