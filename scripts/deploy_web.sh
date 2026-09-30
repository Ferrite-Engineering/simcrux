#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Build + deploy the OPEN-CORE SimCrux read-only web dashboard viewer to
# Cloudflare (app.simcrux.app).
#
# Cloudflare Workers Static Assets, same model as the WaveCrux app and the
# marketing sites. The viewer ships open-core with no beta expiry — redeploy to
# ship updates to everyone.
#
# The web viewer builds from the dedicated read-only entrypoint
# lib/main_web.dart (no orchestration/subprocess code — browsers can't spawn
# simulators; it only renders a results bundle).
#
# One-time setup:
#   - `wrangler login` (OAuth) to authenticate this machine to the Cloudflare
#     account that holds the simcrux.app zone (it already hosts the marketing
#     site).
#   - app.simcrux.app is provisioned automatically from wrangler.jsonc on
#     first deploy.
#
# Run from the repo root:
#   ./scripts/deploy_web.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=== pub get ==="
flutter pub get

# No build_runner step. SimCrux uses hand-written providers — there is not a
# single .g.dart under lib/ and build_runner is not in dev_dependencies, so the
# `dart run build_runner build` this script used to carry (copy-pasted from a
# sibling product's script) could only ever fail with "Could not find package
# build_runner". Adding the dependency to satisfy a generator with nothing to
# generate would be the wrong fix.

echo "=== l10n ==="
flutter gen-l10n

echo "=== flutter build web (release, read-only entrypoint) ==="
flutter build web --release --target lib/main_web.dart

echo "=== Deploy to Cloudflare (simcrux-viewer -> app.simcrux.app) ==="
if command -v wrangler >/dev/null 2>&1; then
  wrangler deploy
else
  npx --yes wrangler deploy
fi

echo ""
echo "Deployed. Live at https://app.simcrux.app/"
echo "(First deploy provisions the custom domain — DNS/SSL may take a minute.)"
