export interface HealthResponse {
  ok: boolean;
  workspace_root: string;
}

export interface Model {
  id: string;
  provider_id: string;
  name: string;
  remote_id: string;
  endpoint: string;
  type: "openai_chat_completions" | "openai_responses" | "anthropic_messages";
  context_window_tokens: number;
  max_tokens: number | null;
}

export interface ModelsResponse {
  models: Model[];
}

export interface BindingValue {
  type: "environment_variable" | "literal";
  value: string;
}

export interface Binding {
  name: string;
  value: BindingValue;
}

export interface HttpMcpTransport {
  type: "streamable_http";
  endpoint: string;
  headers: Binding[];
}

export interface StdioMcpTransport {
  type: "stdio";
  executable: string;
  arguments: string[];
  working_directory: string | null;
  environment: Binding[];
}

export type McpTransport = HttpMcpTransport | StdioMcpTransport;

export interface McpServer {
  id: string;
  timeout_milliseconds: number;
  transport: McpTransport;
}

export interface McpConfiguration {
  id: string;
  label: string;
  enabled: boolean;
  server_count: number;
  servers: McpServer[];
}

export interface McpConfigurationsResponse {
  configurations: McpConfiguration[];
}

export interface TextContent {
  type: "text";
  text: string;
}

export interface ReasoningContent {
  type: "reasoning";
  summary: string[];
  encrypted: boolean;
}

export interface ToolCallContent {
  type: "tool_call";
  id: string;
  name: string;
  arguments: unknown;
}

export interface ToolResultContent {
  type: "tool_result";
  id: string;
  is_error: boolean;
  content: MessageContent[];
}

export interface ImageContent {
  type: "image";
  detail: "auto" | "low" | "high";
  source: unknown;
}

export interface DocumentContent {
  type: "document";
  source: unknown;
}

export type MessageContent =
  | TextContent
  | ReasoningContent
  | ToolCallContent
  | ToolResultContent
  | ImageContent
  | DocumentContent;

export interface Message {
  role: "system" | "developer" | "user" | "assistant" | "tool";
  content: MessageContent[];
}

export interface TokenStats {
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
}

export interface CompactionState {
  requested: number;
  completed: number;
  pending: boolean;
  error: string | null;
  context_tokens: number | null;
}

export interface Agent {
  id: string;
  role: string;
  kind: "coding" | "researcher" | "mcp";
  status: "ready" | "waiting" | "completed" | "failed";
  failure: string | null;
  round: number;
  revision: number;
  model_id: string;
  pending_messages: number;
  compaction: CompactionState;
  stats: TokenStats;
  messages: Message[];
}

export type Execution =
  | { status: "idle" }
  | { status: "completed" }
  | {
      status: "running";
      owner: string;
      epoch: number;
      lease_expires_at: number;
    };

export interface Session {
  id: string;
  title: string;
  prompt: string;
  workspace: string;
  cloud_storage_workspace: string | null;
  created_at: number;
  revision: number;
  execution: Execution;
  agents: Agent[];
}

export interface SessionsResponse {
  sessions: Session[];
}

export interface CloudStorageWorkspace {
  id: string;
  label: string;
  prefix: string;
}

export interface CloudStorageWorkspacesResponse {
  workspaces: CloudStorageWorkspace[];
}

export interface CloudStorageWorkspaceInput {
  id: string;
  label: string;
  prefix: string;
}

export interface UpdateCloudStorageWorkspaceInput {
  label: string;
  prefix: string;
}

export interface CreateSessionInput {
  model_id: string;
  workspace: string;
  team_size: number;
  cloud_storage_workspace_id: string | null;
}

export interface UpdateAgentInput {
  id: string;
  role: string;
  kind: Agent["kind"];
  model_id: string;
}

export interface UpdateSessionInput {
  name: string;
  agents: UpdateAgentInput[];
  cloud_storage_workspace_id: string | null;
}

export type AddMcpTransport =
  | {
      type: "streamable_http";
      endpoint: string;
      headers: Binding[];
    }
  | {
      type: "stdio";
      executable: string;
      arguments: string[];
      working_directory: string | null;
      environment: Binding[];
    };

export interface AddMcpServerInput {
  configuration_id: string;
  configuration_label: string;
  server: {
    id: string;
    timeout_milliseconds: number;
    transport: AddMcpTransport;
  };
}

export interface UpdateMcpServerInput {
  server: AddMcpServerInput["server"];
}

export interface CompactionResponse {
  ok: boolean;
  generation: number;
}
