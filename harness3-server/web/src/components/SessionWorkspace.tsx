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
  }, [selectedAgent?.id]);

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
    <section className="flex h-full min-h-0 flex-col max-[780px]:min-h-[calc(100vh-66px)]">
      <header className="flex min-h-[112px] items-start justify-between gap-5 border-b border-line-soft px-[26px] pt-[21px] pb-[18px] max-[780px]:p-[17px]">
        <div className="min-w-0">
          <div className="flex gap-[7px] text-[10px] tracking-[.08em] text-faint uppercase">
            <span>Session</span><b className="font-normal text-[#3e4642]">/</b>
            <span>{session.id.replace("session-", "").slice(0, 8)}</span>
          </div>
          <h1 className="my-[9px] truncate text-xl tracking-[-.025em]">{session.title}</h1>
          <div className="flex flex-wrap items-center gap-[13px] text-[10px] text-faint [&>span:not(:first-child)]:max-w-[310px] [&>span:not(:first-child)]:truncate">
            <span className={`rounded-full border px-[7px] py-1 tracking-[.08em] uppercase ${session.execution.status === "completed" ? "border-[#304354] bg-[#131a20] text-info" : session.execution.status === "idle" ? "border-[#4c3a26] bg-[#1e1811] text-warn" : "border-[#39462f] bg-[#151c13] text-accent"}`}>
              {session.execution.status}
            </span>
            <span>{modelSummary(models, session.agents)}</span>
            <span title={session.workspace}>{session.workspace}</span>
          </div>
        </div>
        <div className="flex items-center gap-2 max-[780px]:flex-col max-[780px]:items-stretch">
          <button className={ghostButton} type="button" onClick={onEdit}>
            Edit team
          </button>
          <button className={`${dangerGhostButton} max-[520px]:hidden`} type="button" onClick={onStop}>
            Stop team
          </button>
        </div>
      </header>

      <div className="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)_292px] max-[1020px]:grid-cols-[minmax(0,1fr)_240px] max-[780px]:flex max-[780px]:flex-col">
        <section className="flex min-h-0 min-w-0 flex-col max-[780px]:min-h-[640px]">
          <div className="flex items-center justify-between border-b border-line-soft px-[26px] py-[13px] max-[780px]:px-4">
            <div>
              <span className={sectionLabel}>Agent thread</span>
              <strong className="mt-1 block text-[13px]">{selectedAgent.id} · round {selectedAgent.round}</strong>
            </div>
            <div className="flex items-center gap-3">
              <CompactButton
                agent={selectedAgent}
                requesting={compactionRequesting}
                onCompact={onCompact}
              />
              <div
                className="flex items-center gap-1.5 text-[10px] tracking-[.09em] text-faint uppercase"
                title="The durable group state is refreshed automatically"
              >
                <span className="size-[5px] animate-pulse rounded-full bg-accent" /> live
              </div>
            </div>
          </div>

          <div
            className="min-h-0 flex-1 scroll-smooth overflow-y-auto px-[26px] pt-[22px] pb-8 max-[780px]:px-4"
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

          <form className="mx-[26px] mb-[22px] rounded-xl border border-[#30383d] bg-[#121619] p-[11px] shadow-[0_16px_50px_rgba(0,0,0,.2)] focus-within:border-[#536644] max-[780px]:mx-4" onSubmit={(event) => void submitMessage(event)}>
            <div className="flex items-center gap-2 px-[3px] pb-1.5 text-[10px] text-faint">
              <label htmlFor="target-agent">Send to</label>
              <select className="border-0 bg-transparent py-[3px] pr-[19px] pl-[5px] text-[10px] text-accent"
                id="target-agent"
                value={selectedAgent.id}
                onChange={(event) => onSelectAgent(event.target.value)}
              >
                {session.agents.map((agent) => (
                  <option key={agent.id} value={agent.id}>
                    {agent.id} · {agent.status}
                  </option>
                ))}
              </select>
            </div>
            <textarea className="block min-h-[65px] w-full resize-y border-0 bg-transparent px-1 py-2 leading-normal text-ink outline-0 placeholder:text-[#535c58]"
              rows={3}
              value={message}
              onChange={(event) => setMessage(event.target.value)}
              onKeyDown={handleComposerKeyDown}
              placeholder="Describe the task, ask a follow-up, or activate a teammate…"
              required
            />
            <div className="flex items-center justify-between border-t border-line-soft pt-[7px] text-[9px] text-faint">
              <span><kbd className="rounded border border-[#363d3a] bg-[#121513] px-[5px] py-0.5 text-[10px] text-faint">⌘</kbd><kbd className="rounded border border-[#363d3a] bg-[#121513] px-[5px] py-0.5 text-[10px] text-faint">Enter</kbd> to send</span>
              <button className={`${primaryButton} px-3 py-2 text-[11px]`} type="submit" disabled={sending}>
                {sending ? "Sending…" : "Send message"} <span>↗</span>
              </button>
            </div>
          </form>
        </section>

        <aside className="min-h-0 overflow-y-auto border-l border-line-soft bg-[rgba(14,17,19,.63)] px-[17px] py-5 max-[780px]:order-first max-[780px]:border-l-0 max-[780px]:border-b max-[780px]:border-line">
          <div className="flex items-end justify-between px-[3px] pb-[13px]">
            <div>
              <span className={sectionLabel}>Team</span>
              <h2 className="mt-[5px] mb-0 text-base">Agents</h2>
            </div>
            <span className="text-[10px] text-faint">{session.agents.length} total</span>
          </div>
          <div className="flex flex-col gap-[7px] max-[780px]:grid max-[780px]:grid-cols-2 max-[520px]:grid-cols-1">
            {session.agents.map((agent) => (
              <AgentCard
                key={agent.id}
                agent={agent}
                active={agent.id === selectedAgent.id}
                onClick={() => onSelectAgent(agent.id)}
              />
            ))}
          </div>
          <div className="mt-[18px] rounded-[10px] border border-line-soft bg-[#111416] p-[14px] max-[780px]:hidden">
            <span className={sectionLabel}>Session usage</span>
            <div className="my-3">
              <strong className="font-serif text-[26px] font-normal">{formatNumber(usage.input + usage.output)}</strong>
              <small className="ml-[5px] text-faint">tokens</small>
            </div>
            <dl className="grid grid-cols-3 gap-[5px] [&_dd]:mt-[3px] [&_dd]:mb-0 [&_dd]:text-[10px] [&_dd]:text-muted [&_dt]:text-[8px] [&_dt]:text-faint [&_dt]:uppercase">
              <div className="min-w-0"><dt>Input</dt><dd>{formatNumber(usage.input)}</dd></div>
              <div className="min-w-0"><dt>Output</dt><dd>{formatNumber(usage.output)}</dd></div>
              <div className="min-w-0"><dt>Cache read</dt><dd>{formatNumber(usage.cache)}</dd></div>
            </dl>
          </div>
        </aside>
      </div>
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
    >
      {label}
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
    <article className="mx-auto mb-[22px] max-w-[860px]">
      <div className="mb-[7px] flex items-center gap-[9px] text-[10px] tracking-[.075em] text-faint uppercase">
        <span className={`grid size-6 place-items-center rounded-[7px] border text-[10px] font-extrabold ${message.role === "tool" ? "border-[#4c3c2a] bg-[#201910] text-warn" : message.role === "assistant" ? "border-[#34402e] bg-[#171e14] text-accent" : "border-[#3c4146] bg-[#1c2023] text-[#c8ceca]"}`}>{avatar}</span><span>{label}</span>
      </div>
      <div className="pl-[33px] text-[13px] leading-[1.62] text-[#d8ddd8]">
        {message.content.map((content, index) => (
          <ContentView key={`${content.type}-${index}`} content={content} />
        ))}
      </div>
    </article>
  );
}

function ContentView({ content }: { content: MessageContent }) {
  switch (content.type) {
    case "text":
      return <div className="mt-[10px] first:mt-0"><pre className="m-0 whitespace-pre-wrap break-words font-[inherit]">{content.text}</pre></div>;
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

function AgentCard({
  agent,
  active,
  onClick,
}: {
  agent: Agent;
  active: boolean;
  onClick: () => void;
}) {
  const tokens = agent.stats.input_tokens + agent.stats.output_tokens;
  return (
    <button
      className={`w-full rounded-[10px] border p-[11px] text-left text-muted transition ${active ? "border-[#45563b] bg-[#171e15]" : "border-line-soft bg-[#121619] hover:border-[#354039]"}`}
      type="button"
      onClick={onClick}
    >
      <div className="flex items-center gap-2">
        <span className="grid size-6 place-items-center rounded-[7px] border border-[#34402e] bg-[#171e14] text-[10px] font-extrabold text-accent">{agent.id.slice(0, 1).toUpperCase()}</span>
        <strong className="text-xs text-ink capitalize">{agent.id}</strong>
        <span className={`ml-auto rounded-[5px] px-[5px] py-[3px] text-[8px] tracking-[.08em] uppercase ${agent.status === "ready" ? "bg-[#26351e] text-accent" : agent.status === "completed" ? "bg-[#18232b] text-info" : agent.status === "failed" ? "bg-[#271716] text-danger" : "bg-[#1b2023] text-faint"}`}>{agent.status}</span>
      </div>
      <p className="my-[9px] line-clamp-2 text-[10px] leading-[1.45] text-faint">{agent.role}</p>
      <div className="flex gap-[11px] text-[9px] text-[#5c6661]">
        <span>{agent.kind === "mcp" ? "MCP specialist" : `round ${agent.round}`}</span>
        <span>{formatNumber(tokens)} tokens</span>
        {agent.pending_messages > 0 ? <span>{agent.pending_messages} queued</span> : null}
      </div>
    </button>
  );
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
