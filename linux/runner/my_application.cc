#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include <cstring>

#include "flutter/generated_plugin_registrant.h"
#include "crux_file_dialogs.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The token a directed cross-probe hands the target so it may come forward:
// on Wayland an xdg-activation token from the compositor (GDK's launch
// context asks for one), on X11 a "_TIME<user time>" startup id, and null
// where the desktop supports neither, which makes no hand-off.
static FlValue* foreground_yield_token(GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    // GLib's launch context query checks for an app info; this one is never
    // launched.
    g_autoptr(GError) error = nullptr;
    GAppInfo* info = g_app_info_create_from_commandline(
        "true", "SimCrux", G_APP_INFO_CREATE_NONE, &error);
    if (info == nullptr) {
      return nullptr;
    }
    GdkAppLaunchContext* context = gdk_display_get_app_launch_context(display);
    gchar* token = g_app_launch_context_get_startup_notify_id(
        G_APP_LAUNCH_CONTEXT(context), info, nullptr);
    g_object_unref(context);
    g_object_unref(info);
    FlValue* value = nullptr;
    if (token != nullptr && token[0] != '\0') {
      value = fl_value_new_string(token);
    }
    g_free(token);
    return value;
  }
#endif
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) {
    // The time of this app's last user event (the click that sent the
    // cross-probe) on the X server both apps share, as GTK's "_TIME" startup
    // id: the target presents its window with that timestamp, so the window
    // manager's focus-stealing prevention sees a fresh user action.
    g_autofree gchar* token = g_strdup_printf(
        "_TIME%u", static_cast<guint>(gdk_x11_display_get_user_time(display)));
    return fl_value_new_string(token);
  }
#endif
  (void)display;
  return nullptr;
}

// Answers crux_window_chrome's `crux_window_chrome/foreground` channel, the
// directed cross-probe's foreground hand-off. `yieldForeground {pid}` answers
// the token above; `takeForeground {token}` sets the window's startup id to a
// non-empty token (on Wayland GTK activates the window with it; a "_TIME"
// id presents it with that timestamp), presents the window and answers true;
// where the desktop declines to raise it (focus-stealing prevention), the
// window manager marks it as asking for attention. Anything else is not
// implemented.
static void foreground_method_call(FlMethodChannel* channel,
                                   FlMethodCall* method_call,
                                   gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(GError) error = nullptr;
  gboolean answered = FALSE;
  if (strcmp(method, "yieldForeground") == 0) {
    g_autoptr(FlValue) token = foreground_yield_token(window);
    answered = fl_method_call_respond_success(method_call, token, &error);
  } else if (strcmp(method, "takeForeground") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* token = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                         ? fl_value_lookup_string(args, "token")
                         : nullptr;
    if (token != nullptr && fl_value_get_type(token) == FL_VALUE_TYPE_STRING &&
        fl_value_get_string(token)[0] != '\0') {
      gtk_window_set_startup_id(window, fl_value_get_string(token));
    }
    gtk_window_present(window);
    g_autoptr(FlValue) raised = fl_value_new_bool(TRUE);
    answered = fl_method_call_respond_success(method_call, raised, &error);
  } else {
    answered = fl_method_call_respond_not_implemented(method_call, &error);
  }
  if (!answered) {
    g_warning("Failed to answer the foreground call: %s",
              error != nullptr ? error->message : "unknown error");
  }
}

static void register_foreground_channel(FlView* view, GtkWindow* window) {
  // Lives as long as the process: there is one window and one engine.
  static FlMethodChannel* channel = nullptr;
  if (channel != nullptr) {
    return;
  }
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                  "crux_window_chrome/foreground",
                                  FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, foreground_method_call,
                                            window, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  crux_select_renderer_for_display("SimCrux");

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // SimCrux draws its own VS Code-style title bar in-window (app logo +
  // inline menus + custom caption buttons) and uses the `window_manager`
  // plugin to remove the OS decorations at runtime (TitleBarStyle.hidden).
  // We therefore install NO GTK header bar here — a custom GTK titlebar set
  // via gtk_window_set_titlebar would survive window_manager's
  // gtk_window_set_decorated(FALSE) and double up with our Flutter chrome.
  // Just set the window title (used by the taskbar / window list); the
  // Flutter VirtualWindowFrame restores the drop shadow and resize edges a
  // decorationless window loses.
  gtk_window_set_title(window, "SimCrux");

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_set_size_request(GTK_WIDGET(window), 800, 500);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // The software renderer draws through Skia. With Impeller on, the engine
  // aborts at the first line of text ("Impeller DlText cannot be drawn to a
  // Skia canvas"), so turn Impeller off whenever software rendering is
  // selected, by the probe above or by the user.
  if (g_strcmp0(g_getenv("FLUTTER_LINUX_RENDERER"), "software") == 0) {
    fl_dart_project_set_enable_impeller(project, FALSE);
  }
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // File dialogs drawn in-process with GTK, on this window's display, since
  // file_picker's DBus portal is often unreachable on a remote display; and
  // an X server's refusal of the alert sound (ssh -X) kept from ending the
  // process.
  crux_register_file_dialog_channel(view);
  crux_tolerate_refused_x_bell("SimCrux");
  // A directed cross-probe from a peer brings this window forward.
  register_foreground_channel(view, window);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);
  crux_refuse_to_start_without_display("SimCrux");
  crux_prefer_x11_when_only_display_is_set();
  crux_skip_accessibility_bridge_without_session_bus("SimCrux");

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
