# Security Policy

`denizens` is the public registry for **devis.im**. This repo holds only
subdomain claims — no application code runs here. The sensitive surface is the
provisioning automation (Cloudflare API) and the private email-intake Worker.

## Reporting a vulnerability

**Do not open a public issue for security reports.**

- Open a [private security advisory](https://github.com/cdrrazan/denizens/security/advisories/new), or
- Email **security@devis.im**.

Please include enough detail to reproduce (affected component, steps, impact).
Expect an acknowledgement within a few days. There is no paid bug bounty.

## Reporting abuse

A subdomain or alias used for phishing, malware, spam, or impersonation is **not**
a security vulnerability — report it via the [abuse issue template](https://github.com/cdrrazan/denizens/issues/new/choose)
or email **abuse@devis.im**. Abusive names are removed without notice.

## What's in scope

- Ways a pull request could provision DNS or email routing it shouldn't (bypassing
  the validation checks, claiming a reserved name, editing someone else's file).
- Anything that could expose a contributor's private forwarding address — that
  address must never appear in this public repo or its logs.
- Secret handling in the GitHub Actions / Worker (token, zone/account IDs).

## Out of scope

- Abuse of an individual claimed subdomain's own hosted content (report via abuse, above).
- The security of third-party hosts a subdomain points to (GitHub Pages, Vercel, etc.).
