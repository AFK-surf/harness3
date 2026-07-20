export const eyebrow =
  "m-0 text-[10px] font-extrabold tracking-[.19em] text-accent uppercase";

export const sectionLabel =
  "text-[10px] font-bold tracking-[.13em] text-faint uppercase";

export const primaryButton =
  "rounded-[9px] border-0 bg-accent px-[17px] py-[11px] font-bold text-[#11150e] shadow-[0_8px_30px_rgba(123,162,72,.09)] hover:bg-[#d2f79b] disabled:cursor-wait disabled:opacity-55";

export const ghostButton =
  "rounded-lg border border-line bg-transparent px-3 py-[9px] text-muted hover:border-[#3a4248] hover:bg-panel-2 hover:text-ink";

export const dangerGhostButton =
  `${ghostButton} hover:border-[#5a3432] hover:bg-[#211414] hover:text-danger`;

export const smallGhostButton = `${ghostButton} px-2 py-1.5 text-[10px]`;

export const iconButton =
  "grid size-[30px] shrink-0 place-items-center rounded-[7px] border border-line bg-transparent text-xl leading-none text-muted hover:border-[#3a4248] hover:bg-panel-2 hover:text-ink disabled:cursor-default disabled:opacity-30";

export const dangerIconButton =
  `${iconButton} hover:border-[#5a3432] hover:bg-[#211414] hover:text-danger`;

export const field =
  "mb-[15px] block text-[10px] font-semibold tracking-[.08em] text-muted uppercase [&>span]:mb-[7px] [&>span]:block [&_small]:font-normal [&_small]:tracking-normal [&_small]:text-faint [&_small]:normal-case";

export const control =
  "w-full rounded-lg border border-line bg-[#0d1012] p-[11px] text-ink outline-0 placeholder:text-[#535c58] focus:border-[#4a5c3d] read-only:cursor-default read-only:bg-[#111416] read-only:text-muted";

export const dialogCard =
  "relative max-h-[calc(100vh-42px)] overflow-y-auto p-[27px] max-[520px]:p-[21px]";

export const dialogTopline =
  "absolute top-0 right-[34px] left-[34px] h-px bg-linear-to-r from-transparent via-accent to-transparent opacity-55";

export const dialogHeading =
  "mb-[22px] flex items-start justify-between [&_h2]:mt-[7px] [&_h2]:font-serif [&_h2]:text-[29px] [&_h2]:leading-tight [&_h2]:font-normal [&_h2]:tracking-[-.035em]";

export const dialogActions =
  "flex justify-end gap-2 border-t border-line-soft pt-[18px]";

export const emptyPanel =
  "rounded-[10px] border border-dashed border-[#30373a] px-[14px] py-[25px] text-center text-[11px] text-faint";
