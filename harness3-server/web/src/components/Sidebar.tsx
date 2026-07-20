import type { Session } from "../types";

export type ConnectionState = "connecting" | "online" | "offline";

interface SidebarProps {
  sessions: Session[];
  selectedSessionId: string | null;
  connection: ConnectionState;
  workspaceRoot: string;
  onNewSession: () => void;
  onManageMcp: () => void;
  onSelectSession: (id: string) => void;
}

export function Sidebar({
  sessions,
  selectedSessionId,
  connection,
  workspaceRoot,
  onNewSession,
  onManageMcp,
  onSelectSession,
}: SidebarProps) {
  const connectionLabel = connection === "online"
    ? "Server online"
    : connection === "offline"
      ? "Server unavailable"
      : "Connecting…";

  return (
    <aside className="sidebar">
      <div className="brand">
        <div className="brand-mark" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <div>
          <strong>harness<span>3</span></strong>
          <small>coding teams</small>
        </div>
      </div>

      <button className="new-session" type="button" onClick={onNewSession}>
        <span aria-hidden="true">＋</span> New task
        <kbd>N</kbd>
      </button>
      <button className="manage-mcp" type="button" onClick={onManageMcp}>
        <span aria-hidden="true">⌁</span>
        <span className="mcp-button-label">MCP servers</span>
      </button>

      <div className="sidebar-label">Recent sessions</div>
      <nav className="session-list" aria-label="Coding sessions">
        {sessions.length === 0 ? (
          <div className="thread-empty">No sessions yet</div>
        ) : sessions.map((session) => {
          const rounds = session.agents.reduce(
            (total, agent) => total + agent.round,
            0,
          );
          return (
            <button
              className={`session-item${selectedSessionId === session.id ? " active" : ""}`}
              key={session.id}
              type="button"
              onClick={() => onSelectSession(session.id)}
            >
              <strong>{session.title}</strong>
              <small>
                <span className={`mini-dot ${session.execution.status}`} />
                {session.execution.status} · {rounds} round{rounds === 1 ? "" : "s"}
              </small>
            </button>
          );
        })}
      </nav>

      <div className="sidebar-footer">
        <span className={`connection-dot ${connection}`} />
        <div>
          <span>{connectionLabel}</span>
          <small title={workspaceRoot}>{workspaceRoot}</small>
        </div>
      </div>
    </aside>
  );
}
