# harness3 — Behavioral Specification

*Derived from the implementation at commit `3ad72e1`. This document describes what the
system actually does (observed behavior and invariants), not aspirations.*

harness3 is a tiny distributed multi-agent LLM harness. Durable state lives entirely in
an object store (local FS, S3, or GCS) accessed through a common conditional-put
interface; there is no database and no Erlang distribution. Nodes coordinate purely
through storage objects (CAS writes, leases) plus token-authenticated HTTP RPC.

---

## 1. Module map

| Module | Responsibility |
|---|---|
| `llm` | Provider-neutral request/response/event model, SSE stream decoding |
| `llm/anthropic_messages`, `llm/openai_chat_completions`, `llm/openai_responses` | Provider adapters: build HTTP requests, decode buffered/streamed responses into neutral events |
| `model_catalog` | Durable, versioned catalog of models (id → name/endpoint/type/credentials), CAS-committed |
| `plugin` | Plugin registry/runtime: system-prompt sections, tools, callbacks, activation hooks, JSON state per plugin |
| `plugin/cloud_storage/*` | Prefix-scoped durable text-object CRUD, pagination, and direct transfer URLs |
| `plugin/mcp/*` | Reusable MCP configuration/catalog, client, stdio and Streamable HTTP transports, per-agent connections, and harness plugin adapter |
| `agent` | Single agent: round loop (LLM call → tool execution → commit), streaming accumulator, plugin host actor, durable state (de)serialization |
| `agent_profile` | Node-local ETS registry of installed profiles (id → plugin registry, transport, observer, limits) |
| `agent_group` | Durable group of agents in one storage object; coordinator actor, lease/fencing, message delivery, cross-agent callbacks |
| `agent_group_registry` | Node-local ETS registry of running groups (id → pid, stop/send handles) |
| `storage` | Storage interface: get/head/put/list/delete + streaming, conditional puts |
| `storage/local`, `storage/s3`, `storage/gcs` | Backends implementing the interface |
| `cluster/core` | Per-node HTTP RPC listener (Erlang-term-over-HTTP), membership publication, recovery bootstrap |
| `cluster/distributed_lock` | Lease-based lock built on storage CAS |
| `cluster/recovery` | Leader-elected scanner that re-dispatches orphaned groups |
| `cluster/agent_group_rpc` | RPC methods: resume/wake/message/stop/force-stop agent groups, routing between nodes |

---

## 2. Storage layer

### 2.1 Interface contract

- `put(key, body, condition)` with `Unconditional`, `IfAbsent` (fail with
  `PreconditionFailed` if the object exists) or `IfUnchanged(version)` (fail with
  `PreconditionFailed` if the stored version differs). Every correctness property of the
  system — leases, fencing, optimistic concurrency — reduces to these two conditional
  modes behaving atomically.
- `VersionToken` is backend-specific: `S3Etag` (ETag string, quotes included, identical
  across put/head/get/list), `GcsGeneration` (decimal generation string), or
  `LocalVersion(mtime_seconds, generation)` where `generation` is a durable per-key
  counter that increments on every put/delete, so tokens change even when identical
  bytes are rewritten.
- `Metadata.modified_at_seconds` is normalized to Unix epoch seconds on every backend
  (HTTP-date and RFC 3339 wire formats are parsed; 0 means missing/unparseable). It is
  informational only — concurrency control uses version tokens exclusively. On GCS,
  `get` metadata comes from the media response's own headers so the version token is
  atomically bound to the returned body.
- `list(prefix)` is a raw string-prefix match over keys (no delimiter semantics) and
  must return every matching key. Both S3 and GCS paginate fully via the XML list
  API (`IsTruncated`/`start-after`); the local backend excludes its entire internal
  `.harness3*` namespace (generations, temporaries, the lock file and any leaked
  lock-break files) and sorts by key. Recovery correctness requires complete
  listings.
- Deleting a missing key succeeds on all backends. Operations retry transport errors
  and retryable HTTP statuses (408/421/425/429/5xx except 501/505) with jittered
  exponential backoff starting at 100 ms and doubling per attempt, bounded at 8
  attempts (7 sleeps, 100 ms → 6.4 s, ~13 s of total backoff) so a persistent outage
  surfaces as an error instead of blocking the caller forever.
  Conditional puts pass through the same retry path, so an ambiguous success can
  resurface as `PreconditionFailed`; every CAS caller that must not mistake its own
  applied write for a conflict compensates by exact-body read-back (group writes,
  group create and claim, running index, distributed lock, model catalog).
- All S3 requests, including lists and their pagination cursors, are signed by the
  in-repo `s3_sign` signer, which canonicalizes queries with strict SigV4 encoding
  (unreserved-only, uppercase hex). The vendored `aws4_request` package only derives
  the credential material.
- The local backend serializes every operation on an `O_EXCL` lock file inside the root;
  condition check, generation bump, tmp-file write, and rename are atomic under it.
  A directory created for a nested key is never an object (`is_regular`, not
  `is_file`). Each holder stamps a random token into the lock file; the
  heartbeat refreshes only a lock still carrying its token, via
  `file:change_time`, which fails on a missing file rather than recreating
  one (losing the refresh race at worst refreshes a successor's lock).
  Heartbeat cleanup, transaction cleanup, and every destructive commit —
  every generation-record write, including records minted while serving
  reads, plus object renames and deletes — verifies the token immediately
  beforehand, so a holder that stalls past the staleness horizon and loses
  the lock to a breaker fails its commit instead of silently overwriting the
  new holder's writes (the residual window is the instant between a verify
  and its following write, not the whole transaction).
  Interrupted writes stamp sentinel mtimes so crashes invalidate outstanding version
  tokens conservatively (false CAS failures, never false successes). Deleting a key
  leaves a small permanent generation tombstone — required for token uniqueness,
  because object mtimes are not monotonic (streaming puts commit pre-lock temp files;
  clocks can step back).
- Streaming get/put are single-pass and backpressured (next chunk is not requested until
  the consumer returns). Streaming puts never retry the body; ambiguous streaming
  outcomes surface as `Transport`.

### 2.2 Well-known key layout

- `cluster/membership/<ip>_<port>` — one object per node, refreshed every 10 s.
- `cluster/agent-groups/<percent-encoded group id>/<epoch>_<owner>` — "running index":
  one durable record per group claim.
- `cluster/locks/<percent-encoded key>` — distributed lock records (notably
  `recovery-leader`).
- Group objects and model-catalog objects live at caller-chosen keys.

---

## 3. LLM layer

### 3.1 Neutral model

`Request` = model name + messages + tools + optional `max_output_tokens` /
`reasoning_effort` + `stream` flag. Messages have roles System / Developer / User /
Assistant / ToolRole and content parts: Text, Image, Document, Reasoning (summary list +
optional provider-bound `EncryptedReasoning`), ToolCall (id, name, JSON arguments),
ToolResult (call id, nested content, is_error).

### 3.2 Event stream contract

Providers are normalized to one event vocabulary: `MessageStart`, `ContentStart(index,
kind)`, `TextDelta`, `ReasoningDelta`, `ReasoningEncrypted`, `RefusalDelta`,
`ToolCallStart(index, id, name)`, `ToolCallArgumentsDelta`, `ContentStop(index)`,
`Finished(reason)`, `UsageReported(usage)`, `MessageStop`, `UnknownEvent`.

Guarantees required of adapters, relied on by the agent accumulator:

- Each concurrently-open content block has a distinct `index`; `ContentStop` frees it.
- `TextDelta`/`RefusalDelta` without a preceding `ContentStart` are tolerated (a text
  part auto-starts); `ReasoningDelta`/`ToolCallArgumentsDelta` without a start are a
  protocol error (`InvalidModelOutput`).
- Usage reports are *cumulative snapshots within one response*; missing fields keep
  their previous value (`apply_usage`).
- Repeated `MessageStart`/`MessageStop` must be tolerated (some OpenAI-compatible
  providers repeat them).
- Adapters may repeat `ContentStart`/`ToolCallStart` on an already-open index (the
  Chat Completions adapter emits a reasoning `ContentStart` on every reasoning
  chunk); the accumulator merges rather than resets.

`StreamDecoder` buffers arbitrary SSE chunks, splits frames on blank lines (normalizes
CRLF), joins multi-`data:` lines, treats `[DONE]` as `MessageStop`, and retains an
incomplete trailing frame across pushes.

### 3.3 Transport

The harness itself never performs LLM HTTP I/O. An `agent.ModelTransport` is injected
per profile; it receives the provider, the request, and a `consume` callback, and must
not produce event N+1 until `consume` of event N has returned (backpressure contract).

A transport classifies failures as `RetryableTransportError` or
`PermanentTransportError`. The agent retries retryable failures indefinitely, beginning
at 100 ms and doubling the delay up to a 10 s cap. Every attempt receives the identical
LLM request and a fresh event accumulator, so failed partial output is not committed and
prompt-cacheable request prefixes remain unchanged. A retryable failure therefore never
marks or interrupts the agent as failed. Permanent failures still return
`ModelTransportFailed`.

The server's buffered HTTP transport treats connection and timeout failures, HTTP
408/409/421/425/429, transient 5xx responses (excluding 501 and 505), and structured
rate-limit/overload/server/timeout errors as retryable. A malformed successful provider
response is also retried because no output was accepted. Invalid requests,
authentication and other permanent HTTP failures, invalid URLs or methods, and
event-consumer failures are permanent.

---

## 4. Plugins

- A `Plugin` has a name, declared dependencies, an initial JSON state string,
  system-prompt sections, tools, named callbacks, and activation hooks.
- Codebase-owned model tools use `snake_case_namespace.snake_case_name`. This is
  a naming convention, not a registry validation rule for application plugins.
- `registry(plugins)` validates: unique plugin names, dependencies present, unique
  callback names per plugin, unique tool names *globally*, valid initial JSON state, and
  computes a topological activation order (cycle → error).
- `activate(registry, persisted_states)` seeds each plugin's state from persisted state
  (falling back to its initial state), validates JSON, then runs activation hooks in
  dependency order. **Dormant-state preservation:** persisted state for plugins *not* in
  the registry is carried through untouched, so a group can pass through a node with a
  smaller plugin set without losing state.
- `activate_hosted(registry, persisted_states, host)` additionally exposes the
  activating agent's durable identity — `Host(group_id, agent_id,
  agent_attributes, group_attributes, peers)`, where `peers` lists the group's
  other agents as id/attributes pairs — to every hook, tool, and dynamic
  prompt section via `host(context)`. `activate` provides an empty host. This
  is the channel through which one generic plugin instance serves agents whose
  per-session configuration lives in durable attributes. Agents activated
  through `agent_group` are always hosted on their group's identity.
- System-prompt sections are static (`with_system_prompt`) or dynamic
  (`with_dynamic_system_prompt`): a dynamic section is computed from the
  plugin's current state and context (including the host) every time the
  prompt is built, and must be total — unavailable content belongs in the
  section text, not in a raised error. A dynamic section whose plugin has no
  valid state is omitted.
- A plugin may also register a **release hook** (`on_release`), run by the agent's
  plugin host before it stops, to release ephemeral resources. Hooks are isolated
  from each other (a raising hook cannot skip the rest, nor make the host exit
  abnormally) and must not block: they are on the coordinator's path when an
  activated-but-unstarted agent is discarded, and the host stop is bounded (5 s),
  after which the host is unlinked and killed. Unlinking first is essential —
  `kill` exits with reason `killed`, which a non-trapping linked caller does not
  survive.
- Hooks are pure functions `state → (new_state, context, value)`. All state values must
  be valid JSON strings (validated after every hook).
- `call_dependency` lets a hook synchronously invoke a *declared* dependency's callback,
  threading state changes through the shared `Context`. Undeclared targets are an error.
- `call_agent_callback` dispatches to a plugin callback in *another agent* of the same
  group. It is available only while a tool (or a callback triggered by one) is running —
  never during activation.
- Tool invocation resolves the tool by global name, runs the owning plugin's hook, and
  returns `ToolOutput(content, is_error)`.

### 4.1 Cloud storage plugin

- `cloud_storage.new(storage, prefix)` gives an agent read, write, list, delete,
  and direct upload/download URL tools over a namespace rooted at an
  independently configurable storage prefix. The prefix must be a non-empty
  safe relative path (a trailing slash is implied); logical keys are safe
  relative paths resolved under it, so agents cannot traverse outside their
  prefix or into another namespace. Plugins built with the same prefix share
  objects; different prefixes stay isolated.
- `cloud_storage.new_resolved(storage, resolve)` defers the scope to a
  per-invocation resolver over the invoking agent's context (typically its
  durable group attributes), so one plugin instance serves agents whose
  workspaces differ or change. A resolution error fails that invocation with
  an explanatory tool error while leaving the agent runnable.
- Objects handled directly by the tools are UTF-8 text. Listing is lexicographic and
  keyset-paginated with opaque cursors. Transfer URLs are backend-provided and expire
  after five minutes where supported.
- `harness3-server` manages durable *cloud storage workspaces* (id, label,
  prefix) in a CAS-committed catalog at
  `harness3-server/cloud-storage-workspaces`, created lazily on the first
  mutation, and exposes add/edit/delete over its web API and UI. A blank
  prefix defaults to `plugins/cloud_storage/workspaces/<id>/objects/`;
  prefixes overlapping the harness control-plane namespaces (`cluster/`,
  `harness3-server/`) are rejected. Each session records an optional
  workspace association in its group attributes (an empty-string upsert
  clears it); associated sessions resolve the workspace's current prefix
  per tool invocation through the resolver-based plugin, while unassociated
  sessions get an isolated namespace at
  `plugins/cloud_storage/sessions/<session id>/objects/`.
  A workspace cannot be deleted while a session
  references it (the reference check re-runs inside the removal's commit
  retry loop), and its stored objects are never deleted with it. If a
  reference nonetheless dangles — an association landing in the same instant
  as a removal's final write — the session stays runnable and editable:
  `cloud_storage.*` invocations fail with a repair hint until the edit path
  re-points or clears the dead association.

### 4.2 MCP plugin

- MCP configuration is application-owned and durable through a CAS catalog analogous
  to the model catalog. Configurations contain one or more servers and are referenced
  by stable ID. The broker plugin itself is stateless (its durable state is empty):
  it is constructed with a configuration *loader*, called at every activation and on
  every connection discovery, so configuration edits reach running agents without the
  plugin holding a snapshot. Credentials may be
  literal or environment-variable bindings. Stdio executables and working directories
  must be absolute; HTTP endpoints must be absolute HTTP(S) URLs.
- The runtime supports MCP 2025-11-25 over newline-delimited stdio and Streamable HTTP.
  It initializes each server, sends `notifications/initialized`, follows paginated
  `tools/list` responses (bounded at 100 pages), and performs best-effort discovery
  when the plugin activates. Each successful server contributes its tools to the new
  manifest; failed servers are recorded and excluded without failing activation.
  Replaced and failed connections are closed. Tool calls are never retried because
  they may have side effects.
- `Tool.input_schema` and `Tool.output_schema` are typed `json.Json` values produced by
  object-only decoders. Catalog persistence and `mcp.list` reuse those values directly;
  there is no string-to-JSON cast. Server/tool names become deterministic,
  snake-case `mcp.*` broker identifiers with hash suffixes.
- The model sees exactly two static broker tools: `mcp.list` returns the tools from
  reachable servers, their typed schemas, and any server failures; `mcp.call` invokes
  one identifier returned by `mcp.list` with an argument object.
- The server loads optional global configuration from an absolute
  `HARNESS3_MCP_CONFIG_PATH` as a first-run seed, validates and persists configuration
  without contacting external services, and discards persisted manifests at startup.
  Its web API and UI can add, edit, or remove servers with CAS-backed durable
  updates. Management responses return complete transport settings and bindings,
  including literal HTTP header values; the UI masks literal values by default and
  can reveal them in plaintext for editing; the management listing reads the
  durable catalog, the same source agents load from. Harness3-server folds
  every server from every enabled configuration into a stable aggregate
  configuration, computed on demand from the durable catalog and namespacing
  server IDs with an injective source-configuration prefix — the aggregate is
  never stored, in the catalog or in the runtime. The agent editor therefore
  exposes one MCP researcher resource profile,
  not one profile per configuration. A configured team assigns that researcher
  `mcp.list`, `mcp.call`, `team.message_agent`, and the session's
  `cloud_storage.*` tools, but no filesystem or shell capability. Coding agents
  receive `coding.read`, `coding.write`, `coding.exec`, `team.message_agent`, and
  `cloud_storage.*`, but no MCP tools. The lead may message all subagents; every
  subagent's `team.message_agent`
  allow-list contains only the lead, preventing direct peer-to-peer subagent
  communication. Without an MCP configuration, the researcher remains a separate
  message-and-cloud-storage-only profile and is not granted local filesystem or shell
  tools.
- harness3-server's three profiles (coding workspace, isolated researcher, MCP
  researcher) are static node capabilities registered at boot, before the
  cluster node advertises itself, so the recovery RPC path can place any group
  on the node without a prior HTTP touch. Session-specific configuration
  (workspace root, role, kind, roster, cloud storage association) reaches the
  generic plugins through the durable group/agent attributes and the
  activation host. Profiles are installed exactly once, at boot, and never
  uninstalled or rewritten: the MCP researcher plugin holds no configuration
  at all — a loader reads the durable MCP catalog from storage at every agent
  activation (validating it is loadable before the agent runs) and on every
  connection discovery, so catalog edits reach agents on every node with no
  profile or runtime synchronization. A loader failure surfaces as
  `Unavailable` and leaves live transports alone; only an authoritative
  `Revoked` answer tears them down.

## 5. Model catalog

A versioned JSON object: `revision` + a list of models (id, name, endpoint, type ∈
{openai_chat_completions, openai_responses, anthropic_messages}, optional per-model
`max_output_tokens` (applied to every request the model serves), api-key credentials —
**stored in plaintext** in the object). `create` uses `IfAbsent`; `commit` bumps
`revision` and CAS-writes with `IfUnchanged`, mapping precondition failure to
`ConcurrentUpdate`. `provider(model)` instantiates the matching adapter. Groups store
only a catalog *key*; the catalog is re-read at wake and at every message injection, so
model renames/endpoint changes take effect on the next wake/injection without touching
group state (verified by test `wake_loads_the_model_catalog_on_demand_test`).

---

## 6. Agent

### 6.1 Durable state

`agent.State` = id, profile_id, revision, model_id, round, `messages`,
`pending_messages` (durable inbox), optional `tool_journal`, token stats,
per-plugin JSON states, `plugin_generation` (monotonic counter for plugin-state freshness),
`attributes` (extended attributes: opaque application-owned string key/values,
persisted verbatim and never interpreted by the harness),
`last_catalog_revision`, status ∈ {Ready, Waiting, Completed, Failed(reason)}.
(`Waiting` is not produced by the core library itself; consumers use it for agents
that should not run until first messaged — harness3-server creates all session agents
as `Waiting` and relies on message injection to promote them to `Ready`.)
State round-trips through JSON inside the group object; the persisted `messages` never
include the synthesized system prompt.

### 6.2 Round loop

Each round (the loop is internal to the worker; there is no public single-round entry
point):
1. Builds the request: plugin system prompt (all sections joined as `## name\n\nbody`,
   dynamic sections evaluated against the plugin's current state and the agent's host)
   prepended as a System message when non-empty; tools = all plugin tools.
2. Runs the transport; retryable LLM failures repeat the identical request forever with
   exponential backoff capped at 10 s. Each attempt gets a fresh per-round accumulator;
   events are keyed by provider index, stored in stream order, and forwarded to the
   profile's `observe` hook.
3. On stream end, parts become assistant content; tool-call arguments must parse as JSON
   (`InvalidModelOutput` otherwise). The finish reason is validated: `Stop`, `ToolUse`,
   `Paused`, or none pass; `Length`, `ContentFilter`, `Cancelled`, `Failed`, and
   `Other` fail the round with `InvalidModelOutput`.
4. Before any tool executes, the complete Assistant message is durably committed with
   an ordered journal whose calls are `Pending`. Each call is committed `Running` before
   invoking its plugin, then `Completed(output)` together with the latest plugin state.
   Calls execute sequentially; cross-agent callbacks still route through the coordinator.
5. Once every call is Completed, all matching ToolResult messages are appended as one
   ordered block and the journal is cleared. Only this final commit folds the durable
   inbox into the conversation. The next model request is never built while a journal
   remains unresolved.
6. After a crash, a durable Running call becomes an error ToolResult saying its outcome
   is unknown and may be partial; later Pending calls become explicit not-executed
   results. Earlier Completed outputs are retained. This closes every ToolCall/ToolResult
   pair before pending user messages are appended, and never blindly replays a possibly
   side-effecting invocation. If the event observer fails at ToolStarted or ToolFinished,
   the journal is likewise closed (later calls are recorded as not executed) before the
   agent becomes Failed; observer errors are never silently swallowed.

### 6.3 Process structure and lifecycle

- The plugin host is a dedicated actor owning the plugin runtime; the worker process,
  spawned unlinked and then linked to the plugin host, waits on a release gate (60 s
  max), then loops round → `commit` until Completed/Failed, stops the plugin host,
  and fires `on_exit`.
- Commits go through an injected `Checkpointer` with the expected agent revision. The
  commit *returns the authoritative state*: if the coordinator merged queued inbox
  messages, the returned status is Ready and the worker immediately runs another round.
- A failed round commits `Failed(reason)`; if the commit response comes back Ready
  (messages were queued meanwhile), the worker retries; otherwise it exits.
- `agent.stop` unlinks and kills the worker (the linked plugin host dies with it).

---

### 6.4 Context compaction

An agent keeps the full `messages` history durably, plus an optional
`context_messages` — the model-facing view after compaction. Compaction asks the
model for a `<handover>` summary of the session (no tools allowed) and replaces the
model-facing context with it; the full history is never truncated. Durable counters
`compaction_requested`/`compaction_completed` sequence requests; `request_compaction`
on the group durably records a request (clearing any prior failure) and starts a
worker for dormant agents. Compaction triggers when a request is pending, or
automatically when the last round's input tokens reach 80 % of the model's context
window — deliberately including right after a round that completed the agent, so a
later revival starts from the compacted handover. A failed attempt records
`last_compaction_error` and *pauses* the manual request (no per-round retries, no
restart-on-exit loops) until a new explicit request clears it; messages that arrived
during a failed compaction are still folded in by its commit and processed by normal
rounds. A worker exiting with an unattempted pending request is restarted by the
coordinator — unless a live replacement worker already exists (stale exit notices
must not start duplicates).

### 6.5 MCP plugin

An optional plugin brokers Model Context Protocol servers to an agent as two tools
(`mcp.list`, `mcp.call`). Stdio servers run as child processes, streamable-HTTP
servers as sessioned HTTP clients.

**Ownership is the load-bearing property.** Configuration is global; connections are
not:

- `mcp/runtime` is a node-wide registry of *configurations* only — the role
  `model_catalog` plays for models. Its catalog is durable and CAS-committed with
  ambiguous-write read-back confirmation. It holds no connections and performs no
  discovery, so every call into it is served from memory and is safe from any
  process, including the group coordinator.
- `mcp/connections` holds one agent's connections and discovered tools as **plain
  state**,
  not a process. The value lives in the plugin's **ephemeral resource**
  (`plugin.resource` / `plugin.set_resource`) — a per-agent slot that, unlike plugin
  state, is never serialized and never leaves the agent. Servers are contacted from
  *inside that agent's plugin host* on first tool use, so the transport actors are
  spawn-linked to the host. A link alone is not sufficient: Erlang discards a
  *normal* exit signal at a non-trapping process, so a gracefully finishing host
  would leave its transports (and their OS children) running. The plugin's
  **release hook** (`plugin.on_release`, run by the host before it stops) closes
  them explicitly; the link covers only abnormal termination. Connections are therefore never
  shared: one agent's discovery cannot close a connection another agent is calling
  through. An intermediate owning actor would add a hop without adding isolation —
  it would be linked to the host too — and the host is already the single serialized
  caller, since an agent's tool calls run sequentially.
- **Activation never touches MCP servers.** Activation hooks run inside the group
  coordinator, which also services lease renewal, so the hook only validates that
  the configuration exists and is enabled. Connecting, discovering, and calling all
  happen in the agent's plugin host.
- Within an agent, a manifest is reused for a TTL (5 min) while its connections are
  still alive, so repeated tool calls don't re-spawn servers; a dead connection
  forces re-discovery rather than failing every call until the TTL lapses.

Transport rules: child processes get SIGTERM *before* their port is closed (closing
first makes the signal a no-op and orphans the child); response correlation requires
the absence of a `method` field, since server-initiated requests share the client's
ID space; servers negotiating an older protocol revision are accepted when supported;
document size, tool count, and page count are bounded because everything listed is
serialized into the agent's context; HTTP sessions are deleted on close and a 404
clears the session id so the next call re-initializes.

## 7. Agent group

### 7.1 Durable object and execution states

`AgentGroup` = id, model_catalog_key, monotonically increasing `revision`, agent states,
group-level `attributes` (extended attributes: opaque application-owned string
key/values, like the per-agent ones), and `execution` ∈ `Idle | Claimed(owner,
epoch, lease_expires_at) | Completed`. The whole group is one JSON object; every
mutation is a CAS (`IfUnchanged`) that bumps `revision` and (while owned)
extends the lease. `peek` reads and decodes the object without profiles,
validation, or claiming — how an application renders a view of a group, or
reconstructs the profiles a `resume` needs from the group's own attributes. The epoch increments on every claim,
is carried through `Idle`/`Completed` as well as `Claimed`, and is the fencing token
in the running-index key — releasing a claim must not reset it, or a later claim
could reuse a key a stale index entry still occupies. A claim takes its epoch from
the greater of the group's own epoch and the highest surviving running-index entry,
so a group written before the epoch was carried (or one whose entries outlived a
crash) still advances past anything already published. Every claim also carries a random nonce so
its body is unique per attempt — the ambiguous-CAS read-back confirmation must never
match a concurrent same-owner claim from the same wall-clock second.

### 7.2 Lifecycle

- `create` — validate, `IfAbsent` write. Creating is dormant: no processes, no
  registry entry, no index entry. Neither `create` nor `resume` writes to the
  node's profile registry — registering profiles as node capabilities is the
  application's responsibility (`agent_profile.install`).
- `resume` / `resume_registered` — load + validate; `resume_registered` reconstructs the
  profile list from the node's installed profiles (only for agents in Ready status).
- **Updates (`GroupUpdate`)** — a durable update *command* for the roster
  and/or extended attributes. Commands carry no agent state: attribute maps
  are upserts, and a `Some` roster is a list of `RosterEntry(id, profile_id,
  model_id, attributes, initial_status)` declaring the desired agent list. The
  group's single writer applies a command to the state it authoritatively
  holds — `wake_detached_updated` atomically with the claim CAS (validated
  against the same profiles and catalog as the wake, fenced by the loaded
  version), `update_group` through a live coordinator, serialized with commits
  and lease renewal — so a stale caller snapshot can never overwrite
  concurrent progress. An existing agent named by a roster entry keeps its
  durable state (history, plugin state, inbox, status); a new id is created
  from scratch with `initial_status`; changing an agent's model scrubs
  provider-locked encrypted reasoning from its conversation. A live
  coordinator rejects roster commands (`InvalidGroup`): roster changes stop
  the group first and ride the next wake. Claimed groups fail a wake-applied
  update with `AlreadyClaimed`, so an active coordinator cannot be
  overwritten. Surviving agents' pending messages are folded in by the claim;
  removed agents' pending messages are dropped with them.
- `wake` (`wake_as…`) — re-reads the model catalog, validates models for Ready agents,
  requires the lease to be absent/expired (`AlreadyClaimed` otherwise), CAS-claims the
  group (epoch+1; queued `pending_messages` are folded into `messages` and agents made
  Ready), then starts the coordinator.
- **Claim publication order (invariant):** local registry registration → synchronous,
  acknowledged membership refresh → `IfAbsent` write of the running-index entry
  (`cluster/agent-groups/<id>/<epoch>_<owner>`). Recovery relies on this order paired
  with its own reversed read order (index first, membership second). If the index write
  fails, the claim is rolled back (unregister, refresh again, kill coordinator) but the
  group object remains claimed until the lease expires.
- One worker is started per agent in Ready status; agents in Completed/Failed status
  stay dormant.
- `wake`/`wake_as` deliberately link the started process tree to the waking process
  (embedders supervise the group with their own lifetime). `wake_detached` runs the
  wake in a short-lived process instead — used by the RPC resume handler and the
  server — so a transient request handler's abnormal exit cannot tear down the group.
  Failed group starts stop any plugin hosts they had already activated.
- The coordinator stops when it has no children and no callback helpers *and* the
  configured minimum lifetime has elapsed; it then releases the group and deletes its
  index entry — in that order, since a deleted index plus a still-`Claimed` group is
  invisible to recovery, whereas a stale index entry for a released group is merely a
  spurious wake (execution → `Completed` if all agents terminal, else `Idle`). `stop()`
  kills children/helpers first, then finishes the same way.

### 7.3 Coordinator serialization and fencing

All group mutations (agent commits, message delivery, callback-state persistence, lease
renewal) are messages to a single coordinator actor, so storage CAS conflicts only occur
against *foreign* writers. On `ConcurrentGroupUpdate` or `LostGroupOwnership` the
coordinator abandons: kills children and helpers, unregisters, stops — without touching
the group object (fenced; the foreign owner wins). Lease renewal fires every
`lease/2` seconds and refuses to renew an already-expired lease.

**Ambiguous CAS absorption:** a `PreconditionFailed` on a group write is confirmed by
reading back the object; if the stored body equals the intended body the write is
treated as having succeeded (handles retried-but-reported-failed writes; verified by
test `ambiguous_successful_cas_is_idempotent…`).

### 7.4 Agent commit protocol

`CommitAgent(id, expected_revision, new_state, mode)`: rejected when unowned
(`LostGroupOwnership`) or when `expected_revision` mismatches (`StaleAgentCommit`).
On success the agent revision increments. `ToolProgressCommit` requires an unresolved
journal and preserves the coordinator's current `pending_messages` without inserting
anything between ToolCall and ToolResult. `RoundCommit` requires the journal to be clear
and atomically appends the inbox to `messages`, clears it, and forces Ready when messages
were pending. If the committed state's `plugin_generation` is older than the currently
persisted one (a cross-agent callback advanced it mid-round), the persisted plugin states
win.

### 7.5 Message delivery (`send_message`)

Empty/whitespace messages are rejected. If the target agent has a live worker, the
message is appended to the durable `pending_messages` inbox *without* bumping the agent
revision (the worker's next final round commit consumes it). Otherwise the inbox plus the
new message are folded into `messages` in one CAS (revision+1, status Ready) and a fresh
worker is started. With an unresolved tool journal, even a dormant worker keeps all new
deliveries in the inbox and restarts recovery first. A message is never inserted between
an Assistant ToolCall and its complete ToolResult block. When a worker exits leaving an
inbox or journal, the coordinator immediately restarts it. Journal-driven restarts are
budgeted: after 3 consecutive worker exits with no successful commit in between (only a
commit can close a journal, so this means storage writes are failing persistently), the
coordinator abandons the group instead of hot-looping; recovery re-dispatches it after
the lease expires, with the journal intact. Any successful commit resets the budget.

### 7.6 Cross-agent callbacks

A tool in agent A may call `plugin.call_agent_callback(ctx, "B", plugin, cb, input)`.
The dispatch travels A's plugin host → coordinator → spawned *helper* process → B's
plugin host (`InvokeCallback`) → back. Self-calls and calls from/to agents without live
workers fail with `AgentCallbackUnavailable`. After the callback runs, the helper
persists B's new plugin states via the coordinator (skipped if the persisted generation
is already ≥ the new one), then replies to A. Helpers are linked to the coordinator:
a helper crash tears the whole group tree down (crash-only recovery); graceful exits are
reaped via `CallbackHelperExited`.

### 7.7 Process tree

The coordinator links to every worker; workers link to their plugin hosts; helpers link
to the coordinator; `wake`'s caller is linked transitively (via `actor.start`). Any
abnormal exit anywhere collapses the whole tree (verified by
`linked_agent_crash_terminates_process_tree_test`); the lease then expires and cluster
recovery redispatches the group.

---

## 8. Cluster

### 8.1 Node (`cluster/core`)

`start` opens a mist HTTP listener, generates a random 32-byte bearer token, writes the
membership object, starts a 10 s membership refresher, and starts the recovery
component. RPC: `POST /rpc/<method>` with `Authorization: Bearer <token>`
(constant-time compare) and an Erlang-term-encoded body (`binary_to_term` with `safe`).
Handlers are name-registered; exceptions map to 500, typed errors to 4xx/5xx. Membership
bodies carry token, ip, port, the node's live group ids, and `refreshed_at`; the object
is deleted on shutdown. `refresh(cluster)` / `context_refresh_membership` publish
membership synchronously and return only after the storage write is acknowledged.

### 8.2 Distributed lock

Lock object under `cluster/locks/`; acquire is `IfAbsent` (or CAS-replace of an expired
record); renew/release are CAS on the last-seen version, `PreconditionFailed` → `Lost`.
Release writes an immediately-expired record. Liveness depends on wall-clock leases;
safety on storage CAS.

### 8.3 Recovery (`cluster/recovery`)

Every 10 s each node tries to acquire/renew the `recovery-leader` lock (30 s lease).
The leader scans: running-index entries first, then membership objects (this order pairs
with the claim-publication invariant). Nodes refreshed within 30 s are alive. Candidate
groups = indexed groups not listed by any alive node, reduced to the newest epoch per
group. Candidates are dispatched round-robin over shuffled alive nodes via the
`resume_agent_group` RPC; on success the group's index entries are *re-listed* and
only epochs strictly below the newest are deleted — the newest is either the fresh
claim's entry or (when the target answered "already running") the live claim itself,
which must survive so the group stays visible to recovery if its node later crashes.
A node that fails is skipped; a group is retried on the next scan. Stale index entries
of groups woken outside recovery are cleaned lazily the next time the group is not
listed by an alive node (at the cost of one spurious wake). Each candidate's index
entry is re-checked immediately before dispatch so a group that stopped cleanly after
the scan snapshot is not resurrected. Leadership is forfeited only on a confirmed
lock replacement (`Lost`); a transient storage error keeps the lock and merely skips
that scan cycle.

### 8.4 Group RPC (`cluster/agent_group_rpc`)

- `resume_agent_group(group_key)` — if the group is already live locally, force a
  membership refresh and return; otherwise `resume_registered` + wake with the node
  token as owner (lease conflicts surface as `wake_failed`).
- `wake_agent_group(group_id, group_key, visited)` — routed to the current recovery
  leader (redirect with loop detection via the `visited` token list); the leader checks
  the running index + membership and either confirms the group is running or dispatches
  a resume to a random alive node.
- `message_agent_group(group_id, agent_id, message, visited)` — try the local registry;
  otherwise locate the host via running index (newest epoch) or membership listing and
  redirect once (loop-checked). Messaging never wakes a dormant group.
- `inject_agent_tool_call(group_id, agent_id, tool_name, arguments, response, visited)` —
  same host routing as `message_agent_group`, but the injection is a synthetic tool call:
  an assistant `ToolCall` (generated `synthetic-*` id, caller-chosen name and JSON-object
  arguments, not necessarily in the agent's tool list) followed by its `ToolResult`
  carrying the caller-chosen response. When the pair would start the conversation or
  directly follow an assistant message (including the uncertain tail behind an in-flight
  round with an empty inbox), a fixed user hint message is prepended — the two shapes
  providers reject. The hint can produce consecutive user messages, which every
  supported provider accepts. Never wakes a dormant group.
- `update_agent_group(group_id, group_attributes, agent_attributes, visited)` —
  host-routed extended-attribute upserts, applied through the owning
  coordinator (same routing as `message_agent_group`). It never wakes a
  dormant group: a caller updates a dormant group by waking it with the update
  riding the claim CAS instead.
- `force_stop_agent_group(group_id)` — local registry force-stop.
- `stop_agent_group(group_id, visited)` — idempotent host-routed stop. A local live
  group is stopped directly; otherwise the newest running index and membership
  locate its host and redirect with loop detection. A group with no reachable live
  host (crashed owner, or an index entry pointing at this node whose registry has
  no such group) is durably finalized: its stale index entries are removed and an
  expired claim is released, so recovery cannot resurrect a group the caller was
  told is stopped. While the crashed owner's lease is unexpired the stop fails
  with `still_leased` rather than reporting success it cannot deliver; storage
  read failures propagate instead of masquerading as a completed stop. A dormant
  group with no index entries is already stopped and succeeds without waking it.

### 8.5 Node-local registries

`agent_group_registry` and `agent_profile` are public named ETS tables created lazily by
a detached holder process. The group registry stores id → (pid, stop closure, send
closure, inject closure, compaction closure, attribute-update closure); reads
sweep entries whose pids died.
Registration of an id overwrites; unregistration only removes the exact (id, pid) pair.

---

## 9. Provider adapters (spec notes)

*(See §3 for the neutral contract. Adapter-specific mapping notes.)*

- **Role mapping.** Anthropic: System and Developer messages are hoisted out of
  `messages` (text-only, concatenated with `\n`) into the single top-level `system`
  string — mid-conversation position is lost; ToolRole → `user` with `tool_result`
  blocks. Chat Completions: System → `system`, Developer → `developer`, ToolRole →
  `tool` with exactly one ToolResult per message. Responses: ToolRole content becomes
  top-level `function_call_output` items; assistant text → `output_text`, other text →
  `input_text`.
- **Tool results.** `is_error` is representable only on Anthropic; Chat Completions and
  Responses drop it silently. Chat/Responses tool results are text-only (`Unsupported`
  otherwise); Anthropic allows text+image.
- **Encrypted reasoning is provider-locked**: Anthropic and Responses hard-fail
  (`InvalidRequest`) on foreign or missing provider state; Chat Completions omits
  encrypted state and replays only concatenated summary text via a configurable field.
- **Index spaces.** Anthropic uses native block indices; Responses uses `output_index`
  for everything (collision-free); Chat Completions has no native blocks — each choice
  gets a disjoint range with base `choice × 1 000 000`: text and refusal at the base,
  reasoning at base + 1 (with an explicit `ContentStart`), tool calls at
  base + 2 + call_index. When a tool-call delta omits its `index` the position in
  that delta's list substitutes — exact for buffered responses and for streamed
  single tool calls, but a streaming provider that omits `index` *and* emits
  parallel tool calls would collapse them onto one index (known limitation; OpenAI
  itself always sends `index`). Text emits no `ContentStart`/`ContentStop` (relies on the
  accumulator's auto-start).
- **Lifecycle.** `MessageStop` comes from `[DONE]` (Chat), `message_stop` (Anthropic),
  or the terminal `response.*` event (Responses). Buffered (non-streaming) decodes
  synthesize the full event lifecycle. Finish-reason mapping includes Anthropic
  `pause_turn` → `Paused`, `refusal` → `ContentFilter`,
  `model_context_window_exceeded` → `Length`.
- **Usage.** Cumulative-snapshot semantics everywhere; Anthropic reports on
  `message_start` and `message_delta`; Chat streaming usage is requested via
  `stream_options.include_usage`; cache-write tokens exist only on Anthropic and
  OpenRouter-style extensions.
- **Notable defaults.** Anthropic `max_tokens` defaults to **1024** when the model's
  catalog entry sets no `max_output_tokens` (truncation risk for agent turns); Anthropic requests set
  a top-level ephemeral `cache_control`; Responses requests always send `store: false`
  and `include: ["reasoning.encrypted_content"]`, and full history is resent each round
  (`previous_response_id` is not used); `reasoning_effort` maps to adaptive thinking +
  `output_config.effort` (Anthropic), `reasoning_effort` (Chat), `reasoning.effort`
  (Responses).

---

## 10. Global invariants (summary)

1. Group state changes only via CAS on the single group object; `revision` strictly
   increases; at most one owner mutates it (lease + fencing on every commit).
2. A message durably exists in exactly one of `messages` / `pending_messages`.
3. Agent revision increments exactly once per worker commit; stale workers are rejected.
4. Plugin state is always valid JSON; unknown plugins' state is preserved verbatim;
   `plugin_generation` never moves backwards in persisted state.
5. Claim visibility order: registry → acknowledged membership → running index; recovery
   reads index → membership. Together these prevent double-dispatch of a live group.
6. Only expired leases can be re-claimed; epochs strictly increase per claim; the
   highest-epoch index entry identifies the latest owner.
7. Tool names are globally unique per registry; dependencies are acyclic and must be
   declared to be callable.
8. The persisted conversation never contains the synthesized system prompt.
9. MCP discovery occurs at agent activation; failed servers are excluded without
   affecting server or agent availability. Every discovered schema remains typed JSON
   across discovery, persistence, broker listing, and tool invocation.
