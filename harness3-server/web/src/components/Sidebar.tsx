import type { Session } from "../types";
import { sectionLabel } from "../ui";

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
    <aside className="flex min-h-0 flex-col border-r border-line-soft bg-[rgba(14,17,19,.94)] px-3 pt-4 pb-3 max-[780px]:sticky max-[780px]:top-0 max-[780px]:z-5 max-[780px]:h-[66px] max-[780px]:flex-row max-[780px]:items-center max-[780px]:border-r-0 max-[780px]:border-b max-[780px]:border-line max-[780px]:p-[10px_12px]">
      <div className="flex items-center gap-2 px-1 pb-2.5 max-[780px]:p-0">
        <div className="brand-mark shrink-0" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <strong className="truncate text-[17px] tracking-[-.03em] max-[780px]:sr-only">harness<span className="text-accent">3</span></strong>
        <span className={`ml-auto size-2 rounded-full max-[780px]:hidden ${connection === "online" ? "bg-accent" : connection === "offline" ? "bg-danger" : "bg-warn"}`} title={connectionLabel} aria-label={connectionLabel} />
      </div>
      <label className="sr-only" htmlFor="mobile-session-switcher">Current session</label>
      <select
        className="mr-2 hidden min-w-0 flex-1 rounded-lg border border-line bg-[#111416] px-2 py-1.5 text-xs text-ink max-[780px]:block"
        id="mobile-session-switcher"
        value={selectedSessionId ?? ""}
        disabled={sessions.length === 0}
        onChange={(event) => onSelectSession(event.target.value)}
      >
        {sessions.length === 0 ? <option value="">No sessions</option> : sessions.map((session) => (
          <option key={session.id} value={session.id}>{session.title}</option>
        ))}
      </select>
      <div className="grid grid-cols-[1fr_auto] gap-1.5 border-b border-line-soft pb-3 max-[780px]:flex max-[780px]:border-0 max-[780px]:p-0">
        <button
          className="flex h-8 items-center justify-center gap-1.5 rounded-lg border border-[#35432d] bg-[#1a2117] px-2.5 text-[11px] font-semibold text-ink transition hover:border-[#526a42] hover:bg-[#20291b]"
          type="button"
          onClick={onNewSession}
          aria-label="New task"
          title="New task (N)"
        >
          <span className="text-base leading-none text-accent" aria-hidden="true">＋</span>
          <span className="max-[780px]:sr-only">New task</span>
        </button>
        <button
          className="flex h-8 items-center justify-center gap-1.5 rounded-lg border border-line bg-transparent px-2.5 max-[780px]:px-2 text-[11px] text-muted hover:border-[#3a4248] hover:bg-panel-2 hover:text-ink"
          type="button"
          onClick={onManageMcp}
          aria-label="Manage MCP servers"
          title="Manage MCP servers"
        >
          <span className="text-base leading-none text-warn" aria-hidden="true">⌁</span>
          <span className="max-[1020px]:hidden">MCP</span>
        </button>
      </div>

      <div className={`${sectionLabel} px-2 pt-4 pb-2 max-[780px]:hidden`}>Recent sessions</div>
      <nav className="flex min-h-0 flex-col gap-[3px] overflow-y-auto max-[780px]:hidden" aria-label="Coding sessions">
        {sessions.length === 0 ? (
          <div className="grid h-full place-items-center text-xs text-faint">No sessions yet</div>
        ) : sessions.map((session) => {
          const rounds = session.agents.reduce(
            (total, agent) => total + agent.round,
            0,
          );
          return (
            <button
              className={`w-full rounded-[9px] border p-[8px_9px] text-left text-muted ${selectedSessionId === session.id ? "border-[#2b3427] bg-[#182016] text-ink" : "border-transparent bg-transparent hover:bg-[#14181a] hover:text-ink"}`}
              key={session.id}
              type="button"
              onClick={() => onSelectSession(session.id)}
            >
              <strong className="block truncate text-[13px] font-semibold">{session.title}</strong>
              <small className="mt-1 flex items-center gap-1.5 text-[10px] text-faint">
                <span className={`size-[5px] rounded-full ${session.execution.status === "running" ? "bg-accent shadow-[0_0_8px_rgba(199,242,132,.55)]" : session.execution.status === "completed" ? "bg-info" : "bg-faint"}`} />
                {session.execution.status} · {rounds} round{rounds === 1 ? "" : "s"}
              </small>
            </button>
          );
        })}
      </nav>

      <div className="mt-auto flex items-start gap-[9px] border-t border-line-soft px-2 pt-2.5 pb-0.5 text-[11px] text-muted max-[780px]:hidden">
        <span className={`mt-[3px] size-[7px] shrink-0 rounded-full ${connection === "online" ? "bg-accent shadow-[0_0_8px_rgba(199,242,132,.4)]" : connection === "offline" ? "bg-danger" : "bg-warn"}`} />
        <div>
          <span>{connectionLabel}</span>
          <small className="mt-1 block max-w-[205px] truncate text-faint" title={workspaceRoot}>{workspaceRoot}</small>
        </div>
      </div>
    </aside>
  );
}
