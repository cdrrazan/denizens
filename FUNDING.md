# Funding devis.im

**Claiming a name is free, and it stays free.** This page exists so the money side of a shared
domain is as transparent as the registry itself — you can read what it costs to run, what support
pays for, and what it will never buy.

If devis.im isn't useful to you, skip it. Nothing here is a paywall.

---

## What it actually costs

| Item | Notes |
| --- | --- |
| **`devis.im` registration** | Annual renewal on a `.im` domain. The single hard cost — if it lapses, every claimed name goes with it. |
| **Cloudflare** | DNS, HTTPS, Email Routing, Turnstile, Pages, and the Worker all run on free tiers today. Growth could push a piece of that into a paid plan. |
| **Operator time** | Reviewing claims, triaging abuse reports, chasing blocklist entries, and keeping email reputation clean. The largest cost, and the one nobody invoices for. |

The domain renewal is the part that must never be missed. Everything else degrades gracefully;
that one doesn't.

---

## What support buys

- **Runway on the domain renewal**, so names stay live year over year.
- **Headroom** if traffic outgrows a free tier and something has to move to a paid plan.
- **Time** for the unglamorous work — abuse triage, DMARC progression, delisting requests, keeping
  the automation honest so a shared domain doesn't turn into a spam vector.

## What it does not buy

Stated plainly, because a shared namespace only works if the rules are the same for everyone:

- **No paid tiers.** Sponsors and non-sponsors get the identical service.
- **No priority claims or queue-jumping.** Review order doesn't change.
- **No reserved names for sale.** [`reserved.json`](./reserved.json) stays reserved — those names keep
  system mail and abuse reports reaching the operators.
- **No raised per-owner cap.** Two names per GitHub account, for everyone.
- **No exemption from the rules.** Phishing, malware, spam, and impersonation get removed regardless
  of who's sponsoring.

---

## How to help

Money is the least interesting way to support this. In rough order of usefulness:

1. **Use it and report what breaks.** [Open an issue](https://github.com/cdrrazan/denizens/issues) —
   confusing docs, a validation message that didn't explain itself, a flow that stalled.
2. **Improve the docs.** The [newcomer walkthrough](./docs/good-first-claim.md) is the highest-leverage
   file in the repo; most first-time contributors land there.
3. **Contribute to the automation.** Validation rules, provisioning edge cases, and the deferred
   `URL`-record support are all fair game. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) and
   [`ROADMAP.md`](./ROADMAP.md).
4. **Report abuse when you see it.** [`abuse@devis.im`](mailto:abuse@devis.im). A shared domain's
   reputation is a common good — one phishing subdomain hurts everyone's email deliverability.
5. **Sponsor**, via the Sponsor button on this repository — see
   [`.github/FUNDING.yml`](./.github/FUNDING.yml).

---

## Transparency

- This is a **one-person project**, run by [@cdrrazan](https://github.com/cdrrazan). There's no
  company, no entity, and no revenue.
- **No sponsor data ever touches this repo.** Same rule as forwarding addresses — the registry
  stores nothing personal.
- If devis.im ever has to shut down, the intent is **advance notice with time to migrate**, not a
  silent NXDOMAIN. Every claim is a plain JSON file in public git history, so the registry stays
  readable and portable regardless.

Questions about any of this: [`irajanbhattarai@gmail.com`](mailto:irajanbhattarai@gmail.com).
