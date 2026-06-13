# site/ — the devis.im landing page

Static landing for the apex **devis.im**. Plain HTML, no build step, no
dependencies — system fonts, light/dark via `color-scheme`. Explains the
project and links to the registry and the claim flow.

This is intentionally separate from `worker/public/` (the private,
`noindex` email-forwarding form). Keep them as two Cloudflare Pages projects
so the form never bleeds into the indexable public site.

## Files

- `index.html` — the landing page (served at `/`).
- `404.html` — Cloudflare Pages serves this for unmatched paths.

## Deploy (Cloudflare Pages)

Once, manually (needs the Cloudflare account):

1. **Create a Pages project** pointed at this repo, or upload the `site/`
   directory directly. If connecting the repo, set the **build output
   directory** to `site` and leave the build command empty (no build).
2. **Add the custom domain** `devis.im` (apex) to the Pages project.
   Cloudflare provisions the certificate automatically.
3. Confirm `https://devis.im/` serves this page and a bad path serves
   `404.html`.

## Parked / unclaimed subdomains

By decision, there is **no wildcard DNS**. An unclaimed `name.devis.im`
returns NXDOMAIN — it simply doesn't resolve. A name is only live once its
claim file is merged and provisioning creates the specific record. This keeps
the attack surface minimal and avoids a wildcard shadowing real claims.

If we ever want a "claim this name" interstitial for unclaimed subdomains,
that's a future change: add a wildcard `*.devis.im` record routed to a Pages
project (specific claims still win over the wildcard) and serve an
interstitial page.
