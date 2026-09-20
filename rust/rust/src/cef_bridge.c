#include "include/capi/cef_app_capi.h"

#include <dlfcn.h>
#include <stddef.h>

typedef int (*roscord_cef_initialize_fn)(const cef_main_args_t *,
                                         const cef_settings_t *, cef_app_t *,
                                         void *);
typedef void (*roscord_cef_shutdown_fn)(void);

int roscord_cef_initialize(void *cef_handle, int argc, char **argv) {
  roscord_cef_initialize_fn initialize =
      (roscord_cef_initialize_fn)dlsym(cef_handle, "cef_initialize");
  if (initialize == NULL) {
    return 0;
  }

  cef_main_args_t main_args = {0};
  main_args.argc = argc;
  main_args.argv = argv;

  cef_settings_t settings = {0};
  settings.size = sizeof(settings);
  settings.no_sandbox = 0;
  settings.multi_threaded_message_loop = 1;
  settings.windowless_rendering_enabled = 1;

  return initialize(&main_args, &settings, NULL, NULL);
}

void roscord_cef_shutdown(void *cef_handle) {
  roscord_cef_shutdown_fn shutdown =
      (roscord_cef_shutdown_fn)dlsym(cef_handle, "cef_shutdown");
  if (shutdown != NULL) {
    shutdown();
  }
}
