import { useEffect, useState, type FormEvent } from "react";
import { errorMessage } from "../api";
import type {
  CloudStorageWorkspace,
  CloudStorageWorkspaceInput,
  UpdateCloudStorageWorkspaceInput,
} from "../types";
import {
  control,
  dangerIconButton,
  dialogActions,
  dialogCard,
  dialogHeading,
  dialogTopline,
  emptyPanel,
  eyebrow,
  field,
  iconButton,
  primaryButton,
  sectionLabel,
  smallGhostButton,
} from "../ui";
import { Modal } from "./Modal";

interface CloudStorageDialogProps {
  open: boolean;
  workspaces: CloudStorageWorkspace[];
  onClose: () => void;
  onAdd: (input: CloudStorageWorkspaceInput) => Promise<void>;
  onUpdate: (
    workspaceId: string,
    input: UpdateCloudStorageWorkspaceInput,
  ) => Promise<void>;
  onRemove: (workspaceId: string) => Promise<void>;
  onError: (message: string) => void;
}

function defaultPrefix(id: string): string {
  return `plugins/cloud_storage/workspaces/${id}/objects/`;
}

export function CloudStorageDialog({
  open,
  workspaces,
  onClose,
  onAdd,
  onUpdate,
  onRemove,
  onError,
}: CloudStorageDialogProps) {
  const [editingId, setEditingId] = useState<string | null>(null);
  const [workspaceId, setWorkspaceId] = useState("");
  const [label, setLabel] = useState("");
  const [prefix, setPrefix] = useState("");
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!open) return;
    resetForm();
  }, [open]);

  function resetForm() {
    setEditingId(null);
    setWorkspaceId("");
    setLabel("");
    setPrefix("");
  }

  function editWorkspace(workspace: CloudStorageWorkspace) {
    setEditingId(workspace.id);
    setWorkspaceId(workspace.id);
    setLabel(workspace.label);
    setPrefix(workspace.prefix);
  }

  function closeDialog() {
    resetForm();
    onClose();
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    try {
      if (editingId) {
        await onUpdate(editingId, { label: label.trim(), prefix: prefix.trim() });
      } else {
        await onAdd({
          id: workspaceId.trim(),
          label: label.trim(),
          prefix: prefix.trim(),
        });
      }
      resetForm();
    } catch (error) {
      onError(errorMessage(error));
    } finally {
      setSubmitting(false);
    }
  }

  async function removeWorkspace(workspace: CloudStorageWorkspace) {
    if (!window.confirm(
      `Remove cloud storage workspace “${workspace.label}” (${workspace.id})? Objects already stored under its prefix are kept. Sessions still using it must be re-pointed first.`,
    )) return;
    try {
      await onRemove(workspace.id);
      if (editingId === workspace.id) resetForm();
    } catch (error) {
      onError(errorMessage(error));
    }
  }

  const suggestedPrefix = defaultPrefix(workspaceId.trim() || "id");

  return (
    <Modal open={open} className="max-w-[980px]" onClose={closeDialog}>
      <div className={dialogCard}>
        <div className={dialogTopline} />
        <div className={dialogHeading}>
          <div>
            <p className={eyebrow}>Global configuration</p>
            <h2>Cloud storage workspaces</h2>
          </div>
          <button
            className={iconButton}
            aria-label="Close dialog"
            type="button"
            onClick={closeDialog}
          >
            ×
          </button>
        </div>

        <div className="grid grid-cols-[minmax(0,.9fr)_minmax(0,1.1fr)] gap-6 max-[520px]:grid-cols-1">
          <section className="min-w-0 border-r border-line-soft pr-[22px] max-[520px]:border-r-0 max-[520px]:border-b max-[520px]:pr-0 max-[520px]:pb-5">
            <div className="mb-3 flex min-h-[42px] items-start justify-between">
              <div>
                <span className={sectionLabel}>Configured</span>
                <p className="mt-1.5 mb-0 text-[10px] leading-normal text-faint">Sessions share the workspace they are associated with; unassociated sessions stay isolated.</p>
              </div>
            </div>
            <div className="flex max-h-[590px] flex-col gap-[10px] overflow-y-auto">
              {workspaces.length === 0 ? (
                <div className={emptyPanel}>No cloud storage workspaces yet.</div>
              ) : workspaces.map((workspace) => (
                <div
                  className="flex items-start justify-between gap-[10px] rounded-[10px] border border-line bg-[#0f1214] p-[11px]"
                  key={workspace.id}
                >
                  <div className="min-w-0">
                    <strong className="block text-[11px]">{workspace.label}</strong>
                    <small className="mt-1 block font-mono text-[9px] text-faint">{workspace.id}</small>
                    <code className="mt-[7px] block truncate text-[9px] text-muted" title={workspace.prefix}>{workspace.prefix}</code>
                  </div>
                  <div className="flex shrink-0 items-center gap-1.5">
                    <button
                      className={`${smallGhostButton} py-[5px]`}
                      type="button"
                      aria-label={`Edit ${workspace.id}`}
                      onClick={() => editWorkspace(workspace)}
                    >
                      Edit
                    </button>
                    <button
                      className={`${dangerIconButton} size-[26px] text-base`}
                      type="button"
                      aria-label={`Remove ${workspace.id}`}
                      onClick={() => void removeWorkspace(workspace)}
                    >
                      ×
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </section>

          <form onSubmit={(event) => void submit(event)}>
            <div className="mb-3 flex min-h-[42px] items-start justify-between">
              <div>
                <span className={sectionLabel}>{editingId ? "Edit workspace" : "Add workspace"}</span>
                <p className="mt-1.5 mb-0 text-[10px] leading-normal text-faint">
                  {editingId
                    ? `Editing ${editingId}. Sessions pick up a changed prefix on their next wake.`
                    : "Workspaces are stored globally and survive restarts."}
                </p>
              </div>
              {editingId ? (
                <button
                  className={smallGhostButton}
                  type="button"
                  onClick={resetForm}
                >
                  Cancel edit
                </button>
              ) : null}
            </div>

            <div className="grid grid-cols-2 gap-3 max-[520px]:grid-cols-1 max-[520px]:gap-0">
              <label className={field}>
                <span>Workspace ID</span>
                <input className={control}
                  value={workspaceId}
                  onChange={(event) => setWorkspaceId(event.target.value)}
                  readOnly={Boolean(editingId)}
                  pattern="[A-Za-z0-9_-]+"
                  placeholder="team-alpha"
                  required
                />
              </label>
              <label className={field}>
                <span>Label</span>
                <input className={control}
                  value={label}
                  onChange={(event) => setLabel(event.target.value)}
                  placeholder="Team Alpha shared storage"
                  required
                />
              </label>
            </div>
            <label className={field}>
              <span>Storage prefix <small>safe relative path; empty uses the default</small></span>
              <input className={control}
                value={prefix}
                onChange={(event) => setPrefix(event.target.value)}
                placeholder={suggestedPrefix}
                autoComplete="off"
              />
              <small className="mt-1.5 block text-[9px] leading-[1.45]">
                Default: <code>{suggestedPrefix}</code>. Prefixes under <code>cluster/</code> or <code>harness3-server/</code> are reserved.
              </small>
            </label>

            <div className={dialogActions}>
              <button className={primaryButton} type="submit" disabled={submitting}>
                {submitting
                  ? editingId ? "Saving…" : "Adding…"
                  : editingId ? "Save changes" : "Add workspace"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </Modal>
  );
}
