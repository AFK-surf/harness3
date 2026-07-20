import harness3/plugin
import harness3/plugin/cloud_storage/plugin as cloud_storage_plugin
import harness3/storage.{type Storage}

/// Builds a durable text-object storage plugin whose keys are isolated to one
/// agent group. Install a separately constructed plugin in each agent profile
/// belonging to the group, using the same storage backend and group ID.
pub fn new(storage: Storage, group_id: String) -> plugin.Plugin {
  cloud_storage_plugin.new(storage, group_id)
}
