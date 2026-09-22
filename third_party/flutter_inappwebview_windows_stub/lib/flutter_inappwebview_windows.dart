/// Cutover stub for the Windows implementation of `flutter_inappwebview`.
///
/// After the CEF BrowserRuntime cutover every roscord-owned web surface on
/// Windows renders through the bundled CEF host. This package keeps the
/// `flutter_inappwebview_windows` plugin name resolvable so `flutter pub get`
/// and the Windows plugin registrant keep working, but the native side
/// registers no method channels and links no foreign engine. Any attempt to
/// drive a web view on Windows fails closed through the platform interface
/// default instead of reaching an engine.
library flutter_inappwebview_windows;
