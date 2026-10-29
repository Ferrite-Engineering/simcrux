#!/usr/bin/env bash
# Usage: tool/x11_keys/check_key_probe.sh <work-dir>
#
# Shows that the runner's keymap guard (linux/runner/x11_keymap_guard.cc) is
# what keeps a key press on an untrusted X display from crashing a Flutter
# app, and that keys, text and shortcuts still work with it on both kinds of
# display.
#
# Builds tool/x11_keys/key_probe.dart as a stock `flutter create` app twice:
# with the template's runner, and with the guard compiled into it. Then,
# through tool/x11_keys/drive.sh:
#
#   without the guard, untrusted  the first key press kills it with SIGSEGV,
#                                 which shows the check sees the defect
#   without the guard, trusted    keys, text and Ctrl+S arrive
#   with the guard, untrusted     it keeps running; keys, text and Ctrl+S
#                                 arrive
#   with the guard, trusted       keys, text and Ctrl+S arrive
#
# Needs Flutter, the GTK development files, Xvfb, xauth, xdpyinfo and
# xdotool.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?usage: $0 <work-dir>}
mkdir -p "$work"
work=$(cd "$work" && pwd)

# An untrusted client gets no GLX, so the template runner, which has no
# software fallback of its own, would never show a window. Draw in software
# on both displays, with Impeller off as the software renderer needs.
export FLUTTER_LINUX_RENDERER=software

create() {
  local dir=$1
  rm -rf "$dir"
  flutter create --platforms=linux --project-name key_probe "$dir" >/dev/null
  cp "$here/key_probe.dart" "$dir/lib/main.dart"
  sed -i 's|^\( *g_autoptr(FlDartProject) project = fl_dart_project_new();\)$|\1\n  fl_dart_project_set_enable_impeller(project, FALSE);|' \
    "$dir/linux/runner/my_application.cc"
  grep -q 'fl_dart_project_set_enable_impeller(project, FALSE);' \
    "$dir/linux/runner/my_application.cc"
}

create "$work/unguarded"
create "$work/guarded"
cp "$repo/linux/runner/x11_keymap_guard.cc" "$work/guarded/linux/runner/"
sed -i 's|^\( *\)"my_application.cc"$|&\n\1"x11_keymap_guard.cc"|' \
  "$work/guarded/linux/runner/CMakeLists.txt"
grep -q '"x11_keymap_guard.cc"' "$work/guarded/linux/runner/CMakeLists.txt"
cat >>"$work/guarded/linux/runner/CMakeLists.txt" <<'CMAKE'
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11 ${CMAKE_DL_LIBS})
CMAKE

for variant in unguarded guarded; do
  (cd "$work/$variant" && flutter build linux --release)
done
unguarded=$work/unguarded/build/linux/x64/release/bundle/key_probe
guarded=$work/guarded/build/linux/x64/release/bundle/key_probe

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# The guard works only if the executable exports its definition.
if nm -D --defined-only "$guarded" | grep -qw gdk_keymap_lookup_key; then
  echo "The guarded build exports gdk_keymap_lookup_key."
else
  fail "the guarded build does not export gdk_keymap_lookup_key"
fi

# Runs one case; $3 is the exit status drive.sh must give.
run() {
  local name=$1 trust=$2 want=$3 exe=$4 status=0
  echo "== $name"
  "$here/drive.sh" "$trust" "$work/$name.log" -- "$exe" | tee "$work/$name.out" ||
    status=${PIPESTATUS[0]}
  sed 's/^/  | /' "$work/$name.log"
  if [ "$status" -ne "$want" ]; then
    fail "$name: drive.sh exited $status, expected $want"
  fi
}

# Keys, text and the shortcut all reached the framework.
expect_keys() {
  local name=$1 log=$work/$1.log
  for line in 'KEY A' 'KEY B' 'KEY 1' 'KEY Q' 'KEY Backspace' 'KEY S' \
    'TEXT ab1Q' 'SHORTCUT save'; do
    grep -qx "$line" "$log" || fail "$name: no '$line' in the output"
  done
  [ "$(grep '^TEXT ' "$log" | tail -1)" = 'TEXT ab1' ] ||
    fail "$name: the field does not end as 'ab1'"
}

run unguarded-untrusted untrusted 1 "$unguarded"
grep -q 'killed by SIGSEGV' "$work/unguarded-untrusted.out" ||
  fail "unguarded-untrusted: expected a segmentation fault"

run unguarded-trusted trusted 0 "$unguarded"
expect_keys unguarded-trusted

run guarded-untrusted untrusted 0 "$guarded"
expect_keys guarded-untrusted

run guarded-trusted trusted 0 "$guarded"
expect_keys guarded-trusted

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All key probe checks passed."
