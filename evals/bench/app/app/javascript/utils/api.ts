export class ApiError extends Error {
  constructor(public status: number, message: string, public details?: string[]) {
    super(message);
  }
}

export interface PagedResponse<T> {
  items: T[];
  total: number;
  nextPage: number | null;
}

function token(): string | null {
  return window.localStorage.getItem("tasker.api_key");
}

async function request<T>(method: string, path: string, body?: unknown): Promise<Response> {
  const response = await fetch(`/api/v1${path}`, {
    method,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token() ?? ""}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({ error: { message: response.statusText } }));
    throw new ApiError(response.status, payload.error?.message ?? response.statusText, payload.error?.details);
  }
  return response;
}

export async function get<T>(path: string): Promise<T> {
  return (await request<T>("GET", path)).json();
}

export async function getPaged<T>(path: string): Promise<PagedResponse<T>> {
  const response = await request<T>("GET", path);
  const next = response.headers.get("X-Next-Cursor");
  return {
    items: await response.json(),
    total: Number(response.headers.get("X-Total-Count") ?? 0),
    nextPage: next ? Number(next) : null,
  };
}

export async function post<T>(path: string, body?: unknown): Promise<T> {
  const response = await request<T>("POST", path, body);
  return response.status === 204 ? (undefined as T) : response.json();
}

export async function patch<T>(path: string, body: unknown): Promise<T> {
  return (await request<T>("PATCH", path, body)).json();
}

export async function destroy(path: string): Promise<void> {
  await request<void>("DELETE", path);
}
