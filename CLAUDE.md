# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout and commands

Two Gleam-on-BEAM projects plus a TypeScript web UI:

- `/` — the `harness3` library (distributed multi-agent LLM harness).
- `/harness3-server` — the application (path-depends on the library): sessions, JSON API, profile wiring. Its README covers running it.
- `/harness3-server/web` — React/Vite UI, built into `../priv/static`.

```sh
gleam test                                # library suite (repo root)
cd harness3-server && gleam test          # server suite
gleam format src test                     # both projects; CI runs --check
cd harness3-server/web && npm run check   # tsc --noEmit
cd harness3-server/web && npm run build   # typecheck + vite build
```

gleeunit has no single-test filter; each suite runs whole (both finish in seconds — the server suite boots real services against tmp-dir local storage). CI (`.github/workflows/test.yml`) pins Gleam 1.17.0 and enforces `gleam format --check` on both projects; keep formatting churn in unrelated files out of feature diffs.

Known flaky test: `stop_rpc_finalizes_a_crashed_owner_group_test` races a 1-second lease and occasionally fails under load.

## SPEC.md is load-bearing

`SPEC.md` documents observed behavior and invariants of the library (not aspirations). Any behavior change must update it in the same commit, and it is the fastest way to understand a subsystem before reading code — especially storage semantics (§2), the round loop and tool journal (§6.2), and group lifecycle/fencing (§7).

## Architecture

**Everything durable lives in an object store; there is no database and no Erlang distribution.** Storage (`storage/` — local FS, S3, GCS) exposes conditional puts: `IfAbsent` and `IfUnchanged(version_token)`. Every correctness property — leases, fencing, optimistic concurrency, recovery — reduces to these behaving atomically. Nodes coordinate only through storage objects plus token-authenticated Erlang-term-over-HTTP RPC (`cluster/core`). The storage layer retries transient faults internally with backoff; that is the one sanctioned place infrastructure errors are absorbed. A recurring pattern: an ambiguous CAS (applied, response lost, retry sees "conflict") is resolved by exact-body read-back — every CAS caller that must not mistake its own write for a conflict does this.

**Error philosophy: let it crash.** `Result` is for domain answers (validation, revocation, precondition failures). Infrastructure faults — unreachable storage outside the retry budget, dead node-level actors — panic the process that hit them; supervision/recovery structures absorb the crash. Do not add `exception.rescue` or map faults into error strings.

**Agent (`agent.gleam`)**: worker process runs the round loop (LLM call → tools → commit) against an injected `Checkpointer`; every commit returns the authoritative state. Tool execution is write-ahead journaled: the assistant message plus a Pending-per-call journal is durably committed before any tool runs, each call is committed Running before invocation and Completed after. After a crash, Pending is provably unstarted, Running becomes an honest "outcome unknown" error result — tools are never blindly replayed. The journaled worker loop is the only execution path; there is no public single-round entry point.

**Agent group (`agent_group.gleam`)**: a group of agents is one JSON object; a coordinator actor claims it via CAS (owner token + epoch + lease), and the epoch in the running-index key is the fencing token. Wakes, roster edits, and attribute updates ride the claim CAS. Workers that exit with an unresolved journal are restarted under a budget (3 consecutive exits without a successful commit), after which the coordinator abandons and recovery re-dispatches after lease expiry.

**Profiles are static node capabilities.** `agent_profile` is a node-local ETS registry, written exactly once at boot by the application — `agent_group.create`/`resume` do NOT install profiles, and nothing uninstalls them. The recovery path (`resume_registered`, used by the leader-elected scanner in `cluster/recovery`) depends on this: harness3-server registers its three kind profiles (coding-workspace, isolated-researcher, mcp-researcher) before `core.start` publishes membership.

**Per-session configuration reaches plugins through durable state, never constructor closures.** Plugins see a `plugin.Host` (group id, agent id, agent/group attributes, peers) via `activate_hosted`; system-prompt sections can be dynamic (built per prompt from state + host); the cloud-storage plugin resolves its scope per invocation via a resolver; the MCP broker plugin is stateless and takes a configuration loader called on every connection discovery. This is what keeps profiles session-independent — preserve it when adding plugins.

**MCP**: the durable CAS catalog (`harness3-server/mcp-catalog`) is the single source of truth; the server computes the aggregate configuration from it on demand (loader, management listing, team composition — no synchronization, no snapshots). The catalog object always exists after first boot, so a read failure including NotFound is a fault (panic), never "no MCP configured". In `connections`, only an authoritative `Revoked` load answer tears down live transports. Agent-owned connections live in the agent's plugin host and die with it; the runtime actor owns no connections and must never be touched during activation (activation runs inside the group coordinator, which also services lease renewal).

**harness3-server sessions are views**: a session is an agent group; all metadata (title, prompt, workspace path, cloud-storage association, per-agent role/kind) lives in group/agent extended attributes. The group object is the only durable record.

## Conventions

- Commit subjects are imperative and body paragraphs explain the why (see `git log`); behavior changes update SPEC.md in the same commit.
- Server tests configure services via `HARNESS3_*` env vars against throwaway roots in `/tmp` and unset them on exit; follow the existing `start_service` patterns in `harness3-server/test`.
- Comments state constraints the code can't express (frequently: ordering requirements and crash-window reasoning). Match that register.
