interface ApiErrorBody {
  error?: string;
}

export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body !== undefined && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }

  const response = await fetch(path, { ...init, headers });
  const body = await readJson(response);
  if (!response.ok) {
    const message = isApiErrorBody(body) && body.error
      ? body.error
      : `Request failed (${response.status})`;
    throw new ApiError(message, response.status);
  }
  return body as T;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function readJson(response: Response): Promise<unknown> {
  const text = await response.text();
  if (text.length === 0) return {};
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new ApiError("Server returned an invalid JSON response", response.status);
  }
}

function isApiErrorBody(value: unknown): value is ApiErrorBody {
  return typeof value === "object" && value !== null && "error" in value;
}
