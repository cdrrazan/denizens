# Email reputation — DMARC & monitoring

devis.im forwards mail (Cloudflare Email Routing). SPF, DKIM, and the MX records
are already locked in Cloudflare. This doc covers the remaining reputation work:
DMARC and ongoing monitoring. These are **operator DNS / account steps** — they
are not provisioned by the registry automation.

## DMARC

Add one TXT record at `_dmarc.devis.im`. Start permissive (`p=none`) so nothing
breaks while you watch the aggregate reports, then tighten.

**Phase 1 — observe (start here):**

```
_dmarc.devis.im  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@devis.im; fo=1"
```

- `p=none` — don't act on failures yet, just report.
- `rua=` — where aggregate (XML) reports go. Use a reserved alias that forwards
  to the operator inbox, or a dedicated DMARC-report service.
- `fo=1` — request failure reports when SPF or DKIM fails.

**Phase 2 — quarantine**, once reports look clean for a few weeks:

```
_dmarc.devis.im  TXT  "v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc@devis.im; fo=1"
```

**Phase 3 — reject**, only once confident:

```
_dmarc.devis.im  TXT  "v=DMARC1; p=reject; rua=mailto:dmarc@devis.im; fo=1"
```

> Forwarding caveat: plain forwarding can break SPF (the forwarding hop isn't in
> the original sender's SPF) and sometimes DKIM. Cloudflare Email Routing
> rewrites the envelope sender (SRS) to keep SPF aligned, so forwarded mail
> generally passes DMARC — but this is exactly why you sit at `p=none` first and
> read the reports before moving to `quarantine`/`reject`.

The move from `none` → `quarantine` → `reject` is an open decision tracked in
`ROADMAP.md`; don't tighten until the aggregate reports are consistently clean.

## Google Postmaster Tools

1. Add devis.im at <https://postmaster.google.com/> and verify ownership via a
   DNS TXT record (Cloudflare).
2. Watch **domain reputation**, **spam rate**, and **SPF/DKIM/DMARC** pass rates.
3. A reputation dip usually means an abusive claim — cross-check with
   [`docs/abuse-triage.md`](./abuse-triage.md).

## Blocklist monitoring

Automated: [`.github/workflows/blocklist.yml`](../.github/workflows/blocklist.yml)
runs weekly and on demand, checking devis.im against domain DNSBLs (Spamhaus DBL,
SURBL, URIBL) via [`scripts/blocklist-check.rb`](../scripts/blocklist-check.rb).
A real listing opens a tracking issue. CI runners use public resolvers that some
DNSBLs rate-limit, so the script reports those as *unknown* rather than crying
wolf — only a genuine `127.0.x.x` hit counts as listed.
