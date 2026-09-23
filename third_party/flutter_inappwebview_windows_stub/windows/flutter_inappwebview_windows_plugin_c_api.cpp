// Cutover stub for the Windows flutter_inappwebview plugin.
//
// After the CEF BrowserRuntime cutover Windows renders every roscord-owned
// web surface through the bundled CEF host, so this plugin registers no
// method channels and links no foreign engine. The symbol must keep the
// exact upstream registration name because the generated plugin registrant
// calls it by name.

#include "include/flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

void FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  // Intentionally empty: no foreign-engine backend exists behind this name.
  (void)registrar;
}
