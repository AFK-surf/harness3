import { useEffect, useMemo, useState, type FormEvent } from "react";
import { errorMessage } from "../api";
import type {
  AddMcpServerInput,
  Binding,
  BindingValue,
  McpConfiguration,
  McpServer,
  UpdateMcpServerInput,
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

interface McpDialogProps {
  open: boolean;
  configurations: McpConfiguration[];
  onClose: () => void;
  onAdd: (input: AddMcpServerInput) => Promise<void>;
  onUpdate: (
    configurationId: string,
    serverId: string,
    input: UpdateMcpServerInput,
  ) => Promise<void>;
  onRemove: (configurationId: string, serverId: string) => Promise<void>;
  onError: (message: string) => void;
}

interface EditableBinding extends Binding {
  key: number;
}

interface EditingServer {
  configurationId: string;
  serverId: string;
}

let nextBindingKey = 0;

export function McpDialog({
  open,
  configurations,
  onClose,
  onAdd,
  onUpdate,
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
  const [editing, setEditing] = useState<EditingServer | null>(null);
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

  function editServer(
    configuration: McpConfiguration,
    server: McpServer,
  ) {
    setEditing({
      configurationId: configuration.id,
      serverId: server.id,
    });
    setSelectedConfiguration(configuration.id);
    setConfigurationId(configuration.id);
    setConfigurationLabel(configuration.label);
    setServerId(server.id);
    setTimeoutValue(server.timeout_milliseconds);
    setTransportType(server.transport.type);
    if (server.transport.type === "streamable_http") {
      setEndpoint(server.transport.endpoint);
      setExecutable("");
      setArgumentsJson("[]");
      setWorkingDirectory("");
      setBindings(editableBindings(server.transport.headers));
    } else {
      setEndpoint("");
      setExecutable(server.transport.executable);
      setArgumentsJson(JSON.stringify(server.transport.arguments));
      setWorkingDirectory(server.transport.working_directory ?? "");
      setBindings(editableBindings(server.transport.environment));
    }
  }

  function resetServerForm() {
    setEditing(null);
    setServerId("");
    setTimeoutValue(60_000);
    setTransportType("streamable_http");
    setEndpoint("");
    setExecutable("");
    setArgumentsJson("[]");
    setWorkingDirectory("");
    setBindings([]);
  }

  function closeDialog() {
    resetServerForm();
    onClose();
  }

  function addBinding() {
    setBindings((current) => [
      ...current,
      {
        key: bindingKey(),
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
      const server = {
        id: serverId.trim(),
        timeout_milliseconds: timeout,
        transport,
      };
      const submittedConfigurationId = configurationId.trim();
      if (editing) {
        await onUpdate(editing.configurationId, editing.serverId, { server });
      } else {
        await onAdd({
          configuration_id: submittedConfigurationId,
          configuration_label: configurationLabel.trim(),
          server,
        });
      }
      setSelectedConfiguration(submittedConfigurationId);
      resetServerForm();
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
    <Modal open={open} className="max-w-[980px]" onClose={closeDialog}>
      <div className={dialogCard}>
        <div className={dialogTopline} />
        <div className={dialogHeading}>
          <div>
            <p className={eyebrow}>Global configuration</p>
            <h2>Manage MCP servers</h2>
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
                <span className={sectionLabel}>Installed</span>
                <p className="mt-1.5 mb-0 text-[10px] leading-normal text-faint">Servers are discovered when an MCP specialist activates.</p>
              </div>
            </div>
            <div className="flex max-h-[590px] flex-col gap-[10px] overflow-y-auto">
              {serverCount === 0 ? (
                <div className={emptyPanel}>No MCP servers installed yet.</div>
              ) : configurations.map((configuration) => configuration.servers.length > 0 && (
                <div className="overflow-hidden rounded-[10px] border border-line bg-[#0f1214]" key={configuration.id}>
                  <div className="flex items-baseline justify-between gap-[10px] border-b border-line-soft bg-[#14181a] px-[11px] py-[9px]">
                    <strong className="truncate text-[11px]">{configuration.label}</strong>
                    <span className="font-mono text-[9px] text-faint">{configuration.id}</span>
                  </div>
                  {configuration.servers.map((server) => (
                    <McpServerRow
                      key={server.id}
                      server={server}
                      onEdit={() => editServer(configuration, server)}
                      onRemove={() => void removeServer(configuration.id, server.id)}
                    />
                  ))}
                </div>
              ))}
            </div>
          </section>

          <form onSubmit={(event) => void submit(event)}>
            <div className="mb-3 flex min-h-[42px] items-start justify-between">
              <div>
                <span className={sectionLabel}>{editing ? "Edit server" : "Add server"}</span>
                <p className="mt-1.5 mb-0 text-[10px] leading-normal text-faint">
                  {editing
                    ? `Editing ${editing.configurationId} / ${editing.serverId}`
                    : "Settings are stored globally and survive restarts."}
                </p>
              </div>
              {editing ? (
                <button
                  className={smallGhostButton}
                  type="button"
                  onClick={resetServerForm}
                >
                  Cancel edit
                </button>
              ) : null}
            </div>

            <label className={field}>
              <span>Configuration</span>
              <select className={control}
                value={selectedConfiguration}
                onChange={(event) => chooseConfiguration(event.target.value)}
                disabled={Boolean(editing)}
              >
                {configurations.map((configuration) => (
                  <option key={configuration.id} value={configuration.id}>
                    {configuration.label} · {configuration.id}
                  </option>
                ))}
                <option value="">＋ New configuration</option>
              </select>
            </label>
            <div className="grid grid-cols-2 gap-3 max-[520px]:grid-cols-1 max-[520px]:gap-0">
              <label className={field}>
                <span>Configuration ID</span>
                <input className={control}
                  value={configurationId}
                  onChange={(event) => setConfigurationId(event.target.value)}
                  readOnly={Boolean(existingConfiguration)}
                  pattern="[A-Za-z0-9_-]+"
                  placeholder="research"
                  required
                />
              </label>
              <label className={field}>
                <span>Configuration label</span>
                <input className={control}
                  value={configurationLabel}
                  onChange={(event) => setConfigurationLabel(event.target.value)}
                  readOnly={Boolean(existingConfiguration)}
                  placeholder="Research services"
                  required
                />
              </label>
            </div>
            <div className="grid grid-cols-2 gap-3 max-[520px]:grid-cols-1 max-[520px]:gap-0">
              <label className={field}>
                <span>Server ID</span>
                <input className={control}
                  value={serverId}
                  onChange={(event) => setServerId(event.target.value)}
                  readOnly={Boolean(editing)}
                  pattern="[A-Za-z0-9_-]+"
                  placeholder="knowledge"
                  required
                />
              </label>
              <label className={field}>
                <span>Timeout <small>milliseconds</small></span>
                <input className={control}
                  type="number"
                  min={1}
                  max={300_000}
                  value={timeout}
                  onChange={(event) => setTimeoutValue(Number(event.target.value))}
                  required
                />
              </label>
            </div>
            <label className={field}>
              <span>Transport</span>
              <select className={control}
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
              <label className={field}>
                <span>Endpoint <small>absolute HTTP(S) URL</small></span>
                <input className={control}
                  type="url"
                  value={endpoint}
                  onChange={(event) => setEndpoint(event.target.value)}
                  placeholder="https://mcp.example.com/mcp"
                  required
                />
              </label>
            ) : (
              <>
                <label className={field}>
                  <span>Executable <small>absolute path</small></span>
                  <input className={control}
                    value={executable}
                    onChange={(event) => setExecutable(event.target.value)}
                    placeholder="/usr/bin/node"
                    required
                  />
                </label>
                <label className={field}>
                  <span>Arguments <small>JSON string array</small></span>
                  <input className={control}
                    value={argumentsJson}
                    onChange={(event) => setArgumentsJson(event.target.value)}
                    placeholder='["/absolute/server.js"]'
                  />
                </label>
                <label className={field}>
                  <span>Working directory <small>optional absolute path</small></span>
                  <input className={control}
                    value={workingDirectory}
                    onChange={(event) => setWorkingDirectory(event.target.value)}
                    placeholder="/absolute/path"
                  />
                </label>
              </>
            )}

            <div className="mt-[5px] mb-2 flex items-center justify-between gap-3 text-[10px] font-semibold tracking-[.08em] text-muted uppercase">
              <span>{transportType === "streamable_http" ? "HTTP headers" : "Process environment"}</span>
              <button className={smallGhostButton} type="button" onClick={addBinding}>
                ＋ Add binding
              </button>
            </div>
            <div className="flex flex-col gap-[7px]">
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
            <p className="mt-[9px] mb-[15px] text-[9px] leading-normal text-faint">
              Use an environment-variable binding for secrets when possible.
              Literal values are stored and returned by the management API in
              plaintext; use Show to reveal them in this form.
            </p>

            <div className={dialogActions}>
              <button className={primaryButton} type="submit" disabled={submitting}>
                {submitting
                  ? editing ? "Saving…" : "Adding…"
                  : editing ? "Save changes" : "Add server"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </Modal>
  );
}

function McpServerRow({
  server,
  onEdit,
  onRemove,
}: {
  server: McpServer;
  onEdit: () => void;
  onRemove: () => void;
}) {
  const location = server.transport.type === "streamable_http"
    ? server.transport.endpoint
    : server.transport.executable;
  const kind = server.transport.type === "streamable_http" ? "HTTP" : "stdio";
  const argumentCount = server.transport.type === "stdio" && server.transport.arguments.length
    ? ` · ${server.transport.arguments.length} arg${server.transport.arguments.length === 1 ? "" : "s"}`
    : "";
  const bindings = server.transport.type === "streamable_http"
    ? server.transport.headers
    : server.transport.environment;
  const bindingCount = bindings.length
    ? ` · ${bindings.length} binding${bindings.length === 1 ? "" : "s"}`
    : "";
  return (
    <div className="flex items-start justify-between gap-[10px] p-[11px] not-first:border-t not-first:border-line-soft">
      <div className="min-w-0">
        <strong className="block text-[11px]">{server.id}</strong>
        <small className="mt-1 block text-[9px] text-faint">
          {kind} · {new Intl.NumberFormat().format(server.timeout_milliseconds)} ms
          {argumentCount}{bindingCount}
        </small>
        <code className="mt-[7px] block truncate text-[9px] text-muted" title={location}>{location}</code>
      </div>
      <div className="flex shrink-0 items-center gap-1.5">
        <button
          className={`${smallGhostButton} py-[5px]`}
          type="button"
          aria-label={`Edit ${server.id}`}
          onClick={onEdit}
        >
          Edit
        </button>
        <button
          className={`${dangerIconButton} size-[26px] text-base`}
          type="button"
          aria-label={`Remove ${server.id}`}
          onClick={onRemove}
        >
          ×
        </button>
      </div>
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
  const [showValue, setShowValue] = useState(false);

  function updateValue(update: Partial<BindingValue>) {
    onChange((current) => ({
      ...current,
      value: { ...current.value, ...update },
    }));
  }

  return (
    <div className="grid grid-cols-[minmax(0,.8fr)_minmax(0,1fr)_minmax(0,1fr)_42px_30px] gap-1.5 max-[650px]:grid-cols-[1fr_1fr_42px_30px]">
      <input
        className={`${control} min-w-0 p-2 text-[10px]`}
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
        className={`${control} min-w-0 p-2 text-[10px]`}
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
        className={`${control} min-w-0 p-2 text-[10px] max-[650px]:col-span-2 max-[650px]:row-start-2`}
        aria-label="Binding value"
        type={binding.value.type === "literal" && !showValue ? "password" : "text"}
        value={binding.value.value}
        onChange={(event) => updateValue({ value: event.target.value })}
        placeholder={binding.value.type === "literal"
          ? "Stored plaintext value"
          : "VARIABLE_NAME"}
        required
      />
      {binding.value.type === "literal" ? (
        <button
          className="rounded-[7px] border border-line bg-transparent px-1 text-[9px] text-muted hover:border-[#3a4248] hover:bg-panel-2 hover:text-ink max-[650px]:col-start-3 max-[650px]:row-start-2"
          type="button"
          aria-pressed={showValue}
          onClick={() => setShowValue((shown) => !shown)}
        >
          {showValue ? "Hide" : "Show"}
        </button>
      ) : <span className="max-[650px]:col-start-3 max-[650px]:row-start-2" aria-hidden="true" />}
      <button
        className={`${iconButton} text-base max-[650px]:col-start-4 max-[650px]:row-start-2`}
        type="button"
        aria-label="Remove binding"
        onClick={onRemove}
      >
        ×
      </button>
    </div>
  );
}

function editableBindings(bindings: Binding[]): EditableBinding[] {
  return bindings.map((binding) => ({ ...binding, key: bindingKey() }));
}

function bindingKey(): number {
  nextBindingKey += 1;
  return nextBindingKey;
}
