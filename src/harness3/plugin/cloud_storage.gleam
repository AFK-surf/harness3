import gleam/result
import harness3/plugin
import harness3/plugin/cloud_storage/plugin as cloud_storage_plugin
import harness3/plugin/cloud_storage/scope
import harness3/storage.{type Storage}

/// Builds a durable text-object storage plugin whose keys are isolated to one
/// independently configurable storage prefix. Install a separately constructed
/// plugin in each agent profile that should share the prefix's objects; agents
/// with different prefixes stay isolated from each other.
pub fn new(storage: Storage, prefix: String) -> Result(plugin.Plugin, String) {
  use storage_scope <- result.try(scope.new(prefix))
  Ok(cloud_storage_plugin.new(storage, storage_scope))
}
