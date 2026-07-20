# harness3-server

A local-first coding-agent service built on `harness3`. It loads the same model
configuration as Pi, exposes a JSON API, and serves a multi-agent web UI.

## Run

Pi models are loaded from `~/.pi/agent/models.json` by default. Build the web
UI, then run the server from this directory:

```sh
cd web
npm ci
npm run build
cd ..
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

Use the **MCP servers** button in the web UI sidebar to add, edit, or remove
global MCP servers. The manager supports Streamable HTTP and stdio transports,
multiple servers per named configuration, environment-variable or literal
bindings, and absolute stdio paths. Changes are validated and written to the
durable catalog without contacting the external server; discovery waits until
an MCP specialist activates.

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
written. The management API intentionally returns configured bindings in full,
including literal HTTP header values, and the web editor can reveal those values
in plaintext. Protect the management API accordingly. Supplied and previously
discovered manifests are discarded at startup.

When a configured team has at least two agents, its researcher receives every
server from every enabled global MCP configuration. Harness3-server maintains a
stable aggregate runtime configuration and namespaces server IDs by their source
configuration, so identically named servers do not collide. Each server is
discovered independently. Unavailable servers are excluded, so server startup
and agent availability do not depend on external services. The model receives
only `mcp.list`, which reports reachable tools and failures, and `mcp.call`,
which invokes an identifier returned by `mcp.list`. The researcher keeps durable
`team.message_agent` access but has no workspace, file-write, or shell tools.
Without any enabled MCP servers, the researcher remains least-privilege and receives
`team.message_agent` plus the group cloud-storage tools; it never falls back to
local filesystem or shell tools. Every agent receives `cloud_storage.read`,
`cloud_storage.write`, `cloud_storage.list`, `cloud_storage.delete`, and
`cloud_storage.get_url`. These tools share durable objects within one session
while keeping different sessions isolated. The lead, implementer, and reviewer
retain the coding tools and do not receive MCP
access. Plugin state references the stable aggregate configuration ID, while
the group's agent attributes only record the MCP resource profile and the
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
| `HARNESS3_CLUSTER_BIND` | `127.0.0.1` |
| `HARNESS3_CLUSTER_PORT` | `0` (ephemeral) |
| `HARNESS3_WORKSPACE_ROOT` | `..` (resolved and suggested in the UI) |
| `HARNESS3_DATA_DIR` | `./.harness3-server-data` |
| `HARNESS3_STORAGE` | `local` |
| `HARNESS3_MODEL_TIMEOUT_MS` | `300000` |

The output-token cap is configured per model, not globally: each model's
`maxTokens` from the Pi models file is carried into the harness model catalog
and applied to every request that model serves. A model without `maxTokens`
uses the provider default (the Anthropic API's required-field fallback is
1024).

`coding.exec` deliberately gives coding agents a shell inside the selected workspace.
Keep the default loopback bind unless the surrounding environment provides
authentication and isolation.

## API

- `GET /api/health`
- `GET /api/models`
- `GET /api/mcp/configurations`
- `POST /api/mcp/servers`
- `PUT /api/mcp/configurations/:configuration_id/servers/:server_id`
- `DELETE /api/mcp/configurations/:configuration_id/servers/:server_id`
- `GET /api/sessions`
- `POST /api/sessions`
- `GET /api/sessions/:id`
- `PUT /api/sessions/:id`
- `POST /api/sessions/:id/messages`
- `POST /api/sessions/:id/agents/:agent_id/compact`
- `POST /api/sessions/:id/stop`

The MCP update route accepts `{ "server": { ... } }` using the same server
shape nested in the add request. The configuration and server IDs come from
the URL and remain stable. MCP configuration responses include full `headers`
or `environment` binding arrays and stdio `arguments`, rather than redacted
counts.

Create request example:

```json
{
  "model_id": "provider/model",
  "workspace": "/absolute/path/to/project",
  "team_size": 3
}
```

Update request example:

```json
{
  "name": "Release team",
  "agents": [
    {
      "id": "lead",
      "role": "Lead engineer with coding workspace access.",
      "kind": "coding",
      "model_id": "provider/model"
    },
    {
      "id": "researcher",
      "role": "MCP research specialist that reports to the lead.",
      "kind": "mcp",
      "model_id": "provider/other-model"
    }
  ]
}
```

The **Edit team** button changes the group name, each agent's model and resource
profile, and adds or removes agents. Sessions have no storage record of their
own: a session is a view of its durable agent group, whose extended attributes
carry the title, prompt, workspace, creation time, and each agent's role and
kind. Every update goes through the group's single writer — a name-only edit
reaches a live coordinator via the host-routed update RPC (waking a dormant
group with the update riding its claim), while roster or model changes stop the
group first through the host-routed RPC and apply the new roster atomically
with the next wake's claim. Surviving agents retain their durable history and
plugin state, added agents start dormant, and removed agents are deleted.
Because updates ride a wake, editing or renaming a session whose agents were
interrupted mid-work (still in Ready status) resumes their execution; agents
that completed or were never messaged stay dormant. Existing agent IDs are
immutable in the UI; replace an agent to give it a different ID.

A team of at least two uses the MCP researcher automatically when any enabled
global configuration contains a server. The agent editor exposes one MCP
resource profile covering all enabled servers; it does not select individual
configurations. A lead-only team, or a server with no enabled configuration,
has no MCP specialist; an included researcher is message-only in that case.

Creating a session opens its chat without starting a model call. Every agent is
durable and dormant until messaged. The first message names the session, wakes
its target, and starts that agent's first round.

Transient LLM connection, timeout, throttling, overload, and server failures are
retried indefinitely with exponential backoff capped at 10 seconds. They do not
fail or interrupt the agent; permanent request and authentication errors still
surface as agent failures.

The **Compact** button in the selected agent's thread toolbar manually queues a
handover compaction. It is available after that agent has session messages,
shows pending and retry states, and first sends the idempotent cluster wake RPC
before sending the host-routed compaction RPC. An inactive team is therefore
woken automatically, while an already-active team is left running in place.

## Web UI development

The UI source is a lightweight React and TypeScript application under `web/`,
built with Vite and Tailwind CSS. It has no separate production runtime:
`npm run build` writes
fixed `app.js`, `styles.css`, and `index.html` assets to `priv/static/` for the
Gleam server to serve. These generated files are intentionally ignored; build
or packaging workflows must generate them before compiling or releasing the
server. Node.js is not needed after the assets have been built.

Vite requires Node.js 20.19 or newer. For local development:

```sh
cd web
npm ci
npm run dev
```

The development server proxies `/api` to harness3-server on
`http://127.0.0.1:8080`. Type-check and generate the production assets with:

```sh
npm run build
```

## Test

```sh
gleam test
```
