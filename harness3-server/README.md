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

## MCP configurations

Use the **MCP servers** button in the web UI sidebar to add or remove global MCP
servers. The manager supports Streamable HTTP and stdio transports, multiple
servers per named configuration, environment-variable or literal bindings, and
absolute stdio paths. Changes are validated and written to the durable catalog
without contacting the external server; discovery waits until an MCP specialist
activates.

As an optional bootstrap, set `HARNESS3_MCP_CONFIG_PATH` to an absolute JSON
file path. The file seeds the durable catalog only when no catalog exists yet,
so subsequent web UI changes survive restarts. Startup never contacts an
external MCP server.

```json
{
  "configurations": [
    {
      "id": "research",
      "label": "Research services",
      "enabled": true,
      "servers": [
        {
          "id": "knowledge",
          "timeout_milliseconds": 60000,
          "transport": {
            "type": "streamable_http",
            "endpoint": "https://mcp.example.com/mcp",
            "headers": [
              {
                "name": "authorization",
                "value": {
                  "type": "environment_variable",
                  "value": "KNOWLEDGE_MCP_TOKEN"
                }
              }
            ]
          }
        }
      ]
    }
  ]
}
```

Stdio servers use `"type": "stdio"` with an absolute `executable`, optional
`arguments`, an optional absolute `working_directory`, and `environment`
bindings in the same format as HTTP headers. Prefer
`environment_variable` bindings for secrets: literal values are persisted as
written. Supplied and previously discovered manifests are discarded at startup.

When a configured team has at least two agents, its researcher can be assigned
one configuration. When that agent activates, each configured server is
discovered independently. Unavailable servers are excluded, so server startup
and agent availability do not depend on external services. The model receives
only `mcp.list`, which reports reachable tools and failures, and `mcp.call`,
which invokes an identifier returned by `mcp.list`. The researcher keeps durable
teammate messaging but has no workspace, file-write, or shell tools.
Without MCP, the researcher remains least-privilege and receives
`MessageAgent` plus the group cloud-storage tools; it never falls back to local
filesystem or shell tools. Every agent receives `cloud_storage_read`,
`cloud_storage_write`, `cloud_storage_list`, `cloud_storage_delete`, and
`cloud_storage_get_url`. These tools share durable objects within one session
while keeping different sessions isolated. The lead, implementer, and reviewer
retain the coding tools and do not receive MCP
access. Session metadata and plugin state store the configuration ID, while the
global catalog owns the actual server settings. The lead can message every
subagent; subagents can message only the lead, so there is no direct
subagent-to-subagent communication path.

Models must provide Pi's `contextWindow` field. Each agent automatically
compacts its model-facing context after a normal request reaches 80% of that
window. Compaction keeps the complete persisted message history returned to
clients and stores a separate handover context for subsequent model calls.

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
| `HARNESS3_MCP_CONFIG_PATH` | unset (reuse the persisted catalog) |
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
- `GET /api/mcp/configurations`
- `POST /api/mcp/servers`
- `DELETE /api/mcp/configurations/:configuration_id/servers/:server_id`
- `GET /api/sessions`
- `POST /api/sessions`
- `GET /api/sessions/:id`
- `POST /api/sessions/:id/messages`
- `POST /api/sessions/:id/stop`

Create request example:

```json
{
  "model_id": "provider/model",
  "workspace": "/absolute/path/to/project",
  "team_size": 3,
  "mcp_configuration_id": "research"
}
```

`mcp_configuration_id` is optional. If omitted or `null` for a team of at least
two, the first enabled configuration is selected. A lead-only team,
or a server with no installed configuration, has no MCP specialist; an included
researcher is message-only in that case.

Creating a session opens its chat without starting a model call. Every agent is
durable and dormant until messaged. The first message names the session, wakes
its target, and starts that agent's first round.

## Test

```sh
gleam test
```
