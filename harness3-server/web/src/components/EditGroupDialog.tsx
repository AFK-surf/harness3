import { useEffect, useState, type FormEvent } from "react";
import { errorMessage } from "../api";
import type {
  McpConfiguration,
  Model,
  Session,
  UpdateAgentInput,
  UpdateSessionInput,
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
  ghostButton,
  iconButton,
  primaryButton,
  sectionLabel,
  smallGhostButton,
} from "../ui";
import { Modal } from "./Modal";

interface EditGroupDialogProps {
  open: boolean;
  session: Session;
  models: Model[];
  configurations: McpConfiguration[];
  onClose: () => void;
  onSave: (input: UpdateSessionInput) => Promise<void>;
  onError: (message: string) => void;
}

interface DraftAgent extends UpdateAgentInput {
  key: number;
  existing: boolean;
}

let nextAgentKey = 0;

export function EditGroupDialog({
  open,
  session,
  models,
  configurations,
  onClose,
  onSave,
  onError,
}: EditGroupDialogProps) {
  const [name, setName] = useState(session.title);
  const [agents, setAgents] = useState<DraftAgent[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setName(session.title);
    setAgents(session.agents.map((agent) => ({
      key: nextKey(),
      existing: true,
      id: agent.id,
      role: agent.role,
      kind: agent.kind,
      mcp_configuration_id: agent.mcp_configuration_id,
      model_id: agent.model_id,
    })));
  }, [open, session.id]);

  function updateAgent(
    key: number,
    update: (agent: DraftAgent) => DraftAgent,
  ) {
    setAgents((current) => current.map(
      (agent) => agent.key === key ? update(agent) : agent,
    ));
  }

  function addAgent() {
    setAgents((current) => [
      ...current,
      {
        key: nextKey(),
        existing: false,
        id: "",
        role: "Coding agent working on tasks assigned by the lead.",
        kind: "coding",
        mcp_configuration_id: null,
        model_id: models[0]?.id ?? "",
      },
    ]);
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    setSaving(true);
    try {
      await onSave({
        name,
        agents: agents.map(({ key: _key, existing: _existing, ...agent }) => agent),
      });
    } catch (error) {
      onError(errorMessage(error));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal open={open} className="max-w-[920px]" onClose={onClose}>
      <form className={dialogCard} onSubmit={(event) => void submit(event)}>
        <div className={dialogTopline} />
        <div className={dialogHeading}>
          <div>
            <p className={eyebrow}>Agent group</p>
            <h2>Edit team</h2>
          </div>
          <button
            className={iconButton}
            aria-label="Close dialog"
            type="button"
            onClick={onClose}
          >
            ×
          </button>
        </div>

        <label className={field}>
          <span>Group name</span>
          <input className={control}
            value={name}
            onChange={(event) => setName(event.target.value)}
            required
          />
        </label>

        <div className="mt-2 mb-3 flex items-start justify-between gap-4">
          <div>
            <span className={sectionLabel}>Agents</span>
            <p className="mt-1.5 mb-0 text-[10px] text-faint">Surviving agents keep their history and durable plugin state.</p>
          </div>
          <button className={smallGhostButton} type="button" onClick={addAgent}>
            ＋ Add agent
          </button>
        </div>

        <div className="flex flex-col gap-[10px]">
          {agents.map((agent, index) => (
            <AgentEditor
              key={agent.key}
              agent={agent}
              index={index}
              models={models}
              configurations={configurations}
              removable={agents.length > 1}
              onChange={(update) => updateAgent(agent.key, update)}
              onRemove={() => setAgents((current) => current.filter(
                (item) => item.key !== agent.key,
              ))}
            />
          ))}
          {agents.length === 0 ? (
            <div className={emptyPanel}>Add at least one agent to continue.</div>
          ) : null}
        </div>

        <p className="mt-[13px] mb-0 border-l-2 border-[#5a452a] bg-[#19150f] px-[11px] py-[10px] text-[10px] leading-normal text-[#b5a387]">
          Roster changes stop running agents before they are applied. Surviving
          agents keep their history; removed agents are deleted. New agents stay
          dormant until messaged. Renaming alone does not stop the team.
        </p>
        <div className={`${dialogActions} mt-[18px]`}>
          <button className={ghostButton} type="button" onClick={onClose}>Cancel</button>
          <button
            className={primaryButton}
            type="submit"
            disabled={saving || agents.length === 0}
          >
            {saving ? "Saving team…" : "Save changes"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function AgentEditor({
  agent,
  index,
  models,
  configurations,
  removable,
  onChange,
  onRemove,
}: {
  agent: DraftAgent;
  index: number;
  models: Model[];
  configurations: McpConfiguration[];
  removable: boolean;
  onChange: (update: (agent: DraftAgent) => DraftAgent) => void;
  onRemove: () => void;
}) {
  const access = accessValue(agent);
  const resourceDescription = agent.kind === "coding"
    ? agent.id === "lead"
      ? "Workspace read/write, shell commands, shared cloud storage, and messaging to every teammate."
      : "Workspace read/write, shell commands, shared cloud storage, and messaging only to the lead."
    : agent.kind === "mcp"
      ? "MCP list/call, shared cloud storage, and messaging to the lead; no filesystem or shell."
      : "Shared cloud storage and messaging to the lead; no filesystem, shell, or MCP access.";

  function changeAccess(value: string) {
    onChange((current) => value.startsWith("mcp:") ? {
      ...current,
      kind: "mcp",
      mcp_configuration_id: value.slice(4),
    } : {
      ...current,
      kind: value as "coding" | "researcher",
      mcp_configuration_id: null,
    });
  }

  return (
    <section className="overflow-hidden rounded-[11px] border border-line bg-[#0f1214]">
      <div className="flex items-center justify-between border-b border-line-soft bg-[#14181a] px-[11px] py-[9px]">
        <div className="flex items-center gap-2">
          <span className="grid size-5 place-items-center rounded-md border border-[#384530] bg-[#171e14] text-[9px] text-accent">{index + 1}</span>
          <strong className="text-[11px]">{agent.id || "New agent"}</strong>
        </div>
        <button
          className={`${dangerIconButton} size-[26px] text-base`}
          type="button"
          aria-label={`Remove ${agent.id || "new agent"}`}
          disabled={!removable}
          onClick={onRemove}
        >
          ×
        </button>
      </div>

      <div className="grid grid-cols-[minmax(0,.8fr)_minmax(0,1.2fr)] gap-x-3 p-3 max-[520px]:grid-cols-1 max-[520px]:gap-0">
        <label className={`${field} mb-3`}>
          <span>Agent ID</span>
          <input className={control}
            value={agent.id}
            onChange={(event) => onChange((current) => ({
              ...current,
              id: event.target.value,
            }))}
            readOnly={agent.existing}
            placeholder="specialist"
            required
          />
        </label>
        <label className={`${field} mb-3`}>
          <span>Model</span>
          <select className={control}
            value={agent.model_id}
            onChange={(event) => onChange((current) => ({
              ...current,
              model_id: event.target.value,
            }))}
            required
          >
            {models.map((model) => (
              <option key={model.id} value={model.id}>{model.name}</option>
            ))}
          </select>
        </label>
        <label className={`${field} mb-3`}>
          <span>Resource profile</span>
          <select className={control} value={access} onChange={(event) => changeAccess(event.target.value)}>
            <option value="coding">Coding workspace</option>
            <option value="researcher">Isolated researcher</option>
            {configurations.map((configuration) => (
              <option key={configuration.id} value={`mcp:${configuration.id}`}>
                MCP · {configuration.label}
              </option>
            ))}
          </select>
          <small className="mt-1.5 block text-[9px] leading-[1.45]">{resourceDescription}</small>
        </label>
        <label className={`${field} mb-3`}>
          <span>Role description</span>
          <textarea className={`${control} min-h-[76px] resize-y leading-[1.55]`}
            rows={3}
            value={agent.role}
            onChange={(event) => onChange((current) => ({
              ...current,
              role: event.target.value,
            }))}
            required
          />
        </label>
      </div>
    </section>
  );
}

function accessValue(agent: DraftAgent): string {
  return agent.kind === "mcp"
    ? `mcp:${agent.mcp_configuration_id ?? ""}`
    : agent.kind;
}

function nextKey(): number {
  nextAgentKey += 1;
  return nextAgentKey;
}
