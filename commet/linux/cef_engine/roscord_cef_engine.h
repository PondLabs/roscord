// C ABI between the Rust `cef_host` and the C++ CEF engine
// (libroscord_cef_engine.so).
//
// The Rust host owns everything that is not CEF: argument and payload
// validation, the authenticated socket, surface policy, profiles and the
// wire protocol.  After validating the locked runtime it dlopen()s
// Release/libcef.so with RTLD_GLOBAL and then this engine, which has no
// DT_NEEDED entry for libcef: its CEF symbols bind to the library the host
// already loaded, so the dynamic loader never searches for CEF on its own.
//
// Threading: every command may be called from any thread; the engine posts
// it to the CEF UI thread.  Callbacks run on the CEF UI thread, except
// `filter_request` (CEF IO thread) and `log` (any thread).  Strings passed
// to callbacks are only valid for the duration of the call.
//
// Keep this header and rust/rust/src/cef_engine.rs in step; the ABI version
// is checked at load time.

#ifndef ROSCORD_CEF_ENGINE_H_
#define ROSCORD_CEF_ENGINE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ROSCORD_CEF_ENGINE_ABI_VERSION 1u

#if defined(ROSCORD_CEF_ENGINE_IMPLEMENTATION)
#define ROSCORD_CEF_ENGINE_EXPORT __attribute__((visibility("default")))
#else
#define ROSCORD_CEF_ENGINE_EXPORT
#endif

// Pointer kinds; values match the wire `PointerKind` order.
enum {
  ROSCORD_POINTER_DOWN = 0,
  ROSCORD_POINTER_UP = 1,
  ROSCORD_POINTER_MOVE = 2,
  ROSCORD_POINTER_ENTER = 3,
  ROSCORD_POINTER_LEAVE = 4,
  ROSCORD_POINTER_WHEEL = 5,
};

// IME phases; values match the wire `ImePhase` order.
enum {
  ROSCORD_IME_START = 0,
  ROSCORD_IME_UPDATE = 1,
  ROSCORD_IME_COMMIT = 2,
  ROSCORD_IME_CANCEL = 3,
};

// before_browse results.
enum {
  ROSCORD_NAVIGATION_ALLOW = 0,
  ROSCORD_NAVIGATION_CANCEL = 1,
};

// log levels.
enum {
  ROSCORD_LOG_INFO = 0,
  ROSCORD_LOG_WARNING = 1,
  ROSCORD_LOG_ERROR = 2,
};

typedef struct roscord_cef_engine_callbacks {
  void* context;
  // A frame is about to navigate.  Returns ROSCORD_NAVIGATION_ALLOW or
  // ROSCORD_NAVIGATION_CANCEL.  Redirects arrive here too.
  int32_t (*before_browse)(void* context, uint64_t surface_id,
                           const char* url, int32_t main_frame,
                           int32_t user_gesture, int32_t is_redirect);
  // The page asked for a new window or tab.  The engine never creates one;
  // the host decides whether the app opens the URL externally.
  void (*open_url)(void* context, uint64_t surface_id, const char* url,
                   int32_t user_gesture);
  // A frame was written to the shared ring named `buffer`.
  void (*frame_ready)(void* context, uint64_t surface_id, const char* buffer,
                      uint32_t slot, uint32_t width, uint32_t height,
                      uint64_t frame_sequence);
  void (*browser_created)(void* context, uint64_t surface_id);
  // The browser is gone and its ring was released.  Also sent when the
  // browser could not be created.
  void (*browser_closed)(void* context, uint64_t surface_id);
  // The main frame failed to load (aborted loads are not reported).
  void (*load_failed)(void* context, uint64_t surface_id, int32_t error_code,
                      const char* url);
  void (*certificate_error)(void* context, uint64_t surface_id,
                            const char* url);
  void (*renderer_gone)(void* context, uint64_t surface_id, int32_t status);
  // A CSS cursor name ("default", "pointer", "text", ...).
  void (*cursor_changed)(void* context, uint64_t surface_id,
                         const char* cursor);
  // A page called window.__roscordBrowserRuntimeSend(json) in `frame_url`.
  void (*script_message)(void* context, uint64_t surface_id,
                         const char* frame_url, const char* json);
  // Content-filtering hook, only called when the config enables it.
  // Returns 1 to cancel the request.
  int32_t (*filter_request)(void* context, uint64_t surface_id,
                            const char* url, const char* initiator,
                            int32_t resource_type);
  void (*log)(void* context, int32_t level, const char* message);
} roscord_cef_engine_callbacks;

typedef struct roscord_cef_engine_config {
  uint32_t abi_version;
  // Validated runtime root; Release/ holds libcef.so and everything it loads.
  const char* cef_root;
  // CefSettings.root_cache_path; every persistent profile lives below it.
  const char* profile_root;
  // Random token used in shared-memory names, so they reveal nothing about
  // the transport nonce.
  const char* frame_namespace;
  int32_t software_rendering;
  int32_t filter_requests;
  // Off-screen frame rate (1-60).
  int32_t frame_rate;
} roscord_cef_engine_config;

typedef struct roscord_cef_browser_options {
  const char* url;
  // Profile directory below profile_root, or NULL for an in-memory context.
  const char* cache_path;
  uint32_t width;
  uint32_t height;
  double device_scale_factor;
  // Runs in every frame before page scripts, or NULL.
  const char* document_start_script;
} roscord_cef_browser_options;

ROSCORD_CEF_ENGINE_EXPORT uint32_t roscord_cef_engine_abi_version(void);

// Runs a CEF child process (renderer, GPU, utility, zygote).  Returns the
// child's exit code, or -1 when `argv` is not a child invocation.
ROSCORD_CEF_ENGINE_EXPORT int32_t roscord_cef_engine_execute_process(int32_t argc, char** argv);

// Initializes CEF in the browser process and waits for its context.
// Returns 1 on success.
ROSCORD_CEF_ENGINE_EXPORT int32_t roscord_cef_engine_initialize(
    int32_t argc, char** argv, const roscord_cef_engine_config* config,
    const roscord_cef_engine_callbacks* callbacks);

// Starts creating an off-screen browser.  Returns 1 when creation was
// scheduled; browser_created or browser_closed follows.
ROSCORD_CEF_ENGINE_EXPORT int32_t roscord_cef_engine_create_browser(
    uint64_t surface_id, const roscord_cef_browser_options* options);

ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_close_browser(uint64_t surface_id);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_navigate(uint64_t surface_id, const char* url);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_resize(uint64_t surface_id, uint32_t width,
                               uint32_t height, double device_scale_factor);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_focus(uint64_t surface_id, int32_t focused);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_pointer(uint64_t surface_id, int32_t kind, double x,
                                double y, uint32_t buttons,
                                uint32_t modifiers, double delta_x,
                                double delta_y);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_key(uint64_t surface_id, const char* key,
                            const char* code, uint32_t modifiers,
                            int32_t pressed);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_ime(uint64_t surface_id, int32_t phase,
                            const char* text, uint32_t selection_start,
                            uint32_t selection_end);
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_execute_script(uint64_t surface_id,
                                       const char* script);

// Closes every browser, waits for them, and shuts CEF down.  Must be called
// on the thread that called roscord_cef_engine_initialize.
ROSCORD_CEF_ENGINE_EXPORT void roscord_cef_engine_shutdown(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ROSCORD_CEF_ENGINE_H_
