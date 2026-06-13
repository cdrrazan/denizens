#!/usr/bin/env node
/**
 * Provisions Cloudflare DNS for merged denizens claims.
 *
 * Runs on push to main. Diffs the merge, then for each changed domains/*.json:
 *   - added/modified -> reconcile DNS records for <name>.devis.im idempotently
 *     (look up by name, delete stale, create missing, patch changed). Honors `proxied`.
 *   - deleted        -> tear down all DNS records for the name + any matching
 *     name@devis.im email routing rule.
 *   - email.enabled on an added file -> queued for a "submit your forwarding
 *     address" comment (written to EMAIL_COMMENTS_PATH; the workflow posts it).
 *
 * URL records are deferred (logged + skipped) — Cloudflare has no native URL DNS
 * type; redirect support lands in a follow-up.
 *
 * Failure isolation: one bad file is logged and recorded but does not stop the
 * batch. The process exits non-zero if any file errored. Never logs the API
 * token or any email address.
 *
 * Env:
 *   CF_API_TOKEN, CF_ZONE_ID, CF_ACCOUNT_ID   Cloudflare credentials (GitHub Secrets)
 *   ZONE_NAME                                  apex zone, default "devis.im"
 *   BEFORE_SHA, AFTER_SHA                      push range to diff
 *   EMAIL_COMMENTS_PATH                        where to write [names] needing the email comment
 */
const fs = require("fs");
const { execFileSync } = require("child_process");

const CF_API = "https://api.cloudflare.com/client/v4";
const TOKEN = required("CF_API_TOKEN");
const ZONE_ID = required("CF_ZONE_ID");
const ZONE_NAME = process.env.ZONE_NAME || "devis.im";
const BEFORE_SHA = process.env.BEFORE_SHA || "";
const AFTER_SHA = process.env.AFTER_SHA || "HEAD";
const EMAIL_COMMENTS_PATH = process.env.EMAIL_COMMENTS_PATH || "email-comments.json";
const ZERO_SHA = "0000000000000000000000000000000000000000";

const PROXIABLE = new Set(["CNAME", "A", "AAAA"]);

function required(key) {
  const v = process.env[key];
  if (!v) {
    console.error(`Missing required env: ${key}`);
    process.exit(1);
  }
  return v;
}

async function cf(method, path, body) {
  const res = await fetch(`${CF_API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json;
  try {
    json = await res.json();
  } catch {
    throw new Error(`Cloudflare ${method} ${path} -> ${res.status} (non-JSON response)`);
  }
  if (!res.ok || json.success === false) {
    const errs = (json.errors || []).map((e) => `${e.code}: ${e.message}`).join("; ");
    throw new Error(`Cloudflare ${method} ${path} -> ${res.status} ${errs || "unknown error"}`);
  }
  return json.result;
}

// --- diff -------------------------------------------------------------------

function changedDomainFiles() {
  let out;
  if (!BEFORE_SHA || BEFORE_SHA === ZERO_SHA) {
    // New branch / unknown base: treat every domain file as added.
    out = execFileSync("git", ["ls-tree", "-r", "--name-only", AFTER_SHA, "domains/"], {
      encoding: "utf8",
    })
      .split("\n")
      .filter(Boolean)
      .map((f) => `A\t${f}`)
      .join("\n");
  } else {
    // --no-renames: each domains/<name>.json is its own claim. A delete+add of
    // identical content must stay two events (D + A), never collapse to a rename.
    out = execFileSync(
      "git",
      ["diff", "--no-renames", "--name-status", `${BEFORE_SHA}`, `${AFTER_SHA}`, "--", "domains/"],
      { encoding: "utf8" }
    );
  }
  const files = [];
  for (const line of out.split("\n").filter(Boolean)) {
    const parts = line.split("\t");
    const code = parts[0][0]; // A | M | D | R | C
    // For renames/copies the destination path is the last field.
    const path = parts[parts.length - 1];
    if (!path.endsWith(".json") || path === "domains/example.json") continue;
    let status;
    if (code === "A" || code === "C") status = "added";
    else if (code === "M" || code === "R") status = "modified";
    else if (code === "D") status = "deleted";
    else continue;
    files.push({ path, status, name: path.replace(/^domains\//, "").replace(/\.json$/, "") });
  }
  return files;
}

// --- desired-state mapping --------------------------------------------------

function desiredRecords(name, record, proxied) {
  const fqdn = `${name}.${ZONE_NAME}`;
  const recs = [];
  const push = (type, content, canProxy) =>
    recs.push({
      type,
      name: fqdn,
      content,
      proxied: canProxy ? !!proxied : false,
      ttl: 1,
    });

  if (record.CNAME !== undefined) push("CNAME", record.CNAME, true);
  if (Array.isArray(record.A)) for (const ip of record.A) push("A", ip, true);
  if (Array.isArray(record.AAAA)) for (const ip of record.AAAA) push("AAAA", ip, true);
  if (record.TXT !== undefined) {
    const vals = Array.isArray(record.TXT) ? record.TXT : [record.TXT];
    for (const v of vals) push("TXT", v, false);
  }
  if (record.URL !== undefined) {
    console.log(`  · URL record for ${fqdn} deferred (redirect support not yet implemented) — skipped`);
  }
  return recs;
}

function sameRecord(existing, desired) {
  return existing.type === desired.type && existing.content === desired.content;
}

// --- operations -------------------------------------------------------------

async function listByName(fqdn) {
  return cf("GET", `/zones/${ZONE_ID}/dns_records?name=${encodeURIComponent(fqdn)}&per_page=100`);
}

async function reconcile(name, data) {
  const fqdn = `${name}.${ZONE_NAME}`;
  const desired = desiredRecords(name, data.record || {}, data.proxied);
  const existing = await listByName(fqdn);

  // Delete stale first (also resolves CNAME-vs-other-type conflicts before create).
  const stale = existing.filter((e) => !desired.some((d) => sameRecord(e, d)));
  for (const e of stale) {
    await cf("DELETE", `/zones/${ZONE_ID}/dns_records/${e.id}`);
    console.log(`  − deleted stale ${e.type} ${fqdn}`);
  }

  for (const d of desired) {
    const match = existing.find((e) => sameRecord(e, d));
    if (!match) {
      await cf("POST", `/zones/${ZONE_ID}/dns_records`, d);
      console.log(`  + created ${d.type} ${fqdn}${PROXIABLE.has(d.type) ? ` (proxied=${d.proxied})` : ""}`);
    } else if (PROXIABLE.has(d.type) && match.proxied !== d.proxied) {
      await cf("PATCH", `/zones/${ZONE_ID}/dns_records/${match.id}`, { proxied: d.proxied });
      console.log(`  ~ updated ${d.type} ${fqdn} (proxied -> ${d.proxied})`);
    } else {
      console.log(`  = unchanged ${d.type} ${fqdn}`);
    }
  }
}

async function teardown(name) {
  const fqdn = `${name}.${ZONE_NAME}`;
  const existing = await listByName(fqdn);
  for (const e of existing) {
    await cf("DELETE", `/zones/${ZONE_ID}/dns_records/${e.id}`);
    console.log(`  − deleted ${e.type} ${fqdn}`);
  }
  // Remove any email routing rule for name@devis.im.
  const alias = `${name}@${ZONE_NAME}`;
  try {
    const rules = await cf("GET", `/zones/${ZONE_ID}/email/routing/rules?per_page=100`);
    const rule = (rules || []).find((r) =>
      (r.matchers || []).some((m) => m.field === "to" && m.value === alias)
    );
    if (rule) {
      await cf("DELETE", `/zones/${ZONE_ID}/email/routing/rules/${rule.tag || rule.id}`);
      console.log(`  − deleted email routing rule for ${alias}`);
    }
  } catch (e) {
    console.log(`  ! could not check/remove routing rule for ${alias}: ${e.message}`);
  }
}

// --- main -------------------------------------------------------------------

async function main() {
  const files = changedDomainFiles();
  if (files.length === 0) {
    console.log("No domain changes to provision.");
    fs.writeFileSync(EMAIL_COMMENTS_PATH, "[]");
    return;
  }

  const emailComments = [];
  const failures = [];

  for (const f of files) {
    console.log(`\n▶ ${f.status}: ${f.name}`);
    try {
      if (f.status === "deleted") {
        await teardown(f.name);
        continue;
      }
      const data = JSON.parse(fs.readFileSync(f.path, "utf8"));
      await reconcile(f.name, data);
      if (f.status === "added" && data.email && data.email.enabled === true) {
        emailComments.push(f.name);
      }
    } catch (e) {
      console.error(`  ✗ ${f.name}: ${e.message}`);
      failures.push(f.name);
    }
  }

  fs.writeFileSync(EMAIL_COMMENTS_PATH, JSON.stringify(emailComments));

  console.log(
    `\nDone. ${files.length - failures.length}/${files.length} provisioned` +
      (failures.length ? `, failed: ${failures.join(", ")}` : "")
  );
  if (failures.length) process.exit(1);
}

if (require.main === module) {
  main().catch((e) => {
    console.error(`Fatal: ${e.message}`);
    process.exit(1);
  });
}

module.exports = { changedDomainFiles, desiredRecords, reconcile, teardown };
