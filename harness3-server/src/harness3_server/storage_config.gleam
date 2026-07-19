import gleam/option.{None}
import gleam/result
import harness3/storage.{type Storage}
import harness3/storage/local
import harness3/storage/s3
import harness3_server/config
import simplifile

/// Builds the durable storage backend from server environment variables.
/// Local storage is the safe default; setting HARNESS3_STORAGE=s3 enables any
/// S3-compatible service, including the local MinIO instance used in tests.
pub fn from_environment() -> Result(Storage, String) {
  case config.environment_or("HARNESS3_STORAGE", "local") {
    "local" -> local_storage()
    "s3" -> Ok(s3_storage())
    other -> Error("unsupported HARNESS3_STORAGE value: " <> other)
  }
}

fn local_storage() -> Result(Storage, String) {
  use cwd <- result.try(
    simplifile.current_directory()
    |> result.map_error(simplifile.describe_error),
  )
  let path =
    config.environment_or("HARNESS3_DATA_DIR", cwd <> "/.harness3-server-data")
  use _ <- result.try(
    simplifile.create_directory_all(path)
    |> result.map_error(simplifile.describe_error),
  )
  Ok(local.new(local.config(path)))
}

fn s3_storage() -> Storage {
  s3.new(s3.Config(
    bucket: config.environment_or("HARNESS3_S3_BUCKET", "harness3"),
    region: config.environment_or("HARNESS3_S3_REGION", "us-east-1"),
    access_key_id: config.environment_or(
      "HARNESS3_S3_ACCESS_KEY_ID",
      "minioadmin",
    ),
    secret_access_key: config.environment_or(
      "HARNESS3_S3_SECRET_ACCESS_KEY",
      "minioadmin",
    ),
    session_token: None,
    endpoint: config.environment_or(
      "HARNESS3_S3_ENDPOINT",
      "http://127.0.0.1:9000",
    ),
  ))
}
