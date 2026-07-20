# harness3-server

A local-first coding-agent service built on `harness3`. It loads the same model
configuration as Pi, exposes a JSON API, and serves a multi-agent web UI.

## Run

Pi models are loaded from `~/.pi/agent/models.json` by default. From this
directory:

```sh
gleam run
```

Open <http://127.0.0.1:8080>. The server binds only to loopback by default.

Workspace paths must be absolute. The UI initially suggests the absolute path
resolved from `HARNESS3_WORKSPACE_ROOT` (the parent directory, `..`, by default),
and durable state is stored under `./.harness3-server-data`. Override the
suggested workspace or state location:

```sh
HARNESS3_WORKSPACE_ROOT=/path/to/projects \
HARNESS3_DATA_DIR=/path/to/state \
gleam run
```

Model secrets loaded from Pi are held in process environment variables. The
durable harness catalog stores only generated environment-variable references,
not the secret values.

## MinIO / S3 storage

The existing local MinIO instance can be used instead of filesystem storage.
The bucket must already exist.

```sh
HARNESS3_STORAGE=s3 \
HARNESS3_S3_ENDPOINT=http://127.0.0.1:9000 \
HARNESS3_S3_BUCKET=harness3-test \
HARNESS3_S3_REGION=us-east-1 \
HARNESS3_S3_ACCESS_KEY_ID=minioadmin \
HARNESS3_S3_SECRET_ACCESS_KEY=minioadmin \
gleam run
```

## Configuration

| Variable | Default |
|---|---|
| `HARNESS3_MODELS_PATH` | `~/.pi/agent/models.json` |
| `HARNESS3_BIND` | `127.0.0.1` |
| `HARNESS3_PORT` | `8080` |
| `HARNESS3_WORKSPACE_ROOT` | `..` (resolved and suggested in the UI) |
| `HARNESS3_DATA_DIR` | `./.harness3-server-data` |
| `HARNESS3_STORAGE` | `local` |
| `HARNESS3_MODEL_TIMEOUT_MS` | `300000` |
| `HARNESS3_MAX_OUTPUT_TOKENS` | `8192` |

`Exec` deliberately gives coding agents a shell inside the selected workspace.
Keep the default loopback bind unless the surrounding environment provides
authentication and isolation.

## API

- `GET /api/health`
- `GET /api/models`
- `GET /api/sessions`
- `POST /api/sessions`
- `GET /api/sessions/:id`
- `POST /api/sessions/:id/messages`
- `POST /api/sessions/:id/stop`

Create request example:

```json
{
  "prompt": "Inspect the project, fix the failing tests, and verify the result.",
  "model_id": "provider/model",
  "workspace": ".",
  "team_size": 3
}
```

Only the lead starts immediately. Specialist agents remain durable and dormant
until the lead or a user messages them. Sending a message wakes the target and
starts a new agent round.

## Test

```sh
gleam test
```
