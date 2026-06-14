/**
 * denizens — private email-intake Worker for devis.im.
 *
 * Flow (POST):
 *   1. validate { name, email, turnstileToken, code }
 *   2. verify the Turnstile token server-side
 *   3. confirm the name is actually merged + email-enabled by fetching the public
 *      domain file from raw.githubusercontent.com (also reads owner.github)
 *   4. prove ownership: exchange the GitHub OAuth code, read the signed-in login,
 *      and require it to equal the file's owner.github — you can only set up
 *      forwarding for a name your own GitHub account claimed
 *   5. create a VERIFIED destination address (idempotent) — Cloudflare emails the
 *      user a verification link they must click; this also proves inbox control
 *   6. upsert the routing rule name@devis.im -> forward (idempotent)
 *   7. return "check your inbox" — STORE NOTHING
 *
 * The forwarding address and the OAuth token are never logged, echoed, or persisted.
 */

export interface Env {
  // secrets (wrangler secret put ...)
  CF_API_TOKEN: string;
  CF_ACCOUNT_ID: string;
  CF_ZONE_ID: string;
  TURNSTILE_SECRET: string;
  GH_CLIENT_SECRET: string; // GitHub OAuth App client secret
  // vars (wrangler.toml [vars])
  ZONE_NAME: string;
  GH_RAW_BASE: string; // e.g. https://raw.githubusercontent.com/cdrrazan/denizens/main/domains
  GH_CLIENT_ID: string; // GitHub OAuth App client id (public)
  ALLOWED_ORIGIN: string; // the Pages form origin, e.g. https://claim.devis.im
}

const NAME_RE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const CF_API = "https://api.cloudflare.com/client/v4";

interface CfResult<T = unknown> {
  success: boolean;
  errors?: Array<{ code: number; message: string }>;
  result?: T;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const cors = corsHeaders(env);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (request.method !== "POST") {
      return json({ ok: false, error: "Method not allowed." }, 405, cors);
    }

    let body: { name?: string; email?: string; turnstileToken?: string; code?: string };
    try {
      body = await parseBody(request);
    } catch {
      return json({ ok: false, error: "Invalid request body." }, 400, cors);
    }

    const name = (body.name || "").trim().toLowerCase();
    const email = (body.email || "").trim();
    const token = body.turnstileToken || "";
    const code = (body.code || "").trim();

    if (!NAME_RE.test(name) || name.length > 63) {
      return json({ ok: false, error: "Invalid name." }, 400, cors);
    }
    if (!EMAIL_RE.test(email)) {
      return json({ ok: false, error: "Invalid email address." }, 400, cors);
    }
    if (!token) {
      return json({ ok: false, error: "Missing Turnstile token." }, 400, cors);
    }
    if (!code) {
      return json({ ok: false, error: "Sign in with GitHub to prove you own this name." }, 401, cors);
    }

    // 2. Turnstile.
    const ip = request.headers.get("CF-Connecting-IP") || undefined;
    if (!(await verifyTurnstile(env, token, ip))) {
      return json({ ok: false, error: "Turnstile verification failed." }, 403, cors);
    }

    // 3. Confirm the claim is merged and email-enabled.
    const claim = await fetchClaim(env, name);
    if (!claim.ok || !claim.owner) {
      return json(
        { ok: false, error: "That name isn't a merged claim with email enabled yet." },
        404,
        cors,
      );
    }

    // 4. Prove ownership: the signed-in GitHub login must match the file's owner.
    let login: string;
    try {
      login = await githubLogin(env, code);
    } catch (e) {
      console.error(`github oauth failed for ${name}: ${(e as Error).message}`);
      return json({ ok: false, error: "GitHub sign-in failed. Please try again." }, 502, cors);
    }
    if (login.toLowerCase() !== claim.owner.toLowerCase()) {
      return json(
        { ok: false, error: "This name belongs to a different GitHub account." },
        403,
        cors,
      );
    }

    try {
      // 5. Destination address (idempotent) — a brand-new one triggers Cloudflare's
      //    verification email. The forward rule below can only attach to a *verified*
      //    destination, so a freshly-created address is not ready on this submit.
      const dest = await ensureDestinationAddress(env, email);
      if (!dest.verified) {
        return json(
          {
            ok: true,
            pending: true,
            message:
              "Almost there — Cloudflare just emailed you a verification link. Click it, then submit this form again to finish. Forwarding goes live on that second submit.",
          },
          200,
          cors,
        );
      }
      // 6. Destination is verified — create/update the routing rule (idempotent).
      await upsertRoutingRule(env, name, email);
    } catch (e) {
      // Never surface internals or the address; log without the email.
      console.error(`provisioning failed for ${name}: ${(e as Error).message}`);
      return json({ ok: false, error: "Could not set up forwarding. Please try again later." }, 502, cors);
    }

    return json(
      {
        ok: true,
        message: `Done — mail sent to ${name}@${env.ZONE_NAME} now forwards to your inbox.`,
      },
      200,
      cors,
    );
  },
};

// --- helpers ---------------------------------------------------------------

function corsHeaders(env: Env): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN || "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Content-Type": "application/json",
  };
}

function json(payload: unknown, status: number, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(payload), { status, headers });
}

async function parseBody(request: Request): Promise<Record<string, string>> {
  const ct = request.headers.get("Content-Type") || "";
  if (ct.includes("application/json")) {
    return (await request.json()) as Record<string, string>;
  }
  const form = await request.formData();
  const out: Record<string, string> = {};
  for (const [k, v] of form.entries()) out[k] = String(v);
  // Turnstile's default field name.
  if (out["cf-turnstile-response"] && !out.turnstileToken) {
    out.turnstileToken = out["cf-turnstile-response"];
  }
  return out;
}

async function verifyTurnstile(env: Env, token: string, ip?: string): Promise<boolean> {
  const form = new FormData();
  form.append("secret", env.TURNSTILE_SECRET);
  form.append("response", token);
  if (ip) form.append("remoteip", ip);
  const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: form,
  });
  const data = (await res.json()) as { success: boolean };
  return data.success === true;
}

async function fetchClaim(env: Env, name: string): Promise<{ ok: boolean; owner?: string }> {
  const res = await fetch(`${env.GH_RAW_BASE}/${name}.json`, {
    headers: { "User-Agent": "denizens-email-intake" },
  });
  if (res.status !== 200) return { ok: false };
  try {
    const data = (await res.json()) as {
      email?: { enabled?: boolean };
      owner?: { github?: string };
    };
    return { ok: data?.email?.enabled === true, owner: data?.owner?.github };
  } catch {
    return { ok: false };
  }
}

/**
 * Exchange a GitHub OAuth code for the signed-in user's login. Throws when the
 * code can't be exchanged or the profile can't be read — the caller maps that to
 * a "sign-in failed" response, distinct from a successful login that simply
 * doesn't own the name. The access token is used once to read the public profile
 * and then discarded — never logged, never stored. We request no scopes, so the
 * token only ever sees public profile data.
 */
async function githubLogin(env: Env, code: string): Promise<string> {
  const tokenRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      client_id: env.GH_CLIENT_ID,
      client_secret: env.GH_CLIENT_SECRET,
      code,
    }),
  });
  const tokenData = (await tokenRes.json()) as { access_token?: string; error?: string };
  const accessToken = tokenData.access_token;
  if (!accessToken) throw new Error("oauth code exchange failed");

  const userRes = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "User-Agent": "denizens-email-intake",
      Accept: "application/vnd.github+json",
    },
  });
  if (userRes.status !== 200) throw new Error("github user lookup failed");
  const user = (await userRes.json()) as { login?: string };
  if (!user.login) throw new Error("github user has no login");
  return user.login;
}

async function cf<T = unknown>(
  env: Env,
  method: string,
  path: string,
  body?: unknown,
): Promise<CfResult<T>> {
  const res = await fetch(`${CF_API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env.CF_API_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  return (await res.json()) as CfResult<T>;
}

/**
 * Ensure a destination address exists and report whether it is verified.
 *
 * A freshly-created address is unverified — Cloudflare emails the user a
 * verification link, and a forward rule cannot attach until they click it. So
 * we return the verification state and let the caller decide: defer the rule
 * (new address) or create it (already verified). Idempotent: an existing
 * address is found via the list rather than re-created.
 */
async function ensureDestinationAddress(env: Env, email: string): Promise<{ verified: boolean }> {
  const created = await cf(env, "POST", `/accounts/${env.CF_ACCOUNT_ID}/email/routing/addresses`, {
    email,
  });
  // A successful create is always a brand-new, not-yet-verified address.
  if (created.success) return { verified: false };

  // Already exists (or the create errored) — list to confirm presence and read
  // the verification state. Never trust the error text alone.
  const list = await cf<Array<{ email: string; verified?: string | null }>>(
    env,
    "GET",
    `/accounts/${env.CF_ACCOUNT_ID}/email/routing/addresses?per_page=50`,
  );
  const found =
    list.success ? (list.result || []).find((a) => a.email.toLowerCase() === email.toLowerCase()) : undefined;
  if (!found) throw new Error("destination address create failed");

  // Cloudflare sets `verified` to a timestamp once confirmed, null/absent otherwise.
  return { verified: found.verified != null };
}

interface RoutingRule {
  tag?: string;
  id?: string;
  matchers?: Array<{ type: string; field: string; value: string }>;
}

/**
 * Upsert the routing rule  name@<zone> -> forward [email].  Idempotent:
 * updates the existing rule for this address rather than creating a duplicate.
 */
async function upsertRoutingRule(env: Env, name: string, email: string): Promise<void> {
  const alias = `${name}@${env.ZONE_NAME}`;
  const rule = {
    name: `denizens:${name}`,
    enabled: true,
    matchers: [{ type: "literal", field: "to", value: alias }],
    actions: [{ type: "forward", value: [email] }],
  };

  const list = await cf<RoutingRule[]>(env, "GET", `/zones/${env.CF_ZONE_ID}/email/routing/rules?per_page=100`);
  const existing = (list.result || []).find((r) =>
    (r.matchers || []).some((m) => m.field === "to" && m.value === alias),
  );

  if (existing) {
    const tag = existing.tag || existing.id;
    const updated = await cf(env, "PUT", `/zones/${env.CF_ZONE_ID}/email/routing/rules/${tag}`, rule);
    if (!updated.success) throw new Error("routing rule update failed");
  } else {
    const created = await cf(env, "POST", `/zones/${env.CF_ZONE_ID}/email/routing/rules`, rule);
    if (!created.success) throw new Error("routing rule create failed");
  }
}
