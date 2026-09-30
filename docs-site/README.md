# SimCrux documentation site

The SimCrux user guide, published at <https://docs.simcrux.app/>. This README
is not part of the built site.

## Preview

Use the same versions CI pins:

```bash
python3 -m venv .venv
.venv/bin/pip install mkdocs==1.6.0 mkdocs-material==9.5.27 \
  pymdown-extensions==10.9 Pygments==2.19.2
cd docs-site
../.venv/bin/mkdocs serve
```

## Build

```bash
cd docs-site
mkdocs build --strict
```

`--strict` turns every warning into a failure: a broken relative link, a
missing anchor, or a page that is not in `nav` stops the build. The output
lands in `docs-site/site/`, which is git-ignored.

## Deploy

`.github/workflows/docs.yml` builds the site on every pull request that
touches `docs-site/`, and deploys the build output with Wrangler
(`wrangler.jsonc`, Workers Static Assets on `docs.simcrux.app`) on merge to
`main`. Without the Cloudflare secrets the deploy job records a notice and
skips, so forks stay green.

## Conventions

- **One page per slug.** Each page is `docs/<slug>.md` and is served at
  `https://docs.simcrux.app/<slug>` (the build writes `<slug>.html`, with
  `use_directory_urls: false`). The app's contextual help links point at
  these slugs, so do not rename or move a page without updating the app.
  Keep existing heading anchors (`{#id}`) stable for the same reason.
- **Tier badges.** Mark a feature's tier right after its heading or name with
  exactly `<span class="tier tier-pro">Pro</span>`,
  `<span class="tier tier-enterprise">Enterprise</span>` or
  `<span class="tier tier-edu">EDU</span>`. Styles live in
  `docs/assets/brand.css`. Unmarked means open core.
- **Known issues.** Describe current behaviour, not intended behaviour. When
  something does not work as designed, say so in a
  `!!! warning "Known issue"` admonition and remove it when the fix ships.
- **Links.** Between pages, use relative `.md` links. Marketing pages are
  absolute `https://simcrux.app/<page>`; suite pages are
  `https://edacrux.app/<page>`.
- **Behaviour changes update these pages in the same pull request.** A label,
  shortcut, flag, config key or default that changes in `lib/` changes here
  too.
