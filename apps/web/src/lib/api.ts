/**
 * API client for the metrics Flask backend.
 *
 * - Base URL from VITE_API_URL (fallback "/api" — works behind Caddy).
 * - Credentials included: the accounts `3m4_session` cookie IS the login
 *   (no bearer tokens in the browser).
 * - On `401 session_expired` it refreshes once against accounts and retries;
 *   on `401 no_session` / `invalid_session` it sends the visitor to the hosted
 *   login page and rejects.
 *
 * Throws `ApiRequestError` (carrying the parsed `error` body + HTTP status) so
 * callers can branch on e.g. 402 limit_reached (`error.which`) or
 * 403 email_unverified.
 */
import { loginUrl, session } from "./auth";
import type {
  ApiError,
  ApiKey,
  ApiKeyRole,
  AuditEvent,
  Breakdown,
  Dimension,
  EventKind,
  EventsPage,
  Live,
  MeResponse,
  Project,
  ProjectPatch,
  RolesResponse,
  Stats,
  StatsQuery,
  Summary,
  Usage,
} from "./types";

const BASE = (import.meta.env.VITE_API_URL || "/api").replace(/\/$/, "");

export class ApiRequestError extends Error {
  status: number;
  error: ApiError;
  constructor(status: number, error: ApiError) {
    super(error?.message || `Request failed (${status})`);
    this.name = "ApiRequestError";
    this.status = status;
    this.error = error;
  }
  get isUnverified(): boolean {
    return this.status === 403 && this.error?.code === "email_unverified";
  }
}

interface RequestOptions {
  method?: string;
  body?: unknown;
  /** Public endpoint: a missing session must not trigger the login redirect. */
  auth?: boolean;
  headers?: Record<string, string>;
}

async function parseError(res: Response): Promise<ApiError> {
  try {
    const data = await res.json();
    if (data?.error) return data.error as ApiError;
    return { code: "error", message: data?.message || res.statusText };
  } catch {
    return { code: "error", message: res.statusText || "Request failed" };
  }
}

async function rawFetch(path: string, opts: RequestOptions = {}): Promise<Response> {
  const { method = "GET", body, auth = true, headers: extra = {} } = opts;

  const headers: Record<string, string> = { ...extra };
  if (body !== undefined) headers["Content-Type"] = "application/json";

  // fetchWithSession: credentials included + one transparent refresh on
  // `401 session_expired`.
  const res = await session.fetchWithSession(`${BASE}${path}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (!res.ok) {
    const error = await parseError(res);
    if (res.status === 401 && auth && typeof location !== "undefined") {
      // No usable session (none, invalid, or the refresh failed): go log in.
      session.invalidate();
      location.assign(loginUrl());
    }
    throw new ApiRequestError(res.status, error);
  }
  return res;
}

export async function apiFetch<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const res = await rawFetch(path, opts);
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

/** Build a query string from defined, non-empty values. */
function qs(params: Record<string, string | number | boolean | undefined>): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === "") continue;
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
  }
  return parts.length ? `?${parts.join("&")}` : "";
}

function statsParams(query: StatsQuery = {}): Record<string, string | number | undefined> {
  return {
    period: query.from || query.to ? undefined : query.period,
    from: query.from,
    to: query.to,
    tz: query.tz,
    interval: query.interval,
    limit: query.limit,
    ...(query.filters ?? {}),
  };
}

const enc = encodeURIComponent;
const p = (id: string) => `/projects/${enc(id)}`;

export const api = {
  /* ─── Auth (identity lives at accounts.3m4.net; this is the tenant view) ── */
  me: () => apiFetch<MeResponse>("/auth/me"),

  /* ─── Features (metrics' own switches; public, used by anonymous pages) ── */
  features: () => apiFetch<{ features: Record<string, boolean> }>("/features", { auth: false }),

  /* ─── Projects ───────────────────────────────────────────────────────── */
  listProjects: (q = "") => apiFetch<{ items: Project[]; total: number }>(`/projects${qs({ q })}`),

  createProject: (input: { name: string; key?: string; description?: string; url?: string; timezone?: string }) =>
    apiFetch<Project>("/projects", { method: "POST", body: input }),

  getProject: (id: string) => apiFetch<Project>(p(id)),

  updateProject: (id: string, input: ProjectPatch) =>
    apiFetch<Project>(p(id), { method: "PATCH", body: input }),

  deleteProject: (id: string) => apiFetch<void>(p(id), { method: "DELETE" }),

  rotateProjectKey: (id: string) =>
    apiFetch<{ public_key: string; public_key_prefix: string }>(`${p(id)}/rotate-key`, { method: "POST" }),

  projectSummary: (id: string) => apiFetch<Summary>(`${p(id)}/summary`),

  purgeEvents: (id: string, before?: string) =>
    apiFetch<{ deleted: number; before: string | null }>(`${p(id)}/events${qs({ before })}`, { method: "DELETE" }),

  /* ─── Stats ──────────────────────────────────────────────────────────── */
  stats: (id: string, query: StatsQuery = {}) => apiFetch<Stats>(`${p(id)}/stats${qs(statsParams(query))}`),

  breakdown: (id: string, by: Dimension, query: StatsQuery = {}, page = 1, per_page = 50) =>
    apiFetch<Breakdown>(`${p(id)}/stats/breakdown${qs({ ...statsParams(query), by, page, per_page })}`),

  events: (id: string, query: StatsQuery = {}, opts: { page?: number; per_page?: number; kind?: EventKind | ""; q?: string } = {}) =>
    apiFetch<EventsPage>(
      `${p(id)}/events${qs({ ...statsParams(query), page: opts.page ?? 1, per_page: opts.per_page ?? 50, kind: opts.kind, q: opts.q })}`,
    ),

  live: (id: string) => apiFetch<Live & { project_id: string }>(`${p(id)}/live`),

  /* ─── Account ────────────────────────────────────────────────────────── */
  usage: () => apiFetch<Usage>("/account/usage"),

  audit: (limit = 50, action = "") =>
    apiFetch<{ items: AuditEvent[]; limit: number }>(`/account/audit${qs({ limit, action })}`),

  /* ─── API keys ───────────────────────────────────────────────────────── */
  listApiKeys: () => apiFetch<ApiKey[]>("/apikeys"),

  apiKeyRoles: () => apiFetch<RolesResponse>("/apikeys/roles", { auth: false }),

  createApiKey: (name: string, role: ApiKeyRole = "editor") =>
    apiFetch<{ id: string; key: string; prefix: string; name: string; role: ApiKeyRole }>("/apikeys", {
      method: "POST",
      body: { name, role },
    }),

  deleteApiKey: (id: string) => apiFetch<void>(`/apikeys/${enc(id)}`, { method: "DELETE" }),

  /* ─── Billing ────────────────────────────────────────────────────────── */
  billingOfferings: () => apiFetch<unknown>("/billing/offerings"),
};

/** Public base URL of the API, for docs snippets (e.g. curl examples). */
export const API_PUBLIC_BASE = BASE;
