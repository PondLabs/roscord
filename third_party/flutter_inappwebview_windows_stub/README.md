# `flutter_inappwebview_windows` cutover stub

After the CEF BrowserRuntime cutover (#132, epic #110) every roscord-owned
web surface on Windows renders through the bundled CEF host. The upstream
`flutter_inappwebview_windows` 0.6.0 plugin downloads WebView2 and WIL through
NuGet at CMake configure time and links `WebView2Loader.dll` into the app, so
it cannot remain in the Windows target graph.

This directory is a purpose-built stub, not a vendored copy: it keeps the
`flutter_inappwebview_windows` plugin name resolvable (the generated Windows
plugin registrant calls
`FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar` by name) while
registering no method channels and linking no WebView2. The root
`flutter_inappwebview` package and its Android/iOS/macOS/web implementations
are untouched, so those preserved flows keep working.

Wired through `dependency_overrides` in `commet/pubspec.yaml`. The clean
artifact scans (`tools/qualify_windows_artifact.py` and
`tools/test_cef_host_contract.py`) prove the Windows bundle carries no
`WebView2Loader.dll`, no `CreateCoreWebView2` reference, and no
`desktop_webview_window` registration.
