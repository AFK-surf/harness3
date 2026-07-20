# harness3
harness/3 - a tiny distributed multi-agent harness

The runnable coding-agent service and multi-agent web UI live in
[`harness3-server`](./harness3-server/README.md).

The reusable MCP plugin lives under `src/harness3/plugin/mcp/`. It provides a
validated configuration format, CAS-backed catalog, MCP 2025-11-25 protocol
client, stdio and Streamable HTTP transports, discovery runtime, and an
ordinary harness3 plugin exposing the static `mcp.list` and `mcp.call` broker
tools. Discovery runs when an agent activates, excludes unavailable servers,
and keeps application startup independent of external MCP availability.
Applications retain ownership of configuration policy and storage;
`harness3-server` is one such integration.
