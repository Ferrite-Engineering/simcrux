#!/usr/bin/env bash
# Usage: tool/x11_keys/check_app.sh <bundle executable>
#
# Checks that a release build of this app keeps running when keys are pressed
# in its window on an untrusted X display, as under `ssh -X`, and on a
# trusted one. tool/x11_keys/check_key_probe.sh shows the crash this guards
# against and that text and shortcuts still arrive; this runs the real app.
#
# Needs Xvfb, xauth, xdpyinfo and xdotool.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
exe=${1:?usage: $0 <bundle executable>}
logs=$(mktemp -d)

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# The guard works only if the executable exports its definition.
if nm -D --defined-only "$exe" | grep -qw gdk_keymap_lookup_key; then
  echo "$exe exports gdk_keymap_lookup_key."
else
  fail "$exe does not export gdk_keymap_lookup_key; the keymap guard is not linked in"
fi

for trust in untrusted trusted; do
  echo "== $trust display"
  status=0
  "$here/drive.sh" "$trust" "$logs/$trust.log" -- "$exe" || status=$?
  sed 's/^/  | /' "$logs/$trust.log"
  [ "$status" -eq 0 ] || fail "$trust display: drive.sh exited $status"
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "The app kept running through key presses on both displays."
