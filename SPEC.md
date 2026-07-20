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
| `plugin/mcp/*` | Reusable MCP configuration/catalog, 2025-11-25 client, stdio and Streamable HTTP transports, discovery runtime, and harness plugin adapter |
| `agent` | Single agent: round loop (LLM call → tool execution → commit), streaming accumulator, plugin host actor, durable state (de)serialization |
| `agent_profile` | Node-local ETS registry of installed profiles (id → plugin registry, transport, observer, limits) |
| `agent_group` | Durable group of agents in one storage object; coordinator actor, lease/fencing, message delivery, cross-agent callbacks |
| `agent_group_registry` | Node-local ETS registry of running groups (id → pid, stop/send handles) |
| `storage` | Storage interface: get/head/put/list/delete + streaming, conditional puts |
| `storage/local`, `storage/s3`, `storage/gcs` | Backends implementing the interface |
| `cluster/core` | Per-node HTTP RPC listener (Erlang-term-over-HTTP), membership publication, recovery bootstrap |
| `cluster/distributed_lock` | Lease-based lock built on storage CAS |
| `cluster/recovery` | Leader-elected scanner that re-dispatches orphaned groups |
| `cluster/agent_group_rpc` | RPC methods: resume/wake/message/force-stop agent groups, routing between nodes |

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
  must return every matching key. S3 and GCS backends paginate fully
  (`IsTruncated`/`start-after`, `nextPageToken`); the local backend excludes its
  internal bookkeeping files and sorts by key. Recovery correctness requires complete
  listings.
- Deleting a missing key succeeds on all backends. Operations retry transport errors
  and retryable HTTP statuses (408/421/425/429/5xx except 501/505) with jittered
  exponential backoff (100 ms → 10 s), bounded at 8 attempts (~13 s of backoff) so a
  persistent outage surfaces as an error instead of blocking the caller forever.
  Conditional puts pass through the same retry path, so an ambiguous success can
  resurface as `PreconditionFailed`; every CAS caller that must not mistake its own
  applied write for a conflict compensates by exact-body read-back (group writes,
  group create and claim, running index, distributed lock, model catalog).
- Known limitation: the vendored `aws4_request` signer canonicalizes query strings
  with form encoding (`+` for space), so an S3 `list` whose pagination cursor
  (`start-after`) contains a space or `+` would fail signing. Unreachable with the
  key alphabets this system generates; the in-repo `s3_sign` signer used for
  streaming canonicalizes queries with strict SigV4 encoding (unreserved-only,
  uppercase hex), though no streaming caller currently sets a query.
- The local backend serializes every operation on an `O_EXCL` lock file inside the root;
  condition check, generation bump, tmp-file write, and rename are atomic under it.
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

`StreamDecoder` buffers arbitrary SSE chunks, splits frames on blank lines (normalizes
CRLF), joins multi-`data:` lines, treats `[DONE]` as `MessageStop`, and retains an
incomplete trailing frame across pushes.

### 3.3 Transport

The harness itself never performs LLM HTTP I/O. An `agent.ModelTransport` is injected
per profile; it receives the provider, the request, and a `consume` callback, and must
not produce event N+1 until `consume` of event N has returned (backpressure contract).

---

## 4. Plugins

- A `Plugin` has a name, declared dependencies, an initial JSON state string,
  system-prompt sections, tools, named callbacks, and activation hooks.
- `registry(plugins)` validates: unique plugin names, dependencies present, unique
  callback names per plugin, unique tool names *globally*, valid initial JSON state, and
  computes a topological activation order (cycle → error).
- `activate(registry, persisted_states)` seeds each plugin's state from persisted state
  (falling back to its initial state), validates JSON, then runs activation hooks in
  dependency order. **Dormant-state preservation:** persisted state for plugins *not* in
  the registry is carried through untouched, so a group can pass through a node with a
  smaller plugin set without losing state.
- Hooks are pure functions `state → (new_state, context, value)`. All state values must
  be valid JSON strings (validated after every hook).
- `call_dependency` lets a hook synchronously invoke a *declared* dependency's callback,
  threading state changes through the shared `Context`. Undeclared targets are an error.
- `call_agent_callback` dispatches to a plugin callback in *another agent* of the same
  group. It is available only while a tool (or a callback triggered by one) is running —
  never during activation.
- Tool invocation resolves the tool by global name, runs the owning plugin's hook, and
  returns `ToolOutput(content, is_error)`.

### 4.1 MCP plugin

- MCP configuration is application-owned and durable through a CAS catalog analogous
  to the model catalog. Configurations contain one or more servers; plugin state and
  server session metadata reference a configuration by stable ID. Credentials may be
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
  there is no string-to-JSON cast. Server/tool names are deterministically namespaced
  and hash-suffixed into stable broker identifiers.
- The model sees exactly two static broker tools: `mcp.list` returns the tools from
  reachable servers, their typed schemas, and any server failures; `mcp.call` invokes
  one identifier returned by `mcp.list` with an argument object.
- The server loads optional global configuration from an absolute
  `HARNESS3_MCP_CONFIG_PATH` as a first-run seed, validates and persists configuration
  without contacting external services, and discards persisted manifests at startup.
  Its web API and UI can add or remove servers with CAS-backed durable updates; those
  updates invalidate live connections and discovery state for the affected
  configuration. Management responses omit binding values. A configured team
  assigns the researcher `mcp.list`, `mcp.call`, and `MessageAgent`, but no filesystem
  or shell capability. Coding agents receive Read/Write/Exec plus `MessageAgent`, but no
  MCP tools. The lead may message all subagents; every subagent's `MessageAgent`
  allow-list contains only the lead, preventing direct peer-to-peer subagent
  communication. Without an MCP configuration, the researcher remains a separate
  message-only profile and is not granted local filesystem or shell tools.

## 5. Model catalog

A versioned JSON object: `revision` + a list of models (id, name, endpoint, type ∈
{openai_chat_completions, openai_responses, anthropic_messages}, api-key credentials —
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
`pending_messages` (durable inbox), token stats, per-plugin JSON states,
`plugin_generation` (monotonic counter for plugin-state freshness),
`last_catalog_revision`, status ∈ {Ready, Waiting, Completed, Failed(reason)}.
(`Waiting` is not produced by the core library itself; consumers use it for agents
that should not run until first messaged — harness3-server creates all session agents
as `Waiting` and relies on message injection to promote them to `Ready`.)
State round-trips through JSON inside the group object; the persisted `messages` never
include the synthesized system prompt.

### 6.2 Round loop

`run_round`:
1. Builds the request: plugin system prompt (all sections joined as `## name\n\nbody`)
   prepended as a System message when non-empty; tools = all plugin tools.
2. Runs the transport; every event is forwarded to the profile's `observe` hook and to a
   per-round accumulator actor (events keyed by provider index, stored in stream order).
3. On stream end, parts become assistant content; tool-call arguments must parse as JSON
   (`InvalidModelOutput` otherwise). `Finished(reason)` events are **ignored** — the
   round's outcome is derived solely from whether tool calls are present.
4. Tool calls execute sequentially through the plugin-host actor; each produces one
   ToolRole message. During a tool, cross-agent callbacks are dispatched through the
   group coordinator.
5. Disposition: tool messages present → `Continue` (status Ready); none → `Complete`
   (status Completed). Round counter increments; plugin states/generation are
   re-snapshotted from the plugin host.

### 6.3 Process structure and lifecycle

- The plugin host is a dedicated actor owning the plugin runtime; the worker process,
  spawned unlinked and then linked to the plugin host, waits on a release gate (60 s
  max), then loops `run_round` → `commit` until Complete/Failed, stops the plugin host,
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

## 7. Agent group

### 7.1 Durable object and execution states

`AgentGroup` = id, model_catalog_key, monotonically increasing `revision`, agent states,
and `execution` ∈ `Idle | Claimed(owner, epoch, lease_expires_at) | Completed`. The
whole group is one JSON object; every mutation is a CAS (`IfUnchanged`) that bumps
`revision` and (while owned) extends the lease. Epoch increments on every claim and is
the fencing token in the running-index key. Every claim also carries a random nonce so
its body is unique per attempt — the ambiguous-CAS read-back confirmation must never
match a concurrent same-owner claim from the same wall-clock second.

### 7.2 Lifecycle

- `create` — validate, install profiles, `IfAbsent` write. Creating is dormant: no
  processes, no registry entry, no index entry.
- `resume` / `resume_registered` — load + validate; `resume_registered` reconstructs the
  profile list from the node's installed profiles (only for agents in Ready status).
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
  configured minimum lifetime has elapsed; it then deletes its index entry and releases
  the group (execution → `Completed` if all agents terminal, else `Idle`). `stop()`
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

`CommitAgent(id, expected_revision, new_state)`: rejected when unowned
(`LostGroupOwnership`) or when `expected_revision` mismatches (`StaleAgentCommit`).
On success the agent revision increments, and — atomically in the same group CAS —
any messages queued in `pending_messages` while the worker was busy are appended to
`messages`, the inbox is cleared, and status is forced Ready so the returned state makes
the worker continue. If the committed state's `plugin_generation` is older than the
currently persisted one (a cross-agent callback advanced it mid-round), the persisted
plugin states win.

### 7.5 Message delivery (`send_message`)

Empty/whitespace messages are rejected. If the target agent has a live worker, the
message is appended to the durable `pending_messages` inbox *without* bumping the agent
revision (the running worker's next commit consumes it). Otherwise the inbox plus the
new message are folded into `messages` in one CAS (revision+1, status Ready) and a fresh
worker is started. A message is never persisted in both collections nor absent from
both. When a worker exits leaving a non-empty inbox, the coordinator immediately
restarts it with the inbox injected.

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
- `force_stop_agent_group(group_id)` — local registry force-stop.

### 8.5 Node-local registries

`agent_group_registry` and `agent_profile` are public named ETS tables created lazily by
a detached holder process. The group registry stores id → (pid, stop closure, send
closure); reads sweep entries whose pids died. Registration of an id overwrites;
unregistration only removes the exact (id, pid) pair.

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
  base + 2 + call_index. Text emits no `ContentStart`/`ContentStop` (relies on the
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
- **Notable defaults.** Anthropic `max_tokens` defaults to **1024** when the profile
  sets no `max_output_tokens` (truncation risk for agent turns); Anthropic requests set
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
