// Keeps a key press from crashing the app on an X display that refuses it
// the XKEYBOARD extension, as the X SECURITY extension does for an untrusted
// client: `ssh -X` from an ssh client that keeps OpenSSH's default of
// untrusted X forwarding, as macOS does.
//
// Flutter's GTK embedder works out the keyboard layout on the first key
// press, and on the way it asks gdk_keymap_lookup_key() about every keycode
// from 0 to 127. An X display has no keycodes below its minimum, which is 8
// on every server. With XKEYBOARD, GDK answers those lookups from tables that
// start at keycode 0. Without it, GDK falls back to the core keymap, subtracts
// the minimum keycode from 0 in unsigned arithmetic, reads far outside the
// table, and the process gets a segmentation fault.
//
// This file defines gdk_keymap_lookup_key in the executable itself. The
// dynamic linker binds the embedder's calls, and GTK's, to the executable's
// definition before the library's, so every lookup comes here first. A
// keycode the X display does not have maps to no keyval (0, which is what
// GDK returns for a key with nothing mapped), and every other lookup goes to
// GDK's own function unchanged. Nothing calls into this file: compiling it
// into the runner is the whole installation. The linker exports the
// definition because libflutter_linux_gtk.so, which the runner links, refers
// to it; the untrusted-client CI job checks that it did.
//
// The same file is in each product's runner, and each Pro overlay compiles
// its open core's copy.

#include <dlfcn.h>
#include <gdk/gdk.h>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

using LookupKeyFunction = guint (*)(GdkKeymap*, const GdkKeymapKey*);

// GDK's own gdk_keymap_lookup_key, the next definition after this one.
LookupKeyFunction gdk_lookup_key() {
  static const LookupKeyFunction function = reinterpret_cast<LookupKeyFunction>(
      dlsym(RTLD_NEXT, "gdk_keymap_lookup_key"));
  return function;
}

// Whether [keymap] belongs to the X display and that display has no key
// [keycode]. False for any other display, which keeps its own checks.
bool outside_x_keycodes(GdkKeymap* keymap, guint keycode) {
#ifdef GDK_WINDOWING_X11
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display) ||
      gdk_keymap_get_for_display(display) != keymap) {
    return false;
  }
  // Read from the connection setup: no request goes to the server.
  int min_keycode = 0;
  int max_keycode = 0;
  XDisplayKeycodes(GDK_DISPLAY_XDISPLAY(display), &min_keycode, &max_keycode);
  return keycode < static_cast<guint>(min_keycode) ||
         keycode > static_cast<guint>(max_keycode);
#else
  return false;
#endif
}

}  // namespace

guint gdk_keymap_lookup_key(GdkKeymap* keymap, const GdkKeymapKey* key) {
  if (key != nullptr && outside_x_keycodes(keymap, key->keycode)) {
    return 0;
  }
  LookupKeyFunction lookup = gdk_lookup_key();
  return lookup != nullptr ? lookup(keymap, key) : 0;
}
