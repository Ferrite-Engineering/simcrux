#!/usr/bin/env bash
# Usage: tool/x11_keys/drive.sh <trusted|untrusted> <log> -- <command> [args...]
#
# Runs <command> as a trusted or an untrusted client of a private Xvfb that
# has the X SECURITY extension, waits for its window, types into it with
# xdotool, and reports whether it is still running afterwards.
#
# An untrusted client is what `ssh -X` makes of a remote app when the ssh
# client keeps OpenSSH's default of untrusted X forwarding, as macOS does:
# the server hides most extensions from it, XKEYBOARD among them. The cookie
# comes from `xauth generate ... untrusted`, as ssh's does. xdotool itself
# connects as a trusted client, since XTEST is one of the hidden extensions.
#
# The keys: a click in the middle of the window, "ab1", Shift+Q, Backspace,
# Ctrl+S. The command's stdout and stderr go to <log>.
#
# Exit status: 0 the app was still running after the keys; 1 it exited
# before the keys were done, and the output says how; 2 no window appeared.
set -uo pipefail

if [ $# -lt 4 ] || [ "$3" != "--" ]; then
  echo "usage: $0 <trusted|untrusted> <log> -- <command> [args...]" >&2
  exit 64
fi
trust=$1
log=$2
shift 3

work=$(mktemp -d)
display=:77
xvfb=
app=
cleanup() {
  [ -n "$app" ] && kill "$app" 2>/dev/null
  [ -n "$xvfb" ] && kill "$xvfb" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

xauth -q -f "$work/trusted" add "$display" . "$(mcookie)"
# -noreset: without it the server resets when its last client disconnects,
# and a reset revokes every cookie made by `xauth generate`.
Xvfb "$display" -screen 0 1600x1000x24 -auth "$work/trusted" \
  +extension SECURITY -noreset >"$work/xvfb.log" 2>&1 &
xvfb=$!
export DISPLAY=$display
for _ in $(seq 50); do
  XAUTHORITY="$work/trusted" xdpyinfo >/dev/null 2>&1 && break
  sleep 0.2
done

case "$trust" in
  trusted) cp "$work/trusted" "$work/client" ;;
  untrusted)
    XAUTHORITY="$work/trusted" xauth -q -f "$work/client" \
      generate "$display" . untrusted timeout 3600
    ;;
  *) echo "trust must be trusted or untrusted, not $trust" >&2; exit 64 ;;
esac
echo "Extensions a $trust client sees:" \
  "$(XAUTHORITY="$work/client" xdpyinfo -queryExtensions |
    awk '/^number of extensions/ { on = 1; next }
         on && /^    [^ ]/ { sub(/ +\(opcode.*/, ""); sub(/^ +/, ""); print }
         on && /^[^ ]/ { on = 0 }' | paste -sd ',' -)"

XAUTHORITY="$work/client" "$@" >"$log" 2>&1 &
app=$!

export XAUTHORITY="$work/trusted"
window=
for _ in $(seq 120); do
  kill -0 "$app" 2>/dev/null || break
  window=$(xdotool search --onlyvisible --pid "$app" 2>/dev/null | head -1)
  [ -n "$window" ] && break
  sleep 1
done

report_exit() {
  wait "$app"
  local status=$?
  app=
  if [ "$status" -gt 128 ]; then
    echo "The app was killed by SIG$(kill -l $((status - 128)))."
  else
    echo "The app exited with status $status."
  fi
}

if [ -z "$window" ]; then
  if kill -0 "$app" 2>/dev/null; then
    echo "No window appeared in 120 seconds."
  else
    report_exit
  fi
  exit 2
fi

# Let the first frame settle before the click gives the window focus.
sleep 3
eval "$(xdotool getwindowgeometry --shell "$window")"
xdotool mousemove $((X + WIDTH / 2)) $((Y + HEIGHT / 2)) click 1
timeout 10 xdotool windowfocus --sync "$window" ||
  echo "xdotool could not focus the window; typing anyway."
sleep 1
xdotool type --delay 150 'ab1'
xdotool key --delay 150 shift+q BackSpace ctrl+s
sleep 3

if kill -0 "$app" 2>/dev/null; then
  echo "The app was still running after the key presses."
  exit 0
fi
report_exit
exit 1
