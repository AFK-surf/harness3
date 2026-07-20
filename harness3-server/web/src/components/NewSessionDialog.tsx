import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { errorMessage } from "../api";
import type {
  CreateSessionInput,
  McpConfiguration,
  Model,
} from "../types";
import { Modal } from "./Modal";

interface NewSessionDialogProps {
  open: boolean;
  models: Model[];
  configurations: McpConfiguration[];
  workspaceRoot: string;
  onClose: () => void;
  onCreate: (input: CreateSessionInput) => Promise<void>;
  onError: (message: string) => void;
}

export function NewSessionDialog({
  open,
  models,
  configurations,
  workspaceRoot,
  onClose,
  onCreate,
  onError,
}: NewSessionDialogProps) {
  const enabledConfigurations = useMemo(
    () => configurations.filter(
      (configuration) => configuration.enabled && configuration.servers.length > 0,
    ),
    [configurations],
  );
  const [modelId, setModelId] = useState("");
  const [teamSize, setTeamSize] = useState(3);
  const [configurationId, setConfigurationId] = useState("");
  const [workspace, setWorkspace] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const workspaceInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!open) return;
    setModelId((current) => models.some((model) => model.id === current)
      ? current
      : models[0]?.id ?? "");
    setConfigurationId((current) => enabledConfigurations.some(
      (configuration) => configuration.id === current,
    ) ? current : enabledConfigurations[0]?.id ?? "");
    setWorkspace((current) => current || workspaceRoot);
    const frame = window.requestAnimationFrame(() => workspaceInput.current?.focus());
    return () => window.cancelAnimationFrame(frame);
  }, [enabledConfigurations, models, open, workspaceRoot]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    try {
      await onCreate({
        model_id: modelId,
        workspace,
        team_size: teamSize,
        mcp_configuration_id: teamSize >= 2 ? configurationId || null : null,
      });
      setTeamSize(3);
      setWorkspace(workspaceRoot);
    } catch (error) {
      onError(errorMessage(error));
    } finally {
      setSubmitting(false);
    }
  }

  const roles = ["lead", "researcher", "implementer", "reviewer"];

  return (
    <Modal open={open} onClose={onClose}>
      <form className="dialog-card" onSubmit={(event) => void submit(event)}>
        <div className="dialog-topline" />
        <div className="dialog-heading">
          <div>
            <p className="eyebrow">New coding session</p>
            <h2>Configure your coding team</h2>
          </div>
          <button
            className="icon-button"
            aria-label="Close dialog"
            type="button"
            onClick={onClose}
          >
            ×
          </button>
        </div>

        <div className="field-grid">
          <label className="field">
            <span>Model</span>
            <select
              value={modelId}
              onChange={(event) => setModelId(event.target.value)}
              required
            >
              {models.map((model) => (
                <option key={model.id} value={model.id}>{model.name}</option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Team size</span>
            <select
              value={teamSize}
              onChange={(event) => setTeamSize(Number(event.target.value))}
            >
              <option value={1}>1 · Lead only</option>
              <option value={2}>2 · Lead + researcher</option>
              <option value={3}>3 · Balanced team</option>
              <option value={4}>4 · Full team</option>
            </select>
          </label>
          <label className="field">
            <span>MCP researcher</span>
            <select
              value={configurationId}
              onChange={(event) => setConfigurationId(event.target.value)}
              disabled={teamSize < 2 || enabledConfigurations.length === 0}
            >
              {enabledConfigurations.length === 0 ? (
                <option value="">No MCP configuration installed</option>
              ) : enabledConfigurations.map((configuration) => (
                <option key={configuration.id} value={configuration.id}>
                  {configuration.label} · {configuration.server_count} server{configuration.server_count === 1 ? "" : "s"}
                </option>
              ))}
            </select>
          </label>
        </div>

        <label className="field">
          <span>Workspace <small>absolute path</small></span>
          <input
            ref={workspaceInput}
            value={workspace}
            onChange={(event) => setWorkspace(event.target.value)}
            placeholder="/absolute/path/to/project"
            autoComplete="off"
            required
          />
        </label>

        <div className="team-preview">
          {roles.slice(0, teamSize).map((role, index) => (
            <span key={role}>
              ○ {index === 1 && configurationId ? "MCP specialist" : role} · on demand
            </span>
          ))}
        </div>
        <div className="dialog-actions">
          <button className="ghost" type="button" onClick={onClose}>Cancel</button>
          <button className="primary" type="submit" disabled={submitting}>
            {submitting ? "Creating team…" : "Create session"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
