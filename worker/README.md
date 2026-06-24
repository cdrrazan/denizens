# denizens email-intake Worker

Private intake for `name@devis.im` forwarding. A contributor who set
`"email": { "enabled": true }` in their claim submits their real forwarding
address here — **after** their PR is merged. The address is provisioned into
Cloudflare Email Routing and **never stored** anywhere in this repo.

## Flow

1. Static form (`public/index.html`, hosted on Cloudflare Pages) collects
   `name` + forwarding `email` behind a **Turnstile** widget.
2. Static form also makes the user **sign in with GitHub** (popup OAuth) on submit
   and sends the one-time `code` alongside `name` + `email`.
3. The Worker (`src/index.ts`):
   - verifies the Turnstile token server-side,
   - confirms the name is a merged, email-enabled claim by fetching
     `GH_RAW_BASE/<name>.json` (must be `200` + `email.enabled: true`) and reads
     its `owner.github`,
   - **proves ownership**: exchanges the GitHub OAuth `code`, reads the signed-in
     login, and requires it to equal `owner.github` (else `403`) — so you can only
     set up forwarding for a name your own GitHub account claimed,
   - creates a **verified destination address** (idempotent) — Cloudflare emails
     the user a verification link they must click (this also proves inbox control),
   - upserts the routing rule `name@devis.im → forward` (idempotent),
   - returns "check your inbox." Stores nothing (the OAuth token is discarded).

## GitHub OAuth App (ownership proof)

Create one at **GitHub → Settings → Developer settings → OAuth Apps → New**:

- **Homepage URL**: the form origin, e.g. `https://claim.devis.im`
- **Authorization callback URL**: `https://claim.devis.im/oauth-callback.html`

It needs **no scopes** — the Worker only reads the public `login`. Take the
**Client ID** (public) and a generated **Client Secret** (secret):

- put the Client ID in `wrangler.toml` (`GH_CLIENT_ID`) **and** in
  `public/index.html` (`GH_CLIENT_ID`),
- set the secret with `wrangler secret put GH_CLIENT_SECRET`.

## Configuration

Non-secret config lives in `wrangler.toml` (`ZONE_NAME`, `GH_RAW_BASE`,
`ALLOWED_ORIGIN`, `GH_CLIENT_ID`). Set `ALLOWED_ORIGIN` to the deployed form origin.

Secrets are **never committed** — set them with Wrangler:

```sh
wrangler secret put CF_API_TOKEN     # Zone DNS+Email Routing Edit + Account Email Routing Addresses Edit
wrangler secret put CF_ACCOUNT_ID
wrangler secret put CF_ZONE_ID
wrangler secret put TURNSTILE_SECRET
wrangler secret put GH_CLIENT_SECRET # GitHub OAuth App client secret
```

For local dev, copy `.dev.vars.example` to `.dev.vars` (gitignored).

> The scoped token from earlier phases must additionally have
> **Account → Email Routing Addresses → Edit** for `ensureDestinationAddress` to work.

## Develop / test / deploy

```sh
npm install
npm run typecheck    # tsc --noEmit
npm test             # vitest (fetch mocked)
npm run dev          # wrangler dev (needs .dev.vars)
npm run deploy       # wrangler deploy  → the Worker (api.devis.im)
```

This repo has **two separate Cloudflare deploys**:

1. **The Worker** (`api.devis.im`) — `npm run deploy` (uses `wrangler.toml`).
2. **The static form** (`claim.devis.im`) — a **Cloudflare Pages** project
   (`denizens-email-form`) serving `worker/public/`.

### Deploying the form (Pages)

Run this **from the repo root**, not from `worker/`:

```sh
npx wrangler pages deploy worker/public --project-name denizens-email-form --branch main
```

- **`--branch main` is required** — without it the upload lands on a preview URL
  and the `claim.devis.im` custom domain keeps serving the old build.
- **Run from the repo root on purpose.** `wrangler pages deploy` picks up any
  `wrangler.toml` in the current directory. Running from `worker/` makes it read
  the *Worker's* `wrangler.toml` and warn `missing the "pages_build_output_dir"
  field`. The repo root has no `wrangler.toml`, so the warning disappears and the
  Worker config stays Worker-only (no `pages_build_output_dir` pollution).

After deploying the form, set its Turnstile **site key** and the deployed Worker
URL (`WORKER_URL`) in `public/index.html`, then set the registry repo variable
`EMAIL_FORM_URL` to the form's URL so the provisioning Action can link
contributors to it.
