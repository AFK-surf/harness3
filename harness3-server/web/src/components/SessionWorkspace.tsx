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

interface SessionWorkspaceProps {
  session: Session;
  models: Model[];
  selectedAgentId: string | null;
  sending: boolean;
  compactionRequesting: boolean;
  scrollRequest: number;
  onSelectAgent: (id: string) => void;
  onSendMessage: (agentId: string, message: string) => Promise<boolean>;
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
    <section className="workspace">
      <header className="workspace-header">
        <div className="header-copy">
          <div className="breadcrumb">
            <span>Session</span><b>/</b>
            <span>{session.id.replace("session-", "").slice(0, 8)}</span>
          </div>
          <h1>{session.title}</h1>
          <div className="session-meta">
            <span className={`status-pill ${session.execution.status}`}>
              {session.execution.status}
            </span>
            <span>{modelName(models, session.model_id)}</span>
            <span title={session.workspace}>{session.workspace}</span>
          </div>
        </div>
        <button className="ghost danger" type="button" onClick={onStop}>
          Stop team
        </button>
      </header>

      <div className="workspace-body">
        <section className="thread-panel">
          <div className="thread-toolbar">
            <div>
              <span className="sidebar-label">Agent thread</span>
              <strong>{selectedAgent.id} · round {selectedAgent.round}</strong>
            </div>
            <div className="thread-toolbar-actions">
              <CompactButton
                agent={selectedAgent}
                requesting={compactionRequesting}
                onCompact={onCompact}
              />
              <div
                className="poll-indicator"
                title="The durable group state is refreshed automatically"
              >
                <span /> live
              </div>
            </div>
          </div>

          <div
            className="thread"
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

          <form className="composer" onSubmit={(event) => void submitMessage(event)}>
            <div className="composer-row">
              <label htmlFor="target-agent">Send to</label>
              <select
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
            <textarea
              rows={3}
              value={message}
              onChange={(event) => setMessage(event.target.value)}
              onKeyDown={handleComposerKeyDown}
              placeholder="Describe the task, ask a follow-up, or activate a teammate…"
              required
            />
            <div className="composer-actions">
              <span><kbd>⌘</kbd><kbd>Enter</kbd> to send</span>
              <button className="send-button" type="submit" disabled={sending}>
                {sending ? "Sending…" : "Send message"} <span>↗</span>
              </button>
            </div>
          </form>
        </section>

        <aside className="team-panel">
          <div className="team-heading">
            <div>
              <span className="sidebar-label">Team</span>
              <h2>Agents</h2>
            </div>
            <span className="team-count">{session.agents.length} total</span>
          </div>
          <div className="team-list">
            {session.agents.map((agent) => (
              <AgentCard
                key={agent.id}
                agent={agent}
                active={agent.id === selectedAgent.id}
                onClick={() => onSelectAgent(agent.id)}
              />
            ))}
          </div>
          <div className="usage-card">
            <span className="sidebar-label">Session usage</span>
            <div>
              <strong>{formatNumber(usage.input + usage.output)}</strong>
              <small>tokens</small>
            </div>
            <dl>
              <div><dt>Input</dt><dd>{formatNumber(usage.input)}</dd></div>
              <div><dt>Output</dt><dd>{formatNumber(usage.output)}</dd></div>
              <div><dt>Cache read</dt><dd>{formatNumber(usage.cache)}</dd></div>
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
      className={`ghost compact-context${compaction.pending ? " pending" : ""}${compaction.error ? " failed" : ""}`}
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
      <div className="thread-empty">
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
        <div className="message">
          <div className="message-body">
            <div className="failure-card">{agent.failure}</div>
          </div>
        </div>
      ) : null}
    </>
  );
}

function MessageView({ message, agentId }: { message: Message; agentId: string }) {
  const roleClass = message.role === "tool" ? "tool" : message.role;
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
    <article className={`message ${roleClass}`}>
      <div className="message-head">
        <span className="avatar">{avatar}</span><span>{label}</span>
      </div>
      <div className="message-body">
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
      return <div className="content-block"><pre>{content.text}</pre></div>;
    case "reasoning":
      return (
        <details className="content-block reasoning">
          <summary>
            Reasoning summary{content.encrypted ? " · encrypted state retained" : ""}
          </summary>
          <pre>{content.summary.join("\n")}</pre>
        </details>
      );
    case "tool_call":
      return (
        <details className="content-block tool-block">
          <summary>Called {content.name}</summary>
          <pre>{JSON.stringify(content.arguments, null, 2)}</pre>
        </details>
      );
    case "tool_result":
      return (
        <details
          className={`content-block tool-block${content.is_error ? " error" : ""}`}
          open
        >
          <summary>{content.is_error ? "Tool error" : "Tool output"}</summary>
          <pre>{content.content.map(contentText).join("\n")}</pre>
        </details>
      );
    case "image":
      return <div className="content-block">[image · {content.detail}]</div>;
    case "document":
      return <div className="content-block">[document]</div>;
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
      className={`agent-card${active ? " active" : ""}`}
      type="button"
      onClick={onClick}
    >
      <div className="agent-card-top">
        <span className="avatar">{agent.id.slice(0, 1).toUpperCase()}</span>
        <strong>{agent.id}</strong>
        <span className={`agent-status ${agent.status}`}>{agent.status}</span>
      </div>
      <p>{agent.role}</p>
      <div className="agent-card-footer">
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

function modelName(models: Model[], id: string): string {
  return models.find((model) => model.id === id)?.name ?? id;
}

function formatNumber(value: number): string {
  return new Intl.NumberFormat().format(value || 0);
}

function scrollToLatest(element: HTMLDivElement | null) {
  if (element) element.scrollTop = element.scrollHeight;
}
