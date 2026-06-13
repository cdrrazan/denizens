#!/usr/bin/env node
/**
 * Validates a denizens domain-claim pull request.
 *
 * Enforces the "Validation checklist" in CLAUDE.md:
 *   - exactly one changed file, under domains/, ending in .json
 *   - filename (the claimed name) is lowercase [a-z0-9-], no leading/trailing hyphen
 *   - file validates against schema.json
 *   - name is not reserved (reserved.json)
 *   - name is not already taken (no such file at the PR base)
 *   - owner.github equals the PR author
 *   - no forwarding email anywhere in the file (only owner.email, a public contact, is allowed)
 *   - edits/deletes are only allowed on the author's own file
 *
 * Inputs (env):
 *   CHANGED_FILES_JSON  path to JSON: [{ filename, status }]  (status: added|modified|removed|renamed)
 *   PR_AUTHOR           the PR author's GitHub login
 *   BASE_SHA            the base commit sha (to read prior file state for ownership/taken checks)
 *   COMMENT_PATH        where to write the markdown report (default: comment.md)
 *
 * Exit code: 0 if all checks pass (or nothing to validate), 1 if any check fails.
 */
const fs = require("fs");
const { execFileSync } = require("child_process");
const Ajv = require("ajv");
const addFormats = require("ajv-formats");

const REPO_ROOT = process.cwd();
const COMMENT_PATH = process.env.COMMENT_PATH || "comment.md";
const PR_AUTHOR = process.env.PR_AUTHOR || "";
const BASE_SHA = process.env.BASE_SHA || "";

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const NAME_RE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;

const results = []; // { ok: bool, label, detail }
function check(ok, label, detail) {
  results.push({ ok, label, detail: detail || "" });
  return ok;
}

function readJSON(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

// Read a file's content at the base commit, or null if it doesn't exist there.
function readAtBase(path) {
  if (!BASE_SHA) return null;
  try {
    return execFileSync("git", ["show", `${BASE_SHA}:${path}`], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return null;
  }
}

function fail(summary) {
  writeComment(summary);
  process.exit(1);
}

function main() {
  const changed = readJSON(process.env.CHANGED_FILES_JSON);

  // Claim-relevant changes only: under domains/, *.json, excluding the example template.
  const domainChanges = changed.filter(
    (f) =>
      f.filename.startsWith("domains/") &&
      f.filename.endsWith(".json") &&
      f.filename !== "domains/example.json"
  );

  if (domainChanges.length === 0) {
    writeComment(null, "No domain claim changes detected — nothing to validate.");
    process.exit(0);
  }

  // One PR, one name: the domain file must be the ONLY changed file.
  if (
    !check(
      changed.length === 1,
      "One file per PR",
      changed.length === 1
        ? ""
        : `This PR changes ${changed.length} files. A claim PR must change exactly one file under \`domains/\`. Files changed:\n` +
            changed.map((f) => `  - \`${f.filename}\` (${f.status})`).join("\n")
    )
  ) {
    return fail();
  }

  const file = domainChanges[0];
  const path = file.filename;
  const name = path.replace(/^domains\//, "").replace(/\.json$/, "");

  // Filename / claimed-name format.
  check(
    NAME_RE.test(name),
    "Valid name format",
    NAME_RE.test(name)
      ? `Claiming \`${name}\`.`
      : `\`${name}\` is invalid. Use lowercase letters, numbers, and hyphens only, with no leading or trailing hyphen.`
  );

  // Reserved name.
  let reserved = [];
  try {
    reserved = readJSON(`${REPO_ROOT}/reserved.json`).reserved || [];
  } catch {
    /* checked below via schema-load failure path */
  }
  check(
    !reserved.includes(name),
    "Name not reserved",
    reserved.includes(name)
      ? `\`${name}\` is reserved (see reserved.json) and cannot be claimed.`
      : ""
  );

  const status = file.status; // added | modified | removed | renamed
  const baseContent = readAtBase(path);

  // Name not already taken (only meaningful for new claims).
  if (status === "added" || status === "renamed") {
    check(
      baseContent === null,
      "Name available",
      baseContent === null
        ? ""
        : `\`${name}\` already exists in the registry and cannot be re-claimed.`
    );
  }

  // Ownership for edits/deletes: the existing file's owner must be the PR author.
  if (status === "modified" || status === "removed" || status === "renamed") {
    let priorOwner = null;
    try {
      priorOwner = baseContent ? JSON.parse(baseContent)?.owner?.github : null;
    } catch {
      priorOwner = null;
    }
    check(
      priorOwner && PR_AUTHOR && priorOwner.toLowerCase() === PR_AUTHOR.toLowerCase(),
      "Owns the file being changed",
      priorOwner && PR_AUTHOR && priorOwner.toLowerCase() === PR_AUTHOR.toLowerCase()
        ? ""
        : `Only the owner may edit or release a name. \`${path}\` is owned by \`${priorOwner || "unknown"}\`, but this PR is by \`${PR_AUTHOR || "unknown"}\`.`
    );
  }

  // For deletions there is no head file to schema-check; ownership above is the gate.
  if (status === "removed") {
    writeComment(null);
    process.exit(allPassed() ? 0 : 1);
  }

  // Read the head version of the file.
  let raw, data;
  try {
    raw = fs.readFileSync(`${REPO_ROOT}/${path}`, "utf8");
    data = JSON.parse(raw);
  } catch (e) {
    check(false, "Valid JSON", `\`${path}\` is not valid JSON: ${e.message}`);
    return fail();
  }
  check(true, "Valid JSON");

  // Schema validation (strip the editor-hint $schema pointer first).
  try {
    const schema = readJSON(`${REPO_ROOT}/schema.json`);
    const ajv = new Ajv({ allErrors: true, strict: false });
    addFormats(ajv);
    const validate = ajv.compile(schema);
    const subject = { ...data };
    delete subject.$schema;
    const ok = validate(subject);
    check(
      ok,
      "Matches schema.json",
      ok
        ? ""
        : (validate.errors || [])
            .map((e) => `  - \`${e.instancePath || "/"}\` ${e.message}`)
            .join("\n")
    );
  } catch (e) {
    check(false, "Matches schema.json", `Could not run schema validation: ${e.message}`);
  }

  // CNAME cannot be combined with A/AAAA (clearer than the raw schema error).
  const rec = data?.record || {};
  const cnameConflict = rec.CNAME !== undefined && (rec.A !== undefined || rec.AAAA !== undefined);
  check(
    !cnameConflict,
    "CNAME not combined with A/AAAA",
    cnameConflict
      ? "`record` uses `CNAME` together with `A`/`AAAA`. Use `CNAME` for hosted platforms, or `A`/`AAAA` for a raw server IP — not both."
      : ""
  );

  // owner.github equals PR author (for added/modified).
  const ownerGithub = data?.owner?.github || "";
  check(
    ownerGithub && PR_AUTHOR && ownerGithub.toLowerCase() === PR_AUTHOR.toLowerCase(),
    "owner.github matches PR author",
    ownerGithub && PR_AUTHOR && ownerGithub.toLowerCase() === PR_AUTHOR.toLowerCase()
      ? ""
      : `\`owner.github\` is \`${ownerGithub || "(missing)"}\` but this PR is by \`${PR_AUTHOR || "unknown"}\`. You can only claim a name for yourself.`
  );

  // No forwarding email anywhere. Only owner.email (a public contact) is allowed.
  const publicContact = (data?.owner?.email || "").toLowerCase();
  const found = (raw.match(EMAIL_RE) || []).map((s) => s.toLowerCase());
  const offending = [...new Set(found.filter((e) => e !== publicContact))];
  check(
    offending.length === 0,
    "No forwarding email in file",
    offending.length === 0
      ? ""
      : `Found email address(es) that must not appear in this public repo: ${offending
          .map((e) => `\`${e}\``)
          .join(", ")}. Your forwarding address is submitted privately after merge — never put it in the file. (\`owner.email\`, if set, is a *public* contact only.)`
  );

  writeComment(null);
  process.exit(allPassed() ? 0 : 1);
}

function allPassed() {
  return results.every((r) => r.ok);
}

function writeComment(overrideSummary, skipMessage) {
  const marker = "<!-- denizens-validation -->";
  let body;
  if (skipMessage) {
    body = `${marker}\n### ✅ Claim validation\n\n${skipMessage}\n`;
  } else {
    const passed = allPassed();
    const header = passed
      ? "### ✅ Claim validation passed"
      : "### ❌ Claim validation failed";
    const lines = results.map((r) => {
      const icon = r.ok ? "✅" : "❌";
      const detail = r.detail ? `\n    ${r.detail.replace(/\n/g, "\n    ")}` : "";
      return `- ${icon} **${r.label}**${detail}`;
    });
    const footer = passed
      ? "\nAll checks passed. A maintainer will review and merge."
      : "\nPlease fix the items marked ❌ and push to this PR — checks will re-run automatically.";
    body = `${marker}\n${header}\n\n${lines.join("\n")}\n${overrideSummary ? "\n" + overrideSummary : ""}${footer}\n`;
  }
  fs.writeFileSync(COMMENT_PATH, body);
}

main();
