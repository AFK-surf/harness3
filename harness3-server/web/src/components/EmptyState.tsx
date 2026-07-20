interface EmptyStateProps {
  onNewSession: () => void;
}

export function EmptyState({ onNewSession }: EmptyStateProps) {
  return (
    <section className="empty-state">
      <div className="empty-orbit" aria-hidden="true">
        <span className="orbit orbit-one" />
        <span className="orbit orbit-two" />
        <span className="orbit orbit-three" />
        <span className="orbit-core">3</span>
      </div>
      <p className="eyebrow">Durable · coordinated · local-first</p>
      <h1>Give a coding task<br />to a focused team.</h1>
      <p className="empty-copy">
        A lead agent can inspect and edit your workspace, run commands, and wake
        specialist teammates when the task calls for it.
      </p>
      <button className="primary" type="button" onClick={onNewSession}>
        Start a coding session
      </button>
      <div className="capabilities">
        <span>Read &amp; write files</span>
        <span>Execute tests</span>
        <span>Message teammates</span>
      </div>
    </section>
  );
}
