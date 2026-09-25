// The Linux CEF engine behind the Rust `cef_host`.
//
// Every surface is an Alloy-style off-screen browser.  OnPaint copies CEF's
// buffer into a POSIX shared-memory frame ring (browser_frame_ring.h) and
// reports the slot to the host, which forwards it to the app as frame_ready;
// the app's texture plugin maps the same region read-only.  Navigation,
// popups, permissions, dialogs and downloads fail closed: the host's surface
// policy decides navigations, and nothing opens a window of its own.
//
// See roscord_cef_engine.h for the ABI and threading rules.

#define ROSCORD_CEF_ENGINE_IMPLEMENTATION
#include "roscord_cef_engine.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "include/base/cef_compiler_specific.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_task.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_helpers.h"

#include "browser_frame_ring.h"
#include "browser_input.h"
#include "cef_cursor_names.h"

namespace {

using browser_surface::CefFlagsFor;
using browser_surface::CefMouseButtonFor;
using browser_surface::KeyCodes;
using browser_surface::KeyCodesForCode;
using browser_surface::kFrameRingMaxDimension;
using browser_surface::kFrameRingSlots;
using browser_surface::kWireButtonPrimary;
using browser_surface::TypedUnits;
using browser_surface::WindowsKeyCodeForKey;

static_assert(browser_surface::kCefFlagShift == EVENTFLAG_SHIFT_DOWN);
static_assert(browser_surface::kCefFlagControl == EVENTFLAG_CONTROL_DOWN);
static_assert(browser_surface::kCefFlagAlt == EVENTFLAG_ALT_DOWN);
static_assert(browser_surface::kCefFlagLeftMouse ==
              EVENTFLAG_LEFT_MOUSE_BUTTON);
static_assert(browser_surface::kCefFlagMiddleMouse ==
              EVENTFLAG_MIDDLE_MOUSE_BUTTON);
static_assert(browser_surface::kCefFlagRightMouse ==
              EVENTFLAG_RIGHT_MOUSE_BUTTON);
static_assert(browser_surface::kCefFlagCommand == EVENTFLAG_COMMAND_DOWN);
static_assert(browser_surface::kCefFlagIsKeyPad == EVENTFLAG_IS_KEY_PAD);
static_assert(browser_surface::kCefFlagIsLeft == EVENTFLAG_IS_LEFT);
static_assert(browser_surface::kCefFlagIsRight == EVENTFLAG_IS_RIGHT);
static_assert(browser_surface::kCefMouseLeft == MBT_LEFT);
static_assert(browser_surface::kCefMouseMiddle == MBT_MIDDLE);
static_assert(browser_surface::kCefMouseRight == MBT_RIGHT);

constexpr char kSendMessageName[] = "roscord_browser_runtime_send";
constexpr char kDocumentStartScriptKey[] = "document_start_script";

// Browser-process state.  Child processes never create it.
struct EngineState {
  roscord_cef_engine_callbacks callbacks{};
  std::string cef_root;
  std::string profile_root;
  std::string frame_namespace;
  bool software_rendering = false;
  bool filter_requests = false;
  int frame_rate = 30;

  std::mutex mutex;
  std::condition_variable condition;
  bool context_ready = false;
  // Browsers scheduled for creation and not yet closed.
  int live_browsers = 0;
};

EngineState* g_state = nullptr;

void Log(int32_t level, const std::string& message) {
  if (g_state != nullptr && g_state->callbacks.log != nullptr) {
    g_state->callbacks.log(g_state->callbacks.context, level,
                           message.c_str());
  }
}

void BrowserGone() {
  std::lock_guard<std::mutex> lock(g_state->mutex);
  if (g_state->live_browsers > 0) --g_state->live_browsers;
  g_state->condition.notify_all();
}

class FunctionTask : public CefTask {
 public:
  explicit FunctionTask(std::function<void()> function)
      : function_(std::move(function)) {}

  void Execute() override { function_(); }

 private:
  std::function<void()> function_;
  IMPLEMENT_REFCOUNTING(FunctionTask);
};

void PostUi(std::function<void()> function) {
  CefPostTask(TID_UI, new FunctionTask(std::move(function)));
}

// One surface's shared-memory ring.  UI thread only.
class SharedFrameRing {
 public:
  SharedFrameRing() = default;
  SharedFrameRing(const SharedFrameRing&) = delete;
  SharedFrameRing& operator=(const SharedFrameRing&) = delete;
  ~SharedFrameRing() { Release(); }

  // Copies one BGRA frame into the next slot.  Grows the region (under a new
  // name) when the frame no longer fits.
  bool Publish(uint64_t surface_id, const void* bgra, int width, int height,
               uint32_t* slot, uint64_t* sequence) {
    if (width <= 0 || height <= 0 ||
        static_cast<uint32_t>(width) > kFrameRingMaxDimension ||
        static_cast<uint32_t>(height) > kFrameRingMaxDimension) {
      return false;
    }
    const uint64_t needed = browser_surface::FrameRingSlotBytesFor(
        static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    if (region_ == nullptr || needed > slot_bytes_) {
      if (!Allocate(surface_id, needed)) return false;
    }
    const uint32_t target = next_slot_;
    next_slot_ = (next_slot_ + 1) % kFrameRingSlots;
    const uint64_t frame_sequence = next_sequence_++;
    if (!browser_surface::FrameRingWriteBgra(
            region_, target, frame_sequence, bgra,
            static_cast<uint32_t>(width), static_cast<uint32_t>(height))) {
      return false;
    }
    *slot = target;
    *sequence = frame_sequence;
    return true;
  }

  const std::string& name() const { return name_; }

  void Release() {
    if (region_ != nullptr) {
      munmap(region_, region_bytes_);
      region_ = nullptr;
    }
    if (!name_.empty()) {
      shm_unlink(name_.c_str());
      name_.clear();
    }
    region_bytes_ = 0;
    slot_bytes_ = 0;
  }

 private:
  bool Allocate(uint64_t surface_id, uint64_t slot_bytes) {
    Release();
    ++generation_;
    const std::string name = "/roscord-cef-" + g_state->frame_namespace + "-" +
                             std::to_string(surface_id) + "-" +
                             std::to_string(generation_);
    const int fd = shm_open(name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                            S_IRUSR | S_IWUSR);
    if (fd < 0) {
      Log(ROSCORD_LOG_ERROR, "cannot create a shared frame ring");
      return false;
    }
    const uint64_t bytes = browser_surface::FrameRingRegionBytes(slot_bytes);
    // ftruncate alone reserves nothing on tmpfs: a full /dev/shm would only
    // show up as SIGBUS when the ring is first written.  Allocating the pages
    // now turns that into a dropped frame.
    if (ftruncate(fd, static_cast<off_t>(bytes)) != 0 ||
        posix_fallocate(fd, 0, static_cast<off_t>(bytes)) != 0) {
      close(fd);
      shm_unlink(name.c_str());
      Log(ROSCORD_LOG_ERROR, "cannot size the shared frame ring");
      return false;
    }
    void* region = mmap(nullptr, static_cast<size_t>(bytes),
                        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (region == MAP_FAILED) {
      shm_unlink(name.c_str());
      Log(ROSCORD_LOG_ERROR, "cannot map the shared frame ring");
      return false;
    }
    browser_surface::FrameRingInitialize(region, slot_bytes);
    name_ = name;
    region_ = region;
    region_bytes_ = static_cast<size_t>(bytes);
    slot_bytes_ = slot_bytes;
    next_slot_ = 0;
    return true;
  }

  std::string name_;
  void* region_ = nullptr;
  size_t region_bytes_ = 0;
  uint64_t slot_bytes_ = 0;
  uint32_t generation_ = 0;
  uint32_t next_slot_ = 0;
  uint64_t next_sequence_ = 1;
};

// Only created when filtering is enabled; asks the host for every request.
class FilteringRequestHandler : public CefResourceRequestHandler {
 public:
  FilteringRequestHandler(uint64_t surface_id, std::string initiator)
      : surface_id_(surface_id), initiator_(std::move(initiator)) {}

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    if (g_state == nullptr || g_state->callbacks.filter_request == nullptr) {
      return RV_CONTINUE;
    }
    const std::string url = request->GetURL().ToString();
    const int32_t cancel = g_state->callbacks.filter_request(
        g_state->callbacks.context, surface_id_, url.c_str(),
        initiator_.c_str(), static_cast<int32_t>(request->GetResourceType()));
    return cancel == 1 ? RV_CANCEL : RV_CONTINUE;
  }

 private:
  const uint64_t surface_id_;
  const std::string initiator_;
  IMPLEMENT_REFCOUNTING(FilteringRequestHandler);
};

class SurfaceClient : public CefClient,
                      public CefRenderHandler,
                      public CefLifeSpanHandler,
                      public CefRequestHandler,
                      public CefLoadHandler,
                      public CefDisplayHandler,
                      public CefContextMenuHandler,
                      public CefDialogHandler,
                      public CefJSDialogHandler,
                      public CefPermissionHandler,
                      public CefDownloadHandler {
 public:
  SurfaceClient(uint64_t surface_id, uint32_t width, uint32_t height,
                double device_scale_factor, std::string context_key)
      : surface_id_(surface_id), context_key_(std::move(context_key)) {
    SetView(width, height, device_scale_factor);
  }

  uint64_t surface_id() const { return surface_id_; }
  const std::string& context_key() const { return context_key_; }
  CefRefPtr<CefBrowser> browser() const { return browser_; }

  void SetView(uint32_t width, uint32_t height, double device_scale_factor) {
    view_width_ = static_cast<int>(std::clamp<uint32_t>(width, 1, 16384));
    view_height_ = static_cast<int>(std::clamp<uint32_t>(height, 1, 16384));
    device_scale_factor_ =
        std::isfinite(device_scale_factor) && device_scale_factor >= 0.25 &&
                device_scale_factor <= 8.0
            ? device_scale_factor
            : 1.0;
  }

  // Closes now if the browser exists, or as soon as it does.
  void RequestClose() {
    close_requested_ = true;
    if (browser_ != nullptr) browser_->GetHost()->CloseBrowser(true);
  }

  void Pointer(int32_t kind, double x, double y, uint32_t buttons,
               uint32_t modifiers, double delta_x, double delta_y) {
    if (browser_ == nullptr) return;
    CefRefPtr<CefBrowserHost> host = browser_->GetHost();
    CefMouseEvent event;
    event.x = static_cast<int>(std::lround(x));
    event.y = static_cast<int>(std::lround(y));
    switch (kind) {
      case ROSCORD_POINTER_DOWN: {
        uint32_t changed = buttons & ~pressed_buttons_;
        if (changed == 0) changed = buttons != 0 ? buttons : kWireButtonPrimary;
        changed &= ~(changed - 1);  // lowest button that went down
        pressed_buttons_ |= changed;
        const int button = CefMouseButtonFor(changed);
        const int clicks = ClickCount(button, event.x, event.y);
        event.modifiers = CefFlagsFor(modifiers, pressed_buttons_);
        host->SendMouseClickEvent(
            event, static_cast<cef_mouse_button_type_t>(button), false,
            clicks);
        break;
      }
      case ROSCORD_POINTER_UP: {
        uint32_t released = buttons;
        if (released == 0) {
          released = pressed_buttons_ != 0 ? pressed_buttons_
                                           : kWireButtonPrimary;
        }
        released &= ~(released - 1);
        pressed_buttons_ &= ~released;
        const int button = CefMouseButtonFor(released);
        event.modifiers = CefFlagsFor(modifiers, pressed_buttons_);
        host->SendMouseClickEvent(
            event, static_cast<cef_mouse_button_type_t>(button), true,
            last_click_count_ > 0 ? last_click_count_ : 1);
        break;
      }
      case ROSCORD_POINTER_MOVE:
      case ROSCORD_POINTER_ENTER:
        // A move carries the buttons held right now.
        pressed_buttons_ = buttons;
        event.modifiers = CefFlagsFor(modifiers, pressed_buttons_);
        host->SendMouseMoveEvent(event, false);
        break;
      case ROSCORD_POINTER_LEAVE:
        event.modifiers = CefFlagsFor(modifiers, pressed_buttons_);
        host->SendMouseMoveEvent(event, true);
        break;
      case ROSCORD_POINTER_WHEEL:
        // Flutter scroll deltas grow downwards; CEF wheel deltas grow upwards.
        event.modifiers = CefFlagsFor(modifiers, pressed_buttons_);
        host->SendMouseWheelEvent(event,
                                  static_cast<int>(std::lround(-delta_x)),
                                  static_cast<int>(std::lround(-delta_y)));
        break;
      default:
        break;
    }
  }

  void Key(const std::string& key, const std::string& code,
           const std::string& text, uint32_t modifiers, bool pressed) {
    if (browser_ == nullptr) return;
    KeyCodes codes{};
    const bool known = KeyCodesForCode(code, &codes);
    CefKeyEvent event;
    event.windows_key_code =
        known ? codes.windows_key_code : WindowsKeyCodeForKey(key);
    event.native_key_code = known ? codes.evdev + 8 : 0;  // XKB keycode
    event.modifiers =
        CefFlagsFor(modifiers, 0) | (known ? codes.location_flags : 0);
    event.is_system_key = false;
    const std::u16string typed = pressed ? TypedUnits(text) : u"";
    event.character = typed.empty() ? 0 : typed.front();
    event.unmodified_character = event.character;
    CefRefPtr<CefBrowserHost> host = browser_->GetHost();
    if (pressed) {
      event.type = KEYEVENT_RAWKEYDOWN;
      host->SendKeyEvent(event);
      for (const char16_t unit : typed) {
        event.type = KEYEVENT_CHAR;
        event.character = unit;
        event.unmodified_character = unit;
        host->SendKeyEvent(event);
      }
    } else {
      event.type = KEYEVENT_KEYUP;
      host->SendKeyEvent(event);
    }
  }

  void Ime(int32_t phase, const std::string& text, uint32_t selection_start,
           uint32_t selection_end) {
    if (browser_ == nullptr) return;
    CefRefPtr<CefBrowserHost> host = browser_->GetHost();
    switch (phase) {
      case ROSCORD_IME_START:
      case ROSCORD_IME_UPDATE:
        host->ImeSetComposition(
            text, std::vector<CefCompositionUnderline>(),
            CefRange::InvalidRange(),
            CefRange(selection_start, selection_end));
        break;
      case ROSCORD_IME_CANCEL:
        host->ImeCancelComposition();
        break;
      case ROSCORD_IME_COMMIT:
      default:
        host->ImeCommitText(text, CefRange::InvalidRange(), 0);
        host->ImeFinishComposingText(false);
        break;
    }
  }

  // CefClient
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (source_process != PID_RENDERER || message == nullptr ||
        message->GetName() != kSendMessageName) {
      return false;
    }
    CefRefPtr<CefListValue> arguments = message->GetArgumentList();
    if (arguments == nullptr || arguments->GetSize() != 1 ||
        arguments->GetType(0) != VTYPE_STRING) {
      return true;
    }
    const std::string json = arguments->GetString(0).ToString();
    const std::string frame_url =
        frame != nullptr ? frame->GetURL().ToString() : std::string();
    if (g_state->callbacks.script_message != nullptr) {
      g_state->callbacks.script_message(g_state->callbacks.context,
                                        surface_id_, frame_url.c_str(),
                                        json.c_str());
    }
    return true;
  }

  // CefRenderHandler
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    rect = CefRect(0, 0, view_width_, view_height_);
  }

  bool GetScreenInfo(CefRefPtr<CefBrowser> browser,
                     CefScreenInfo& screen_info) override {
    screen_info.device_scale_factor = static_cast<float>(device_scale_factor_);
    screen_info.depth = 24;
    screen_info.depth_per_component = 8;
    screen_info.is_monochrome = 0;
    screen_info.rect = CefRect(0, 0, view_width_, view_height_);
    screen_info.available_rect = screen_info.rect;
    return true;
  }

  void OnPopupShow(CefRefPtr<CefBrowser> browser, bool show) override {
    popup_visible_ = show;
    if (!show) {
      popup_pixels_.clear();
      popup_rect_ = CefRect();
    }
    // Repaint the view so it is kept (show) or published without the popup
    // (hide).
    view_pixels_.clear();
    browser->GetHost()->Invalidate(PET_VIEW);
  }

  void OnPopupSize(CefRefPtr<CefBrowser> browser,
                   const CefRect& rect) override {
    popup_rect_ = rect;
  }

  void OnPaint(CefRefPtr<CefBrowser> browser, PaintElementType type,
               const RectList& dirty_rects, const void* buffer, int width,
               int height) override {
    if (buffer == nullptr || width <= 0 || height <= 0) return;
    const auto* pixels = static_cast<const uint8_t*>(buffer);
    const size_t bytes = static_cast<size_t>(width) * height * 4u;
    if (type == PET_POPUP) {
      popup_pixels_.assign(pixels, pixels + bytes);
      popup_pixel_width_ = width;
      popup_pixel_height_ = height;
      PublishComposite();
      return;
    }
    if (popup_visible_) {
      // Keep the view so later popup paints can be composited over it.
      view_pixels_.assign(pixels, pixels + bytes);
      view_pixel_width_ = width;
      view_pixel_height_ = height;
      PublishComposite();
      return;
    }
    Publish(buffer, width, height);
  }

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                     int popup_id, const CefString& target_url,
                     const CefString& target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture, const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo, CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    ReportOpenUrl(target_url.ToString(), user_gesture);
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browser_ = browser;
    if (g_state->callbacks.browser_created != nullptr) {
      g_state->callbacks.browser_created(g_state->callbacks.context,
                                         surface_id_);
    }
    if (close_requested_) browser_->GetHost()->CloseBrowser(true);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  // CefRequestHandler
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user_gesture,
                      bool is_redirect) override {
    if (g_state->callbacks.before_browse == nullptr) return true;
    const std::string url = request->GetURL().ToString();
    const int32_t decision = g_state->callbacks.before_browse(
        g_state->callbacks.context, surface_id_, url.c_str(),
        frame != nullptr && frame->IsMain() ? 1 : 0, user_gesture ? 1 : 0,
        is_redirect ? 1 : 0);
    return decision != ROSCORD_NAVIGATION_ALLOW;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        CefRequestHandler::WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    ReportOpenUrl(target_url.ToString(), user_gesture);
    return true;
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool is_navigation, bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    if (!g_state->filter_requests) return nullptr;
    return new FilteringRequestHandler(surface_id_,
                                       request_initiator.ToString());
  }

  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override {
    if (g_state->callbacks.certificate_error != nullptr) {
      const std::string url = request_url.ToString();
      g_state->callbacks.certificate_error(g_state->callbacks.context,
                                           surface_id_, url.c_str());
    }
    return false;  // cancel the request
  }

  bool OnSelectClientCertificate(
      CefRefPtr<CefBrowser> browser, bool isProxy, const CefString& host,
      int port, const X509CertificateList& certificates,
      CefRefPtr<CefSelectClientCertificateCallback> callback) override {
    callback->Select(nullptr);
    return true;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status, int error_code,
                                 const CefString& error_string) override {
    if (g_state->callbacks.renderer_gone != nullptr) {
      g_state->callbacks.renderer_gone(g_state->callbacks.context, surface_id_,
                                       static_cast<int32_t>(status));
    }
  }

  // CefLoadHandler
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode error_code, const CefString& error_text,
                   const CefString& failed_url) override {
    if (frame == nullptr || !frame->IsMain() || error_code == ERR_ABORTED) {
      return;
    }
    if (g_state->callbacks.load_failed != nullptr) {
      const std::string url = failed_url.ToString();
      g_state->callbacks.load_failed(g_state->callbacks.context, surface_id_,
                                     static_cast<int32_t>(error_code),
                                     url.c_str());
    }
  }

  // CefDisplayHandler
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override {
    const char* name = browser_surface::CssCursorName(type);
    if (name != last_cursor_ && g_state->callbacks.cursor_changed != nullptr) {
      last_cursor_ = name;
      g_state->callbacks.cursor_changed(g_state->callbacks.context,
                                        surface_id_, name);
    }
    return true;
  }

  bool OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) override {
    return true;  // no native tooltip windows
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level, const CefString& message,
                        const CefString& source, int line) override {
    return true;  // page console output stays out of the host's stderr
  }

  // CefContextMenuHandler: there is no native menu for an off-screen view.
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    model->Clear();
  }

  // CefDialogHandler: file choosers are not mediated on Linux yet.
  bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode,
                    const CefString& title, const CefString& default_file_path,
                    const std::vector<CefString>& accept_filters,
                    const std::vector<CefString>& accept_extensions,
                    const std::vector<CefString>& accept_descriptions,
                    CefRefPtr<CefFileDialogCallback> callback) override {
    callback->Cancel();
    return true;
  }

  // CefJSDialogHandler: alert/confirm/prompt are suppressed.
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString& origin_url,
                  JSDialogType dialog_type, const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override {
    suppress_message = true;
    return false;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text, bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    callback->Continue(true, CefString());
    return true;
  }

  // CefPermissionHandler: capture and prompts are denied until Linux
  // mediation exists.
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    callback->Cancel();
    return true;
  }

  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
      const CefString& requesting_origin, uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    callback->Continue(CEF_PERMISSION_RESULT_DENY);
    return true;
  }

  // CefDownloadHandler: downloads are not mediated on Linux yet.
  bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString& url,
                   const CefString& request_method) override {
    return false;
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    return true;  // handled without Continue: the download is cancelled
  }

 private:
  void ReportOpenUrl(const std::string& url, bool user_gesture) {
    if (g_state->callbacks.open_url != nullptr) {
      g_state->callbacks.open_url(g_state->callbacks.context, surface_id_,
                                  url.c_str(), user_gesture ? 1 : 0);
    }
  }

  void Publish(const void* bgra, int width, int height) {
    uint32_t slot = 0;
    uint64_t sequence = 0;
    if (!ring_.Publish(surface_id_, bgra, width, height, &slot, &sequence)) {
      return;
    }
    if (g_state->callbacks.frame_ready != nullptr) {
      g_state->callbacks.frame_ready(g_state->callbacks.context, surface_id_,
                                     ring_.name().c_str(), slot,
                                     static_cast<uint32_t>(width),
                                     static_cast<uint32_t>(height), sequence);
    }
  }

  // Draws the popup widget (a <select> list) over the kept view.  The popup
  // rectangle is in view coordinates; both buffers are in device pixels.
  void PublishComposite() {
    if (view_pixels_.empty()) return;
    composite_ = view_pixels_;
    if (popup_visible_ && !popup_pixels_.empty()) {
      const int left =
          static_cast<int>(std::lround(popup_rect_.x * device_scale_factor_));
      const int top =
          static_cast<int>(std::lround(popup_rect_.y * device_scale_factor_));
      const int first = std::max(left, 0);
      const int last = std::min(left + popup_pixel_width_, view_pixel_width_);
      for (int row = 0; row < popup_pixel_height_ && last > first; ++row) {
        const int y = top + row;
        if (y < 0 || y >= view_pixel_height_) continue;
        std::copy_n(
            popup_pixels_.data() +
                (static_cast<size_t>(row) * popup_pixel_width_ +
                 static_cast<size_t>(first - left)) *
                    4u,
            static_cast<size_t>(last - first) * 4u,
            composite_.data() +
                (static_cast<size_t>(y) * view_pixel_width_ + first) * 4u);
      }
    }
    Publish(composite_.data(), view_pixel_width_, view_pixel_height_);
  }

  int ClickCount(int button, int x, int y) {
    const auto now = std::chrono::steady_clock::now();
    if (button == last_click_button_ &&
        now - last_click_time_ < std::chrono::milliseconds(500) &&
        std::abs(x - last_click_x_) <= 4 && std::abs(y - last_click_y_) <= 4) {
      last_click_count_ = std::min(last_click_count_ + 1, 3);
    } else {
      last_click_count_ = 1;
    }
    last_click_button_ = button;
    last_click_time_ = now;
    last_click_x_ = x;
    last_click_y_ = y;
    return last_click_count_;
  }

  const uint64_t surface_id_;
  const std::string context_key_;
  CefRefPtr<CefBrowser> browser_;
  bool close_requested_ = false;

  int view_width_ = 1;
  int view_height_ = 1;
  double device_scale_factor_ = 1.0;
  SharedFrameRing ring_;

  bool popup_visible_ = false;
  CefRect popup_rect_;
  std::vector<uint8_t> popup_pixels_;
  int popup_pixel_width_ = 0;
  int popup_pixel_height_ = 0;
  std::vector<uint8_t> view_pixels_;
  int view_pixel_width_ = 0;
  int view_pixel_height_ = 0;
  std::vector<uint8_t> composite_;

  const char* last_cursor_ = nullptr;
  uint32_t pressed_buttons_ = 0;
  int last_click_button_ = -1;
  int last_click_count_ = 0;
  std::chrono::steady_clock::time_point last_click_time_{};
  int last_click_x_ = 0;
  int last_click_y_ = 0;

  IMPLEMENT_REFCOUNTING(SurfaceClient);
};

// UI-thread registries.
std::map<uint64_t, CefRefPtr<SurfaceClient>>& Clients() {
  static std::map<uint64_t, CefRefPtr<SurfaceClient>>* clients =
      new std::map<uint64_t, CefRefPtr<SurfaceClient>>();
  return *clients;
}

struct ContextEntry {
  CefRefPtr<CefRequestContext> context;
  int users = 0;
};

std::map<std::string, ContextEntry>& Contexts() {
  static std::map<std::string, ContextEntry>* contexts =
      new std::map<std::string, ContextEntry>();
  return *contexts;
}

CefRefPtr<SurfaceClient> ClientFor(uint64_t surface_id) {
  auto& clients = Clients();
  const auto iterator = clients.find(surface_id);
  return iterator == clients.end() ? nullptr : iterator->second;
}

// Persistent profiles share one context per directory; private surfaces get
// a fresh in-memory context each.
CefRefPtr<CefRequestContext> AcquireContext(const std::string& key,
                                            const std::string& cache_path) {
  auto& contexts = Contexts();
  auto iterator = contexts.find(key);
  if (iterator == contexts.end()) {
    CefRequestContextSettings settings;
    if (!cache_path.empty()) {
      CefString(&settings.cache_path) = cache_path;
      settings.persist_session_cookies = true;
    }
    ContextEntry entry;
    entry.context = CefRequestContext::CreateContext(settings, nullptr);
    if (entry.context == nullptr) return nullptr;
    iterator = contexts.emplace(key, std::move(entry)).first;
  }
  ++iterator->second.users;
  return iterator->second.context;
}

void ReleaseContext(const std::string& key) {
  auto& contexts = Contexts();
  const auto iterator = contexts.find(key);
  if (iterator == contexts.end()) return;
  if (--iterator->second.users <= 0) contexts.erase(iterator);
}

void SurfaceClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  ring_.Release();
  browser_ = nullptr;
  CefRefPtr<SurfaceClient> self(this);
  Clients().erase(surface_id_);
  ReleaseContext(context_key_);
  if (g_state->callbacks.browser_closed != nullptr) {
    g_state->callbacks.browser_closed(g_state->callbacks.context, surface_id_);
  }
  BrowserGone();
}

void CreateBrowserOnUi(uint64_t surface_id, std::string url,
                       std::string cache_path, bool persistent, uint32_t width,
                       uint32_t height, double device_scale_factor,
                       std::string document_start_script) {
  CEF_REQUIRE_UI_THREAD();
  auto fail = [surface_id](const char* message) {
    Log(ROSCORD_LOG_ERROR, message);
    if (g_state->callbacks.browser_closed != nullptr) {
      g_state->callbacks.browser_closed(g_state->callbacks.context,
                                        surface_id);
    }
    BrowserGone();
  };
  if (ClientFor(surface_id) != nullptr) {
    fail("surface already has a browser");
    return;
  }
  const std::string context_key =
      persistent ? "profile:" + cache_path
                 : "private:" + std::to_string(surface_id);
  CefRefPtr<CefRequestContext> context =
      AcquireContext(context_key, persistent ? cache_path : std::string());
  if (context == nullptr) {
    fail("request context could not be created");
    return;
  }
  CefRefPtr<SurfaceClient> client = new SurfaceClient(
      surface_id, width, height, device_scale_factor, context_key);
  Clients()[surface_id] = client;

  CefWindowInfo window_info;
  window_info.SetAsWindowless(kNullWindowHandle);
  CefBrowserSettings settings;
  settings.windowless_frame_rate = g_state->frame_rate;
  CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
  if (!document_start_script.empty()) {
    extra_info->SetString(kDocumentStartScriptKey, document_start_script);
  }
  if (!CefBrowserHost::CreateBrowser(window_info, client, url, settings,
                                     extra_info, context)) {
    Clients().erase(surface_id);
    ReleaseContext(context_key);
    fail("CEF rejected the browser");
  }
}

// Renderer half of the BrowserRuntime script bridge.  It only accepts one
// JSON string; the host wraps it in a ScriptEnvelope with the frame origin.
class RendererSendHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name, CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments, CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    retval = CefV8Value::CreateUndefined();
    if (arguments.size() != 1 || !arguments[0]->IsString()) {
      exception = "BrowserRuntime bridge expects one JSON string";
      return true;
    }
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame =
        context != nullptr ? context->GetFrame() : nullptr;
    if (frame == nullptr) {
      exception = "BrowserRuntime bridge has no frame";
      return true;
    }
    CefRefPtr<CefProcessMessage> message =
        CefProcessMessage::Create(kSendMessageName);
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(RendererSendHandler);
};

class EngineApp : public CefApp,
                  public CefBrowserProcessHandler,
                  public CefRenderProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty() || g_state == nullptr) return;
    // Off-screen rendering needs no display server.  Headless Ozone keeps
    // the host independent of X11/Wayland (and of Wayland's Vulkan/GPU
    // quirks); the app composes the frames itself.
    const char* ozone = std::getenv("ROSCORD_CEF_OZONE_PLATFORM");
    command_line->AppendSwitchWithValue(
        "ozone-platform", ozone != nullptr && *ozone ? ozone : "headless");
    // Playback starts from an explicit click in the app, which never reaches
    // the page as a user gesture.
    command_line->AppendSwitchWithValue("autoplay-policy",
                                        "no-user-gesture-required");
    // Never ask the desktop keyring for cookie encryption.
    command_line->AppendSwitchWithValue("password-store", "basic");
    // Chrome's first-run flow would block startup: on Linux it shows a EULA
    // dialog for every fresh profile directory, and there is no screen here.
    command_line->AppendSwitch("no-first-run");
    command_line->AppendSwitch("no-default-browser-check");
    if (g_state->software_rendering) {
      command_line->AppendSwitch("disable-gpu");
      command_line->AppendSwitch("disable-gpu-compositing");
    }
  }

  // CefBrowserProcessHandler
  void OnContextInitialized() override {
    std::lock_guard<std::mutex> lock(g_state->mutex);
    g_state->context_ready = true;
    g_state->condition.notify_all();
  }

  // CefRenderProcessHandler
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info != nullptr &&
        extra_info->GetType(kDocumentStartScriptKey) == VTYPE_STRING) {
      scripts_[browser->GetIdentifier()] =
          extra_info->GetString(kDocumentStartScriptKey).ToString();
    }
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    scripts_.erase(browser->GetIdentifier());
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    context->GetGlobal()->SetValue(
        "__roscordBrowserRuntimeSend",
        CefV8Value::CreateFunction("__roscordBrowserRuntimeSend",
                                   new RendererSendHandler()),
        static_cast<cef_v8_propertyattribute_t>(
            V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM |
            V8_PROPERTY_ATTRIBUTE_DONTDELETE));
    // Document-start scripts run before any page script in every frame.
    const auto script = scripts_.find(browser->GetIdentifier());
    if (script != scripts_.end() && !script->second.empty()) {
      CefRefPtr<CefV8Value> result;
      CefRefPtr<CefV8Exception> exception;
      context->Eval(script->second, "roscord://document-start", 1, result,
                    exception);
    }
  }

 private:
  // Renderer main thread only.
  std::map<int, std::string> scripts_;
  IMPLEMENT_REFCOUNTING(EngineApp);
};

std::string StringOrEmpty(const char* value) {
  return value != nullptr ? std::string(value) : std::string();
}

}  // namespace

extern "C" {

uint32_t roscord_cef_engine_abi_version(void) {
  return ROSCORD_CEF_ENGINE_ABI_VERSION;
}

// Chromium changes the stack canary in processes forked from the zygote
// (--change-stack-guard-on-fork), so no frame that is live across that fork
// may check its canary on return.  The Rust frames above this one carry none.
NO_STACK_PROTECTOR
int32_t roscord_cef_engine_execute_process(int32_t argc, char** argv) {
  CefMainArgs main_args(argc, argv);
  CefRefPtr<EngineApp> app = new EngineApp();
  return CefExecuteProcess(main_args, app, nullptr);
}

int32_t roscord_cef_engine_initialize(
    int32_t argc, char** argv, const roscord_cef_engine_config* config,
    const roscord_cef_engine_callbacks* callbacks) {
  if (g_state != nullptr || config == nullptr || callbacks == nullptr ||
      config->abi_version != ROSCORD_CEF_ENGINE_ABI_VERSION ||
      config->cef_root == nullptr || config->profile_root == nullptr ||
      config->frame_namespace == nullptr || *config->frame_namespace == '\0') {
    return 0;
  }
  g_state = new EngineState();
  g_state->callbacks = *callbacks;
  g_state->cef_root = config->cef_root;
  g_state->profile_root = config->profile_root;
  g_state->frame_namespace = config->frame_namespace;
  g_state->software_rendering = config->software_rendering != 0;
  g_state->filter_requests = config->filter_requests != 0;
  g_state->frame_rate = std::clamp(config->frame_rate, 1, 60);

  CefMainArgs main_args(argc, argv);
  CefSettings settings;
  settings.no_sandbox = false;
  settings.multi_threaded_message_loop = true;
  settings.windowless_rendering_enabled = true;
  CefString(&settings.root_cache_path) = g_state->profile_root;
  // Resources and locales are not configured: on Linux CEF loads ICU data,
  // the .pak files and locales/ from the directory holding libcef.so, so the
  // staged runtime keeps them all in Release/.
  const char* log_file = std::getenv("ROSCORD_CEF_LOG_FILE");
  if (log_file != nullptr && *log_file != '\0') {
    CefString(&settings.log_file) = log_file;
    settings.log_severity = LOGSEVERITY_INFO;
  } else {
    settings.log_severity = LOGSEVERITY_DISABLE;
  }

  CefRefPtr<EngineApp> app = new EngineApp();
  if (!CefInitialize(main_args, settings, app, nullptr)) {
    Log(ROSCORD_LOG_ERROR, "CefInitialize failed");
    return 0;
  }
  std::unique_lock<std::mutex> lock(g_state->mutex);
  if (!g_state->condition.wait_for(lock, std::chrono::seconds(20),
                                   [] { return g_state->context_ready; })) {
    Log(ROSCORD_LOG_ERROR, "CEF context did not initialize in time");
    return 0;
  }
  return 1;
}

int32_t roscord_cef_engine_create_browser(
    uint64_t surface_id, const roscord_cef_browser_options* options) {
  if (g_state == nullptr || options == nullptr || options->url == nullptr) {
    return 0;
  }
  {
    std::lock_guard<std::mutex> lock(g_state->mutex);
    ++g_state->live_browsers;
  }
  std::string url = options->url;
  std::string cache_path = StringOrEmpty(options->cache_path);
  const bool persistent = options->cache_path != nullptr;
  std::string script = StringOrEmpty(options->document_start_script);
  const uint32_t width = options->width;
  const uint32_t height = options->height;
  const double scale = options->device_scale_factor;
  PostUi([surface_id, url = std::move(url), cache_path = std::move(cache_path),
          persistent, width, height, scale,
          script = std::move(script)]() mutable {
    CreateBrowserOnUi(surface_id, std::move(url), std::move(cache_path),
                      persistent, width, height, scale, std::move(script));
  });
  return 1;
}

void roscord_cef_engine_close_browser(uint64_t surface_id) {
  if (g_state == nullptr) return;
  PostUi([surface_id] {
    if (CefRefPtr<SurfaceClient> client = ClientFor(surface_id)) {
      client->RequestClose();
    }
  });
}

void roscord_cef_engine_navigate(uint64_t surface_id, const char* url) {
  if (g_state == nullptr || url == nullptr) return;
  PostUi([surface_id, target = std::string(url)] {
    CefRefPtr<SurfaceClient> client = ClientFor(surface_id);
    if (client != nullptr && client->browser() != nullptr) {
      client->browser()->GetMainFrame()->LoadURL(target);
    }
  });
}

void roscord_cef_engine_resize(uint64_t surface_id, uint32_t width,
                               uint32_t height, double device_scale_factor) {
  if (g_state == nullptr) return;
  PostUi([surface_id, width, height, device_scale_factor] {
    CefRefPtr<SurfaceClient> client = ClientFor(surface_id);
    if (client == nullptr) return;
    client->SetView(width, height, device_scale_factor);
    if (client->browser() != nullptr) {
      client->browser()->GetHost()->NotifyScreenInfoChanged();
      client->browser()->GetHost()->WasResized();
    }
  });
}

void roscord_cef_engine_focus(uint64_t surface_id, int32_t focused) {
  if (g_state == nullptr) return;
  PostUi([surface_id, focused] {
    CefRefPtr<SurfaceClient> client = ClientFor(surface_id);
    if (client != nullptr && client->browser() != nullptr) {
      client->browser()->GetHost()->SetFocus(focused != 0);
    }
  });
}

void roscord_cef_engine_pointer(uint64_t surface_id, int32_t kind, double x,
                                double y, uint32_t buttons,
                                uint32_t modifiers, double delta_x,
                                double delta_y) {
  if (g_state == nullptr) return;
  PostUi([=] {
    if (CefRefPtr<SurfaceClient> client = ClientFor(surface_id)) {
      client->Pointer(kind, x, y, buttons, modifiers, delta_x, delta_y);
    }
  });
}

void roscord_cef_engine_key(uint64_t surface_id, const char* key,
                            const char* code, const char* text,
                            uint32_t modifiers, int32_t pressed) {
  if (g_state == nullptr || key == nullptr || code == nullptr ||
      text == nullptr) {
    return;
  }
  PostUi([surface_id, key = std::string(key), code = std::string(code),
          text = std::string(text), modifiers, pressed] {
    if (CefRefPtr<SurfaceClient> client = ClientFor(surface_id)) {
      client->Key(key, code, text, modifiers, pressed != 0);
    }
  });
}

void roscord_cef_engine_ime(uint64_t surface_id, int32_t phase,
                            const char* text, uint32_t selection_start,
                            uint32_t selection_end) {
  if (g_state == nullptr || text == nullptr) return;
  PostUi([surface_id, phase, text = std::string(text), selection_start,
          selection_end] {
    if (CefRefPtr<SurfaceClient> client = ClientFor(surface_id)) {
      client->Ime(phase, text, selection_start, selection_end);
    }
  });
}

void roscord_cef_engine_execute_script(uint64_t surface_id,
                                       const char* script) {
  if (g_state == nullptr || script == nullptr) return;
  PostUi([surface_id, code = std::string(script)] {
    CefRefPtr<SurfaceClient> client = ClientFor(surface_id);
    if (client == nullptr || client->browser() == nullptr) return;
    CefRefPtr<CefFrame> frame = client->browser()->GetMainFrame();
    if (frame != nullptr) frame->ExecuteJavaScript(code, frame->GetURL(), 0);
  });
}

void roscord_cef_engine_shutdown(void) {
  if (g_state == nullptr) return;
  PostUi([] {
    // Copy first: closing mutates the registry.
    std::vector<CefRefPtr<SurfaceClient>> clients;
    for (const auto& entry : Clients()) clients.push_back(entry.second);
    for (const auto& client : clients) client->RequestClose();
  });
  {
    std::unique_lock<std::mutex> lock(g_state->mutex);
    g_state->condition.wait_for(lock, std::chrono::seconds(5),
                                [] { return g_state->live_browsers == 0; });
  }
  CefShutdown();
  delete g_state;
  g_state = nullptr;
}

}  // extern "C"
