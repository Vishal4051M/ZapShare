// ============================================================================
// video_player_plugin.cc  —  Linux MPV Process + Unix Socket IPC
//
// Creates a raw X11 child window via Xlib, spawns `mpv --wid=<XID>`,
// and controls it over a Unix domain socket (JSON IPC).
// ============================================================================

#include "video_player_plugin.h"

#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <errno.h>

G_DEFINE_TYPE(VideoPlayerPlugin, video_player_plugin, G_TYPE_OBJECT)

// ─── Forward declarations ───────────────────────────────────────────────────
static void method_call_cb(FlMethodChannel*, FlMethodCall*, gpointer);
static gboolean on_ipc_readable(GIOChannel*, GIOCondition, gpointer);
static gboolean try_connect_ipc(gpointer);
static void setup_ipc_channel(VideoPlayerPlugin*);
static void flush_pending_commands(VideoPlayerPlugin*);
static void push_event(VideoPlayerPlugin*, const gchar*);

// ─── Helpers ────────────────────────────────────────────────────────────────

static gchar* make_socket_path() {
    return g_strdup_printf("/tmp/zapshare-mpv-%d.sock", getpid());
}

static int try_connect_once(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        return fd;
    }
    close(fd);
    return -1;
}

static void send_ipc_raw(VideoPlayerPlugin* self, const gchar* json_line) {
    if (self->ipc_fd < 0) {
        // Queue for later
        if (self->pending_commands) {
            g_queue_push_tail(self->pending_commands, g_strdup(json_line));
        }
        return;
    }

    std::string msg(json_line);
    if (msg.empty() || msg.back() != '\n') msg += '\n';

    ssize_t total = 0;
    ssize_t len = (ssize_t)msg.size();
    while (total < len) {
        ssize_t written = write(self->ipc_fd, msg.c_str() + total, len - total);
        if (written < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                g_usleep(1000);
                continue;
            }
            std::cerr << "[MPV IPC] Write error: " << strerror(errno) << std::endl;
            return;
        }
        total += written;
    }
}

static gchar* build_ipc_json(const char** args, int nargs, int request_id) {
    GString* s = g_string_new("{\"command\":[");
    for (int i = 0; i < nargs; i++) {
        if (i > 0) g_string_append_c(s, ',');
        const char* a = args[i];
        if (strcmp(a, "true") == 0 || strcmp(a, "false") == 0) {
            g_string_append(s, a);
        } else {
            char* end = nullptr;
            strtod(a, &end);
            if (end != a && *end == '\0') {
                g_string_append(s, a);
            } else {
                g_string_append_c(s, '"');
                for (const char* p = a; *p; p++) {
                    if (*p == '"' || *p == '\\') g_string_append_c(s, '\\');
                    g_string_append_c(s, *p);
                }
                g_string_append_c(s, '"');
            }
        }
    }
    g_string_append_printf(s, "],\"request_id\":%d}", request_id);
    return g_string_free(s, FALSE);
}

static void observe_property(VideoPlayerPlugin* self, const char* name, int id) {
    gchar* cmd = g_strdup_printf(
        "{\"command\":[\"observe_property\",%d,\"%s\"],\"request_id\":%d}",
        id, name, self->request_id_counter++);
    send_ipc_raw(self, cmd);
    g_free(cmd);
}

// ─── IPC event ingestion ────────────────────────────────────────────────────

static gboolean on_ipc_readable(GIOChannel* source, GIOCondition condition,
                                gpointer data) {
    VideoPlayerPlugin* self = VIDEO_PLAYER_PLUGIN(data);

    if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) {
        std::cerr << "[MPV IPC] Channel closed/error" << std::endl;
        self->ipc_watch_id = 0;
        return FALSE;
    }

    char buf[8192];
    gsize bytes_read = 0;
    while (true) {
        GIOStatus status = g_io_channel_read_chars(source, buf, sizeof(buf) - 1,
                                                   &bytes_read, nullptr);
        if (status == G_IO_STATUS_NORMAL && bytes_read > 0) {
            buf[bytes_read] = '\0';
            g_string_append(self->ipc_buffer, buf);
        } else {
            break;
        }
    }

    // Process newline-delimited JSON lines
    while (true) {
        char* nl = strchr(self->ipc_buffer->str, '\n');
        if (!nl) break;
        
        gsize line_len = nl - self->ipc_buffer->str;
        gchar* line = g_strndup(self->ipc_buffer->str, line_len);
        if (line_len > 0) {
            push_event(self, line);
        }
        g_free(line);
        g_string_erase(self->ipc_buffer, 0, line_len + 1);
    }

    return TRUE;
}

static void push_event(VideoPlayerPlugin* self, const gchar* json) {
    g_mutex_lock(&self->event_mutex);
    if (g_queue_get_length(self->event_queue) < 2000) {
        g_queue_push_tail(self->event_queue, g_strdup(json));
    }
    g_mutex_unlock(&self->event_mutex);
}

// ─── Deferred IPC connection ────────────────────────────────────────────────

static gboolean try_connect_ipc(gpointer data) {
    VideoPlayerPlugin* self = VIDEO_PLAYER_PLUGIN(data);
    self->ipc_connect_attempts++;

    if (self->ipc_connect_attempts > 50) {
        std::cerr << "[MPV IPC] Gave up connecting after 10s" << std::endl;
        self->ipc_connect_timer_id = 0;
        return FALSE;
    }

    int fd = try_connect_once(self->ipc_socket_path);
    if (fd < 0) return TRUE;  // Keep trying

    // ✅ Connected!
    self->ipc_fd = fd;
    self->ipc_connected = TRUE;
    self->ipc_connect_timer_id = 0;

    std::cout << "[MPV IPC] ✅ Connected to " << self->ipc_socket_path
              << " (attempt " << self->ipc_connect_attempts << ")" << std::endl;

    setup_ipc_channel(self);

    // Observe properties
    observe_property(self, "time-pos", 1);
    observe_property(self, "duration", 2);
    observe_property(self, "pause", 3);
    observe_property(self, "paused-for-cache", 4);
    observe_property(self, "eof-reached", 5);
    observe_property(self, "track-list", 6);

    // Flush queued commands
    flush_pending_commands(self);

    return FALSE;
}

static void setup_ipc_channel(VideoPlayerPlugin* self) {
    if (self->ipc_channel) {
        g_io_channel_shutdown(self->ipc_channel, FALSE, nullptr);
        g_io_channel_unref(self->ipc_channel);
    }
    self->ipc_channel = g_io_channel_unix_new(self->ipc_fd);
    g_io_channel_set_encoding(self->ipc_channel, nullptr, nullptr);
    g_io_channel_set_flags(self->ipc_channel, G_IO_FLAG_NONBLOCK, nullptr);
    self->ipc_watch_id = g_io_add_watch(
        self->ipc_channel,
        (GIOCondition)(G_IO_IN | G_IO_HUP | G_IO_ERR),
        on_ipc_readable, self);
}

static void flush_pending_commands(VideoPlayerPlugin* self) {
    if (!self->pending_commands) return;
    int count = 0;
    while (!g_queue_is_empty(self->pending_commands)) {
        gchar* cmd = (gchar*)g_queue_pop_head(self->pending_commands);
        send_ipc_raw(self, cmd);
        g_free(cmd);
        count++;
    }
    if (count > 0) {
        std::cout << "[MPV IPC] 📤 Flushed " << count << " queued command(s)" << std::endl;
    }
}

// ─── X11 underlay window management ─────────────────────────────────────────

/// Create a raw X11 window as a child of the ROOT window.
/// We position it exactly behind the Flutter app window. This is the only way
/// in X11 to have a 'hole' since GTK3 draws to the Toplevel window, and any
/// child of the Toplevel would ALWAYS draw over Flutter UI.
static Window create_x11_child(VideoPlayerPlugin* self) {
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
    if (!toplevel) return 0;

    self->x_display = GDK_DISPLAY_XDISPLAY(gdk_display_get_default());
    Window root = DefaultRootWindow(self->x_display);

    gint x = 0, y = 0;
    gdk_window_get_root_origin(gtk_widget_get_window(toplevel), &x, &y);

    GtkAllocation allocation;
    gtk_widget_get_allocation(GTK_WIDGET(self->view), &allocation);
    int w = allocation.width;
    int h = allocation.height;
    if (w < 1) w = 1280;
    if (h < 1) h = 720;

    self->x_video_window = XCreateSimpleWindow(
        self->x_display, root,
        x + allocation.x, y + allocation.y,
        (unsigned int)w, (unsigned int)h,
        0, 0, BlackPixel(self->x_display, DefaultScreen(self->x_display))
    );

    // 1. Force the window to be an OVERLAY (Topmost, bypassing Window Manager)
    // This is required for 100% zero-copy performance on high-bitrate Linux setups.
    XSetWindowAttributes attr;
    attr.override_redirect = True;
    XChangeWindowAttributes(self->x_display, self->x_video_window, CWOverrideRedirect, &attr);

    // 2. Motif hints (No decorations)
    struct {
        unsigned long flags;
        unsigned long functions;
        unsigned long decorations;
        long input_mode;
        unsigned long status;
    } motif_hints = {2, 0, 0, 0, 0}; 
    Atom motif_atom = XInternAtom(self->x_display, "_MOTIF_WM_HINTS", False);
    XChangeProperty(self->x_display, self->x_video_window, motif_atom, motif_atom, 
                    32, PropModeReplace, (unsigned char *)&motif_hints, 5);

    // 3. Set _NET_WM_STATE to ABOVE (Overlay mode)
    Atom wm_state = XInternAtom(self->x_display, "_NET_WM_STATE", False);
    Atom state_above = XInternAtom(self->x_display, "_NET_WM_STATE_ABOVE", False);
    XChangeProperty(self->x_display, self->x_video_window, wm_state, XA_ATOM, 
                    32, PropModeReplace, (unsigned char *)&state_above, 1);

    // Map it and RAISE it so it stays completely ON TOP of everything
    XRaiseWindow(self->x_display, self->x_video_window);
    XMapWindow(self->x_display, self->x_video_window);
    
    // Explicitly grab input focus for keyboard shortcuts
    XSelectInput(self->x_display, self->x_video_window, KeyPressMask | KeyReleaseMask | ButtonPressMask | PointerMotionMask);
    XSetInputFocus(self->x_display, self->x_video_window, RevertToParent, CurrentTime);

    XSync(self->x_display, False);

    std::cout << "[MPV X11] Created underlay window " << self->x_video_window
              << " at " << x << "," << y << std::endl;

    // Make the main GTK window background transparent so we can see through it
    GtkCssProvider* provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, "window { background-color: rgba(0,0,0,0); }", -1, nullptr);
    gtk_style_context_add_provider(gtk_widget_get_style_context(toplevel),
        GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);

    return self->x_video_window;
}

static void resize_x11_child(VideoPlayerPlugin* self) {
    if (!self->x_display || !self->x_video_window || !self->view) return;
    
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
    if (!toplevel || !gtk_widget_get_window(toplevel)) return;

    gint root_x = 0, root_y = 0;
    gdk_window_get_root_origin(gtk_widget_get_window(toplevel), &root_x, &root_y);

    GtkAllocation alloc;
    gtk_widget_get_allocation(GTK_WIDGET(self->view), &alloc);
    if (alloc.width < 1 || alloc.height < 1) return;

    // Move to match the Flutter view's absolute screen coordinates
    XMoveResizeWindow(self->x_display, self->x_video_window, 
                      root_x + alloc.x, root_y + alloc.y,
                      (unsigned int)alloc.width, (unsigned int)alloc.height);
    
    // Ensure it stays on top
    XRaiseWindow(self->x_display, self->x_video_window);
    
    // Explicitly grab focus so keyboard controls work immediately
    XSetInputFocus(self->x_display, self->x_video_window, RevertToParent, CurrentTime);
    
    XSync(self->x_display, False);
}

static void destroy_x11_child(VideoPlayerPlugin* self) {
    if (self->x_display && self->x_video_window) {
        XDestroyWindow(self->x_display, self->x_video_window);
        XSync(self->x_display, False);
        self->x_video_window = 0;
    }
}

// ─── Initialize: create window + spawn MPV ──────────────────────────────────

static gboolean do_initialize(VideoPlayerPlugin* self) {
    // 1. Create raw X11 child window
    if (!self->x_video_window) {
        if (!create_x11_child(self)) return FALSE;

        // Track GTK resizes
        g_signal_connect(self->view, "size-allocate",
            G_CALLBACK(+[](GtkWidget*, GdkRectangle*, gpointer data) {
                resize_x11_child((VideoPlayerPlugin*)data);
            }), self);

        // Also track Toplevel window movement to keep underlay synced
        GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
        if (toplevel) {
            g_signal_connect(toplevel, "configure-event",
                G_CALLBACK(+[](GtkWidget*, GdkEventConfigure*, gpointer data) -> gboolean {
                    resize_x11_child((VideoPlayerPlugin*)data);
                    return FALSE;
                }), self);
        }
    }

    Window xid = self->x_video_window;

    // 2. Prepare IPC socket
    if (self->ipc_socket_path) g_free(self->ipc_socket_path);
    self->ipc_socket_path = make_socket_path();
    unlink(self->ipc_socket_path);

    // 3. Spawn MPV
    gchar* wid_arg = g_strdup_printf("--wid=%lu", (unsigned long)xid);
    gchar* ipc_arg = g_strdup_printf("--input-ipc-server=%s",
                                     self->ipc_socket_path);

    const gchar* argv[] = {
        "mpv",
        wid_arg,
        ipc_arg,
        // Video output
        "--vo=gpu",
        "--hwdec=auto",
        // Performance: critical for 4K HEVC
        "--vd-lavc-threads=0",
        "--vd-lavc-dr=yes",
        "--vd-lavc-fast=yes",
        // Behavior: idle so MPV waits for loadfile commands
        "--idle=yes",
        "--keep-open=yes",
        // Enable MPV's own light-weight UI (OSC)
        "--osc=yes",
        "--osd-bar=yes",
        "--input-default-bindings=yes",
        "--no-terminal",
        "--no-input-terminal",
        // Logging via IPC only
        "--msg-level=all=status",
        // Playback
        "--video-sync=display-resample",
        "--cache=yes",
        "--demuxer-max-bytes=512M",
        "--demuxer-readahead-secs=600",
        "--force-seekable=yes",
        nullptr
    };

    // Force MPV to use X11 instead of Wayland.
    // If MPV detects Wayland, it ignores --wid and creates a new window.
    // Unsetting WAYLAND_DISPLAY forces it to fall back to XWayland / X11.
    gchar** envp = g_get_environ();
    envp = g_environ_unsetenv(envp, "WAYLAND_DISPLAY");

    GError* error = nullptr;
    gboolean spawned = g_spawn_async(
        nullptr, (gchar**)argv, envp,
        static_cast<GSpawnFlags>(G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD),
        nullptr, nullptr, &self->mpv_pid, &error);

    g_strfreev(envp);
    g_free(wid_arg);
    g_free(ipc_arg);

    if (!spawned) {
        std::cerr << "[MPV] ✗ Failed to spawn: "
                  << (error ? error->message : "unknown") << std::endl;
        if (error) g_error_free(error);
        return FALSE;
    }

    std::cout << "[MPV] ✅ Spawned PID=" << self->mpv_pid
              << " wid=" << xid
              << " ipc=" << self->ipc_socket_path << std::endl;

    // 4. Deferred IPC connection
    self->ipc_connect_attempts = 0;
    self->ipc_connect_timer_id = g_timeout_add(200, try_connect_ipc, self);

    return TRUE;
}

// ─── Cleanup helper ─────────────────────────────────────────────────────────

static void do_dispose_mpv(VideoPlayerPlugin* self) {
    if (self->ipc_connect_timer_id) {
        g_source_remove(self->ipc_connect_timer_id);
        self->ipc_connect_timer_id = 0;
    }
    if (self->ipc_watch_id) {
        g_source_remove(self->ipc_watch_id);
        self->ipc_watch_id = 0;
    }
    if (self->ipc_channel) {
        g_io_channel_shutdown(self->ipc_channel, FALSE, nullptr);
        g_io_channel_unref(self->ipc_channel);
        self->ipc_channel = nullptr;
    }
    if (self->ipc_fd >= 0) {
        close(self->ipc_fd);
        self->ipc_fd = -1;
    }
    self->ipc_connected = FALSE;

    if (self->mpv_pid != 0) {
        kill(self->mpv_pid, SIGTERM);
        g_usleep(200 * 1000);
        kill(self->mpv_pid, SIGKILL);
        g_spawn_close_pid(self->mpv_pid);
        self->mpv_pid = 0;
    }

    if (self->ipc_socket_path) {
        unlink(self->ipc_socket_path);
        g_free(self->ipc_socket_path);
        self->ipc_socket_path = nullptr;
    }

    if (self->pending_commands) {
        while (!g_queue_is_empty(self->pending_commands))
            g_free(g_queue_pop_head(self->pending_commands));
    }

    destroy_x11_child(self);
}

// ─── Method channel handler ─────────────────────────────────────────────────

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
    VideoPlayerPlugin* self = VIDEO_PLAYER_PLUGIN(user_data);
    const gchar* method = fl_method_call_get_name(method_call);
    FlValue* args = fl_method_call_get_args(method_call);

    // ── initialize ──
    if (strcmp(method, "initialize") == 0) {
        if (self->mpv_pid != 0 && self->x_video_window) {
            fl_method_call_respond_success(method_call,
                fl_value_new_int((int64_t)self->x_video_window), nullptr);
            return;
        }
        if (do_initialize(self)) {
            fl_method_call_respond_success(method_call,
                fl_value_new_int((int64_t)self->x_video_window), nullptr);
        } else {
            fl_method_call_respond_error(method_call, "INIT_FAILED",
                "Failed to spawn MPV", nullptr, nullptr);
        }
        return;
    }

    // ── getXid ──
    if (strcmp(method, "getXid") == 0) {
        fl_method_call_respond_success(method_call,
            fl_value_new_int((int64_t)self->x_video_window), nullptr);
        return;
    }

    // ── getSocketPath ──
    if (strcmp(method, "getSocketPath") == 0) {
        fl_method_call_respond_success(method_call,
            fl_value_new_string(self->ipc_socket_path ? self->ipc_socket_path : ""),
            nullptr);
        return;
    }

    // ── sendCommand: raw JSON string ──
    if (strcmp(method, "sendCommand") == 0) {
        if (fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
            send_ipc_raw(self, fl_value_get_string(args));
            fl_method_call_respond_success(method_call, nullptr, nullptr);
        } else {
            fl_method_call_respond_error(method_call, "INVALID_ARGS",
                "Expected JSON string", nullptr, nullptr);
        }
        return;
    }

    // ── command: list of args → JSON ──
    if (strcmp(method, "command") == 0) {
        if (fl_value_get_type(args) == FL_VALUE_TYPE_LIST) {
            size_t len = fl_value_get_length(args);
            const char** cmd_args = new const char*[len];
            gchar** temp = g_new0(gchar*, len);

            for (size_t i = 0; i < len; i++) {
                FlValue* v = fl_value_get_list_value(args, i);
                switch (fl_value_get_type(v)) {
                    case FL_VALUE_TYPE_STRING:
                        cmd_args[i] = fl_value_get_string(v);
                        break;
                    case FL_VALUE_TYPE_INT:
                        temp[i] = g_strdup_printf("%" G_GINT64_FORMAT,
                            fl_value_get_int(v));
                        cmd_args[i] = temp[i];
                        break;
                    case FL_VALUE_TYPE_FLOAT:
                        temp[i] = g_strdup_printf("%g", fl_value_get_float(v));
                        cmd_args[i] = temp[i];
                        break;
                    case FL_VALUE_TYPE_BOOL:
                        cmd_args[i] = fl_value_get_bool(v) ? "true" : "false";
                        break;
                    default:
                        cmd_args[i] = "null";
                        break;
                }
            }

            int rid = self->request_id_counter++;
            gchar* json = build_ipc_json(cmd_args, (int)len, rid);
            send_ipc_raw(self, json);
            g_free(json);
            delete[] cmd_args;
            for (size_t i = 0; i < len; i++) {
                if (temp[i]) g_free(temp[i]);
            }
            g_free(temp);
            fl_method_call_respond_success(method_call, nullptr, nullptr);
        } else {
            fl_method_call_respond_error(method_call, "INVALID_ARGS",
                "Expected list", nullptr, nullptr);
        }
        return;
    }

    // ── pollEvents ──
    if (strcmp(method, "pollEvents") == 0) {
        g_mutex_lock(&self->event_mutex);
        guint count = g_queue_get_length(self->event_queue);
        FlValue* list = fl_value_new_list();
        for (guint i = 0; i < count; i++) {
            gchar* json = (gchar*)g_queue_pop_head(self->event_queue);
            fl_value_append_take(list, fl_value_new_string(json));
            g_free(json);
        }
        g_mutex_unlock(&self->event_mutex);
        fl_method_call_respond_success(method_call, list, nullptr);
        return;
    }

    // ── resize ──
    if (strcmp(method, "resize") == 0) {
        resize_x11_child(self);
        fl_method_call_respond_success(method_call, nullptr, nullptr);
        return;
    }

    // ── dispose ──
    if (strcmp(method, "dispose") == 0) {
        do_dispose_mpv(self);
        fl_method_call_respond_success(method_call, nullptr, nullptr);
        return;
    }

    fl_method_call_respond_not_implemented(method_call, nullptr);
}

// ─── GObject lifecycle ──────────────────────────────────────────────────────

static void video_player_plugin_dispose(GObject* object) {
    VideoPlayerPlugin* self = VIDEO_PLAYER_PLUGIN(object);
    do_dispose_mpv(self);

    if (self->ipc_buffer) {
        g_string_free(self->ipc_buffer, TRUE);
        self->ipc_buffer = nullptr;
    }
    if (self->pending_commands) {
        g_queue_free(self->pending_commands);
        self->pending_commands = nullptr;
    }
    if (self->event_queue) {
        while (!g_queue_is_empty(self->event_queue))
            g_free(g_queue_pop_head(self->event_queue));
        g_queue_free(self->event_queue);
        self->event_queue = nullptr;
    }
    g_mutex_clear(&self->event_mutex);

    G_OBJECT_CLASS(video_player_plugin_parent_class)->dispose(object);
}

static void video_player_plugin_class_init(VideoPlayerPluginClass* klass) {
    G_OBJECT_CLASS(klass)->dispose = video_player_plugin_dispose;
}

static void video_player_plugin_init(VideoPlayerPlugin* self) {
    self->mpv_pid = 0;
    self->x_display = nullptr;
    self->x_video_window = 0;
    self->ipc_socket_path = nullptr;
    self->ipc_fd = -1;
    self->ipc_connected = FALSE;
    self->ipc_channel = nullptr;
    self->ipc_watch_id = 0;
    self->ipc_connect_timer_id = 0;
    self->ipc_connect_attempts = 0;
    self->ipc_buffer = g_string_new("");
    self->pending_commands = g_queue_new();
    self->event_queue = g_queue_new();
    g_mutex_init(&self->event_mutex);
    self->request_id_counter = 100;
}

// ─── Registration ───────────────────────────────────────────────────────────

void video_player_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
    VideoPlayerPlugin* plugin = VIDEO_PLAYER_PLUGIN(
        g_object_new(video_player_plugin_get_type(), nullptr));

    plugin->view = FL_VIEW(fl_plugin_registrar_get_view(registrar));

    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    plugin->channel = fl_method_channel_new(
        fl_plugin_registrar_get_messenger(registrar),
        "zapshare/video_player",
        FL_METHOD_CODEC(codec));

    fl_method_channel_set_method_call_handler(
        plugin->channel, method_call_cb, plugin, nullptr);
}