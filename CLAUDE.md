# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`denizens` is the public registry for **devis.im** — modeled on is-a.dev, plus email forwarding. A contributor claims one `name.devis.im` subdomain (and an optional `name@devis.im` email alias) by opening a PR that adds a single file `domains/<name>.json`. Maintainers review; on merge, automation provisions the Cloudflare DNS record + HTTPS and, if email is enabled, kicks off a private forwarding-address flow.

Today the repo is **data + schema only** — no automation has been built yet. The sections below describe both the current files and the system being built so future sessions stay aligned.

## How the system works

- **Public registry, PR-based.** One PR adds one file `domains/<name>.json`. The filename **is** the claimed name and the single source of truth.
- **Coupled names.** One claim reserves BOTH `name.devis.im` and `name@devis.im`.
- **Subdomain target is public** — lives in the PR file as a `record` object (CNAME, A, AAAA, TXT, or URL).
- **Email forwarding target is PRIVATE and must NEVER appear in the repo** — not in the file, not in logs, not in PR comments. The public file only carries `email.enabled: true|false`. The real forwarding address is submitted after merge through a private form (Cloudflare Worker + Turnstile), which triggers a Cloudflare verification email the user must click.
- **Fire-and-forget.** No dashboard, no accounts. Change = new PR editing the file. Release a name = delete the file in a PR.

## Layout

- `domains/<name>.json` — one file per claimed name. `domains/example.json` is a template, not a real claim.
- `schema.json` — JSON Schema (draft-07) every domain file must validate against. The contract for what a claim may contain.
- `reserved.json` — names that cannot be claimed (DNS infra, RFC 2142 email roles, security-sensitive local-parts, brand words). Single `reserved` array, lowercase entries.
- `README.md` / `CONTRIBUTING.md` — contributor-facing docs.
- `LICENSE` — MIT.
- `site/` — static landing page for the apex `devis.im` (plain HTML, no build). Separate Cloudflare Pages project from `worker/public/` (the `noindex` email form) so the private form never bleeds into the indexable public site.
- `docs/` — operator runbooks: `abuse-triage.md` (handling abuse reports + delistings), `email-reputation.md` (DMARC progression + Postmaster + blocklist monitoring); plus `good-first-claim.md` (newcomer claim walkthrough).

## Rules enforced by schema.json (mirror these when reviewing a claim)

- `owner.github` and `record` are required; `additionalProperties: false` everywhere — unknown keys are invalid.
- `record` must use **`CNAME` XOR `A`/`AAAA`** — `CNAME` cannot coexist with `A` or `AAAA` (enforced by the `allOf`/`if`/`then` block).
- Record types: `CNAME` (single hostname), `A` (IPv4 array), `AAAA` (IPv6 array), `TXT` (string or array), `URL` (redirect).
- `owner.github` pattern: letters/numbers + internal single hyphens, max 39 chars (GitHub username rules).
- `email` block, if present, requires `{ "enabled": true|false }` and nothing else.
- Domain files keep `"$schema": "../schema.json"` at the top.

## Validation checklist (policy rules the schema CANNOT enforce — these go in the validation Action)

- **One file per PR**, added under `domains/`. Reject multi-file or multi-name PRs.
- **Filename = claimed name**, lowercase `[a-z0-9-]`, no leading/trailing hyphen.
- **Name not already taken** — `domains/<name>.json` must not already exist.
- **Name not in `reserved.json`.**
- **`owner.github` must equal the PR author.** Contributors claim names only for themselves.
- **No forwarding email anywhere in the file** — reject anything that looks like a personal inbox.
- Editing/deleting **someone else's** file is rejected (except the owner releasing their own name).
- **Record sanity** (the schema's `format` can't catch these): reject `URL` records (redirects unbuilt — would merge into a dead name); reject an empty `record`; reject a `CNAME` set to an IP literal (an IP is a syntactically-valid hostname, so `format: hostname` lets it through — use `A`/`AAAA`); reject `A`/`AAAA` values that aren't **public/routable** (loopback, RFC1918/ULA private, link-local, multicast, unspecified) or are the wrong family / empty arrays.

## Hard constraints (do not violate)

1. **Never commit secrets.** Cloudflare token, zone ID, account ID live in GitHub Secrets / Worker env vars / `.dev.vars` — never in tracked files. Keep a `.gitignore`.
2. **Forwarding email never touches the public repo** in any form.
3. **All provisioning must be idempotent** — re-running on the same name updates, never duplicates, DNS records and routing rules.
4. **Validate before trusting input.** Every PR file is untrusted until checks pass.

## Cloudflare — what is already set up (do NOT redo)

- devis.im on Cloudflare. Email Routing live: MX, SPF, DKIM records locked.
- Verified destination inbox exists. Reserved role rules (`abuse`, `postmaster`, `admin`, `security` → operator inbox) created and confirmed forwarding.
- Scoped API token: **Zone → DNS → Edit** + **Zone → Email Routing Rules → Edit**, restricted to devis.im. (Adding destination addresses also needs **Account → Email Routing Addresses → Edit**.)

## Proven Cloudflare API shapes (reuse these)

- Create forward rule: `POST /zones/{ZONE_ID}/email/routing/rules`
  `{"name","enabled":true,"matchers":[{"type":"literal","field":"to","value":"name@devis.im"}],"actions":[{"type":"forward","value":["real@inbox"]}]}`
- DNS records: `/zones/{ZONE_ID}/dns_records`
- Destination addresses: `POST /accounts/{ACCOUNT_ID}/email/routing/addresses` — triggers a verification email the user must click (cannot be automated away; doubles as proof of inbox control).

## What is being built, in order (confirm plan before each)

1. **`CLAUDE.md`** — this file. ✅
2. **Validation GitHub Action** (`pull_request`): enforce the validation checklist above; post a clear pass/fail comment. ✅ `.github/workflows/validate.yml` + `scripts/validate-claim.rb` (Ruby + `json_schemer`). Posts a single sticky comment (marker `<!-- denizens-validation -->`), updated in place on each push.
3. **Provisioning GitHub Action** (merge to `main`): diff added/changed/deleted `domains/*.json`; create/update/delete Cloudflare DNS records idempotently; if `email.enabled`, comment linking the user to the private email form; on deletion, tear down DNS record + routing rule. ✅ `.github/workflows/provision.yml` + `scripts/provision.rb` (Ruby, stdlib `net/http` — no gems). `URL` records deferred (logged + skipped). Serialized by a `provision` concurrency group.
4. **Cloudflare Worker + static form** (private email intake): one-field form (subdomain + forwarding email) behind Turnstile; **submitter signs in with GitHub (popup OAuth)** so the Worker can prove ownership; Worker confirms the name is merged by fetching `raw.githubusercontent.com/cdrrazan/denizens/main/domains/<name>.json`, then requires the signed-in GitHub login to equal the file's `owner.github` (403 otherwise) — you can only set up forwarding for a name your own account claimed; creates verified destination address + routing rule via the proven shapes; returns "check your inbox" message. Store nothing (OAuth token discarded). ✅ `worker/` — **TypeScript** (Cloudflare Workers run JS/TS, not Ruby), isolated subproject, specced with `vitest`. Secrets via `wrangler secret` (incl. `GH_CLIENT_SECRET`); `.dev.vars` gitignored. Needs a **GitHub OAuth App** (no scopes; callback `…/oauth-callback.html`). This is the **only** JS/TS in the repo — the registry automation stays pure Ruby.
5. **Landing page** (apex `devis.im`): static HTML in `site/` (no build), explains the project and links the repo + claim flow. Separate Pages project from the `noindex` email form. **Parked subdomains: NXDOMAIN by decision** — no wildcard DNS; an unclaimed `name.devis.im` does not resolve, a name is live only once its claim merges. ✅ Deploy is manual (see `site/README.md`).
6. **Monitoring & abuse** (Phase 7): weekly **blocklist cron** (`.github/workflows/blocklist.yml` + `scripts/blocklist-check.rb`, stdlib `resolv`) checks devis.im against Spamhaus DBL/SURBL/URIBL — resolver-blocked sentinels are reported *unknown*, never a false hit; a real listing opens a tracking issue. Operator runbooks in `docs/`. DMARC apply + Google Postmaster are manual (values/steps in `docs/email-reputation.md`). ✅

## Stack / conventions

- Registry automation: GitHub Actions running **Ruby** scripts (`scripts/*.rb`) + Cloudflare Worker for email intake. `validate-claim.rb` needs `json_schemer` (see `Gemfile`); `provision.rb` is stdlib-only. Workflows use `ruby/setup-ruby`.
- Scripts are classes (`Validator`, `Provisioner`) with a guarded CLI entrypoint, specced with **RSpec** in `spec/`. Run `bundle exec rspec` (also runs in CI via `.github/workflows/test.yml`). Keep behaviour and specs in sync when changing a script.
- Conventional commits. Keep it minimal and well-documented.
- When adding fields, update `schema.json`, the README field table, and `CONTRIBUTING.md` together — keep them in sync.
- Licensed MIT (`LICENSE`).
