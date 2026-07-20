import { useEffect, useRef, type ReactNode } from "react";

interface ModalProps {
  open: boolean;
  className?: string;
  onClose: () => void;
  children: ReactNode;
}

export function Modal({ open, className, onClose, children }: ModalProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={dialogRef}
      className={`fixed inset-0 m-auto w-[calc(100%-28px)] max-w-[680px] rounded-[15px] border border-[#333c40] bg-[#111518] p-0 text-ink shadow-[0_28px_100px_rgba(0,0,0,.65)] ${className ?? ""}`}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      {children}
    </dialog>
  );
}
