# denizens — build roadmap

Everything left to ship devis.im, in dependency order. Hand this to Claude Code one phase at a time.

**How to use with Claude Code:** `CLAUDE.md` in the repo already holds the architecture, constraints, and proven Cloudflare API shapes — so for each task just say "read CLAUDE.md, then do Phase N task X, show me your plan before coding." Tackle phases top to bottom; later phases depend on earlier ones. Always review the plan before letting it build the security-sensitive pieces (validation, provisioning, the Worker).

> Note: this file is safe to commit or keep local — your call. It describes sequencing, not secrets.

---

## ✅ Done

- [x] **Cloudflare foundation** — devis.im on Cloudflare; Email Routing live (MX/SPF/DKIM locked); destination inbox verified; four reserved role rules (`abuse`, `postmaster`, `admin`, `security`) forwarding to operator inbox; scoped API token (Zone DNS Edit + Zone Email Routing Rules Edit, devis.im only).
- [x] **Repo scaffold** — `schema.json`, `reserved.json`, `domains/example.json`, `README.md`, `CONTRIBUTING.md`.
- [x] **CLAUDE.md** — project context, constraints, API shapes.
- [x] **Cleanup + LICENSE** — removed the handoff prompt from the repo; added MIT license.
- [x] **Validation GitHub Action** — enforces the validation checklist on every PR (Ruby + `json_schemer`).
- [x] **RSpec suite** — `Validator` + `Provisioner` specced in `spec/`; runs in CI (`.github/workflows/test.yml`).

---

## Phase 3 — Provisioning automation (DNS on merge)

Goal: a merged PR makes the subdomain live automatically; a deleted file tears it down. Idempotent and failure-isolated.

- [ ] Add GitHub repo **secrets**: `CF_API_TOKEN`, `CF_ZONE_ID`, `CF_ACCOUNT_ID` (Settings → Secrets and variables → Actions). Never in tracked files. *(manual — required before the Action can run)*
- [ ] Add a repo **variable** `EMAIL_FORM_URL` (placeholder for now; set the real value in Phase 5). *(manual — without it the email-setup comment is skipped)*
- [x] **Provisioning Action** on push to `main` — `.github/workflows/provision.yml` + `scripts/provision.rb` (Ruby, stdlib only):
  - [x] Diff which `domains/*.json` files were added / changed / deleted in the merge (`--no-renames` so delete+add never collapses to a rename).
  - [x] Added/changed → create or update the DNS record(s) **idempotently** (look up by name; delete stale, create missing, patch proxied — never blind-create).
  - [x] Map record types to the Cloudflare DNS API; honor the `proxied` flag. `CNAME`/`A`/`AAAA`/`TXT` done; **`URL` deferred** (logged + skipped — no native CF type; redirect support is a follow-up).
  - [x] Deleted → delete the DNS record **and** any matching `name@devis.im` routing rule (teardown).
  - [x] If `email.enabled` on an added file → post a comment linking the user to `EMAIL_FORM_URL` with their name prefilled.
  - [x] Failure isolation: one bad file does not break the batch; never logs the token or any email address.
- [ ] **Test** end-to-end: open a real PR claiming a throwaway name → merge → confirm `name.devis.im` resolves and HTTPS works. *(needs live secrets)*
- [ ] **Test** teardown: delete the file in a PR → merge → confirm the record is gone. *(needs live secrets)*

> Follow-up: implement `URL` record support (proxied placeholder + Cloudflare Single Redirect rule).

## Phase 4 — Repo governance (make the manual gate real)

Do this **before** opening to the public — without it, "manual review" isn't enforced.

- [ ] **Branch protection** on `main`: require the validation Action to pass, require 1 approving review (you), block direct pushes. *(GitHub setting, not a file — apply via repo Settings or `gh api`; see below.)*
- [x] **CODEOWNERS** so every PR auto-requests your review — `.github/CODEOWNERS` (`* @cdrrazan`).
- [x] **PR template** — `.github/pull_request_template.md` (the claim checklist).
- [x] **Issue templates** — `.github/ISSUE_TEMPLATE/` (claim help, abuse report, name release) + `config.yml` (security/abuse contact links, blank issues off).
- [x] **SECURITY.md** — private reporting via security advisory / `security@devis.im`; abuse via `abuse@devis.im`.

Apply branch protection once (requires admin + the check to have run at least once so its name resolves):

```sh
gh api -X PUT repos/cdrrazan/denizens/branches/main/protection \
  -F required_pull_request_reviews.required_approving_review_count=1 \
  -F required_pull_request_reviews.require_code_owner_reviews=true \
  -F 'required_status_checks.contexts[]=validate' \
  -F required_status_checks.strict=true \
  -F enforce_admins=true \
  -F restrictions=
```

## Phase 5 — Email intake Worker (private forwarding)

The private channel for the forwarding address. Nothing about it is stored.

- [ ] Add **Account → Email Routing Addresses → Edit** to the token (or mint a separate token scoped for the Worker).
- [ ] **Static form** (Cloudflare Pages): two fields — name + forwarding email — behind a **Turnstile** widget.
- [ ] **Worker**:
  - [ ] Verify the Turnstile token server-side.
  - [ ] Confirm the name is actually merged: fetch `raw.githubusercontent.com/cdrrazan/denizens/main/domains/<name>.json` → must return 200 and `email.enabled: true`.
  - [ ] Create the verified **destination address** (`POST /accounts/{ACCOUNT_ID}/email/routing/addresses`) → triggers Cloudflare's verification email to the user.
  - [ ] Create the **routing rule** `name@devis.im → forward_to` using the proven shape in CLAUDE.md.
  - [ ] Idempotent — re-submitting the same name doesn't duplicate the address or rule.
  - [ ] Return "check your inbox and click the verification link." **Store nothing.**
  - [ ] Secrets via `wrangler secret` / `.dev.vars` (gitignored) — never committed.
- [ ] **Deploy** Worker + Pages; wire the form's submit to the Worker.
- [ ] Set the real `EMAIL_FORM_URL` repo variable so Phase 3's comment links to the live form.
- [ ] **Test** the full loop: claim → merge → submit email → click CF verification → send a test mail → confirm it lands.

## Phase 6 — What the domain serves

- [ ] Decide and build what **root `devis.im`** shows — a landing page explaining the project, linking the repo and the claim form.
- [ ] Decide what an **unclaimed/parked subdomain** shows (clean 404 vs. redirect to the landing).
- [ ] Host the landing on Pages (can share the Worker/Pages project).

## Phase 7 — Monitoring & abuse (ongoing safety)

The work that keeps a shared domain alive and reputable.

- [ ] Add a **DMARC** record if not already present (start `p=none`, monitor, tighten later).
- [ ] Set up **Google Postmaster Tools** for devis.im — watch domain reputation and SPF/DKIM/DMARC pass rates.
- [ ] **Scheduled check** (Action on a cron): is devis.im on major blocklists (Spamhaus etc.)?
- [ ] Document the **abuse triage flow**: report → remove file → teardown DNS + rule.
- [ ] *(Later)* automated phishing/malware scan on claimed subdomains.

## Phase 8 — Launch

- [ ] Seed a few real claims (start with your own: `rajan`).
- [ ] Write the build-in-public / digitonX post.
- [ ] Announce; add a "good first claim" path for newcomers.

---

## Open decisions to make along the way

- **DMARC strictness** — when to move from `p=none` to `quarantine`/`reject`.
- **Full mailboxes** — currently out of scope (forward-only). Revisit only if real demand appears; it's a different product with real reputation risk.
- **Landing page design** — tone and how much it leans on the digitonX/ARU brand.
