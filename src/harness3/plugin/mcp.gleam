import harness3/plugin
import harness3/plugin/mcp/catalog
import harness3/plugin/mcp/configuration
import harness3/plugin/mcp/plugin as mcp_plugin
import harness3/plugin/mcp/runtime

pub type Runtime =
  runtime.Runtime

pub type Snapshot =
  runtime.Snapshot

pub fn start(
  catalog: catalog.Catalog,
  resolve_environment: fn(String) -> Result(String, Nil),
  now_seconds: fn() -> Int,
) -> Result(Runtime, String) {
  runtime.start(catalog, resolve_environment, now_seconds)
}

pub fn discover(
  mcp_runtime: Runtime,
  configuration_id: String,
) -> Result(Snapshot, String) {
  runtime.discover(mcp_runtime, configuration_id)
}

pub fn snapshot(
  mcp_runtime: Runtime,
  configuration_id: String,
) -> Result(Snapshot, String) {
  runtime.snapshot(mcp_runtime, configuration_id)
}

pub fn plugin(mcp_runtime: Runtime, snapshot: Snapshot) -> plugin.Plugin {
  mcp_plugin.new(mcp_runtime, snapshot)
}

pub fn catalog(mcp_runtime: Runtime) -> catalog.Catalog {
  runtime.catalog(mcp_runtime)
}

pub fn put_configuration(
  mcp_runtime: Runtime,
  configuration: configuration.Configuration,
) -> Result(Nil, String) {
  runtime.put_configuration(mcp_runtime, configuration)
}

pub fn stop(mcp_runtime: Runtime) -> Nil {
  runtime.stop(mcp_runtime)
}
