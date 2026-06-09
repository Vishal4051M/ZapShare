#ifndef VIDEO_PLAYER_PLUGIN_H_
#define VIDEO_PLAYER_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <X11/Xlib.h>

G_BEGIN_DECLS

#define VIDEO_PLAYER_PLUGIN_TYPE (video_player_plugin_get_type())

G_DECLARE_FINAL_TYPE(
    VideoPlayerPlugin,
    video_player_plugin,
    VIDEO_PLAYER,
    PLUGIN,
    GObject)

struct _VideoPlayerPlugin {
  GObject parent_instance;

  FlMethodChannel* channel;
  FlView* view;

  // Raw X11 child window for MPV embedding (created via Xlib, NOT GDK)
  Display* x_display;
  Window   x_video_window;  // 0 = not created

  // MPV child process PID (0 = not running)
  GPid    mpv_pid;

  // Unix socket path for JSON IPC
  gchar*  ipc_socket_path;

  // IPC socket file descriptor (-1 = not connected)
  int     ipc_fd;

  // TRUE once IPC is fully connected and observers are set up
  gboolean ipc_connected;

  // GIO channel for async IPC reads
  GIOChannel* ipc_channel;
  guint       ipc_watch_id;

  // Timer for deferred IPC connection
  guint       ipc_connect_timer_id;
  int         ipc_connect_attempts;

  // Pending IPC read buffer (newline-delimited JSON)
  GString*    ipc_buffer;

  // Command queue: commands sent before IPC is connected
  GQueue*     pending_commands;

  // Event queue (JSON strings pushed to Dart on poll)
  GQueue*     event_queue;
  GMutex      event_mutex;

  // Request-ID counter
  int         request_id_counter;
};

void video_player_plugin_register_with_registrar(FlPluginRegistrar* registrar);

G_END_DECLS

#endif