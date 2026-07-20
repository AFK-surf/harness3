interface EmptyStateProps {
  onNewSession: () => void;
}

export function EmptyState({ onNewSession }: EmptyStateProps) {
  return (
    <section className="relative flex h-full flex-col items-center justify-center overflow-hidden p-10 text-center before:absolute before:size-[640px] before:rounded-full before:border before:border-white/[.025] max-[780px]:min-h-[calc(100vh-66px)] max-[780px]:px-[18px] max-[780px]:py-[30px]">
      <div className="empty-orbit mb-[22px]" aria-hidden="true">
        <span className="orbit orbit-one" />
        <span className="orbit orbit-two" />
        <span className="orbit orbit-three" />
        <span className="absolute top-[25px] left-[41px] grid size-[30px] place-items-center rounded-full bg-accent font-serif font-bold text-[#0d110c] shadow-[0_0_35px_rgba(199,242,132,.2)]">3</span>
      </div>
      <p className={eyebrow}>Durable · coordinated · local-first</p>
      <h1 className="z-1 my-[18px] max-w-[780px] font-serif text-[clamp(48px,6.2vw,82px)] leading-[.99] font-normal tracking-[-.055em] max-[780px]:text-[45px]">Give a coding task<br />to a focused team.</h1>
      <p className="z-1 mb-[30px] max-w-[570px] text-[15px] leading-[1.65] text-muted">
        A lead agent can inspect and edit your workspace, run commands, and wake
        specialist teammates when the task calls for it.
      </p>
      <button className={`${primaryButton} z-1`} type="button" onClick={onNewSession}>
        Start a coding session
      </button>
      <div className="z-1 mt-[37px] flex flex-wrap justify-center gap-[9px] text-[10px] text-faint [&>span]:rounded-full [&>span]:border [&>span]:border-line [&>span]:bg-panel/75 [&>span]:px-[10px] [&>span]:py-[7px]">
        <span>Read &amp; write files</span><span>Execute tests</span><span>Message teammates</span>
      </div>
    </section>
  );
}
import { eyebrow, primaryButton } from "../ui";
