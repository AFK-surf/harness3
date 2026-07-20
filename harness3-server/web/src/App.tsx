import { useCallback, useEffect, useRef, useState } from "react";
import { api, errorMessage } from "./api";
import { EmptyState } from "./components/EmptyState";
import { McpDialog } from "./components/McpDialog";
import { NewSessionDialog } from "./components/NewSessionDialog";
import { SessionWorkspace } from "./components/SessionWorkspace";
import { Sidebar, type ConnectionState } from "./components/Sidebar";
import type {
  AddMcpServerInput,
  CompactionResponse,
  CreateSessionInput,
  HealthResponse,
  McpConfiguration,
  McpConfigurationsResponse,
  Model,
  ModelsResponse,
  Session,
  SessionsResponse,
} from "./types";

interface ToastState {
  id: number;
  message: string;
  error: boolean;
}

export function App() {
  const [models, setModels] = useState<Model[]>([]);
  const [mcpConfigurations, setMcpConfigurations] = useState<McpConfiguration[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [current, setCurrent] = useState<Session | null>(null);
  const [selectedAgentId, setSelectedAgentId] = useState<string | null>(null);
  const [workspaceRoot, setWorkspaceRoot] = useState("");
  const [connection, setConnection] = useState<ConnectionState>("connecting");
  const [newSessionOpen, setNewSessionOpen] = useState(false);
  const [mcpOpen, setMcpOpen] = useState(false);
  const [sending, setSending] = useState(false);
  const [compactionRequesting, setCompactionRequesting] = useState(false);
  const [scrollRequest, setScrollRequest] = useState(0);
  const [toast, setToast] = useState<ToastState | null>(null);
  const toastSequence = useRef(0);
  const refreshTick = useRef(0);

  const showToast = useCallback((message: string, isError = false) => {
    toastSequence.current += 1;
    setToast({ id: toastSequence.current, message, error: isError });
  }, []);

  useEffect(() => {
    if (!toast) return;
    const timeout = window.setTimeout(() => setToast((currentToast) =>
      currentToast?.id === toast.id ? null : currentToast
    ), 3500);
    return () => window.clearTimeout(timeout);
  }, [toast]);

  const loadSessions = useCallback(async () => {
    const response = await api<SessionsResponse>("/api/sessions");
    setSessions(response.sessions);
    return response.sessions;
  }, []);

  const loadMcpConfigurations = useCallback(async () => {
    const response = await api<McpConfigurationsResponse>(
      "/api/mcp/configurations",
    );
    setMcpConfigurations(response.configurations);
    return response.configurations;
  }, []);

  useEffect(() => {
    let active = true;
    void (async () => {
      const [healthResult, modelResult, mcpResult, sessionResult] =
        await Promise.allSettled([
          api<HealthResponse>("/api/health"),
          api<ModelsResponse>("/api/models"),
          api<McpConfigurationsResponse>("/api/mcp/configurations"),
          api<SessionsResponse>("/api/sessions"),
        ] as const);
      if (!active) return;

      if (healthResult.status === "fulfilled") {
        setWorkspaceRoot(healthResult.value.workspace_root);
        setConnection("online");
      } else {
        setConnection("offline");
        showToast(errorMessage(healthResult.reason), true);
      }
      if (modelResult.status === "fulfilled") {
        setModels(modelResult.value.models);
      } else {
        showToast(errorMessage(modelResult.reason), true);
      }
      if (mcpResult.status === "fulfilled") {
        setMcpConfigurations(mcpResult.value.configurations);
      } else {
        showToast(errorMessage(mcpResult.reason), true);
      }
      if (sessionResult.status === "fulfilled") {
        const loadedSessions = sessionResult.value.sessions;
        setSessions(loadedSessions);
        const first = loadedSessions[0];
        if (first) {
          setCurrent(first);
          setSelectedAgentId(first.agents[0]?.id ?? null);
        }
      } else {
        showToast(errorMessage(sessionResult.reason), true);
      }
    })();
    return () => {
      active = false;
    };
  }, [showToast]);

  const currentSessionId = current?.id;
  useEffect(() => {
    if (!currentSessionId) return;
    let active = true;
    let refreshing = false;
    const interval = window.setInterval(() => {
      if (refreshing) return;
      refreshing = true;
      void api<Session>(`/api/sessions/${encodeURIComponent(currentSessionId)}`)
        .then(async (session) => {
          if (!active) return;
          setCurrent((existing) => existing?.id === currentSessionId ? session : existing);
          setSelectedAgentId((selected) => session.agents.some(
            (agent) => agent.id === selected,
          ) ? selected : session.agents[0]?.id ?? null);
          setConnection("online");
          refreshTick.current += 1;
          if (refreshTick.current % 4 === 0) await loadSessions();
        })
        .catch((error: unknown) => {
          if (!active) return;
          setConnection("offline");
          console.error(error);
        })
        .finally(() => {
          refreshing = false;
        });
    }, 1800);
    return () => {
      active = false;
      window.clearInterval(interval);
    };
  }, [currentSessionId, loadSessions]);

  const openNewSession = useCallback(() => {
    if (models.length === 0) {
      showToast("No supported Pi models were loaded.", true);
      return;
    }
    setNewSessionOpen(true);
  }, [models.length, showToast]);

  useEffect(() => {
    function handleShortcut(event: globalThis.KeyboardEvent) {
      const element = document.activeElement;
      const typing = element instanceof HTMLInputElement
        || element instanceof HTMLTextAreaElement
        || element instanceof HTMLSelectElement;
      if (!typing && event.key.toLowerCase() === "n") openNewSession();
    }
    document.addEventListener("keydown", handleShortcut);
    return () => document.removeEventListener("keydown", handleShortcut);
  }, [openNewSession]);

  async function selectSession(id: string) {
    try {
      const session = await api<Session>(`/api/sessions/${encodeURIComponent(id)}`);
      setCurrent(session);
      setSelectedAgentId((selected) => session.agents.some(
        (agent) => agent.id === selected,
      ) ? selected : session.agents[0]?.id ?? null);
      setScrollRequest((request) => request + 1);
    } catch (error) {
      showToast(errorMessage(error), true);
    }
  }

  async function createSession(input: CreateSessionInput) {
    const session = await api<Session>("/api/sessions", {
      method: "POST",
      body: JSON.stringify(input),
    });
    setNewSessionOpen(false);
    setCurrent(session);
    setSelectedAgentId(session.agents[0]?.id ?? null);
    setScrollRequest((request) => request + 1);
    await loadSessions();
    showToast("Session ready. Send the first message to start an agent.");
  }

  async function sendMessage(agentId: string, message: string): Promise<boolean> {
    if (!current || sending) return false;
    setSending(true);
    try {
      await api<{ ok: boolean }>(
        `/api/sessions/${encodeURIComponent(current.id)}/messages`,
        {
          method: "POST",
          body: JSON.stringify({ agent_id: agentId, message }),
        },
      );
      showToast("Message queued durably.");
      const refreshed = await api<Session>(
        `/api/sessions/${encodeURIComponent(current.id)}`,
      );
      setCurrent(refreshed);
      setScrollRequest((request) => request + 1);
      await loadSessions();
      return true;
    } catch (error) {
      showToast(errorMessage(error), true);
      return false;
    } finally {
      setSending(false);
    }
  }

  async function stopSession() {
    if (!current || !window.confirm(
      "Stop all currently running agents in this session? Durable state will be preserved.",
    )) return;
    try {
      await api<{ ok: boolean }>(
        `/api/sessions/${encodeURIComponent(current.id)}/stop`,
        { method: "POST" },
      );
      showToast("Team stopped; durable state was preserved.");
      const refreshed = await api<Session>(
        `/api/sessions/${encodeURIComponent(current.id)}`,
      );
      setCurrent(refreshed);
    } catch (error) {
      showToast(errorMessage(error), true);
    }
  }

  async function compactSelectedAgent() {
    if (!current || !selectedAgentId || compactionRequesting) return;
    setCompactionRequesting(true);
    try {
      const response = await api<CompactionResponse>(
        `/api/sessions/${encodeURIComponent(current.id)}/agents/${encodeURIComponent(selectedAgentId)}/compact`,
        { method: "POST" },
      );
      showToast(
        `Compaction generation ${response.generation} requested for ${selectedAgentId}.`,
      );
      const refreshed = await api<Session>(
        `/api/sessions/${encodeURIComponent(current.id)}`,
      );
      setCurrent(refreshed);
    } catch (error) {
      showToast(errorMessage(error), true);
    } finally {
      setCompactionRequesting(false);
    }
  }

  async function addMcpServer(input: AddMcpServerInput) {
    await api<McpConfiguration>("/api/mcp/servers", {
      method: "POST",
      body: JSON.stringify(input),
    });
    await loadMcpConfigurations();
    showToast("MCP server added. It will be discovered when a specialist activates.");
  }

  async function removeMcpServer(configurationId: string, serverId: string) {
    await api<McpConfiguration>(
      `/api/mcp/configurations/${encodeURIComponent(configurationId)}/servers/${encodeURIComponent(serverId)}`,
      { method: "DELETE" },
    );
    await loadMcpConfigurations();
    showToast("MCP server removed.");
  }

  return (
    <>
      <div className="shell">
        <Sidebar
          sessions={sessions}
          selectedSessionId={current?.id ?? null}
          connection={connection}
          workspaceRoot={workspaceRoot}
          onNewSession={openNewSession}
          onManageMcp={() => setMcpOpen(true)}
          onSelectSession={(id) => void selectSession(id)}
        />
        <main className="main">
          {current ? (
            <SessionWorkspace
              session={current}
              models={models}
              selectedAgentId={selectedAgentId}
              sending={sending}
              compactionRequesting={compactionRequesting}
              scrollRequest={scrollRequest}
              onSelectAgent={(id) => {
                setSelectedAgentId(id);
                setScrollRequest((request) => request + 1);
              }}
              onSendMessage={sendMessage}
              onStop={() => void stopSession()}
              onCompact={() => void compactSelectedAgent()}
            />
          ) : <EmptyState onNewSession={openNewSession} />}
        </main>
      </div>

      <NewSessionDialog
        open={newSessionOpen}
        models={models}
        configurations={mcpConfigurations}
        workspaceRoot={workspaceRoot}
        onClose={() => setNewSessionOpen(false)}
        onCreate={createSession}
        onError={(message) => showToast(message, true)}
      />
      <McpDialog
        open={mcpOpen}
        configurations={mcpConfigurations}
        onClose={() => setMcpOpen(false)}
        onAdd={addMcpServer}
        onRemove={removeMcpServer}
        onError={(message) => showToast(message, true)}
      />

      <div
        className={`toast${toast ? " visible" : ""}${toast?.error ? " error" : ""}`}
        role="status"
      >
        {toast?.message}
      </div>
    </>
  );
}
