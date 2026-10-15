/** Environment-driven configuration shared by the stdio and HTTP entrypoints. */

export interface Config {
  apiUrl: string;
  apiKey: string | undefined;
  auditLog: string | undefined;
  port: number;
}

export const DEFAULT_API_URL = "https://metrics.3m4.net/api";

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    apiUrl: (env.METRICS_API_URL || DEFAULT_API_URL).replace(/\/+$/, ""),
    apiKey: env.METRICS_API_KEY?.trim() || undefined,
    auditLog: env.METRICS_AUDIT_LOG,
    port: Number(env.METRICS_MCP_PORT || 3333),
  };
}
