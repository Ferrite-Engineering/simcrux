# Publishing the results dashboard

Beyond the single-file HTML report covered in [CI recipes](ci.md), SimCrux's web
build lets you publish the full read-only [web dashboard](web-mode.md) — as a
long-lived site, or as a CI artifact per run or per pull request. Either way the
result is a static directory you can host anywhere; there is no server
component, no build-time configuration and nothing to keep running.

## What you need {#required-artefacts}

1. **Results** — a `simcrux-results.json` (the consolidated form) or
   `results.ndjson` (the streaming form). `--ci` always writes the latter next
   to `simcrux.yaml`; the `simcrux export-dashboard` subcommand wraps either
   format into the consolidated shape and copies the web bundle alongside.
2. **The web bundle** — the `build/web/` directory that
   `flutter build web --target lib/main_web.dart --release` produces in a
   SimCrux source checkout. It does not depend on your results, so build it once
   per SimCrux version and cache it.

## Build the web bundle {#build}

In a SimCrux source checkout:

```bash
flutter pub get
flutter build web --target lib/main_web.dart --release
```

The `--target` matters: without it Flutter builds the desktop app's shell, not
the viewer. Pass `--base-href /some/path/` when the site will not be served from
the root of its domain (a GitHub Pages project site is served from `/<repo>/`).

## Host it {#host}

Copy `build/web/` to the host, then either add a `simcrux-results.json` /
`results.ndjson` next to `index.html`, or leave the bundle empty and open
results with `?results=<url>` or the **Open results file…** button (see
[The web dashboard](web-mode.md)). Any static host works: GitHub Pages, GitLab
Pages, S3 or another object store behind a CDN, Cloudflare, or an internal
nginx.

To try it locally:

```bash
flutter build web --target lib/main_web.dart --release
cd build/web
# Any static server works.
python3 -m http.server 8080
```

Open `http://localhost:8080/?results=./my-results.ndjson` (drop the
`my-results.ndjson` into `build/web/` first) to exercise the deep-link path.

The exported `simcrux-results.json` records the config path and each test's log
and waveform paths on the runner, plus failure messages. Keep that in mind
before publishing a dashboard for a private design to a public host.

## A dashboard per CI run: GitHub Actions {#github-actions}

This job checks out your project and a SimCrux source tree side by side, builds
the `simcrux` binary and the web bundle, runs the regression and publishes the
dashboard.

```yaml
jobs:
  regression:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v5

      - uses: actions/checkout@v5
        with:
          repository: Ferrite-Engineering/simcrux
          path: simcrux-src
          submodules: recursive

      - name: Install Flutter (stable)
        uses: subosito/flutter-action@v2
        with:
          channel: stable

      - name: Build simcrux CLI and web bundle
        working-directory: simcrux-src
        run: |
          flutter pub get
          tool/build_cli.sh
          flutter build web --target lib/main_web.dart --release
          echo "$PWD/build/cli/bundle/bin" >> "$GITHUB_PATH"

      - name: Run regression
        run: |
          simcrux simcrux.yaml --ci --export junit=report.xml

      - name: Bundle dashboard
        if: always()
        run: |
          simcrux export-dashboard ./dashboard \
            --results ./results.ndjson \
            --web-bundle ./simcrux-src/build/web

      - name: Upload dashboard artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: simcrux-dashboard
          path: ./dashboard

      - name: Publish to gh-pages (preview per PR)
        if: github.event_name == 'pull_request'
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./dashboard
          publish_branch: gh-pages
          destination_dir: pr-${{ github.event.pull_request.number }}
```

Your simulators must also be installed on the runner (for example with
`apt-get install iverilog verilator ghdl`).

This produces:

- A downloadable `simcrux-dashboard` artifact on every run.
- A live preview at `https://<owner>.github.io/<repo>/pr-<n>/` for every pull
  request.

### Commenting the URL on PRs {#pr-comment}

If you publish per-PR previews as above, post the URL back to the PR in a
follow-on step:

```yaml
- name: Comment PR with dashboard URL
  if: github.event_name == 'pull_request'
  uses: marocchino/sticky-pull-request-comment@v2
  with:
    header: simcrux-dashboard
    message: |
      Regression dashboard:
      https://${{ github.repository_owner }}.github.io/${{ github.event.repository.name }}/pr-${{ github.event.pull_request.number }}/
```

## GitLab Pages {#gitlab}

GitLab CI's `pages` job hosts the dashboard at the project's Pages URL. Replace
the upload-artifact and gh-pages steps above with:

```yaml
pages:
  stage: deploy
  script:
    - simcrux export-dashboard ./public --results ./results.ndjson --web-bundle ./simcrux-src/build/web
  artifacts:
    paths: [public]
```

The dashboard lives at `https://<group>.gitlab.io/<project>/`.

## Watching a long run {#watching}

`--ci` appends each finished test to `results.ndjson` as it goes. If your CI can
serve the job's working directory while the run is in progress, point a hosted
copy of the web viewer at that file with `?results=<url>` and reload the page to
see new rows — the viewer reads the document once per page load and does not
poll. Serve the file with `Cache-Control: no-cache` so a reload fetches the new
rows, and allow cross-origin requests when the viewer is hosted on a different
origin.

## The hosted viewer {#hosted}

A hosted copy of the viewer runs at [app.simcrux.app](https://app.simcrux.app/).
Open a local results file in it with **Open results file…** — the file is read
in your browser and never uploaded.
