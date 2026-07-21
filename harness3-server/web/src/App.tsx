import { useCallback, useEffect, useRef, useState } from "react";
import { api, errorMessage } from "./api";
import { EditGroupDialog } from "./components/EditGroupDialog";
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
  UpdateSessionInput,
  UpdateMcpServerInput,
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
  const [editGroupOpen, setEditGroupOpen] = useState(false);
  const [sending, setSending] = useState(false);
  const [compactionRequesting, setCompactionRequesting] = useState(false);
  const [scrollRequest, setScrollRequest] = useState(0);
  const [toast, setToast] = useState<ToastState | null>(null);
  const toastSequence = useRef(0);
  const refreshTick = useRef(0);
  const selectionEpoch = useRef(0);
  const currentRef = useRef<Session | null>(null);

  // Single writer for the displayed session: keeps the ref used by the
  // staleness guards in sync and reconciles the agent selection.
  const showSession = useCallback((session: Session) => {
    currentRef.current = session;
    setCurrent(session);
    setSelectedAgentId((selected) => session.agents.some(
      (agent) => agent.id === selected,
    ) ? selected : session.agents[0]?.id ?? null);
  }, []);

  // Applies a fetched session only while it is still the one on screen and
  // not older than what is already shown: a slow response or an in-flight
  // poll must not revert a newer write (group revisions increase with every
  // durable change) or reset the agent selection from a stale roster.
  const refreshSession = useCallback((session: Session) => {
    const existing = currentRef.current;
    if (!existing || existing.id !== session.id) return;
    if (session.revision < existing.revision) return;
    showSession(session);
  }, [showSession]);

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
        if (first) showSession(first);
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
          refreshSession(session);
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
    // A slower response for an earlier click must not snap the view back:
    // only the most recent selection may apply its result.
    selectionEpoch.current += 1;
    const epoch = selectionEpoch.current;
    try {
      const session = await api<Session>(`/api/sessions/${encodeURIComponent(id)}`);
      if (selectionEpoch.current !== epoch) return;
      showSession(session);
      setScrollRequest((request) => request + 1);
    } catch (error) {
      if (selectionEpoch.current !== epoch) return;
      showToast(errorMessage(error), true);
    }
  }

  async function createSession(input: CreateSessionInput) {
    const session = await api<Session>("/api/sessions", {
      method: "POST",
      body: JSON.stringify(input),
    });
    setNewSessionOpen(false);
    selectionEpoch.current += 1;
    showSession(session);
    setScrollRequest((request) => request + 1);
    await loadSessions();
    showToast("Session ready. Send the first message to start an agent.");
  }

  async function updateSession(input: UpdateSessionInput) {
    if (!current) return;
    const session = await api<Session>(
      `/api/sessions/${encodeURIComponent(current.id)}`,
      {
        method: "PUT",
        body: JSON.stringify(input),
      },
    );
    refreshSession(session);
    setEditGroupOpen(false);
    await loadSessions();
    showToast("Agent group updated. Interrupted agents resume; new agents await their first message.");
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
      refreshSession(refreshed);
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
      refreshSession(refreshed);
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
      refreshSession(refreshed);
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

  async function updateMcpServer(
    configurationId: string,
    serverId: string,
    input: UpdateMcpServerInput,
  ) {
    await api<McpConfiguration>(
      `/api/mcp/configurations/${encodeURIComponent(configurationId)}/servers/${encodeURIComponent(serverId)}`,
      { method: "PUT", body: JSON.stringify(input) },
    );
    await loadMcpConfigurations();
    showToast("MCP server updated. Active specialists pick it up on next activation.");
  }

  return (
    <>
      <div className="grid h-screen grid-cols-[clamp(196px,17vw,232px)_minmax(0,1fr)] max-[780px]:block max-[780px]:h-auto max-[780px]:min-h-screen">
        <Sidebar
          sessions={sessions}
          selectedSessionId={current?.id ?? null}
          connection={connection}
          workspaceRoot={workspaceRoot}
          onNewSession={openNewSession}
          onManageMcp={() => setMcpOpen(true)}
          onSelectSession={(id) => void selectSession(id)}
        />
        <main className="min-h-0 min-w-0 max-[780px]:h-[calc(100dvh-66px)]">
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
              onEdit={() => setEditGroupOpen(true)}
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
        onUpdate={updateMcpServer}
        onRemove={removeMcpServer}
        onError={(message) => showToast(message, true)}
      />
      {current ? (
        <EditGroupDialog
          open={editGroupOpen}
          session={current}
          models={models}
          onClose={() => setEditGroupOpen(false)}
          onSave={updateSession}
          onError={(message) => showToast(message, true)}
        />
      ) : null}

      <div
        className={`pointer-events-none fixed right-[22px] bottom-[22px] z-20 max-w-[390px] rounded-[9px] border px-[14px] py-[11px] text-[11px] text-ink shadow-[0_14px_45px_rgba(0,0,0,.4)] transition duration-200 ${toast ? "translate-y-0 opacity-100" : "translate-y-5 opacity-0"} ${toast?.error ? "border-[#623a36] bg-[#241615]" : "border-[#48573d] bg-[#192015]"}`}
        role="status"
      >
        {toast?.message}
      </div>
    </>
  );
}
