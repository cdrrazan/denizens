# denizens email-intake Worker

Private intake for `name@devis.im` forwarding. A contributor who set
`"email": { "enabled": true }` in their claim submits their real forwarding
address here — **after** their PR is merged. The address is provisioned into
Cloudflare Email Routing and **never stored** anywhere in this repo.

## Flow

1. Static form (`public/index.html`, hosted on Cloudflare Pages) collects
   `name` + forwarding `email` behind a **Turnstile** widget.
2. The Worker (`src/index.ts`):
   - verifies the Turnstile token server-side,
   - confirms the name is a merged, email-enabled claim by fetching
     `GH_RAW_BASE/<name>.json` (must be `200` + `email.enabled: true`),
   - creates a **verified destination address** (idempotent) — Cloudflare emails
     the user a verification link they must click (this also proves inbox control),
   - upserts the routing rule `name@devis.im → forward` (idempotent),
   - returns "check your inbox." Stores nothing.

## Configuration

Non-secret config lives in `wrangler.toml` (`ZONE_NAME`, `GH_RAW_BASE`,
`ALLOWED_ORIGIN`). Set `ALLOWED_ORIGIN` to the deployed form origin.

Secrets are **never committed** — set them with Wrangler:

```sh
wrangler secret put CF_API_TOKEN     # Zone DNS+Email Routing Edit + Account Email Routing Addresses Edit
wrangler secret put CF_ACCOUNT_ID
wrangler secret put CF_ZONE_ID
wrangler secret put TURNSTILE_SECRET
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
npm run deploy       # wrangler deploy
```

Deploy the form to Cloudflare Pages, set its Turnstile **site key** in
`public/index.html` and the deployed Worker URL in `WORKER_URL`. Then set the
registry repo variable `EMAIL_FORM_URL` to the form's URL so the provisioning
Action can link contributors to it.
