# Contributing to denizens

Thanks for claiming a spot on devis.im. Most pull requests are reviewed quickly when they follow these rules.

## One PR, one name

- Add **exactly one** file per pull request: `domains/<yourname>.json`.
- The **filename is the name you're claiming**. `rajan.json` → `rajan.devis.im` and `rajan@devis.im`.
- Names are lowercase and may contain letters, numbers, and hyphens only. No leading/trailing hyphens.

## Before you open the PR

- [ ] `owner.github` matches **your** GitHub username (the PR author).
- [ ] Your file validates against [`schema.json`](./schema.json) — keep `"$schema": "../schema.json"` at the top.
- [ ] The name isn't already taken (a file with that name doesn't already exist).
- [ ] The name isn't in [`reserved.json`](./reserved.json).
- [ ] You used `CNAME` **or** `A`/`AAAA`, not both. Addresses are public/routable — no loopback, private, or link-local IPs.
- [ ] You did **not** put your private forwarding email anywhere in the file.
- [ ] You hold fewer than **2 names** already (the per-account cap — release one to free a slot).

## What gets a PR rejected

- Claiming a reserved name, or a name someone already owns.
- Editing or deleting **someone else's** file.
- A `github` owner that doesn't match the PR author (you can only claim names for yourself).
- More than one file (or more than one name) in a single PR.
- A `URL` record — redirects aren't supported yet, so the claim would merge into a dead name.
- Anything intended for phishing, malware, spam, or impersonation.

## Email forwarding

If you set `"email": { "enabled": true }`, you'll receive a link **after merge** to privately submit the address you want mail forwarded to. Never put that address in this repository — it's public. See the README for why.

## Changing or releasing a name

Open a new PR that edits your file (to change targets) or deletes it (to release the name). There is no dashboard; the repository is the source of truth.

## Changing the automation

The Ruby scripts in `scripts/` are specced in `spec/`; the Worker in `worker/` is specced with vitest. Keep behaviour and specs in sync:

```sh
bundle install && bundle exec rspec
cd worker && npm install && npm test
```

When you add or change a claim field, update `schema.json`, the README field table, and this file together.

## Questions

Open an issue (templates exist for claim help, abuse reports, and name releases), or email [irajanbhattarai@gmail.com](mailto:irajanbhattarai@gmail.com). Abuse goes to [abuse@devis.im](mailto:abuse@devis.im); security issues follow [`SECURITY.md`](./SECURITY.md).
