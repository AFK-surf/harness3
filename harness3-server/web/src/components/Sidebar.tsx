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
  onManageCloudStorage: () => void;
  onSelectSession: (id: string) => void;
}

export function Sidebar({
  sessions,
  selectedSessionId,
  connection,
  workspaceRoot,
  onNewSession,
  onManageMcp,
  onManageCloudStorage,
  onSelectSession,
}: SidebarProps) {
  const connectionLabel = connection === "online"
    ? "Server online"
    : connection === "offline"
      ? "Server unavailable"
      : "Connecting…";

  return (
    <aside className="flex min-h-0 flex-col border-r border-line-soft bg-[rgba(14,17,19,.94)] px-4 pt-6 pb-4 max-[780px]:sticky max-[780px]:top-0 max-[780px]:z-5 max-[780px]:h-[66px] max-[780px]:flex-row max-[780px]:items-center max-[780px]:border-r-0 max-[780px]:border-b max-[780px]:border-line max-[780px]:p-[10px_12px]">
      <div className="flex items-center gap-3 px-2 pb-6 max-[780px]:p-0">
        <div className="brand-mark" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
        <div>
          <strong className="block text-lg tracking-[-.03em]">harness<span className="text-accent">3</span></strong>
          <small className="mt-0.5 block text-[11px] tracking-[.1em] text-faint uppercase max-[780px]:hidden">coding teams</small>
        </div>
      </div>

      <button className="flex w-full items-center gap-[9px] rounded-[10px] border border-[#35432d] bg-linear-to-b from-[#1c2518] to-[#171d15] px-3 py-[11px] text-ink transition hover:-translate-y-px hover:border-[#526a42] max-[780px]:ml-auto max-[780px]:w-auto" type="button" onClick={onNewSession}>
        <span className="text-[19px] leading-none text-accent" aria-hidden="true">＋</span> New task
        <kbd className="ml-auto rounded border border-[#363d3a] bg-[#121513] px-[5px] py-0.5 text-[10px] text-faint max-[780px]:hidden">N</kbd>
      </button>
      <button className="mt-[7px] flex w-full items-center gap-[9px] rounded-[9px] border border-transparent bg-transparent px-3 py-[9px] text-left text-muted hover:border-line hover:bg-panel-2 hover:text-ink max-[780px]:mt-0 max-[780px]:ml-[5px] max-[780px]:w-auto" type="button" onClick={onManageMcp}>
        <span className="text-[17px] text-warn" aria-hidden="true">⌁</span>
        <span className="max-[780px]:hidden">MCP servers</span>
      </button>
      <button className="mt-[2px] flex w-full items-center gap-[9px] rounded-[9px] border border-transparent bg-transparent px-3 py-[9px] text-left text-muted hover:border-line hover:bg-panel-2 hover:text-ink max-[780px]:mt-0 max-[780px]:ml-[5px] max-[780px]:w-auto" type="button" onClick={onManageCloudStorage}>
        <span className="text-[15px] text-info" aria-hidden="true">☁</span>
        <span className="max-[780px]:hidden">Cloud storage</span>
      </button>

      <div className={`${sectionLabel} px-[9px] pt-6 pb-[9px] max-[780px]:hidden`}>Recent sessions</div>
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
              className={`w-full rounded-[9px] border p-[11px_10px] text-left text-muted ${selectedSessionId === session.id ? "border-[#2b3427] bg-[#182016] text-ink" : "border-transparent bg-transparent hover:bg-[#14181a] hover:text-ink"}`}
              key={session.id}
              type="button"
              onClick={() => onSelectSession(session.id)}
            >
              <strong className="block truncate text-[13px] font-semibold">{session.title}</strong>
              <small className="mt-1.5 flex items-center gap-1.5 text-[10px] text-faint">
                <span className={`size-[5px] rounded-full ${session.execution.status === "running" ? "bg-accent shadow-[0_0_8px_rgba(199,242,132,.55)]" : session.execution.status === "completed" ? "bg-info" : "bg-faint"}`} />
                {session.execution.status} · {rounds} round{rounds === 1 ? "" : "s"}
              </small>
            </button>
          );
        })}
      </nav>

      <div className="mt-auto flex items-start gap-[9px] border-t border-line-soft px-[9px] pt-[14px] pb-0.5 text-[11px] text-muted max-[780px]:hidden">
        <span className={`mt-[3px] size-[7px] shrink-0 rounded-full ${connection === "online" ? "bg-accent shadow-[0_0_8px_rgba(199,242,132,.4)]" : connection === "offline" ? "bg-danger" : "bg-warn"}`} />
        <div>
          <span>{connectionLabel}</span>
          <small className="mt-1 block max-w-[205px] truncate text-faint" title={workspaceRoot}>{workspaceRoot}</small>
        </div>
      </div>
    </aside>
  );
}
