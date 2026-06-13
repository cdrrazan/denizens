# denizens

The public registry for **devis.im** — claim your own `name.devis.im` subdomain and an optional `name@devis.im` email alias, free, by opening a pull request.

> A *denizen* is an inhabitant of a place. Claim your name and you're a denizen of devis.im.

## What you get

When your claim is approved you get one identity on devis.im:

- **A subdomain** — `yourname.devis.im`, pointed wherever you like: GitHub Pages, Vercel, Netlify, a raw server, or a redirect to another URL. HTTPS is included automatically.
- **An email alias** *(optional)* — `yourname@devis.im` that forwards to your real inbox. People email `yourname@devis.im`, it lands in your private inbox, and your real address is never exposed.

Your subdomain and email share a single name. Claim `rajan` and both `rajan.devis.im` and `rajan@devis.im` are yours.

## How it works

1. **You open a pull request** that adds one file: `domains/yourname.json`, describing where your subdomain points.
2. **A maintainer reviews it.** If the name is available and the request looks fine, it's merged. If something needs changing, you'll get a comment — update your PR and it'll be re-reviewed.
3. **On merge, automation provisions your subdomain** — the DNS record and HTTPS certificate are created for you within minutes.
4. **If you asked for email**, you'll get a link to privately add your forwarding address (see below), then a one-time verification click.

### Why your forwarding email is *not* in the pull request

This repository is **public**. Anything in your `domains/yourname.json` file — and its entire git history — is visible to the world and scraped by bots forever.

The whole point of `yourname@devis.im` is to *hide* your real address. So your real forwarding email never goes in the PR. After your subdomain is merged, you submit it through a private form; Cloudflare then sends a verification link to that inbox, you click it, and forwarding goes live. Your real address is held inside Cloudflare's verified-destination system — this registry never stores it.

To opt in, set `"email": { "enabled": true }` in your file. Leave the `email` block out for a subdomain only.

## Claiming a name

New to pull requests? Follow the slow, no-assumptions walkthrough in
[**Your first claim, step by step**](./docs/good-first-claim.md). The short version:

1. **Fork** this repository.
2. **Create** `domains/<yourname>.json`. The filename *is* the name you're claiming — `rajan.json` claims `rajan.devis.im` and `rajan@devis.im`. Use lowercase letters, numbers, and hyphens only.
3. **Fill it in** using the format below. Keep `"$schema": "../schema.json"` at the top so your editor validates it as you type.
4. **Set `owner.github`** to your own GitHub username — it must match the author of the pull request.
5. **Open a pull request.** Automated checks run on your file; fix anything they flag.
6. **Wait for review.** On merge, your subdomain is set up automatically.

## File format

```json
{
  "$schema": "../schema.json",
  "owner": {
    "github": "your-github-username"
  },
  "record": {
    "CNAME": "your-github-username.github.io"
  },
  "email": {
    "enabled": true
  }
}
```

| Field | Required | Description |
| --- | --- | --- |
| `owner.github` | yes | Your GitHub username. Must match the PR author. |
| `owner.email` | no | A *public* contact email. **Never** your private forwarding address. |
| `record` | yes | Where the subdomain points (see record types below). |
| `email.enabled` | no | `true` if you also want `name@devis.im` forwarding. Omit for subdomain only. |
| `proxied` | no | Route through Cloudflare's proxy. Defaults to `false`. |

### Record types

Pick whichever fits how your site is hosted. You may use `CNAME` **or** `A`/`AAAA`, not both.

| Type | Value | Use for |
| --- | --- | --- |
| `CNAME` | a single hostname | GitHub Pages, Vercel, Netlify, most hosts |
| `A` | array of IPv4 addresses | a raw server with an IPv4 address |
| `AAAA` | array of IPv6 addresses | a raw server with an IPv6 address |
| `TXT` | a string or array of strings | verification records, etc. |
| `URL` | a URL | redirect the subdomain elsewhere |

## Reserved names

Some names can't be claimed — DNS infrastructure (`www`, `ns1`, `mail`…), email role addresses (`abuse`, `postmaster`, `admin`, `security`…), and a handful of reserved service words. The full list is in [`reserved.json`](./reserved.json). These stay with devis.im so that system mail and abuse reports always reach the operators rather than a third party.

## After your name goes live

- **Subdomain** — live within minutes of merge, HTTPS included.
- **Email** — live once you submit your forwarding address through the private form and click the verification link Cloudflare sends to that inbox. That click is required and only you can do it; it also proves you control the inbox you're forwarding to.

## Changing or removing your name

This is a fire-and-forget registry — there's no dashboard. To change where your subdomain points, or your forwarding target, open a new pull request editing your file. To release a name, delete your file in a pull request.

## Abuse

Subdomains or aliases used for phishing, malware, spam, or impersonation will be removed without notice. Report abuse to `abuse@devis.im`.

## License

[MIT](./LICENSE) © Rajan Bhattarai
