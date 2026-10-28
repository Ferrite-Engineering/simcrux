#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Launch a SimCrux Linux release bundle on Xvfb and prove it draws, on a
# display with OpenGL and on one without (simcrux#36).
#
# Flutter's GTK embedder draws nothing when the display cannot create an
# OpenGL context (VNC, X forwarding, a virtual machine without 3D), and the
# window never appears. The runner probes the display first and selects the
# software renderer by itself. This checks both halves:
#
#   glx     Xvfb with GLX (Mesa llvmpipe): draws, and does NOT fall back
#   noglx   Xvfb -extension GLX: draws, and logs the software fallback
#
# Each Xvfb maps its framebuffer to a file (-fbdir), so the screen is copied
# without any X client tool; xwd_frame.py turns it into a PNG and decides
# whether a frame was drawn. Needs Xvfb, dbus-run-session, Mesa (GL, EGL and
# GLES) and python3.
#
#   tool/linux_smoke/launch_smoke.sh [bundle-dir] [out-dir]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${1:-build/linux/x64/release/bundle}"
OUT="${2:-build/linux-smoke}"
APP="$BUNDLE/simcrux"
RUN_SECONDS="${RUN_SECONDS:-35}"
SNAP_SECONDS="${SNAP_SECONDS:-25}"

[[ -x "$APP" ]] || { echo "no $APP" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

scenario() {
  local name="$1" glx="$2"
  local fb="$OUT/fb-$name" home="$OUT/home-$name" rt="$OUT/rt-$name"
  mkdir -p "$fb" "$home" "$rt"
  chmod 700 "$rt"

  local xargs=(:97 -screen 0 1280x800x24 -fbdir "$fb" -nolisten tcp -br)
  [[ "$glx" == off ]] && xargs+=(-extension GLX)
  Xvfb "${xargs[@]}" >"$OUT/$name.xvfb.log" 2>&1 &
  local xpid=$! _
  for _ in $(seq 100); do [[ -S /tmp/.X11-unix/X97 ]] && break; sleep 0.1; done

  local envs=(DISPLAY=:97 HOME="$home" XDG_RUNTIME_DIR="$rt")
  [[ "$glx" == on ]] && envs+=(LIBGL_ALWAYS_SOFTWARE=1)
  env -u DBUS_SESSION_BUS_ADDRESS -u FLUTTER_LINUX_RENDERER -u WAYLAND_DISPLAY \
    "${envs[@]}" timeout --kill-after=5 "$RUN_SECONDS" \
    dbus-run-session -- "$APP" >"$OUT/$name.log" 2>&1 &
  local apid=$!
  sleep "$SNAP_SECONDS"
  cp "$fb/Xvfb_screen0" "$OUT/$name.xwd"
  wait "$apid"
  kill "$xpid" 2>/dev/null
  wait "$xpid" 2>/dev/null
  rm -rf "$fb" "$rt"
}

scenario glx on
scenario noglx off

frames="$(python3 "$HERE/xwd_frame.py" "$OUT"/*.xwd 2>&1)"
rm -f "$OUT"/*.xwd
echo "$frames"

failures=()
grep -q '^glx frame=yes' <<<"$frames" || failures+=("no frame with GLX")
grep -q '^noglx frame=yes' <<<"$frames" || failures+=("no frame without GLX")
grep -q 'falling back to the software renderer' "$OUT/noglx.log" \
  || failures+=("no software fallback logged without GLX")
grep -q 'falling back to the software renderer' "$OUT/glx.log" \
  && failures+=("fell back although GLX was there")

if [[ ${#failures[@]} -eq 0 ]]; then
  echo "LAUNCH SMOKE PASSED"
  exit 0
fi
for name in glx noglx; do
  echo "--- $name.log (last 30 lines) ---"
  tail -30 "$OUT/$name.log"
done
printf 'LAUNCH SMOKE FAILED: %s\n' "$(IFS=';'; echo "${failures[*]}")"
exit 1
