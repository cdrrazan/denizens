# Abuse triage

How an operator handles an abuse report against a `name.devis.im` subdomain or
`name@devis.im` alias. devis.im is a shared domain — one abusive name hurts
deliverability and reputation for everyone, so act fast.

## Where reports come from

- The [abuse issue template](https://github.com/cdrrazan/denizens/issues/new/choose).
- `abuse@devis.im` (forwards to the operator inbox via a reserved role rule).
- A blocklist hit — the weekly [`Blocklist check`](../.github/workflows/blocklist.yml)
  workflow opens a tracking issue if devis.im lands on a domain DNSBL.

## Triage flow

1. **Confirm.** Visit the reported subdomain / inspect the headers. Phishing,
   malware, spam, or impersonation → actionable. Mere content you dislike is not.
   When unsure, err toward removal — the contributor can re-claim and appeal.
2. **Remove the claim.** Open a PR deleting `domains/<name>.json` (or merge the
   reporter's). On merge, [`provision.rb`](../scripts/provision.rb) tears down
   **both** the DNS record(s) **and** the `name@devis.im` routing rule
   automatically — no manual Cloudflare clicking.
3. **Verify teardown.** Confirm `name.devis.im` no longer resolves and the
   routing rule is gone (check the provision workflow log).
4. **Reserve if needed.** If the name is likely to be re-abused (brand
   impersonation, lookalike), add it to [`reserved.json`](../reserved.json) so it
   can't be re-claimed.
5. **Close the loop.** Reply to the reporter / close the issue. Never expose any
   forwarding address in the thread.

## If devis.im is blocklisted

1. Find the abusive name(s) — recent claims, the ones the listing references.
2. Remove them (steps above).
3. Request delisting:
   - Spamhaus: <https://www.spamhaus.org/lookup/> → request removal.
   - SURBL: <https://www.surbl.org/removal-request>.
   - URIBL: <https://admin.uribl.com/>.
4. Watch reputation recover in Google Postmaster Tools before tightening DMARC.

## Notes

- **Removal is reversible by re-claim** unless the name is reserved. That's
  intentional — fast removal first, debate later.
- The forwarding address is never in the repo, so an alias can only be killed by
  deleting the routing rule (done by teardown) — there's nothing to scrub from
  git history.
