import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type KeyboardEvent,
} from "react";
import type { Agent, Message, MessageContent, Model, Session } from "../types";
import { Markdown } from "./Markdown";
import {
  dangerGhostButton,
  ghostButton,
  primaryButton,
  sectionLabel,
} from "../ui";

interface SessionWorkspaceProps {
  session: Session;
  models: Model[];
  selectedAgentId: string | null;
  sending: boolean;
  compactionRequesting: boolean;
  scrollRequest: number;
  onSelectAgent: (id: string) => void;
  onSendMessage: (agentId: string, message: string) => Promise<boolean>;
  onEdit: () => void;
  onStop: () => void;
  onCompact: () => void;
}

export function SessionWorkspace({
  session,
  models,
  selectedAgentId,
  sending,
  compactionRequesting,
  scrollRequest,
  onSelectAgent,
  onSendMessage,
  onEdit,
  onStop,
  onCompact,
}: SessionWorkspaceProps) {
  const [message, setMessage] = useState("");
  const threadRef = useRef<HTMLDivElement>(null);
  const followsLatest = useRef(true);
  const selectedAgent = session.agents.find(
    (agent) => agent.id === selectedAgentId,
  ) ?? session.agents[0];

  useEffect(() => setMessage(""), [session.id]);

  useLayoutEffect(() => {
    followsLatest.current = true;
    scrollToLatest(threadRef.current);
  }, [session.id, selectedAgent?.id]);

  useLayoutEffect(() => {
    if (followsLatest.current) scrollToLatest(threadRef.current);
  }, [selectedAgent?.messages.length]);

  useLayoutEffect(() => {
    followsLatest.current = true;
    scrollToLatest(threadRef.current);
  }, [scrollRequest]);

  const usage = useMemo(() => session.agents.reduce(
    (total, agent) => ({
      input: total.input + agent.stats.input_tokens,
      output: total.output + agent.stats.output_tokens,
      cache: total.cache + agent.stats.cache_read_tokens,
    }),
    { input: 0, output: 0, cache: 0 },
  ), [session.agents]);

  if (!selectedAgent) return null;

  async function submitMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const value = message.trim();
    if (!value || !selectedAgent) return;
    const sent = await onSendMessage(selectedAgent.id, value);
    if (sent) {
      setMessage("");
      followsLatest.current = true;
    }
  }

  function handleComposerKeyDown(event: KeyboardEvent<HTMLTextAreaElement>) {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      event.currentTarget.form?.requestSubmit();
    }
  }

  return (
    <section className="flex h-full min-h-0 flex-col">
      <header className="flex h-16 shrink-0 items-center justify-between gap-3 border-b border-line-soft px-5 max-[780px]:h-[60px] max-[780px]:px-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <h1 className="min-w-[4rem] truncate text-base font-semibold tracking-[-.02em]" title={session.title}>
            {session.title}
          </h1>
          <span className={`shrink-0 rounded-full border px-2 py-1 text-[9px] tracking-[.08em] uppercase ${session.execution.status === "completed" ? "border-[#304354] bg-[#131a20] text-info" : session.execution.status === "idle" ? "border-[#4c3a26] bg-[#1e1811] text-warn" : "border-[#39462f] bg-[#151c13] text-accent"}`}>
            {session.execution.status}
          </span>
          <span className="shrink-0 text-[10px] text-faint max-[1000px]:hidden" title={`Session ${session.id} · ${session.workspace}`}>
            {session.id.replace("session-", "").slice(0, 8)} · {modelSummary(models, session.agents)}
          </span>
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
          <span className="flex items-center gap-1.5 text-[9px] tracking-[.08em] text-faint uppercase max-[900px]:hidden" title="Durable group state refreshes automatically">
            <span className="size-1.5 animate-pulse rounded-full bg-accent" /> live
          </span>
          <CompactButton agent={selectedAgent} requesting={compactionRequesting} onCompact={onCompact} />
          <button className={`${ghostButton} px-2.5 py-1.5 text-[10px]`} type="button" onClick={onEdit} aria-label="Edit team" title="Edit team">
            <span className="max-[520px]:hidden">Edit</span><span className="hidden text-sm max-[520px]:inline" aria-hidden="true">✎</span>
          </button>
          <button className={`${dangerGhostButton} px-2.5 py-1.5 text-[10px]`} type="button" onClick={onStop} aria-label="Stop team" title="Stop team">
            <span className="max-[520px]:hidden">Stop</span><span className="hidden max-[520px]:inline" aria-hidden="true">■</span>
          </button>
        </div>
      </header>

      <div className="flex h-10 shrink-0 border-b border-line-soft bg-[rgba(14,17,19,.55)]">
        <nav className="flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto px-3" aria-label="Team agents">
          <span className={`${sectionLabel} mr-1 shrink-0 max-[520px]:sr-only`}>Team</span>
          {session.agents.map((agent) => {
            const tokens = agent.stats.input_tokens + agent.stats.output_tokens;
            return (
              <button
                className={`flex h-7 shrink-0 items-center gap-1.5 rounded-md border px-2 text-[10px] transition ${agent.id === selectedAgent.id ? "border-[#45563b] bg-[#1b2418] text-ink" : "border-transparent text-muted hover:border-line hover:bg-panel-2 hover:text-ink"}`}
                key={agent.id}
                type="button"
                aria-current={agent.id === selectedAgent.id ? "true" : undefined}
                title={`${agent.role} · ${agent.status} · round ${agent.round} · ${formatNumber(tokens)} tokens`}
                onClick={() => onSelectAgent(agent.id)}
              >
                <span className={`size-1.5 rounded-full ${agent.status === "failed" ? "bg-danger" : agent.status === "completed" ? "bg-info" : agent.status === "ready" ? "bg-accent" : "bg-faint"}`} aria-hidden="true" />
                <span className="max-w-28 truncate capitalize">{agent.id}</span>
                <span className="text-[8px] text-faint">R{agent.round}</span>
                {agent.pending_messages > 0 ? <span className="rounded bg-[#322617] px-1 text-[8px] text-warn">{agent.pending_messages}</span> : null}
              </button>
            );
          })}
        </nav>
        <dl
          className="flex shrink-0 items-center gap-2.5 border-l border-line-soft px-3 text-[9px] tabular-nums max-[520px]:gap-1.5 max-[520px]:px-2"
          title="Session token usage"
          aria-label="Session token usage"
        >
          <div className="flex items-center gap-1"><dt className="text-faint"><span className="max-[520px]:hidden">Input</span><abbr className="hidden no-underline max-[520px]:inline" title="Input">I</abbr></dt><dd className="m-0 text-muted">{formatNumber(usage.input)}</dd></div>
          <div className="flex items-center gap-1"><dt className="text-faint"><span className="max-[520px]:hidden">Output</span><abbr className="hidden no-underline max-[520px]:inline" title="Output">O</abbr></dt><dd className="m-0 text-muted">{formatNumber(usage.output)}</dd></div>
          <div className="flex items-center gap-1"><dt className="text-faint"><span className="max-[520px]:hidden">Cached</span><abbr className="hidden no-underline max-[520px]:inline" title="Cached">C</abbr></dt><dd className="m-0 text-muted">{formatNumber(usage.cache)}</dd></div>
        </dl>
      </div>

      <section className="flex min-h-0 min-w-0 flex-1 flex-col">
        <div
          className="min-h-0 flex-1 overflow-y-auto px-[26px] pt-5 pb-6 max-[780px]:px-4"
          ref={threadRef}
          aria-live="polite"
          onScroll={(event) => {
            const element = event.currentTarget;
            followsLatest.current =
              element.scrollHeight - element.scrollTop - element.clientHeight < 100;
          }}
        >
          <AgentThread agent={selectedAgent} />
        </div>

        <form className="mx-[26px] mb-3.5 rounded-xl border border-[#30383d] bg-[#121619] px-3 pt-2 pb-2 shadow-[0_16px_50px_rgba(0,0,0,.2)] focus-within:border-[#536644] max-[780px]:mx-4" onSubmit={(event) => void submitMessage(event)}>
          <textarea className="block min-h-11 w-full resize-y border-0 bg-transparent px-1 py-1.5 leading-normal text-ink outline-0 placeholder:text-[#535c58]"
            rows={2}
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            onKeyDown={handleComposerKeyDown}
            placeholder="Message the selected agent…"
            required
          />
          <div className="flex items-center gap-2 border-t border-line-soft pt-1.5 text-[9px] text-faint">
            <span className="min-w-0 truncate">To <strong className="font-semibold text-accent">{selectedAgent.id}</strong></span>
            <span className="ml-auto max-[520px]:hidden">⌘ Enter to send</span>
            <button className={`${primaryButton} shrink-0 px-3 py-1.5 text-[10px]`} type="submit" disabled={sending}>
              {sending ? "Sending…" : "Send"} <span aria-hidden="true">↗</span>
            </button>
          </div>
        </form>
      </section>
    </section>
  );
}

function CompactButton({
  agent,
  requesting,
  onCompact,
}: {
  agent: Agent;
  requesting: boolean;
  onCompact: () => void;
}) {
  const { compaction } = agent;
  const hasMessages = agent.messages.length > 0;
  const label = requesting
    ? "Requesting…"
    : compaction.pending
      ? "Compacting…"
      : compaction.error
        ? "Retry compact"
        : "Compact";
  const title = !hasMessages
    ? "This agent has no session context to compact"
    : compaction.pending
      ? `Compaction generation ${compaction.requested} is pending`
      : compaction.error
        ? `Last compaction failed: ${compaction.error}`
        : compaction.context_tokens
          ? `Compact the selected agent's model context (last request: ${formatNumber(compaction.context_tokens)} tokens)`
          : "Compact the selected agent's model context";

  return (
    <button
      className={`${ghostButton} px-[9px] py-1.5 text-[10px] disabled:cursor-default disabled:opacity-50 ${compaction.pending ? "border-[#4c3a26] bg-[#1e1811] text-warn" : compaction.error ? "border-[#5a3432] text-danger" : ""}`}
      type="button"
      title={title}
      disabled={requesting || compaction.pending || !hasMessages}
      onClick={onCompact}
      aria-label={label}
    >
      <span className="max-[520px]:hidden">{label}</span>
      <span className="hidden text-sm max-[520px]:inline" aria-hidden="true">↙</span>
    </button>
  );
}

function AgentThread({ agent }: { agent: Agent }) {
  const messages = agent.messages.filter(
    (message) => message.role !== "system" && message.role !== "developer",
  );
  if (messages.length === 0) {
    return (
      <div className="grid h-full place-items-center text-xs text-faint">
        Send the first message below to start {agent.id}.
      </div>
    );
  }
  return (
    <>
      {messages.map((message, index) => (
        <MessageView
          key={`${message.role}-${index}`}
          message={message}
          agentId={agent.id}
        />
      ))}
      {agent.failure ? (
        <div className="mx-auto mb-[22px] max-w-[860px]">
          <div className="pl-[33px] text-[13px] leading-[1.62] text-[#d8ddd8]">
            <div className="rounded-[9px] border border-[#583531] bg-[#201313] p-[10px] text-danger">{agent.failure}</div>
          </div>
        </div>
      ) : null}
    </>
  );
}

function MessageView({ message, agentId }: { message: Message; agentId: string }) {
  const [showRaw, setShowRaw] = useState(false);
  const hasText = message.content.some((content) => content.type === "text");
  const label = message.role === "assistant"
    ? agentId
    : message.role === "tool"
      ? "Tool result"
      : "Instruction";
  const avatar = message.role === "assistant"
    ? agentId.slice(0, 1).toUpperCase()
    : message.role === "tool"
      ? "T"
      : "U";

  return (
    <article className="group mx-auto mb-[22px] max-w-[860px]">
      <div className="mb-[7px] flex items-center gap-[9px] text-[10px] tracking-[.075em] text-faint uppercase">
        <span className={`grid size-6 place-items-center rounded-[7px] border text-[10px] font-extrabold ${message.role === "tool" ? "border-[#4c3c2a] bg-[#201910] text-warn" : message.role === "assistant" ? "border-[#34402e] bg-[#171e14] text-accent" : "border-[#3c4146] bg-[#1c2023] text-[#c8ceca]"}`}>{avatar}</span><span>{label}</span>
        {hasText ? (
          <button
            className={`ml-auto rounded-md border px-[7px] py-[3px] text-[9px] font-semibold tracking-[.075em] transition ${showRaw ? "border-[#4a5c3d] bg-[#171e14] text-accent" : "border-transparent text-faint opacity-0 group-hover:opacity-100 focus-visible:opacity-100 hover:border-line hover:bg-panel-2 hover:text-muted"}`}
            type="button"
            onClick={() => setShowRaw((raw) => !raw)}
            aria-pressed={showRaw}
            title={showRaw ? "Render markdown" : "Show raw text"}
          >
            {showRaw ? "Raw" : "MD"}
          </button>
        ) : null}
      </div>
      <div className="pl-[33px] text-[13px] leading-[1.62] text-[#d8ddd8]">
        {message.content.map((content, index) => (
          <ContentView key={`${content.type}-${index}`} content={content} raw={showRaw} />
        ))}
      </div>
    </article>
  );
}

function ContentView({ content, raw }: { content: MessageContent; raw: boolean }) {
  switch (content.type) {
    case "text":
      return (
        <div className="mt-[10px] first:mt-0">
          {raw
            ? <pre className="m-0 whitespace-pre-wrap break-words font-[inherit]">{content.text}</pre>
            : <Markdown text={content.text} />}
        </div>
      );
    case "reasoning":
      return (
        <details className="mt-[10px] border-l-2 border-[#3c4934] bg-[#121713] px-[11px] py-[9px] text-muted first:mt-0">
          <summary className="cursor-pointer text-[11px] text-[#a5afa8]">
            Reasoning summary{content.encrypted ? " · encrypted state retained" : ""}
          </summary>
          <pre className="mt-[7px] whitespace-pre-wrap break-words font-[inherit] text-[11px]">{content.summary.join("\n")}</pre>
        </details>
      );
    case "tool_call":
      return (
        <details className="mt-[10px] overflow-hidden rounded-[9px] border border-line bg-[#101315] first:mt-0">
          <summary className="cursor-pointer px-[10px] py-2 text-[11px] text-muted">Called {content.name}</summary>
          <pre className="max-h-80 overflow-auto border-t border-line-soft p-[10px] whitespace-pre-wrap break-words font-mono text-[10px] leading-[1.55] text-[#b8c0bb]">{JSON.stringify(content.arguments, null, 2)}</pre>
        </details>
      );
    case "tool_result":
      return (
        <details
          className={`mt-[10px] overflow-hidden rounded-[9px] border bg-[#101315] first:mt-0 ${content.is_error ? "border-[#583531]" : "border-line"}`}
          open
        >
          <summary className="cursor-pointer px-[10px] py-2 text-[11px] text-muted">{content.is_error ? "Tool error" : "Tool output"}</summary>
          <pre className="max-h-80 overflow-auto border-t border-line-soft p-[10px] whitespace-pre-wrap break-words font-mono text-[10px] leading-[1.55] text-[#b8c0bb]">{content.content.map(contentText).join("\n")}</pre>
        </details>
      );
    case "image":
      return <div className="mt-[10px] first:mt-0">[image · {content.detail}]</div>;
    case "document":
      return <div className="mt-[10px] first:mt-0">[document]</div>;
  }
}

function contentText(content: MessageContent): string {
  if (content.type === "text") return content.text;
  return JSON.stringify(content);
}

function modelSummary(models: Model[], agents: Agent[]): string {
  const ids = [...new Set(agents.map((agent) => agent.model_id))];
  if (ids.length === 1) {
    const id = ids[0];
    return id ? models.find((model) => model.id === id)?.name ?? id : "No model";
  }
  return `${ids.length} models`;
}

function formatNumber(value: number): string {
  return new Intl.NumberFormat().format(value || 0);
}

function scrollToLatest(element: HTMLDivElement | null) {
  if (element) element.scrollTop = element.scrollHeight;
}
