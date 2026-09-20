#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <sddl.h>
#include <shellapi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <tchar.h>
#include <cwctype>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/cef_render_handler.h"
#include "include/cef_request.h"
#include "include/cef_resource_handler.h"
#include "include/cef_sandbox_win.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/cef_version_info.h"
#include "include/wrapper/cef_helpers.h"

namespace roscord::cef_host {

namespace {

constexpr uint16_t kProtocolVersion = 1;
constexpr uint32_t kMaxFrameBytes = 1024u * 1024u;
constexpr DWORD kConnectTimeoutMs = 10000;
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\roscord-browser-";
constexpr char kFixtureUrl[] = "commet://fixture/";

// The browser runtime owns the protocol boundary.  Keep the list here as a
// deny-list as a second line of defence against inherited CEF command-line
// switches.  CEF's sandbox and web security settings are never relaxed.
constexpr std::array<std::wstring_view, 7> kForbiddenSwitches = {
    L"--no-sandbox",
    L"--disable-web-security",
    L"--allow-file-access-from-files",
    L"--remote-debugging-port",
    L"--enable-media-stream",
    L"--use-fake-device-for-media-stream",
    L"--use-fake-ui-for-media-stream",
};

std::wstring Lowercase(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

bool StartsWith(std::wstring_view value, std::wstring_view prefix) {
  return value.size() >= prefix.size() && value.substr(0, prefix.size()) == prefix;
}

bool IsHex(std::string_view value) {
  if (value.empty()) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
  });
}

bool IsValidProfileKey(std::string_view value) {
  if (value.empty() || value.size() > 256) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char c) {
    return c >= 0x20 && c != 0x7f && c != '/' && c != '\\';
  });
}

std::wstring ModuleDirectory() {
  std::array<wchar_t, MAX_PATH> buffer{};
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(), buffer.size());
  if (length == 0 || length == buffer.size()) {
    return {};
  }
  return std::filesystem::path(std::wstring(buffer.data(), length))
      .parent_path()
      .wstring();
}

std::wstring ModulePath(HMODULE module) {
  std::array<wchar_t, MAX_PATH> buffer{};
  DWORD length = GetModuleFileNameW(module, buffer.data(), buffer.size());
  if (length == 0 || length == buffer.size()) {
    return {};
  }
  return std::wstring(buffer.data(), length);
}

bool IsRegularFile(const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return false;
  }
  for (auto ancestor = path.parent_path(); !ancestor.empty();
       ancestor = ancestor.parent_path()) {
    const DWORD ancestor_attributes = GetFileAttributesW(ancestor.c_str());
    if (ancestor_attributes == INVALID_FILE_ATTRIBUTES ||
        (ancestor_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    if (ancestor == ancestor.root_path()) {
      break;
    }
  }
  return true;
}

bool IsPathInDirectory(const std::filesystem::path& path,
                       const std::filesystem::path& directory) {
  std::error_code path_error;
  std::error_code directory_error;
  const auto full_path = std::filesystem::weakly_canonical(path, path_error);
  const auto full_directory =
      std::filesystem::weakly_canonical(directory, directory_error);
  if (path_error || directory_error) {
    return false;
  }
  auto path_it = full_path.begin();
  auto directory_it = full_directory.begin();
  for (; directory_it != full_directory.end(); ++directory_it, ++path_it) {
    if (path_it == full_path.end() ||
        Lowercase(path_it->wstring()) != Lowercase(directory_it->wstring())) {
      return false;
    }
  }
  return true;
}

struct HostArgs {
  DWORD parent_pid = 0;
  std::wstring pipe_name;
  std::string nonce;
  std::wstring module_name;
};

struct ParsedCommandLine {
  std::vector<std::wstring> values;
  bool is_cef_child = false;
};

std::optional<std::wstring> ValueForSwitch(const std::vector<std::wstring>& args,
                                           std::wstring_view name) {
  const std::wstring prefix = std::wstring(name) + L"=";
  for (const auto& arg : args) {
    if (StartsWith(Lowercase(arg), Lowercase(prefix))) {
      return arg.substr(prefix.size());
    }
  }
  return std::nullopt;
}

bool HasSwitch(const std::vector<std::wstring>& args, std::wstring_view name) {
  const std::wstring lowered_name = Lowercase(std::wstring(name));
  return std::any_of(args.begin(), args.end(), [&](const std::wstring& arg) {
    const std::wstring lowered = Lowercase(arg);
    return lowered == lowered_name || StartsWith(lowered, lowered_name + L"=");
  });
}

ParsedCommandLine ParseCommandLine() {
  ParsedCommandLine result;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return result;
  }
  for (int index = 1; index < argc; ++index) {
    result.values.emplace_back(argv[index]);
  }
  LocalFree(argv);
  result.is_cef_child = HasSwitch(result.values, L"--type");
  return result;
}

bool ParseDword(std::wstring_view value, DWORD& result) {
  if (value.empty()) {
    return false;
  }
  wchar_t* end = nullptr;
  const std::wstring copy(value);
  const unsigned long parsed = wcstoul(copy.c_str(), &end, 10);
  if (end == copy.c_str() || *end != L'\0' || parsed == 0 ||
      parsed > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  result = static_cast<DWORD>(parsed);
  return true;
}

bool ValidatePipeName(std::wstring_view pipe_name) {
  if (!StartsWith(pipe_name, kPipePrefix) || pipe_name.size() ==
                                                    std::wstring_view(kPipePrefix).size()) {
    return false;
  }
  const auto suffix = pipe_name.substr(std::wstring_view(kPipePrefix).size());
  return std::all_of(suffix.begin(), suffix.end(), [](wchar_t c) {
    return (c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f') ||
           (c >= L'A' && c <= L'F') || c == L'-';
  });
}

std::optional<HostArgs> ValidateHostArgs(const ParsedCommandLine& command_line,
                                          std::wstring& error) {
  for (const auto& value : command_line.values) {
    const std::wstring lowered = Lowercase(value);
    for (const auto forbidden : kForbiddenSwitches) {
      const std::wstring forbidden_string(forbidden);
      if (lowered == forbidden_string ||
          StartsWith(lowered, forbidden_string + L"=")) {
        error = L"insecure CEF command-line switch is forbidden";
        return std::nullopt;
      }
    }
  }

  const auto module = ValueForSwitch(command_line.values, L"--module");
  const auto pipe = ValueForSwitch(command_line.values, L"--pipe");
  const auto nonce = ValueForSwitch(command_line.values, L"--nonce");
  const auto parent = ValueForSwitch(command_line.values, L"--parent-pid");
  if (!module || Lowercase(*module) != L"client.dll" || !pipe || !nonce ||
      !parent) {
    error = L"cef_host requires --module=client.dll, --pipe, --nonce, and --parent-pid";
    return std::nullopt;
  }

  HostArgs result;
  result.module_name = *module;
  result.pipe_name = *pipe;
  result.nonce.assign(nonce->begin(), nonce->end());
  if (!ValidatePipeName(result.pipe_name) || result.nonce.size() < 32 ||
      result.nonce.size() > 128 || !IsHex(result.nonce) ||
      !ParseDword(*parent, result.parent_pid) ||
      result.parent_pid == GetCurrentProcessId()) {
    error = L"cef_host transport arguments are invalid";
    return std::nullopt;
  }
  return result;
}

bool VerifyBundledRuntime(std::wstring& error) {
  const std::filesystem::path root(ModuleDirectory());
  if (root.empty()) {
    error = L"cannot resolve the cef_host module directory";
    return false;
  }

  // The M138+ bootstrap checks the signed bootstrap/client pair.  These
  // additional checks make a partial or host-installed CEF impossible to use.
  const std::array<std::filesystem::path, 8> required = {
      root / L"cef_host.exe",       root / L"client.dll",
      root / L"libcef.dll",         root / L"chrome_elf.dll",
      root / L"v8_context_snapshot.bin", root / L"Resources" / L"icudtl.dat",
      root / L"Resources" / L"resources.pak",
      root / L"Resources" / L"locales" / L"en-US.pak",
  };
  if (!std::all_of(required.begin(), required.end(), IsRegularFile)) {
    error = L"bundled CEF bootstrap, client, or resource is missing";
    return false;
  }

  return true;
}

bool VerifyLoadedBundledRuntime(std::wstring& error) {
  const std::filesystem::path root(ModuleDirectory());
  if (root.empty()) {
    error = L"cannot resolve the cef_host module directory";
    return false;
  }
  const HMODULE libcef = GetModuleHandleW(L"libcef.dll");
  const HMODULE chrome_elf = GetModuleHandleW(L"chrome_elf.dll");
  if (libcef == nullptr || chrome_elf == nullptr ||
      !IsPathInDirectory(ModulePath(libcef), root) ||
      !IsPathInDirectory(ModulePath(chrome_elf), root)) {
    error = L"CEF is not loaded from the bundled host directory";
    return false;
  }
  return true;
}

class OwnerOnlySecurityDescriptor {
 public:
  OwnerOnlySecurityDescriptor() = default;
  OwnerOnlySecurityDescriptor(const OwnerOnlySecurityDescriptor&) = delete;
  OwnerOnlySecurityDescriptor& operator=(const OwnerOnlySecurityDescriptor&) = delete;

  bool Create() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
      return false;
    }
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    if (size == 0) {
      CloseHandle(token);
      return false;
    }
    std::vector<std::byte> token_data(size);
    auto* token_user = reinterpret_cast<PTOKEN_USER>(token_data.data());
    const bool token_ok = GetTokenInformation(
        token, TokenUser, token_user, size, &size) != FALSE;
    CloseHandle(token);
    if (!token_ok) {
      return false;
    }

    LPWSTR sid_string = nullptr;
    if (!ConvertSidToStringSidW(token_user->User.Sid, &sid_string)) {
      return false;
    }
    const std::wstring sddl = L"D:P(A;;GA;;;" + std::wstring(sid_string) + L")";
    LocalFree(sid_string);
    return ConvertStringSecurityDescriptorToSecurityDescriptorW(
               sddl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr) != FALSE;
  }

  PSECURITY_DESCRIPTOR get() const { return descriptor_; }

  ~OwnerOnlySecurityDescriptor() {
    if (descriptor_ != nullptr) {
      LocalFree(descriptor_);
    }
  }

 private:
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};

class PipeChannel {
 public:
  explicit PipeChannel(const HostArgs& args) : args_(args) {}
  PipeChannel(const PipeChannel&) = delete;
  PipeChannel& operator=(const PipeChannel&) = delete;

  bool ConnectAndAuthenticate(std::wstring& error) {
    OwnerOnlySecurityDescriptor security;
    if (!security.Create()) {
      error = L"cannot create owner-only named-pipe security descriptor";
      return false;
    }
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = security.get();

    pipe_ = CreateNamedPipeW(
        args_.pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT, 1,
        kMaxFrameBytes + 4, kMaxFrameBytes + 4, kConnectTimeoutMs, &attributes);
    if (pipe_ == INVALID_HANDLE_VALUE) {
      error = L"cannot create the private named pipe";
      pipe_ = nullptr;
      return false;
    }

    const ULONGLONG deadline = GetTickCount64() + kConnectTimeoutMs;
    bool connected = false;
    while (GetTickCount64() < deadline) {
      const BOOL result = ConnectNamedPipe(pipe_, nullptr);
      const DWORD connect_error = result ? ERROR_SUCCESS : GetLastError();
      if (result || connect_error == ERROR_PIPE_CONNECTED) {
        connected = true;
        break;
      }
      if (connect_error != ERROR_PIPE_LISTENING &&
          connect_error != ERROR_NO_DATA) {
        break;
      }
      Sleep(20);
    }
    if (!connected) {
      error = L"parent did not connect to the private named pipe";
      Close();
      return false;
    }

    DWORD pipe_mode = PIPE_READMODE_BYTE | PIPE_WAIT;
    if (!SetNamedPipeHandleState(pipe_, &pipe_mode, nullptr, nullptr)) {
      error = L"cannot switch the private named pipe to blocking mode";
      Close();
      return false;
    }

    ULONG client_pid = 0;
    if (!GetNamedPipeClientProcessId(pipe_, &client_pid) ||
        client_pid != args_.parent_pid ||
        !SameUser(static_cast<DWORD>(client_pid))) {
      error = L"named-pipe peer is not the authenticated parent instance";
      Close();
      return false;
    }
    return true;
  }

  bool ReadFrame(std::string& body) {
    std::array<std::uint8_t, 4> header{};
    if (!ReadExact(header.data(), header.size())) {
      return false;
    }
    const std::uint32_t size = (static_cast<std::uint32_t>(header[0]) << 24) |
                               (static_cast<std::uint32_t>(header[1]) << 16) |
                               (static_cast<std::uint32_t>(header[2]) << 8) |
                               static_cast<std::uint32_t>(header[3]);
    if (size == 0 || size > kMaxFrameBytes) {
      return false;
    }
    body.assign(size, '\0');
    return ReadExact(body.data(), body.size());
  }

  bool WriteFrame(std::string_view body) {
    if (body.empty() || body.size() > kMaxFrameBytes) {
      return false;
    }
    std::array<std::uint8_t, 4> header = {
        static_cast<std::uint8_t>((body.size() >> 24) & 0xff),
        static_cast<std::uint8_t>((body.size() >> 16) & 0xff),
        static_cast<std::uint8_t>((body.size() >> 8) & 0xff),
        static_cast<std::uint8_t>(body.size() & 0xff),
    };
    std::lock_guard lock(write_mutex_);
    return WriteExact(header.data(), header.size()) &&
           WriteExact(body.data(), body.size());
  }

  void Close() {
    std::lock_guard lock(write_mutex_);
    if (pipe_ != nullptr && pipe_ != INVALID_HANDLE_VALUE) {
      FlushFileBuffers(pipe_);
      DisconnectNamedPipe(pipe_);
      CloseHandle(pipe_);
      pipe_ = nullptr;
    }
  }

  ~PipeChannel() { Close(); }

 private:
  bool ReadExact(void* destination, size_t size) {
    auto* bytes = static_cast<std::uint8_t*>(destination);
    while (size > 0) {
      DWORD read = 0;
      if (pipe_ == nullptr || !ReadFile(pipe_, bytes,
                                        static_cast<DWORD>(size), &read,
                                        nullptr) ||
          read == 0) {
        return false;
      }
      bytes += read;
      size -= read;
    }
    return true;
  }

  bool WriteExact(const void* source, size_t size) {
    const auto* bytes = static_cast<const std::uint8_t*>(source);
    while (size > 0) {
      DWORD written = 0;
      if (pipe_ == nullptr ||
          !WriteFile(pipe_, bytes, static_cast<DWORD>(size), &written,
                     nullptr) ||
          written == 0) {
        return false;
      }
      bytes += written;
      size -= written;
    }
    return true;
  }

  bool SameUser(DWORD process_id) const {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
    if (process == nullptr) {
      return false;
    }
    HANDLE peer_token = nullptr;
    const bool opened = OpenProcessToken(process, TOKEN_QUERY, &peer_token) != FALSE;
    CloseHandle(process);
    if (!opened) {
      return false;
    }
    HANDLE own_token = nullptr;
    const bool own_opened =
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &own_token) != FALSE;
    if (!own_opened) {
      CloseHandle(peer_token);
      return false;
    }

    DWORD peer_size = 0;
    DWORD own_size = 0;
    GetTokenInformation(peer_token, TokenUser, nullptr, 0, &peer_size);
    GetTokenInformation(own_token, TokenUser, nullptr, 0, &own_size);
    std::vector<std::byte> peer_data(peer_size);
    std::vector<std::byte> own_data(own_size);
    const bool peer_info = peer_size != 0 &&
                           GetTokenInformation(peer_token, TokenUser,
                                               peer_data.data(), peer_size,
                                               &peer_size) != FALSE;
    const bool own_info = own_size != 0 &&
                          GetTokenInformation(own_token, TokenUser,
                                              own_data.data(), own_size,
                                              &own_size) != FALSE;
    const bool same = peer_info && own_info &&
                     EqualSid(reinterpret_cast<PTOKEN_USER>(peer_data.data())->User.Sid,
                              reinterpret_cast<PTOKEN_USER>(own_data.data())->User.Sid) != FALSE;
    CloseHandle(peer_token);
    CloseHandle(own_token);
    return same;
  }

  HostArgs args_;
  HANDLE pipe_ = nullptr;
  std::mutex write_mutex_;
};

class HostController;

class FixtureResourceHandler final : public CefResourceHandler {
 public:
  FixtureResourceHandler() : body_(
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>roscord "
      "CEF fixture</title></head><body><main id=\"fixture\">roscord CEF "
      "fixture</main><script>window.__roscordCefFixtureReady=true;</script>"
      "</body></html>") {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    CEF_REQUIRE_IO_THREAD();
    handle_request = true;
    return request != nullptr && request->GetURL().ToString() == kFixtureUrl;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirect_url) override {
    CEF_REQUIRE_IO_THREAD();
    response->SetStatus(200);
    response->SetMimeType("text/html; charset=utf-8");
    response_length = static_cast<int64_t>(body_.size());
    redirect_url.clear();
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    CEF_REQUIRE_IO_THREAD();
    if (bytes_to_read <= 0 || offset_ >= body_.size()) {
      bytes_read = 0;
      return false;
    }
    const size_t count = std::min<size_t>(bytes_to_read, body_.size() - offset_);
    memcpy(data_out, body_.data() + offset_, count);
    offset_ += count;
    bytes_read = static_cast<int>(count);
    return true;
  }

  void Cancel() override { CEF_REQUIRE_IO_THREAD(); }

 private:
  std::string body_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(FixtureResourceHandler);
};

class FixtureSchemeHandlerFactory final : public CefSchemeHandlerFactory {
 public:
  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& scheme_name,
                                       CefRefPtr<CefRequest> request) override {
    CEF_REQUIRE_IO_THREAD();
    if (request == nullptr || request->GetURL().ToString() != kFixtureUrl) {
      return nullptr;
    }
    return new FixtureResourceHandler();
  }

 private:
  IMPLEMENT_REFCOUNTING(FixtureSchemeHandlerFactory);
};

class HostApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  HostApp() = default;

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {
    CEF_REQUIRE_UI_THREAD();
    registrar->AddCustomScheme(
        "commet", CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
            CEF_SCHEME_OPTION_CORS_ENABLED);
  }

  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    CefRegisterSchemeHandlerFactory("commet", "fixture",
                                   new FixtureSchemeHandlerFactory());
    {
      std::lock_guard lock(mutex_);
      context_initialized_ = true;
    }
    condition_.notify_all();
  }

  bool WaitForContext(std::chrono::seconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout,
                               [&] { return context_initialized_; });
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool context_initialized_ = false;
  IMPLEMENT_REFCOUNTING(HostApp);
};

class CreateBrowserTask;
class CloseBrowserTask;

struct SurfaceState {
  uint64_t id = 0;
  std::string profile_key;
  std::string presentation;
  int last_command_sequence = 0;
  CefRefPtr<CefBrowser> browser;
  bool close_requested = false;
};

class BrowserClient final : public CefClient,
                            public CefLifeSpanHandler,
                            public CefRenderHandler {
 public:
  BrowserClient(HostController* controller, uint64_t surface_id)
      : controller_(controller), surface_id_(surface_id) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

  bool GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    rect = CefRect(0, 0, 1024, 768);
    return true;
  }

  void OnPaint(CefRefPtr<CefBrowser> browser,
               PaintElementType type,
               const RectList& dirty_rects,
               const void* buffer,
               int width,
               int height) override {
    // The first host milestone proves lifecycle and protocol ownership.  The
    // embedded frame-ring/Flutter texture adapter consumes this callback in
    // the next ticket.  Do not retain |buffer|: it belongs to CEF only for the
    // duration of this callback.
    CEF_REQUIRE_UI_THREAD();
    (void)browser;
    (void)type;
    (void)dirty_rects;
    (void)buffer;
    (void)width;
    (void)height;
  }

  uint64_t surface_id() const { return surface_id_; }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

class HostController {
 public:
  HostController(const HostArgs& args, PipeChannel& pipe)
      : args_(args), pipe_(pipe) {}
  HostController(const HostController&) = delete;
  HostController& operator=(const HostController&) = delete;

  void Run();
  void Shutdown();
  void CreateBrowserOnUi(uint64_t surface_id, std::string url,
                         std::string presentation);
  void CloseBrowserOnUi(uint64_t surface_id);
  void OnBrowserCreated(uint64_t surface_id, CefRefPtr<CefBrowser> browser);
  void OnBrowserClosed(uint64_t surface_id);

 private:
  bool HandleFrame(std::string_view body);
  bool AuthenticateEnvelope(CefRefPtr<CefDictionaryValue> envelope,
                            CefRefPtr<CefDictionaryValue>& message,
                            std::string& error);
  bool HandleOpen(CefRefPtr<CefDictionaryValue> payload);
  bool HandleClose(CefRefPtr<CefDictionaryValue> payload);
  bool HandleCommand(CefRefPtr<CefDictionaryValue> payload);
  void SendMessage(CefRefPtr<CefDictionaryValue> message);
  void SendError(std::optional<int> request_id, std::string_view code,
                 std::string_view message);
  void SendOpened(int request_id, uint64_t surface_id);
  void SendReady(const SurfaceState& surface, std::string_view url);
  void SendClosed(uint64_t surface_id, uint64_t sequence);
  std::optional<SurfaceState> GetSurface(uint64_t surface_id);
  bool HasSurface(uint64_t surface_id);

  HostArgs args_;
  PipeChannel& pipe_;
  std::mutex state_mutex_;
  std::map<uint64_t, SurfaceState> surfaces_;
  uint64_t next_surface_id_ = 1;
  std::atomic<bool> stopping_ = false;
  std::condition_variable closed_condition_;
};

class CreateBrowserTask final : public CefTask {
 public:
  CreateBrowserTask(HostController* controller, uint64_t surface_id,
                    std::string url, std::string presentation)
      : controller_(controller),
        surface_id_(surface_id),
        url_(std::move(url)),
        presentation_(std::move(presentation)) {}

  void Execute() override {
    controller_->CreateBrowserOnUi(surface_id_, std::move(url_),
                                   std::move(presentation_));
  }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  std::string url_;
  std::string presentation_;
  IMPLEMENT_REFCOUNTING(CreateBrowserTask);
};

class CloseBrowserTask final : public CefTask {
 public:
  CloseBrowserTask(HostController* controller, uint64_t surface_id)
      : controller_(controller), surface_id_(surface_id) {}

  void Execute() override { controller_->CloseBrowserOnUi(surface_id_); }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  IMPLEMENT_REFCOUNTING(CloseBrowserTask);
};

CefRefPtr<CefDictionaryValue> Dictionary(CefRefPtr<CefValue> value) {
  if (value == nullptr || value->GetType() != VTYPE_DICTIONARY) {
    return nullptr;
  }
  return value->GetDictionary();
}

CefRefPtr<CefDictionaryValue> NewDictionary() {
  return CefDictionaryValue::Create();
}

CefRefPtr<CefValue> NewEnvelope(CefRefPtr<CefDictionaryValue> message,
                                std::string_view nonce) {
  auto envelope = CefValue::Create();
  auto dictionary = NewDictionary();
  dictionary->SetInt("version", kProtocolVersion);
  dictionary->SetString("nonce", std::string(nonce));
  dictionary->SetDictionary("message", message);
  envelope->SetDictionary(dictionary);
  return envelope;
}

std::string Json(CefRefPtr<CefValue> value) {
  return CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
}

void HostController::SendMessage(CefRefPtr<CefDictionaryValue> message) {
  if (stopping_) {
    return;
  }
  const std::string body = Json(NewEnvelope(message, args_.nonce));
  if (body.empty() || !pipe_.WriteFrame(body)) {
    stopping_ = true;
  }
}

void HostController::SendError(std::optional<int> request_id,
                               std::string_view code,
                               std::string_view message) {
  auto payload = NewDictionary();
  if (request_id.has_value()) {
    payload->SetInt("request_id", *request_id);
  } else {
    payload->SetNull("request_id");
  }
  payload->SetString("code", std::string(code));
  payload->SetString("message", std::string(message));
  auto wire = NewDictionary();
  wire->SetString("type", "error");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendOpened(int request_id, uint64_t surface_id) {
  auto payload = NewDictionary();
  payload->SetInt("request_id", request_id);
  payload->SetInt("surface_id", static_cast<int>(surface_id));
  auto wire = NewDictionary();
  wire->SetString("type", "opened");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendReady(const SurfaceState& surface,
                               std::string_view url) {
  auto navigation = NewDictionary();
  navigation->SetString("url", std::string(url));
  navigation->SetString("disposition", "current");
  navigation->SetBool("user_initiated", false);

  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface.id));
  event_payload->SetInt("sequence", 1);
  event_payload->SetDictionary("initial_navigation", navigation);

  auto event = NewDictionary();
  event->SetString("type", "ready");
  event->SetDictionary("payload", event_payload);

  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendClosed(uint64_t surface_id, uint64_t sequence) {
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("reason", "user");

  auto event = NewDictionary();
  event->SetString("type", "closed");
  event->SetDictionary("payload", event_payload);

  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

bool HostController::AuthenticateEnvelope(
    CefRefPtr<CefDictionaryValue> envelope,
    CefRefPtr<CefDictionaryValue>& message,
    std::string& error) {
  if (envelope == nullptr || envelope->GetType("version") != VTYPE_INT ||
      envelope->GetInt("version") != kProtocolVersion) {
    error = "unsupported_version";
    return false;
  }
  if (envelope->GetType("nonce") != VTYPE_STRING ||
      envelope->GetString("nonce").ToString() != args_.nonce) {
    error = "nonce_mismatch";
    return false;
  }
  message = envelope->GetDictionary("message");
  if (message == nullptr || message->GetType("type") != VTYPE_STRING ||
      message->GetType("payload") != VTYPE_DICTIONARY) {
    error = "invalid_message";
    return false;
  }
  const std::string type = message->GetString("type").ToString();
  if (type != "open" && type != "command" && type != "close") {
    error = "unknown_message_type";
    return false;
  }
  return true;
}

bool HostController::HandleFrame(std::string_view body) {
  auto decoded = CefParseJSON(std::string(body), JSON_PARSER_RFC);
  auto envelope = Dictionary(decoded);
  CefRefPtr<CefDictionaryValue> message;
  std::string error;
  if (!AuthenticateEnvelope(envelope, message, error)) {
    SendError(std::nullopt, error, "protocol frame rejected");
    return false;
  }
  const auto payload = message->GetDictionary("payload");
  const std::string type = message->GetString("type").ToString();
  if (type == "open") {
    return HandleOpen(payload);
  }
  if (type == "close") {
    return HandleClose(payload);
  }
  return HandleCommand(payload);
}

bool HostController::HandleOpen(CefRefPtr<CefDictionaryValue> payload) {
  if (payload == nullptr || payload->GetType("request_id") != VTYPE_INT ||
      payload->GetType("spec") != VTYPE_DICTIONARY) {
    SendError(std::nullopt, "invalid_spec", "open payload is malformed");
    return false;
  }
  const int request_id = payload->GetInt("request_id");
  const auto spec = payload->GetDictionary("spec");
  const auto navigation = spec->GetDictionary("initial_navigation");
  const std::string profile = spec->GetString("profile_key").ToString();
  const std::string presentation = spec->GetString("presentation").ToString();
  const std::string privacy = spec->GetString("privacy").ToString();
  const std::string url = navigation == nullptr
                              ? std::string()
                              : navigation->GetString("url").ToString();
  if (request_id < 0 || !IsValidProfileKey(profile) ||
      (presentation != "embedded" && presentation != "standalone") ||
      (privacy != "persistent" && privacy != "private") ||
      navigation == nullptr || navigation->GetType("url") != VTYPE_STRING ||
      navigation->GetType("disposition") != VTYPE_STRING ||
      navigation->GetType("user_initiated") != VTYPE_BOOL ||
      spec->GetType("policy") != VTYPE_DICTIONARY || url != kFixtureUrl ||
      presentation != "embedded") {
    SendError(request_id < 0 ? std::nullopt
                             : std::optional<int>(request_id),
              "invalid_spec",
              "the Windows host smoke fixture requires an embedded commet URL");
    return true;
  }

  SurfaceState surface;
  bool surface_ids_exhausted = false;
  {
    std::lock_guard lock(state_mutex_);
    if (next_surface_id_ >
        static_cast<uint64_t>(std::numeric_limits<int>::max())) {
      surface_ids_exhausted = true;
    } else {
      surface.id = next_surface_id_++;
      surface.profile_key = profile;
      surface.presentation = presentation;
      surfaces_.emplace(surface.id, surface);
    }
  }
  if (surface_ids_exhausted) {
    SendError(request_id, "runtime_failed", "surface id space is exhausted");
    return true;
  }
  SendOpened(request_id, surface.id);
  CefTaskRunner::GetForThread(TID_UI)->PostTask(
      new CreateBrowserTask(this, surface.id, url, presentation));
  return true;
}

bool HostController::HandleCommand(CefRefPtr<CefDictionaryValue> payload) {
  if (payload == nullptr || payload->GetType("surface_id") != VTYPE_INT ||
      payload->GetType("command") != VTYPE_DICTIONARY) {
    SendError(std::nullopt, "invalid_command", "command payload is malformed");
    return false;
  }
  const int raw_surface_id = payload->GetInt("surface_id");
  if (raw_surface_id <= 0) {
    SendError(std::nullopt, "invalid_command", "surface id must be positive");
    return false;
  }
  const uint64_t surface_id = static_cast<uint64_t>(raw_surface_id);
  const auto command = payload->GetDictionary("command");
  if (command->GetType("type") != VTYPE_STRING ||
      command->GetType("payload") != VTYPE_DICTIONARY) {
    SendError(std::nullopt, "invalid_command", "command is malformed");
    return false;
  }
  const std::string command_type = command->GetString("type").ToString();
  constexpr std::array<std::string_view, 10> kCommandTypes = {
      "navigate", "input", "resize", "focus", "script", "permission",
      "popup", "download", "clipboard", "release_frame",
  };
  if (std::find(kCommandTypes.begin(), kCommandTypes.end(),
                std::string_view(command_type)) ==
      kCommandTypes.end()) {
    SendError(std::nullopt, "unknown_command", "command type is not supported");
    return false;
  }
  const auto command_payload = command->GetDictionary("payload");
  if (command_payload->GetType("sequence") != VTYPE_INT ||
      command_payload->GetInt("sequence") <= 0) {
    SendError(std::nullopt, "invalid_command", "command sequence is invalid");
    return false;
  }
  if (command_payload->GetType("profile_key") == VTYPE_STRING &&
      command_payload->GetString("profile_key").ToString().empty()) {
    SendError(std::nullopt, "invalid_command", "profile key is empty");
    return false;
  }
  if (command_payload->GetType("profile_key") != VTYPE_STRING &&
      command_payload->GetType("profile_key") != VTYPE_NULL &&
      command_payload->GetType("profile_key") != VTYPE_INVALID) {
    SendError(std::nullopt, "invalid_command", "profile key is malformed");
    return false;
  }
  const auto surface = GetSurface(surface_id);
  if (!surface) {
    SendError(std::nullopt, "stale_surface", "surface id is not active");
    return true;
  }
  if (command_payload->GetType("profile_key") == VTYPE_STRING &&
      command_payload->GetString("profile_key").ToString() !=
          surface->profile_key) {
    SendError(std::nullopt, "profile_mismatch", "surface profile key does not match");
    return true;
  }
  const int sequence = command_payload->GetInt("sequence");
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) {
      SendError(std::nullopt, "stale_surface", "surface id is not active");
      return true;
    }
    if (sequence <= iterator->second.last_command_sequence) {
      SendError(std::nullopt, "sequence_violation",
                "command sequence must increase");
      return true;
    }
    iterator->second.last_command_sequence = sequence;
  }
  // Navigation/input/frame handling is added behind this same seam by the
  // caller tickets.  A fixture host accepts a well-formed command but never
  // replays a side effect or exposes a CEF object over IPC.
  return true;
}

bool HostController::HandleClose(CefRefPtr<CefDictionaryValue> payload) {
  if (payload == nullptr || payload->GetType("surface_id") != VTYPE_INT) {
    SendError(std::nullopt, "invalid_command", "close payload is malformed");
    return false;
  }
  const int raw_surface_id = payload->GetInt("surface_id");
  if (raw_surface_id <= 0) {
    SendError(std::nullopt, "invalid_command", "surface id must be positive");
    return false;
  }
  const uint64_t surface_id = static_cast<uint64_t>(raw_surface_id);
  bool found = false;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator != surfaces_.end()) {
      iterator->second.close_requested = true;
      found = true;
    }
  }
  if (!found) {
    SendError(std::nullopt, "stale_surface", "surface id is not active");
    return true;
  }
  CefTaskRunner::GetForThread(TID_UI)->PostTask(
      new CloseBrowserTask(this, surface_id));
  return true;
}

bool HostController::HasSurface(uint64_t surface_id) {
  std::lock_guard lock(state_mutex_);
  return surfaces_.find(surface_id) != surfaces_.end();
}

std::optional<SurfaceState> HostController::GetSurface(uint64_t surface_id) {
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) {
    return std::nullopt;
  }
  return iterator->second;
}

void HostController::CreateBrowserOnUi(uint64_t surface_id, std::string url,
                                       std::string presentation) {
  CEF_REQUIRE_UI_THREAD();
  if (stopping_) {
    std::lock_guard lock(state_mutex_);
    if (surfaces_.erase(surface_id) != 0) {
      closed_condition_.notify_all();
    }
    return;
  }
  auto surface = GetSurface(surface_id);
  if (!surface || presentation != "embedded") {
    SendError(std::nullopt, "invalid_spec", "surface is no longer creatable");
    return;
  }

  CefWindowInfo window_info;
  window_info.SetAsWindowless(nullptr, false);
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 30;
  auto client = new BrowserClient(this, surface_id);
  auto browser = CefBrowserHost::CreateBrowserSync(
      window_info, client, url, settings, nullptr, nullptr);
  if (browser == nullptr) {
    SendError(std::nullopt, "runtime_failed", "CEF rejected the fixture surface");
    {
      std::lock_guard lock(state_mutex_);
      surfaces_.erase(surface_id);
    }
    closed_condition_.notify_all();
    return;
  }
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator != surfaces_.end()) {
    iterator->second.browser = browser;
  }
}

void HostController::CloseBrowserOnUi(uint64_t surface_id) {
  CEF_REQUIRE_UI_THREAD();
  auto surface = GetSurface(surface_id);
  if (!surface || surface->browser == nullptr) {
    OnBrowserClosed(surface_id);
    return;
  }
  surface->browser->GetHost()->CloseBrowser(true);
}

void HostController::OnBrowserCreated(uint64_t surface_id,
                                      CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  std::optional<SurfaceState> surface;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    iterator->second.browser = browser;
    surface = iterator->second;
  }
  SendReady(*surface, kFixtureUrl);
}

void HostController::OnBrowserClosed(uint64_t surface_id) {
  CEF_REQUIRE_UI_THREAD();
  bool was_active = false;
  {
    std::lock_guard lock(state_mutex_);
    was_active = surfaces_.erase(surface_id) != 0;
  }
  if (was_active) {
    SendClosed(surface_id, 2);
    closed_condition_.notify_all();
  }
}

void HostController::Shutdown() {
  stopping_ = true;
  std::vector<uint64_t> ids;
  {
    std::lock_guard lock(state_mutex_);
    for (const auto& [id, surface] : surfaces_) {
      ids.push_back(id);
    }
  }
  for (const uint64_t id : ids) {
    CefTaskRunner::GetForThread(TID_UI)->PostTask(
        new CloseBrowserTask(this, id));
  }
  std::unique_lock lock(state_mutex_);
  // CefShutdown must not race a BrowserClient callback: BrowserClient keeps a
  // non-owning pointer back to this controller and CEF may deliver
  // OnBeforeClose asynchronously after CloseBrowser(true).  Keep the
  // controller alive until every surface has reached that callback.
  closed_condition_.wait(lock, [&] { return surfaces_.empty(); });
}

void HostController::Run() {
  std::string body;
  while (!stopping_ && pipe_.ReadFrame(body)) {
    if (!HandleFrame(body)) {
      break;
    }
  }
  Shutdown();
}

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  controller_->OnBrowserCreated(surface_id_, browser);
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  controller_->OnBrowserClosed(surface_id_);
}

int RunHost(HINSTANCE instance, void* sandbox_info) {
  const ParsedCommandLine command_line = ParseCommandLine();
  CefMainArgs main_args(instance);
  CefRefPtr<HostApp> app = new HostApp();

  // CEF child processes are launched by the same signed bootstrap/client pair.
  // They must exit through CefExecuteProcess before any browser-process IPC is
  // created.
  const int child_exit_code = CefExecuteProcess(main_args, app, sandbox_info);
  if (child_exit_code >= 0 || command_line.is_cef_child) {
    return child_exit_code >= 0 ? child_exit_code : EXIT_FAILURE;
  }

  std::wstring error;
  const auto args = ValidateHostArgs(command_line, error);
  if (!args) {
    return EXIT_FAILURE;
  }
  if (sandbox_info == nullptr || !VerifyBundledRuntime(error)) {
    return EXIT_FAILURE;
  }

  CefSettings settings;
  settings.no_sandbox = false;
  settings.multi_threaded_message_loop = true;
  settings.windowless_rendering_enabled = true;
  settings.log_severity = LOGSEVERITY_DISABLE;

  const bool initialized = CefInitialize(main_args, settings, app, sandbox_info);
  if (!initialized) {
    return EXIT_FAILURE;
  }
  if (!VerifyLoadedBundledRuntime(error)) {
    CefShutdown();
    return EXIT_FAILURE;
  }
  if (!app->WaitForContext(std::chrono::seconds(10))) {
    CefShutdown();
    return EXIT_FAILURE;
  }

  PipeChannel pipe(*args);
  if (!pipe.ConnectAndAuthenticate(error)) {
    CefShutdown();
    return EXIT_FAILURE;
  }

  {
    HostController controller(*args, pipe);
    controller.Run();
  }
  pipe.Close();
  CefShutdown();
  return EXIT_SUCCESS;
}

}  // namespace

// M138+ bootstrap.exe calls this exact export in the signed client.dll.  The
// bootstrap supplies the sandbox information object; dropping it or replacing
// the bootstrap with a hand-written subprocess would disable the supported
// Windows sandbox arrangement.
extern "C" CEF_BOOTSTRAP_EXPORT int RunWinMain(
    HINSTANCE instance,
    LPTSTR command_line,
    int show_command,
    void* sandbox_info,
    cef_version_info_t* version_info) {
  (void)command_line;
  (void)show_command;
  (void)version_info;
  return RunHost(instance, sandbox_info);
}

}  // namespace roscord::cef_host
