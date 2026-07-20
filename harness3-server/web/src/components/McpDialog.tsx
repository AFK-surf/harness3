import { useEffect, useMemo, useState, type FormEvent } from "react";
import { errorMessage } from "../api";
import type {
  AddMcpServerInput,
  Binding,
  BindingValue,
  McpConfiguration,
  McpServer,
} from "../types";
import { Modal } from "./Modal";

interface McpDialogProps {
  open: boolean;
  configurations: McpConfiguration[];
  onClose: () => void;
  onAdd: (input: AddMcpServerInput) => Promise<void>;
  onRemove: (configurationId: string, serverId: string) => Promise<void>;
  onError: (message: string) => void;
}

interface EditableBinding extends Binding {
  key: number;
}

let nextBindingKey = 0;

export function McpDialog({
  open,
  configurations,
  onClose,
  onAdd,
  onRemove,
  onError,
}: McpDialogProps) {
  const [selectedConfiguration, setSelectedConfiguration] = useState("");
  const [configurationId, setConfigurationId] = useState("");
  const [configurationLabel, setConfigurationLabel] = useState("");
  const [serverId, setServerId] = useState("");
  const [timeout, setTimeoutValue] = useState(60_000);
  const [transportType, setTransportType] = useState<"streamable_http" | "stdio">(
    "streamable_http",
  );
  const [endpoint, setEndpoint] = useState("");
  const [executable, setExecutable] = useState("");
  const [argumentsJson, setArgumentsJson] = useState("[]");
  const [workingDirectory, setWorkingDirectory] = useState("");
  const [bindings, setBindings] = useState<EditableBinding[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const existingConfiguration = useMemo(
    () => configurations.find(
      (configuration) => configuration.id === selectedConfiguration,
    ),
    [configurations, selectedConfiguration],
  );

  useEffect(() => {
    if (!open) return;
    setSelectedConfiguration((current) => configurations.some(
      (configuration) => configuration.id === current,
    ) ? current : configurations[0]?.id ?? "");
  }, [configurations, open]);

  useEffect(() => {
    if (!existingConfiguration) return;
    setConfigurationId(existingConfiguration.id);
    setConfigurationLabel(existingConfiguration.label);
  }, [existingConfiguration]);

  function chooseConfiguration(id: string) {
    setSelectedConfiguration(id);
    const existing = configurations.find((configuration) => configuration.id === id);
    setConfigurationId(existing?.id ?? "");
    setConfigurationLabel(existing?.label ?? "");
  }

  function addBinding() {
    nextBindingKey += 1;
    setBindings((current) => [
      ...current,
      {
        key: nextBindingKey,
        name: "",
        value: { type: "environment_variable", value: "" },
      },
    ]);
  }

  function updateBinding(
    key: number,
    update: (binding: EditableBinding) => EditableBinding,
  ) {
    setBindings((current) => current.map(
      (binding) => binding.key === key ? update(binding) : binding,
    ));
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    try {
      const cleanBindings = bindings.map(({ name, value }) => ({ name, value }));
      let transport: AddMcpServerInput["server"]["transport"];
      if (transportType === "streamable_http") {
        transport = {
          type: "streamable_http",
          endpoint,
          headers: cleanBindings,
        };
      } else {
        const parsed = JSON.parse(argumentsJson || "[]") as unknown;
        if (!Array.isArray(parsed) || parsed.some((value) => typeof value !== "string")) {
          throw new Error("Stdio arguments must be a JSON array of strings.");
        }
        transport = {
          type: "stdio",
          executable,
          arguments: parsed,
          working_directory: workingDirectory || null,
          environment: cleanBindings,
        };
      }
      const submittedConfigurationId = configurationId.trim();
      await onAdd({
        configuration_id: submittedConfigurationId,
        configuration_label: configurationLabel.trim(),
        server: {
          id: serverId.trim(),
          timeout_milliseconds: timeout,
          transport,
        },
      });
      setSelectedConfiguration(submittedConfigurationId);
      setServerId("");
      setEndpoint("");
      setExecutable("");
      setArgumentsJson("[]");
      setWorkingDirectory("");
      setBindings([]);
    } catch (error) {
      onError(errorMessage(error));
    } finally {
      setSubmitting(false);
    }
  }

  async function removeServer(configurationIdValue: string, serverIdValue: string) {
    if (!window.confirm(
      `Remove MCP server “${serverIdValue}” from “${configurationIdValue}”?`,
    )) return;
    try {
      await onRemove(configurationIdValue, serverIdValue);
    } catch (error) {
      onError(errorMessage(error));
    }
  }

  const serverCount = configurations.reduce(
    (count, configuration) => count + configuration.servers.length,
    0,
  );

  return (
    <Modal open={open} className="mcp-dialog" onClose={onClose}>
      <div className="dialog-card">
        <div className="dialog-topline" />
        <div className="dialog-heading">
          <div>
            <p className="eyebrow">Global configuration</p>
            <h2>Manage MCP servers</h2>
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

        <div className="mcp-manager-layout">
          <section className="mcp-installed-panel">
            <div className="mcp-section-heading">
              <div>
                <span className="sidebar-label">Installed</span>
                <p>Servers are discovered when an MCP specialist activates.</p>
              </div>
            </div>
            <div className="mcp-server-list">
              {serverCount === 0 ? (
                <div className="mcp-empty">No MCP servers installed yet.</div>
              ) : configurations.map((configuration) => configuration.servers.length > 0 && (
                <div className="mcp-configuration-card" key={configuration.id}>
                  <div className="mcp-configuration-title">
                    <strong>{configuration.label}</strong>
                    <span>{configuration.id}</span>
                  </div>
                  {configuration.servers.map((server) => (
                    <McpServerRow
                      key={server.id}
                      server={server}
                      onRemove={() => void removeServer(configuration.id, server.id)}
                    />
                  ))}
                </div>
              ))}
            </div>
          </section>

          <form className="mcp-add-form" onSubmit={(event) => void submit(event)}>
            <div className="mcp-section-heading">
              <div>
                <span className="sidebar-label">Add server</span>
                <p>Settings are stored globally and survive restarts.</p>
              </div>
            </div>

            <label className="field">
              <span>Configuration</span>
              <select
                value={selectedConfiguration}
                onChange={(event) => chooseConfiguration(event.target.value)}
              >
                {configurations.map((configuration) => (
                  <option key={configuration.id} value={configuration.id}>
                    {configuration.label} · {configuration.id}
                  </option>
                ))}
                <option value="">＋ New configuration</option>
              </select>
            </label>
            <div className="field-grid compact-grid">
              <label className="field">
                <span>Configuration ID</span>
                <input
                  value={configurationId}
                  onChange={(event) => setConfigurationId(event.target.value)}
                  readOnly={Boolean(existingConfiguration)}
                  pattern="[A-Za-z0-9_-]+"
                  placeholder="research"
                  required
                />
              </label>
              <label className="field">
                <span>Configuration label</span>
                <input
                  value={configurationLabel}
                  onChange={(event) => setConfigurationLabel(event.target.value)}
                  readOnly={Boolean(existingConfiguration)}
                  placeholder="Research services"
                  required
                />
              </label>
            </div>
            <div className="field-grid compact-grid">
              <label className="field">
                <span>Server ID</span>
                <input
                  value={serverId}
                  onChange={(event) => setServerId(event.target.value)}
                  pattern="[A-Za-z0-9_-]+"
                  placeholder="knowledge"
                  required
                />
              </label>
              <label className="field">
                <span>Timeout <small>milliseconds</small></span>
                <input
                  type="number"
                  min={1}
                  max={300_000}
                  value={timeout}
                  onChange={(event) => setTimeoutValue(Number(event.target.value))}
                  required
                />
              </label>
            </div>
            <label className="field">
              <span>Transport</span>
              <select
                value={transportType}
                onChange={(event) => setTransportType(
                  event.target.value as "streamable_http" | "stdio",
                )}
              >
                <option value="streamable_http">Streamable HTTP</option>
                <option value="stdio">Stdio process</option>
              </select>
            </label>

            {transportType === "streamable_http" ? (
              <label className="field">
                <span>Endpoint <small>absolute HTTP(S) URL</small></span>
                <input
                  type="url"
                  value={endpoint}
                  onChange={(event) => setEndpoint(event.target.value)}
                  placeholder="https://mcp.example.com/mcp"
                  required
                />
              </label>
            ) : (
              <>
                <label className="field">
                  <span>Executable <small>absolute path</small></span>
                  <input
                    value={executable}
                    onChange={(event) => setExecutable(event.target.value)}
                    placeholder="/usr/bin/node"
                    required
                  />
                </label>
                <label className="field">
                  <span>Arguments <small>JSON string array</small></span>
                  <input
                    value={argumentsJson}
                    onChange={(event) => setArgumentsJson(event.target.value)}
                    placeholder='["/absolute/server.js"]'
                  />
                </label>
                <label className="field">
                  <span>Working directory <small>optional absolute path</small></span>
                  <input
                    value={workingDirectory}
                    onChange={(event) => setWorkingDirectory(event.target.value)}
                    placeholder="/absolute/path"
                  />
                </label>
              </>
            )}

            <div className="binding-heading">
              <span>{transportType === "streamable_http" ? "HTTP headers" : "Process environment"}</span>
              <button className="ghost small" type="button" onClick={addBinding}>
                ＋ Add binding
              </button>
            </div>
            <div className="binding-list">
              {bindings.map((binding) => (
                <BindingRow
                  key={binding.key}
                  binding={binding}
                  onChange={(update) => updateBinding(binding.key, update)}
                  onRemove={() => setBindings((current) => current.filter(
                    (item) => item.key !== binding.key,
                  ))}
                />
              ))}
            </div>
            <p className="field-note">
              Use an environment-variable binding for secrets when possible.
              Literal values are stored in plaintext and are never returned by the API.
            </p>

            <div className="dialog-actions">
              <button className="primary" type="submit" disabled={submitting}>
                {submitting ? "Adding…" : "Add server"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </Modal>
  );
}

function McpServerRow({ server, onRemove }: { server: McpServer; onRemove: () => void }) {
  const location = server.transport.type === "streamable_http"
    ? server.transport.endpoint
    : server.transport.executable;
  const kind = server.transport.type === "streamable_http" ? "HTTP" : "stdio";
  const argumentCount = server.transport.type === "stdio" && server.transport.argument_count
    ? ` · ${server.transport.argument_count} arg${server.transport.argument_count === 1 ? "" : "s"}`
    : "";
  const bindingCount = server.transport.binding_count
    ? ` · ${server.transport.binding_count} binding${server.transport.binding_count === 1 ? "" : "s"}`
    : "";
  return (
    <div className="mcp-server-row">
      <div>
        <strong>{server.id}</strong>
        <small>
          {kind} · {new Intl.NumberFormat().format(server.timeout_milliseconds)} ms
          {argumentCount}{bindingCount}
        </small>
        <code title={location}>{location}</code>
      </div>
      <button
        className="icon-button danger"
        type="button"
        aria-label={`Remove ${server.id}`}
        onClick={onRemove}
      >
        ×
      </button>
    </div>
  );
}

function BindingRow({
  binding,
  onChange,
  onRemove,
}: {
  binding: EditableBinding;
  onChange: (update: (binding: EditableBinding) => EditableBinding) => void;
  onRemove: () => void;
}) {
  function updateValue(update: Partial<BindingValue>) {
    onChange((current) => ({
      ...current,
      value: { ...current.value, ...update },
    }));
  }

  return (
    <div className="binding-row">
      <input
        aria-label="Binding name"
        value={binding.name}
        onChange={(event) => onChange((current) => ({
          ...current,
          name: event.target.value,
        }))}
        placeholder="Name"
        required
      />
      <select
        aria-label="Binding source"
        value={binding.value.type}
        onChange={(event) => updateValue({
          type: event.target.value as BindingValue["type"],
        })}
      >
        <option value="environment_variable">Environment variable</option>
        <option value="literal">Literal value</option>
      </select>
      <input
        aria-label="Binding value"
        type={binding.value.type === "literal" ? "password" : "text"}
        value={binding.value.value}
        onChange={(event) => updateValue({ value: event.target.value })}
        placeholder={binding.value.type === "literal"
          ? "Stored plaintext value"
          : "VARIABLE_NAME"}
        required
      />
      <button
        className="icon-button"
        type="button"
        aria-label="Remove binding"
        onClick={onRemove}
      >
        ×
      </button>
    </div>
  );
}
