#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#include <gtk/gtk.h>
#include <cairo.h>

#include "flutter/generated_plugin_registrant.h"
#include "video_player_plugin.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// ─────────────────────────────────────────────
// ACTIVATE
// ─────────────────────────────────────────────
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Header bar logic
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif

  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "zap_share");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "zap_share");
  }

  // RGBA support
  GdkScreen* rgba_screen = gtk_window_get_screen(window);
  GdkVisual* visual = gdk_screen_get_rgba_visual(rgba_screen);
  if (visual != nullptr) {
    gtk_widget_set_visual(GTK_WIDGET(window), visual);
  }

  gtk_window_set_default_size(window, 1280, 720);

  // CSS styling
  GtkCssProvider* provider = gtk_css_provider_new();
  gtk_css_provider_load_from_data(provider,
    "window { background-color: rgba(0,0,0,0); }"
    "#flutter_view, fl-view, .fl-view { background-color: rgba(0,0,0,0); }",
    -1, nullptr);

  gtk_style_context_add_provider_for_screen(
      rgba_screen,
      GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  // Flutter project
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_set_app_paintable(GTK_WIDGET(view), TRUE);
  gtk_widget_set_name(GTK_WIDGET(view), "flutter_view");

  if (visual != nullptr) {
    gtk_widget_set_visual(GTK_WIDGET(view), visual);
  }

  // Layout (simple, stable)
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // 🔥 IMPORTANT: Plugin registration (ONLY THIS)
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlPluginRegistrar) video_player_registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view), "VideoPlayerPlugin");
  video_player_plugin_register_with_registrar(video_player_registrar);

  gtk_widget_grab_focus(GTK_WIDGET(view));
  gtk_widget_show_all(GTK_WIDGET(window));
}

// ─────────────────────────────────────────────
// COMMAND LINE
// ─────────────────────────────────────────────
static gboolean my_application_local_command_line(
    GApplication* application,
    gchar*** arguments,
    int* exit_status) {

  MyApplication* self = MY_APPLICATION(application);

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

// ─────────────────────────────────────────────
// LIFECYCLE
// ─────────────────────────────────────────────
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

// ─────────────────────────────────────────────
// CLASS INIT
// ─────────────────────────────────────────────
static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

// ─────────────────────────────────────────────
// NEW INSTANCE
// ─────────────────────────────────────────────
MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(
      my_application_get_type(),
      "application-id", APPLICATION_ID,
      "flags", G_APPLICATION_NON_UNIQUE,
      nullptr));
}