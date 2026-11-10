const BASE = process.env.NEXT_PUBLIC_API_URL; // http://localhost:8000/api/v1

export type ApiError = {
  status: number;
  message: string;
  errors?: Record<string, string[]>; // Laravel validation errors
};

function getToken(): string | null {
  return typeof window !== "undefined" ? sessionStorage.getItem("token") : null;
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = getToken();

  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      ...(token && { Authorization: `Bearer ${token}` }),
      ...init.headers,
    },
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const error: ApiError = {
      status: res.status,
      message: body.message ?? res.statusText,
      errors: body.errors,
    };
    throw error;
  }

  if (res.status === 204) return undefined as T; // no content
  return res.json();
}