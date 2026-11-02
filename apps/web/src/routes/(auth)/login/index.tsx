import type { RequestHandler } from "@builder.io/qwik-city";

/**
 * Login lives at accounts.3m4.net (one identity for every 3m4 app). This
 * route only exists so old links and the Caddy matchers keep working: it
 * bounces to the hosted page and asks to come back to the dashboard.
 */
export const onGet: RequestHandler = ({ redirect, url, env }) => {
  const accounts = (env.get("ACCOUNTS_URL") || process.env.ACCOUNTS_URL || "http://localhost:8085").replace(/\/$/, "");
  const requested = url.searchParams.get("return_to") || "";
  // Only our own origin may be a return target; anything else goes to the dashboard.
  const back = requested.startsWith(url.origin) ? requested : `${url.origin}/dashboard`;
  // Language continuity: `?lang=` (the app's `3m4.lang`) is forwarded so the
  // hosted page opens in the same language; accounts ignores unknown values.
  const lang = url.searchParams.get("lang") || "";
  const langParam = /^[a-z]{2}(-[A-Z]{2})?$/.test(lang) ? `&lang=${encodeURIComponent(lang)}` : "";
  throw redirect(302, `${accounts}/login?return_to=${encodeURIComponent(back)}${langParam}`);
};
