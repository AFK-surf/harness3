const state = {
  models: [],
  mcpConfigurations: [],
  sessions: [],
  current: null,
  selectedAgent: null,
  workspaceRoot: "",
  poll: null,
  sessionRefreshTick: 0,
};

const $ = (selector) => document.querySelector(selector);
const sessionList = $("#session-list");
const emptyState = $("#empty-state");
const workspace = $("#workspace");
const dialog = $("#new-session-dialog");
const newForm = $("#new-session-form");
const messageForm = $("#message-form");

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: options.body ? { "content-type": "application/json", ...(options.headers || {}) } : options.headers,
  });
  let body = {};
  try { body = await response.json(); } catch (_) { /* handled below */ }
  if (!response.ok) throw new Error(body.error || `Request failed (${response.status})`);
  return body;
}

function escapeHtml(value = "") {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function number(value) {
  return new Intl.NumberFormat().format(value || 0);
}

function toast(message, error = false) {
  const element = $("#toast");
  element.textContent = message;
  element.className = `toast visible${error ? " error" : ""}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { element.className = "toast"; }, 3500);
}

async function connect() {
  try {
    const health = await api("/api/health");
    $("#connection-dot").className = "connection-dot online";
    $("#connection-label").textContent = "Server online";
    $("#workspace-root").textContent = health.workspace_root;
    state.workspaceRoot = health.workspace_root;
    if (!$("#workspace-input").value) $("#workspace-input").value = health.workspace_root;
  } catch (error) {
    $("#connection-dot").className = "connection-dot offline";
    $("#connection-label").textContent = "Server unavailable";
    toast(error.message, true);
  }
}

async function loadModels() {
  const body = await api("/api/models");
  state.models = body.models;
  const select = $("#model-select");
  select.innerHTML = state.models.map((model) =>
    `<option value="${escapeHtml(model.id)}">${escapeHtml(model.name)}</option>`
  ).join("");
}

async function loadMcpConfigurations() {
  const body = await api("/api/mcp/configurations");
  state.mcpConfigurations = body.configurations.filter((configuration) => configuration.enabled);
  const select = $("#mcp-configuration-select");
  const options = state.mcpConfigurations.map((configuration) =>
    `<option value="${escapeHtml(configuration.id)}">${escapeHtml(configuration.label)} · ${configuration.tool_count} tools</option>`
  );
  if (!options.length) options.push(`<option value="">No MCP configuration installed</option>`);
  select.innerHTML = options.join("");
  updateTeamPreview();
}

async function loadSessions(selectFirst = false) {
  const body = await api("/api/sessions");
  state.sessions = body.sessions;
  renderSessionList();
  if (selectFirst && !state.current && state.sessions.length) {
    await selectSession(state.sessions[0].id);
  }
}

function renderSessionList() {
  if (!state.sessions.length) {
    sessionList.innerHTML = `<div class="thread-empty">No sessions yet</div>`;
    return;
  }
  sessionList.innerHTML = state.sessions.map((session) => {
    const status = session.execution.status;
    const isActive = state.current?.id === session.id;
    const rounds = session.agents.reduce((sum, agent) => sum + agent.round, 0);
    return `<button class="session-item${isActive ? " active" : ""}" data-session="${escapeHtml(session.id)}">
      <strong>${escapeHtml(session.title)}</strong>
      <small><span class="mini-dot ${escapeHtml(status)}"></span>${escapeHtml(status)} · ${rounds} round${rounds === 1 ? "" : "s"}</small>
    </button>`;
  }).join("");
  sessionList.querySelectorAll("[data-session]").forEach((button) => {
    button.addEventListener("click", () => selectSession(button.dataset.session));
  });
}

async function selectSession(id) {
  try {
    state.current = await api(`/api/sessions/${encodeURIComponent(id)}`);
    if (!state.current.agents.some((agent) => agent.id === state.selectedAgent)) {
      state.selectedAgent = state.current.agents[0]?.id || null;
    }
    emptyState.classList.add("hidden");
    workspace.classList.remove("hidden");
    renderSessionList();
    renderCurrent(true);
  } catch (error) {
    toast(error.message, true);
  }
}

function renderCurrent(forceScroll = false) {
  const session = state.current;
  if (!session) return;
  $("#session-short-id").textContent = session.id.replace("session-", "").slice(0, 8);
  $("#session-title").textContent = session.title;
  $("#session-model").textContent = modelName(session.model_id);
  $("#session-workspace").textContent = session.workspace;
  const status = $("#session-status");
  status.textContent = session.execution.status;
  status.className = `status-pill ${session.execution.status}`;
  renderTeam();
  renderThread(forceScroll);
  renderUsage();
}

function modelName(id) {
  return state.models.find((model) => model.id === id)?.name || id;
}

function renderTeam() {
  const session = state.current;
  $("#team-count").textContent = `${session.agents.length} total`;
  $("#team-list").innerHTML = session.agents.map((agent) => {
    const tokens = agent.stats.input_tokens + agent.stats.output_tokens;
    return `<button class="agent-card${state.selectedAgent === agent.id ? " active" : ""}" data-agent="${escapeHtml(agent.id)}">
      <div class="agent-card-top">
        <span class="avatar">${escapeHtml(agent.id.slice(0, 1).toUpperCase())}</span>
        <strong>${escapeHtml(agent.id)}</strong>
        <span class="agent-status ${escapeHtml(agent.status)}">${escapeHtml(agent.status)}</span>
      </div>
      <p>${escapeHtml(agent.role)}</p>
      <div class="agent-card-footer"><span>${agent.kind === "mcp" ? "MCP specialist" : `round ${agent.round}`}</span><span>${number(tokens)} tokens</span>${agent.pending_messages ? `<span>${agent.pending_messages} queued</span>` : ""}</div>
    </button>`;
  }).join("");
  $("#team-list").querySelectorAll("[data-agent]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedAgent = button.dataset.agent;
      renderTeam();
      renderThread(true);
    });
  });

  const select = $("#target-agent");
  select.innerHTML = session.agents.map((agent) =>
    `<option value="${escapeHtml(agent.id)}"${agent.id === state.selectedAgent ? " selected" : ""}>${escapeHtml(agent.id)} · ${escapeHtml(agent.status)}</option>`
  ).join("");
}

function renderThread(forceScroll = false) {
  const agent = state.current.agents.find((item) => item.id === state.selectedAgent);
  if (!agent) return;
  $("#thread-title").textContent = `${agent.id} · round ${agent.round}`;
  const thread = $("#thread");
  const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 100;
  const visible = agent.messages.filter((message) => message.role !== "system" && message.role !== "developer");
  thread.innerHTML = visible.length
    ? visible.map((message) => messageHtml(message, agent.id)).join("") + failureHtml(agent)
    : `<div class="thread-empty">Send the first message below to start ${escapeHtml(agent.id)}.</div>`;
  if (forceScroll || nearBottom) thread.scrollTop = thread.scrollHeight;
}

function messageHtml(message, agentId) {
  const roleClass = message.role === "tool" ? "tool" : message.role;
  const label = message.role === "assistant" ? agentId : message.role === "tool" ? "Tool result" : "Instruction";
  const avatar = message.role === "assistant" ? agentId.slice(0, 1).toUpperCase() : message.role === "tool" ? "T" : "U";
  return `<article class="message ${escapeHtml(roleClass)}">
    <div class="message-head"><span class="avatar">${escapeHtml(avatar)}</span><span>${escapeHtml(label)}</span></div>
    <div class="message-body">${message.content.map(contentHtml).join("")}</div>
  </article>`;
}

function contentHtml(content) {
  if (content.type === "text") {
    return `<div class="content-block"><pre>${escapeHtml(content.text)}</pre></div>`;
  }
  if (content.type === "reasoning") {
    return `<details class="content-block reasoning"><summary>Reasoning summary${content.encrypted ? " · encrypted state retained" : ""}</summary><pre>${escapeHtml(content.summary.join("\n"))}</pre></details>`;
  }
  if (content.type === "tool_call") {
    return `<details class="content-block tool-block"><summary>Called ${escapeHtml(content.name)}</summary><pre>${escapeHtml(JSON.stringify(content.arguments, null, 2))}</pre></details>`;
  }
  if (content.type === "tool_result") {
    const output = content.content.map((item) => item.text || JSON.stringify(item)).join("\n");
    return `<details class="content-block tool-block${content.is_error ? " error" : ""}" open><summary>${content.is_error ? "Tool error" : "Tool output"}</summary><pre>${escapeHtml(output)}</pre></details>`;
  }
  if (content.type === "image") return `<div class="content-block">[image · ${escapeHtml(content.detail)}]</div>`;
  if (content.type === "document") return `<div class="content-block">[document]</div>`;
  return `<div class="content-block"><pre>${escapeHtml(JSON.stringify(content, null, 2))}</pre></div>`;
}

function failureHtml(agent) {
  return agent.failure ? `<div class="message"><div class="message-body"><div class="failure-card">${escapeHtml(agent.failure)}</div></div></div>` : "";
}

function renderUsage() {
  const total = state.current.agents.reduce((stats, agent) => {
    stats.input += agent.stats.input_tokens;
    stats.output += agent.stats.output_tokens;
    stats.cache += agent.stats.cache_read_tokens;
    return stats;
  }, { input: 0, output: 0, cache: 0 });
  $("#usage-total").textContent = number(total.input + total.output);
  $("#usage-input").textContent = number(total.input);
  $("#usage-output").textContent = number(total.output);
  $("#usage-cache").textContent = number(total.cache);
}

function openNewSession() {
  if (!state.models.length) {
    toast("No supported Pi models were loaded.", true);
    return;
  }
  dialog.showModal();
  setTimeout(() => $("#workspace-input").focus(), 30);
}

async function createSession() {
  const button = $("#create-button");
  button.disabled = true;
  button.textContent = "Creating team…";
  try {
    const session = await api("/api/sessions", {
      method: "POST",
      body: JSON.stringify({
        model_id: $("#model-select").value,
        workspace: $("#workspace-input").value,
        team_size: Number($("#team-size").value),
        mcp_configuration_id: Number($("#team-size").value) >= 2
          ? $("#mcp-configuration-select").value || null
          : null,
      }),
    });
    dialog.close();
    newForm.reset();
    $("#workspace-input").value = state.workspaceRoot;
    $("#team-size").value = "3";
    updateTeamPreview();
    state.current = session;
    state.selectedAgent = session.agents[0]?.id;
    await loadSessions(false);
    emptyState.classList.add("hidden");
    workspace.classList.remove("hidden");
    renderCurrent(true);
    $("#message-input").focus();
    toast("Session ready. Send the first message to start an agent.");
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
    button.textContent = "Create session";
  }
}

async function sendMessage() {
  if (!state.current) return;
  const input = $("#message-input");
  const message = input.value.trim();
  if (!message) return;
  const button = messageForm.querySelector("button[type=submit]");
  button.disabled = true;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.current.id)}/messages`, {
      method: "POST",
      body: JSON.stringify({ agent_id: $("#target-agent").value, message }),
    });
    input.value = "";
    toast("Message queued durably.");
    await refreshCurrent(true);
    await loadSessions(false);
  } catch (error) {
    toast(error.message, true);
  } finally {
    button.disabled = false;
  }
}

async function stopSession() {
  if (!state.current || !confirm("Stop all currently running agents in this session? Durable state will be preserved.")) return;
  try {
    await api(`/api/sessions/${encodeURIComponent(state.current.id)}/stop`, { method: "POST" });
    toast("Team stopped; durable state was preserved.");
    await refreshCurrent();
  } catch (error) {
    toast(error.message, true);
  }
}

async function refreshCurrent(forceScroll = false) {
  if (!state.current) return;
  try {
    state.current = await api(`/api/sessions/${encodeURIComponent(state.current.id)}`);
    renderCurrent(forceScroll);
    state.sessionRefreshTick += 1;
    if (state.sessionRefreshTick % 4 === 0) await loadSessions(false);
    $("#connection-dot").className = "connection-dot online";
  } catch (error) {
    $("#connection-dot").className = "connection-dot offline";
    console.error(error);
  }
}

function updateTeamPreview() {
  const roles = ["lead", "researcher", "implementer", "reviewer"];
  const size = Number($("#team-size").value || 3);
  $("#mcp-configuration-select").disabled = size < 2 || !state.mcpConfigurations.length;
  $("#team-preview").innerHTML = roles.slice(0, size).map((role, index) =>
    `<span>○ ${index === 1 && $("#mcp-configuration-select").value ? "MCP specialist" : role} · on demand</span>`
  ).join("");
}

function bindEvents() {
  $("#new-session-button").addEventListener("click", openNewSession);
  $("#empty-new-button").addEventListener("click", openNewSession);
  $("#team-size").addEventListener("change", updateTeamPreview);
  $("#mcp-configuration-select").addEventListener("change", updateTeamPreview);
  $("#target-agent").addEventListener("change", (event) => {
    state.selectedAgent = event.target.value;
    renderTeam();
    renderThread(true);
  });
  $("#stop-button").addEventListener("click", stopSession);
  newForm.addEventListener("submit", (event) => {
    if (event.submitter?.value === "cancel") return;
    event.preventDefault();
    createSession();
  });
  messageForm.addEventListener("submit", (event) => {
    event.preventDefault();
    sendMessage();
  });
  $("#message-input").addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      messageForm.requestSubmit();
    }
  });
  document.addEventListener("keydown", (event) => {
    const typing = ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName);
    if (!typing && event.key.toLowerCase() === "n") openNewSession();
  });
}

async function init() {
  bindEvents();
  updateTeamPreview();
  try {
    await Promise.all([connect(), loadModels(), loadMcpConfigurations()]);
    await loadSessions(true);
  } catch (error) {
    toast(error.message, true);
  }
  state.poll = setInterval(() => refreshCurrent(), 1800);
}

init();
