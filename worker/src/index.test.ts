import { describe, it, expect, vi, beforeEach } from "vitest";
import worker, { type Env } from "./index";

const env: Env = {
  CF_API_TOKEN: "test-token-SHOULD-NOT-LEAK",
  CF_ACCOUNT_ID: "acct123",
  CF_ZONE_ID: "zone123",
  TURNSTILE_SECRET: "ts-secret",
  ZONE_NAME: "devis.im",
  GH_RAW_BASE: "https://raw.example/domains",
  ALLOWED_ORIGIN: "https://claim.devis.im",
};

interface Call { url: string; method: string; body?: string }
let calls: Call[];

/**
 * Install a fetch mock. `overrides` maps a URL substring to a responder so each
 * test can tweak one leg of the flow; everything else uses sane defaults.
 */
type Responder = (method: string) => Response;

function mockFetch(overrides: Record<string, Responder> = {}) {
  calls = [];
  const defaults: Array<[string, Responder]> = [
    ["turnstile/v0/siteverify", () => res({ success: true })],
    ["/domains/", () => res({ email: { enabled: true } })],
    ["/email/routing/addresses", () => res({ success: true, result: [] })],
    ["/email/routing/rules", () => res({ success: true, result: [] })],
  ];
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    const method = init?.method || "GET";
    calls.push({ url, method, body: init?.body as string | undefined });
    const key = Object.keys(overrides).find((k) => url.includes(k));
    if (key) return overrides[key](method);
    const def = defaults.find(([k]) => url.includes(k));
    if (def) return def[1](method);
    throw new Error(`unmocked ${method} ${url}`);
  }) as typeof fetch;
}

function res(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status });
}

function post(body: unknown): Request {
  return new Request("https://worker.test/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

const valid = { name: "rajan", email: "me@example.com", turnstileToken: "tok" };

beforeEach(() => mockFetch());

describe("method + CORS", () => {
  it("answers OPTIONS preflight with the locked origin", async () => {
    const r = await worker.fetch(new Request("https://worker.test/", { method: "OPTIONS" }), env);
    expect(r.status).toBe(204);
    expect(r.headers.get("Access-Control-Allow-Origin")).toBe(env.ALLOWED_ORIGIN);
  });

  it("rejects GET", async () => {
    const r = await worker.fetch(new Request("https://worker.test/"), env);
    expect(r.status).toBe(405);
  });
});

describe("input validation", () => {
  it("rejects a bad name", async () => {
    const r = await worker.fetch(post({ ...valid, name: "-bad" }), env);
    expect(r.status).toBe(400);
  });

  it("rejects a bad email", async () => {
    const r = await worker.fetch(post({ ...valid, email: "nope" }), env);
    expect(r.status).toBe(400);
  });

  it("rejects a missing turnstile token", async () => {
    const r = await worker.fetch(post({ ...valid, turnstileToken: "" }), env);
    expect(r.status).toBe(400);
  });
});

describe("turnstile", () => {
  it("rejects when verification fails", async () => {
    mockFetch({ "siteverify": () => res({ success: false }) });
    const r = await worker.fetch(post(valid), env);
    expect(r.status).toBe(403);
  });
});

describe("claim confirmation", () => {
  it("404s when the domain file is not merged", async () => {
    mockFetch({ "/domains/": () => res({}, 404) });
    const r = await worker.fetch(post(valid), env);
    expect(r.status).toBe(404);
  });

  it("404s when email is not enabled in the file", async () => {
    mockFetch({ "/domains/": () => res({ email: { enabled: false } }) });
    const r = await worker.fetch(post(valid), env);
    expect(r.status).toBe(404);
  });
});

describe("happy path", () => {
  it("creates the address + routing rule and returns check-your-inbox", async () => {
    const r = await worker.fetch(post(valid), env);
    const data = (await r.json()) as { ok: boolean; message: string };
    expect(r.status).toBe(200);
    expect(data.ok).toBe(true);
    expect(data.message).toMatch(/verification email/i);

    expect(calls.some((c) => c.method === "POST" && c.url.includes("/email/routing/addresses"))).toBe(true);
    expect(calls.some((c) => c.method === "POST" && c.url.includes("/email/routing/rules"))).toBe(true);
    // The forwarding rule body carries the address; that's the only place it appears.
    const ruleCall = calls.find((c) => c.method === "POST" && c.url.includes("/email/routing/rules"));
    expect(ruleCall?.body).toContain("rajan@devis.im");
    expect(ruleCall?.body).toContain("me@example.com");
  });

  it("never leaks the API token in any request URL", async () => {
    await worker.fetch(post(valid), env);
    expect(JSON.stringify(calls.map((c) => c.url))).not.toContain("test-token-SHOULD-NOT-LEAK");
  });
});

describe("idempotency", () => {
  it("treats an already-existing destination address as success", async () => {
    mockFetch({
      // POST create reports "already exists"; the GET list confirms it's present.
      "/email/routing/addresses": (method) =>
        method === "POST"
          ? res({ success: false, errors: [{ code: 1009, message: "exists" }] })
          : res({ success: true, result: [{ email: "me@example.com" }] }),
    });
    const r = await worker.fetch(post(valid), env);
    expect(r.status).toBe(200);
  });

  it("updates the existing routing rule instead of creating a duplicate", async () => {
    mockFetch({
      "/email/routing/rules": () =>
        res({
          success: true,
          result: [{ tag: "rule-9", matchers: [{ type: "literal", field: "to", value: "rajan@devis.im" }] }],
        }),
    });
    const r = await worker.fetch(post(valid), env);
    expect(r.status).toBe(200);
    expect(calls.some((c) => c.method === "PUT" && c.url.includes("/email/routing/rules/rule-9"))).toBe(true);
    expect(calls.some((c) => c.method === "POST" && c.url.includes("/email/routing/rules"))).toBe(false);
  });
});
