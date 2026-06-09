#include <stdlib.h>
#include "my_application.h"

int main(int argc, char** argv) {
  // Force X11 backend to allow MPV window embedding (wid) on Wayland systems.
  setenv("GDK_BACKEND", "x11", 1);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
