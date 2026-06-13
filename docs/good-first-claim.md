# Your first claim, step by step

New to pull requests? This is the slow, no-assumptions version of
[claiming a name](../README.md#claiming-a-name). It takes about five minutes and
gives you `yourname.devis.im` (plus an optional `yourname@devis.im` alias).

You'll do everything on GitHub — no command line needed.

## 1. Pick your name

Lowercase letters, numbers, and hyphens only. No leading or trailing hyphen.
`rajan`, `jane-doe`, and `dev2` are fine; `Rajan`, `-x`, and `my_name` are not.

Two things to check first:

- It's **not already taken** — there must be no file `domains/<yourname>.json`
  in this repo yet.
- It's **not reserved** — it's not in [`reserved.json`](../reserved.json) (DNS
  and email-role words devis.im keeps for itself).

## 2. Create your file on GitHub

1. Go to the repo and press <kbd>.</kbd> (period) to open the web editor, or
   click **Add file → Create new file**.
2. Name it exactly `domains/yourname.json` — the filename **is** the name you're
   claiming.
3. Paste this and edit the two values:

   ```json
   {
     "$schema": "../schema.json",
     "owner": { "github": "your-github-username" },
     "record": { "CNAME": "your-github-username.github.io" }
   }
   ```

   - `owner.github` → **your** GitHub username. It must match the account that
     opens the pull request — you can only claim names for yourself.
   - `record.CNAME` → where the subdomain points. `your-username.github.io` is
     right for a GitHub Pages site. Hosting elsewhere? See the
     [record types](../README.md#record-types) (Vercel, Netlify, a raw IP, etc.).

   Want email too? Add an `email` block:

   ```json
   {
     "$schema": "../schema.json",
     "owner": { "github": "your-github-username" },
     "record": { "CNAME": "your-github-username.github.io" },
     "email": { "enabled": true }
   }
   ```

   > Never put your real forwarding address in this file — the repo is public.
   > You submit it privately **after** merge. That's the whole point of the alias.

## 3. Open the pull request

GitHub will offer to commit to a new branch and open a PR — accept that. Add one
file only: your `domains/yourname.json`. (PRs that touch other files or claim
more than one name are rejected.)

## 4. Watch the checks

An automated check runs on your PR and posts a single comment saying what passed
or failed — name available, name not reserved, owner matches you, no private
email in the file, and so on. If something's flagged, edit your file in the same
PR and the check re-runs. Green means a maintainer reviews and merges.

## 5. After merge

- **Subdomain** goes live within minutes — `https://yourname.devis.im`, HTTPS
  included.
- **Email** (if you enabled it) — you'll get a comment linking to a private form.
  Submit your forwarding address there, click the verification link Cloudflare
  emails you, and `yourname@devis.im` starts forwarding.

## Changing or releasing it later

No dashboard — everything is a pull request. Edit your file to change where it
points; delete your file to release the name. See
[Changing or removing your name](../README.md#changing-or-removing-your-name).

Stuck? Open a [claim-help issue](https://github.com/cdrrazan/denizens/issues/new/choose).
