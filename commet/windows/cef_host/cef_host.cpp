// CMakeLists.txt defines NOMINMAX as well; redefining it is C4005 under /WX.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shellapi.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cctype>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <tchar.h>
#include <tuple>
#include <cwctype>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_callback.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_process_message.h"
#include "include/cef_parser.h"
#include "include/cef_render_handler.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request.h"
#include "include/cef_ssl_info.h"
#include "include/cef_resource_handler.h"
#include "include/cef_sandbox_win.h"
#include "include/cef_scheme.h"
#include "include/cef_task.h"
#include "include/cef_values.h"
#include "include/cef_v8.h"
#include "include/cef_version_info.h"
#include "include/wrapper/cef_helpers.h"

// Shared with the Linux engine and the app's browser_surface plugin.
#include "browser_frame_ring.h"
#include "browser_input.h"
#include "cef_cursor_names.h"

// Windows widget surfaces: embedded windowless OSR with CPU OnPaint
// copied into client-owned memory and presented as a Flutter texture, and
// standalone windowed CEF in a roscord-owned top-level HWND.  Both
// presentations share one host, one account request context, one policy, and
// one permission mediation; a surface failure is a typed failure or bounded
// recovery that never selects another engine.  Only the bundled runtime is
// ever loaded and only owned request contexts and owned browsers are ever
// created.

namespace roscord::cef_host {

namespace {

constexpr uint16_t kProtocolVersion = 1;
constexpr uint32_t kMaxFrameBytes = 1024u * 1024u;
constexpr DWORD kConnectTimeoutMs = 10000;
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\roscord-browser-";
constexpr char kFixtureUrl[] = "commet://fixture/";
constexpr char kEvaluateJavaScriptOperation[] = "evaluate_javascript";
constexpr char kDispatchScriptMessageOperation[] = "dispatch_script_message";

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

std::string HexEncode(std::string_view value) {
  constexpr char kHex[] = "0123456789abcdef";
  std::string encoded;
  encoded.reserve(value.size() * 2);
  for (const unsigned char byte : value) {
    encoded.push_back(kHex[byte >> 4]);
    encoded.push_back(kHex[byte & 0x0f]);
  }
  return encoded;
}

std::wstring ProfileDirectoryName(std::string_view key) {
  uint64_t hash = 0xcbf29ce484222325ull;
  for (const unsigned char byte : key) {
    hash ^= byte;
    hash *= 0x100000001b3ull;
  }
  wchar_t buffer[32]{};
  swprintf_s(buffer, L"profile-%016llx",
             static_cast<unsigned long long>(hash));
  return buffer;
}

std::wstring ModuleDirectory() {
  std::array<wchar_t, MAX_PATH> buffer{};
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                    static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    return {};
  }
  return std::filesystem::path(std::wstring(buffer.data(), length))
      .parent_path()
      .wstring();
}

std::wstring ModulePath(HMODULE module) {
  std::array<wchar_t, MAX_PATH> buffer{};
  DWORD length = GetModuleFileNameW(module, buffer.data(),
                                    static_cast<DWORD>(buffer.size()));
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
  std::filesystem::path profile_root;
  std::string nonce;
  // Forced software rendering.  Available in every build (not validation-only):
  // the CPU OnPaint path is release-authoritative and must satisfy the same
  // frame/input/resize/focus contract as the default path.
  bool software_rendering = false;
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
  bool software_rendering = false;
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
    if (lowered == L"--cef-software-rendering") {
      // Forced software rendering is a supported production switch.  It keeps
      // the CPU OnPaint frame ring authoritative when GPU import is
      // unavailable; it never selects another browser engine.
      software_rendering = true;
    } else if (lowered == L"--cef-validation" ||
               StartsWith(lowered, L"--cef-validation=")) {
      // The cutover removed the validation switch: production routing is
      // unconditional, so every spelling is rejected in all builds.
      error = L"CEF validation controls were removed by the cutover";
      return std::nullopt;
    } else if (lowered == L"--cef-fault" ||
               StartsWith(lowered, L"--cef-fault=")) {
      // Fault injection was removed with the validation switch; recovery is
      // driven only by real host observations.
      error = L"CEF fault injection was removed by the cutover";
      return std::nullopt;
    }
  }

  const auto pipe = ValueForSwitch(command_line.values, L"--pipe");
  const auto nonce = ValueForSwitch(command_line.values, L"--nonce");
  const auto parent = ValueForSwitch(command_line.values, L"--parent-pid");
  const auto profile_root = ValueForSwitch(command_line.values, L"--profile-root");
  if (!pipe || !nonce || !parent || !profile_root) {
    error = L"cef_host requires --pipe, --nonce, --parent-pid, and --profile-root";
    return std::nullopt;
  }

  HostArgs result;
  result.software_rendering = software_rendering;
  result.pipe_name = *pipe;
  result.profile_root = std::filesystem::path(*profile_root);
  result.nonce.assign(nonce->begin(), nonce->end());
  if (!ValidatePipeName(result.pipe_name) || result.nonce.size() < 32 ||
      result.nonce.size() > 128 || !IsHex(result.nonce) ||
      !ParseDword(*parent, result.parent_pid) ||
      result.parent_pid == GetCurrentProcessId() ||
      !result.profile_root.is_absolute() ||
      std::any_of(result.profile_root.begin(), result.profile_root.end(),
                  [](const auto& component) {
                    return component == std::filesystem::path(L"..") ||
                           component == std::filesystem::path(L".");
                  })) {
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
  // The list mirrors the windows-x64 runtime allow-list in
  // third_party/cef/cef.lock.json (Release/ and Resources/ flattened into
  // this directory, where CEF looks for ICU data, .pak files and locales, with
  // bootstrap.exe renamed to cef_host.exe by CMake) and is
  // cross-checked offline by tools/qualify_windows_artifact.py.  Only the
  // en-US locale is required for startup; further locales are verified by the
  // qualification gate against the staged manifest.
  const std::array<std::filesystem::path, 18> required = {
      root / L"cef_host.exe",       root / L"cef_host.dll",
      root / L"libcef.dll",         root / L"chrome_elf.dll",
      root / L"d3dcompiler_47.dll", root / L"dxcompiler.dll",
      root / L"dxil.dll",           root / L"libEGL.dll",
      root / L"libGLESv2.dll",      root / L"v8_context_snapshot.bin",
      root / L"vk_swiftshader.dll", root / L"vk_swiftshader_icd.json",
      root / L"vulkan-1.dll",
      root / L"chrome_100_percent.pak",
      root / L"chrome_200_percent.pak",
      root / L"icudtl.dat",
      root / L"resources.pak",
      root / L"locales" / L"en-US.pak",
  };
  for (const auto& path : required) {
    if (!IsRegularFile(path)) {
      error = L"bundled CEF file is missing: " + path.wstring();
      return false;
    }
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

  // `inheritable` marks the ACE for inheritance, so files and directories
  // later created inside a directory stay owner-only too.
  bool Create(bool inheritable = false) {
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
    // The user is named as owner: an elevated administrator's new files would
    // otherwise belong to the Administrators group, which IsOwnerControlled
    // rejects.
    const std::wstring sid(sid_string);
    const std::wstring sddl = L"O:" + sid + L"D:P(A;" +
                              (inheritable ? L"OICI" : L"") + L";GA;;;" + sid +
                              L")";
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

bool IsOwnerControlled(const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  for (auto ancestor = path.parent_path(); !ancestor.empty();
       ancestor = ancestor.parent_path()) {
    const DWORD ancestor_attributes = GetFileAttributesW(ancestor.c_str());
    if (ancestor_attributes == INVALID_FILE_ATTRIBUTES ||
        (ancestor_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    if (ancestor == ancestor.root_path()) break;
  }

  PSECURITY_DESCRIPTOR descriptor = nullptr;
  PSID owner = nullptr;
  PACL dacl = nullptr;
  if (GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT,
                            OWNER_SECURITY_INFORMATION |
                                DACL_SECURITY_INFORMATION,
                            &owner, nullptr, &dacl, nullptr,
                            &descriptor) != ERROR_SUCCESS ||
      owner == nullptr || dacl == nullptr) {
    if (descriptor != nullptr) LocalFree(descriptor);
    return false;
  }

  HANDLE token = nullptr;
  bool owner_matches = false;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<std::byte> token_data(size);
    if (size != 0 && GetTokenInformation(token, TokenUser, token_data.data(),
                                         size, &size)) {
      owner_matches = EqualSid(owner,
                               reinterpret_cast<PTOKEN_USER>(token_data.data())
                                   ->User.Sid) != FALSE;
    }
    CloseHandle(token);
  }
  bool only_owner = owner_matches;
  for (DWORD index = 0; only_owner && index < dacl->AceCount; ++index) {
    LPVOID raw_ace = nullptr;
    if (!GetAce(dacl, index, &raw_ace)) {
      only_owner = false;
      break;
    }
    const auto* header = static_cast<const ACE_HEADER*>(raw_ace);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) continue;
    const auto* ace = static_cast<const ACCESS_ALLOWED_ACE*>(raw_ace);
    if (!owner_matches ||
        !EqualSid(const_cast<DWORD*>(&ace->SidStart), owner)) {
      only_owner = false;
    }
  }
  LocalFree(descriptor);
  return only_owner;
}

class CompletionLatch final : public CefCompletionCallback {
 public:
  void OnComplete() override {
    {
      std::lock_guard lock(mutex_);
      complete_ = true;
    }
    condition_.notify_all();
  }

  bool Wait(std::chrono::seconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout, [&] { return complete_; });
  }

 private:
  std::mutex mutex_;
  std::condition_variable condition_;
  bool complete_ = false;
  IMPLEMENT_REFCOUNTING(CompletionLatch);
};

bool FlushAndCloseContext(const CefRefPtr<CefRequestContext>& context,
                          std::string& error) {
  if (context == nullptr) return true;

  CefRefPtr<CompletionLatch> certificates = new CompletionLatch();
  context->ClearCertificateExceptions(certificates);
  if (!certificates->Wait(std::chrono::seconds(5))) {
    error = "profile certificate exceptions did not clear";
    return false;
  }

  CefRefPtr<CompletionLatch> credentials = new CompletionLatch();
  context->ClearHttpAuthCredentials(credentials);
  if (!credentials->Wait(std::chrono::seconds(5))) {
    error = "profile HTTP credentials did not clear";
    return false;
  }

  auto cookie_manager = context->GetCookieManager(nullptr);
  if (cookie_manager != nullptr) {
    CefRefPtr<CompletionLatch> flushed = new CompletionLatch();
    cookie_manager->FlushStore(flushed);
    if (!flushed->Wait(std::chrono::seconds(5))) {
      error = "profile cookie store did not flush";
      return false;
    }
  }

  CefRefPtr<CompletionLatch> closed = new CompletionLatch();
  context->CloseAllConnections(closed);
  if (!closed->Wait(std::chrono::seconds(5))) {
    error = "profile connections did not close";
    return false;
  }
  return true;
}

bool WriteOwnerManifest(const std::filesystem::path& path,
                        std::string_view contents) {
  // Created owner-only: the token's default DACL would also grant SYSTEM (and
  // Administrators when elevated), which IsOwnerControlled rejects.
  OwnerOnlySecurityDescriptor security;
  if (!security.Create()) return false;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), security.get(), FALSE};
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_WRITE, 0, &attributes, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
          FILE_FLAG_WRITE_THROUGH,
      nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  DWORD written = 0;
  const bool wrote = WriteFile(file, contents.data(),
                               static_cast<DWORD>(contents.size()), &written,
                               nullptr) != FALSE &&
                     written == static_cast<DWORD>(contents.size());
  const bool flushed = wrote && FlushFileBuffers(file) != FALSE;
  CloseHandle(file);
  return flushed && IsOwnerControlled(path);
}

bool ReadOwnerManifest(const std::filesystem::path& path, std::string& contents) {
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;

  LARGE_INTEGER size{};
  const bool sized = GetFileSizeEx(file, &size) != FALSE && size.QuadPart >= 0 &&
                     size.QuadPart <= 4096;
  if (!sized) {
    CloseHandle(file);
    return false;
  }
  contents.assign(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const bool read_ok = ReadFile(file, contents.data(),
                                static_cast<DWORD>(contents.size()), &read,
                                nullptr) != FALSE &&
                       read == static_cast<DWORD>(contents.size());
  CloseHandle(file);
  return read_ok && IsOwnerControlled(path);
}

bool MakeOwnerOnlyDirectory(const std::filesystem::path& path) {
  std::error_code error;
  std::filesystem::create_directories(path, error);
  if (error) return false;
  OwnerOnlySecurityDescriptor security;
  if (!security.Create(/*inheritable=*/true)) return false;
  PACL dacl = nullptr;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  PSID owner = nullptr;
  BOOL owner_defaulted = FALSE;
  if (!GetSecurityDescriptorDacl(security.get(), &present, &dacl,
                                 &defaulted) ||
      !present || dacl == nullptr ||
      !GetSecurityDescriptorOwner(security.get(), &owner, &owner_defaulted) ||
      owner == nullptr) {
    return false;
  }
  return SetNamedSecurityInfoW(
             const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
             OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
                 PROTECTED_DACL_SECURITY_INFORMATION,
             owner, nullptr, dacl, nullptr) == ERROR_SUCCESS;
}

bool ValidateProfileRoot(const std::filesystem::path& path) {
  if (!path.is_absolute() ||
      std::any_of(path.begin(), path.end(), [](const auto& component) {
        return component == std::filesystem::path(L"..") ||
               component == std::filesystem::path(L".");
      })) {
    return false;
  }
  for (auto ancestor = path; !ancestor.empty(); ancestor = ancestor.parent_path()) {
    const DWORD attributes = GetFileAttributesW(ancestor.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    if (ancestor == ancestor.root_path()) break;
  }
  std::error_code error;
  const bool existed = GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
  std::filesystem::create_directories(path, error);
  if (error) return false;
  if (!existed) return MakeOwnerOnlyDirectory(path);
  return IsOwnerControlled(path);
}

bool RejectReparseBelow(const std::filesystem::path& directory) {
  const DWORD attributes = GetFileAttributesW(directory.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) return true;

  std::error_code error;
  for (const auto& entry : std::filesystem::directory_iterator(directory, error)) {
    if (error || !RejectReparseBelow(entry.path())) return false;
  }
  return !error;
}

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

    // Overlapped I/O: the transport thread waits in a read while CEF threads
    // write events.  On a synchronous handle Windows serializes the two, so
    // every event would wait for the parent's next message.
    pipe_ = CreateNamedPipeW(
        args_.pipe_name.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED |
            FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
            PIPE_REJECT_REMOTE_CLIENTS,
        1, kMaxFrameBytes + 4, kMaxFrameBytes + 4, kConnectTimeoutMs,
        &attributes);
    if (pipe_ == INVALID_HANDLE_VALUE) {
      error = L"cannot create the private named pipe";
      pipe_ = nullptr;
      return false;
    }
    read_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    write_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (read_event_ == nullptr || write_event_ == nullptr) {
      error = L"cannot create named-pipe events";
      Close();
      return false;
    }

    bool connected = false;
    OVERLAPPED connect_overlapped{};
    connect_overlapped.hEvent = read_event_;
    ResetEvent(read_event_);
    if (ConnectNamedPipe(pipe_, &connect_overlapped)) {
      connected = true;
    } else {
      const DWORD connect_error = GetLastError();
      if (connect_error == ERROR_PIPE_CONNECTED) {
        connected = true;
      } else if (connect_error == ERROR_IO_PENDING) {
        DWORD ignored = 0;
        if (WaitForSingleObject(read_event_, kConnectTimeoutMs) ==
            WAIT_OBJECT_0) {
          connected = GetOverlappedResult(pipe_, &connect_overlapped, &ignored,
                                          FALSE) != FALSE;
        } else {
          CancelIoEx(pipe_, &connect_overlapped);
          GetOverlappedResult(pipe_, &connect_overlapped, &ignored, TRUE);
        }
      }
    }
    if (!connected) {
      error = L"parent did not connect to the private named pipe";
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
      // Wakes a transport thread still waiting in a read.
      CancelIoEx(pipe_, nullptr);
      FlushFileBuffers(pipe_);
      DisconnectNamedPipe(pipe_);
      CloseHandle(pipe_);
      pipe_ = nullptr;
    }
  }

  ~PipeChannel() {
    Close();
    if (read_event_ != nullptr) CloseHandle(read_event_);
    if (write_event_ != nullptr) CloseHandle(write_event_);
  }

 private:
  // One overlapped read or write, waited for on this thread.  Reads and
  // writes use separate events, so they never wait for each other.
  bool Transfer(bool reading, void* buffer, DWORD size, DWORD& transferred) {
    HANDLE pipe = pipe_;
    if (pipe == nullptr) return false;
    OVERLAPPED overlapped{};
    overlapped.hEvent = reading ? read_event_ : write_event_;
    ResetEvent(overlapped.hEvent);
    const BOOL started =
        reading ? ReadFile(pipe, buffer, size, nullptr, &overlapped)
                : WriteFile(pipe, buffer, size, nullptr, &overlapped);
    if (!started && GetLastError() != ERROR_IO_PENDING) return false;
    transferred = 0;
    return GetOverlappedResult(pipe, &overlapped, &transferred, TRUE) !=
               FALSE &&
           transferred > 0;
  }

  bool ReadExact(void* destination, size_t size) {
    auto* bytes = static_cast<std::uint8_t*>(destination);
    while (size > 0) {
      DWORD read = 0;
      if (!Transfer(true, bytes, static_cast<DWORD>(size), read)) {
        return false;
      }
      bytes += read;
      size -= read;
    }
    return true;
  }

  bool WriteExact(const void* source, size_t size) {
    auto* bytes = const_cast<std::uint8_t*>(
        static_cast<const std::uint8_t*>(source));
    while (size > 0) {
      DWORD written = 0;
      if (!Transfer(false, bytes, static_cast<DWORD>(size), written)) {
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
  HANDLE read_event_ = nullptr;
  HANDLE write_event_ = nullptr;
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

// The renderer-side half of the generic BrowserRuntime script bridge.  It
// deliberately accepts only a JSON string: the browser process validates and
// wraps the opaque value as a ScriptEnvelope before it reaches Dart.  No
// Caller-specific action or capability vocabulary crosses this CEF boundary.
class BrowserRuntimeSendHandler final : public CefV8Handler {
 public:
  bool Execute(const CefString& name, CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    (void)name;
    (void)object;
    retval = CefV8Value::CreateUndefined();
    if (arguments.size() != 1 || !arguments[0]->IsString()) {
      exception = "BrowserRuntime bridge expects one JSON string";
      return false;
    }
    const auto context = CefV8Context::GetCurrentContext();
    const auto frame = context == nullptr ? nullptr : context->GetFrame();
    if (frame == nullptr) {
      exception = "BrowserRuntime bridge has no browser context";
      return false;
    }
    auto message = CefProcessMessage::Create("roscord_browser_runtime_send");
    message->GetArgumentList()->SetString(
        0, arguments[0]->GetStringValue());
    // Process messages are sent through a frame, and delivery is not
    // acknowledged: the host answers on the bridge if it needs to.
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserRuntimeSendHandler);
};

class HostApp final : public CefApp,
                      public CefBrowserProcessHandler,
                      public CefRenderProcessHandler {
 public:
  HostApp() = default;

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    // Playback starts from an explicit click in the app, which never
    // reaches the page as a user gesture.
    command_line->AppendSwitchWithValue("autoplay-policy",
                                        "no-user-gesture-required");
    // Chrome's first-run flow has no place in an embedded host.
    command_line->AppendSwitch("no-first-run");
    command_line->AppendSwitch("no-default-browser-check");
    if (software_rendering_) {
      command_line->AppendSwitch("disable-gpu");
      command_line->AppendSwitch("disable-gpu-compositing");
    }
  }

  // Set before CefInitialize, which is when the browser process's command
  // line is processed.
  void SetSoftwareRendering(bool software_rendering) {
    software_rendering_ = software_rendering;
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

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    CEF_REQUIRE_RENDERER_THREAD();
    (void)browser;
    (void)frame;
    const auto global = context->GetGlobal();
    global->SetValue(
        "__roscordBrowserRuntimeSend",
        CefV8Value::CreateFunction("__roscordBrowserRuntimeSend",
                                   new BrowserRuntimeSendHandler()),
        V8_PROPERTY_ATTRIBUTE_NONE);
  }

  bool WaitForContext(std::chrono::seconds timeout) {
    std::unique_lock lock(mutex_);
    return condition_.wait_for(lock, timeout,
                               [&] { return context_initialized_; });
  }

 private:
  bool software_rendering_ = false;
  std::mutex mutex_;
  std::condition_variable condition_;
  bool context_initialized_ = false;
  IMPLEMENT_REFCOUNTING(HostApp);
};

// The host, rather than a caller, owns request-context creation.  This keeps
// cookies, cache, storage, credentials, and permission decisions inside one
// account-bound context while private surfaces receive an in-memory context.
class ProfileManager {
 public:
  explicit ProfileManager(std::filesystem::path root) : root_(std::move(root)) {}

  bool Open(std::string_view key, std::string_view privacy,
            CefRefPtr<CefRequestContext>& context, uint64_t& context_id,
            std::string& error) {
    std::lock_guard lock(mutex_);
    if (!IsValidProfileKey(key)) {
      error = "profile key is invalid";
      return false;
    }
    if (clearing_.find(std::string(key)) != clearing_.end()) {
      error = "profile is busy";
      return false;
    }
    if (privacy == "persistent") {
      const auto existing = persistent_.find(std::string(key));
      if (existing != persistent_.end()) {
        auto iterator = contexts_.find(existing->second);
        if (iterator == contexts_.end()) {
          error = "profile is unavailable";
          return false;
        }
        if (!EnsureExistingProfile(key, iterator->second.path, error)) {
          return false;
        }
        iterator->second.active += 1;
        context_id = iterator->second.id;
        context = iterator->second.context;
        return true;
      }

      std::filesystem::path profile_path;
      if (!EnsureProfile(key, profile_path, error)) return false;
      CefRequestContextSettings settings;
      CefString(&settings.cache_path) = profile_path.wstring();
      settings.persist_session_cookies = true;
      context = CefRequestContext::CreateContext(settings, nullptr);
      if (context == nullptr) {
        error = "persistent request context could not be created";
        return false;
      }
      context_id = next_context_id_++;
      contexts_.emplace(context_id,
                        Context{context_id, std::string(key), false, 1,
                                profile_path, context});
      persistent_.emplace(std::string(key), context_id);
      return true;
    }
    if (privacy != "private") {
      error = "privacy mode is invalid";
      return false;
    }

    CefRequestContextSettings settings;
    CefString(&settings.cache_path).clear();
    settings.persist_session_cookies = false;
    context = CefRequestContext::CreateContext(settings, nullptr);
    if (context == nullptr) {
      error = "private request context could not be created";
      return false;
    }
    context_id = next_context_id_++;
    contexts_.emplace(context_id,
                      Context{context_id, std::string(key), true, 1, {}, context});
    return true;
  }

  bool Release(uint64_t context_id) {
    std::lock_guard lock(mutex_);
    const auto iterator = contexts_.find(context_id);
    if (iterator == contexts_.end() || iterator->second.active <= 0) return false;
    iterator->second.active -= 1;
    if (iterator->second.is_private) contexts_.erase(iterator);
    return true;
  }

  bool ClearData(std::string_view key, std::string& error) {
    if (!IsValidProfileKey(key)) {
      error = "profile key is invalid";
      return false;
    }
    const std::string account(key);
    std::unique_lock lock(mutex_);
    if (clearing_.find(account) != clearing_.end()) {
      error = "profile is busy";
      return false;
    }
    for (const auto& entry : contexts_) {
      const auto& context = entry.second;
      if (context.key == account && context.active != 0) {
        error = "profile is busy";
        return false;
      }
    }
    clearing_.insert(account);
    CefRefPtr<CefRequestContext> old_context;
    const auto persistent = persistent_.find(std::string(key));
    if (persistent != persistent_.end()) {
      const auto context = contexts_.find(persistent->second);
      if (context != contexts_.end()) old_context = context->second.context;
      if (context != contexts_.end()) contexts_.erase(context);
      persistent_.erase(persistent);
    }
    lock.unlock();

    const auto finish = [&]() {
      std::lock_guard relock(mutex_);
      clearing_.erase(account);
    };
    if (!FlushAndCloseContext(old_context, error)) {
      finish();
      return false;
    }
    old_context = nullptr;

    std::filesystem::path profile_path;
    if (!EnsureProfile(key, profile_path, error)) {
      finish();
      return false;
    }
    std::error_code iterator_error;
    for (std::filesystem::directory_iterator iterator(profile_path,
                                                       iterator_error),
         end;
         iterator != end; iterator.increment(iterator_error)) {
      if (iterator_error) {
        error = "profile data could not be enumerated";
        finish();
        return false;
      }
      const auto& entry = *iterator;
      const auto name = entry.path().filename();
      if (name == L"profile.manifest") continue;
      if (name == L"downloads") {
        const DWORD attributes = GetFileAttributesW(entry.path().c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES ||
            (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
          error = "profile downloads entry is not a real path";
          finish();
          return false;
        }
        continue;
      }
      if (!RemoveTree(entry.path())) {
        error = "profile data could not be cleared";
        finish();
        return false;
      }
    }
    if (iterator_error) {
      error = "profile data could not be enumerated";
      finish();
      return false;
    }
    const bool valid = EnsureProfile(key, profile_path, error);
    finish();
    return valid;
  }

  void Shutdown() {
    std::lock_guard lock(mutex_);
    std::string ignored;
    for (const auto& entry : contexts_) {
      const auto& context = entry.second;
      if (!context.is_private) {
        FlushAndCloseContext(context.context, ignored);
      }
    }
    contexts_.clear();
    persistent_.clear();
    clearing_.clear();
  }

 private:
  struct Context {
    uint64_t id;
    std::string key;
    bool is_private;
    int active;
    std::filesystem::path path;
    CefRefPtr<CefRequestContext> context;
  };

  bool EnsureProfile(std::string_view key, std::filesystem::path& profile_path,
                     std::string& error) const {
    if (!IsValidProfileKey(key)) {
      error = "profile key is invalid";
      return false;
    }
    profile_path = root_ / ProfileDirectoryName(key);
    if (!IsPathInDirectory(profile_path, root_)) {
      error = "profile path is outside the app-data root";
      return false;
    }
    const DWORD attributes = GetFileAttributesW(profile_path.c_str());
    const bool created = attributes == INVALID_FILE_ATTRIBUTES;
    if (created) {
      if (!MakeOwnerOnlyDirectory(profile_path)) {
        error = "profile directory could not be created";
        return false;
      }
    } else if (!IsOwnerControlled(profile_path)) {
      error = "profile directory is not owner-controlled";
      return false;
    }
    if (!RejectReparseBelow(profile_path)) {
      error = "profile directory contains a reparse point";
      return false;
    }

    const auto manifest = profile_path / L"profile.manifest";
    if (!IsRegularFile(manifest)) {
      if (!created) {
        if (!Quarantine(profile_path)) {
          error = "profile quarantine failed";
          return false;
        }
        error = "profile migration failed";
        return false;
      }
      const std::string expected =
          "schema=1\nprofile_key=" + HexEncode(key) + "\n";
      if (!WriteOwnerManifest(manifest, expected)) {
        error = "profile manifest could not be created";
        return false;
      }
      return true;
    }

    const std::string expected = "schema=1\nprofile_key=" + HexEncode(key) + "\n";
    std::string actual;
    if (!ReadOwnerManifest(manifest, actual) || actual != expected) {
      if (!Quarantine(profile_path)) {
        error = "profile quarantine failed";
        return false;
      }
      error = "profile migration failed";
      return false;
    }
    return true;
  }

  bool EnsureExistingProfile(std::string_view key,
                             const std::filesystem::path& expected_path,
                             std::string& error) const {
    const DWORD attributes = GetFileAttributesW(expected_path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      error = "profile migration failed";
      return false;
    }
    std::filesystem::path profile_path;
    if (!EnsureProfile(key, profile_path, error)) return false;
    if (profile_path != expected_path) {
      error = "profile is corrupt";
      return false;
    }
    return true;
  }

  static bool RemoveTree(const std::filesystem::path& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return false;
    }
    std::error_code error;
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      for (const auto& entry : std::filesystem::directory_iterator(path, error)) {
        if (error || !RemoveTree(entry.path())) return false;
      }
      return std::filesystem::remove(path, error) && !error;
    }
    return std::filesystem::remove(path, error) && !error;
  }

  static bool Quarantine(const std::filesystem::path& path) {
    const auto destination = path.parent_path() /
        (L"quarantine-" + std::to_wstring(GetTickCount64()) + L"-" +
         path.filename().wstring());
    return MoveFileExW(path.c_str(), destination.c_str(), MOVEFILE_WRITE_THROUGH) !=
           FALSE;
  }

  std::filesystem::path root_;
  std::mutex mutex_;
  uint64_t next_context_id_ = 1;
  std::map<uint64_t, Context> contexts_;
  std::map<std::string, uint64_t> persistent_;
  std::set<std::string> clearing_;
};

class CreateBrowserTask;
class CloseBrowserTask;
class NavigateBrowserTask;

struct NavigationPolicy {
  std::vector<std::string> allowed_origins;
  std::vector<std::string> allowed_loopback_origins;
  bool allow_external_navigation = false;
  // Explicit capability flags from the surface policy.  Only the canonical
  // media capability names are consulted by permission mediation; all other
  // capability names stay in the Dart adapter and are never interpreted
  // here.  A capability is enabled unless it is explicitly set to false.
  std::map<std::string, bool> capabilities;
};

enum class NavigationDecision { InProcess, External, Cancel };

std::string Lowercase(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

// CefURLParts fields are raw cef_string_t structs.
std::string UrlPart(const cef_string_t& part) {
  return CefString(&part).ToString();
}

std::optional<std::string> UrlOrigin(std::string_view url) {
  CefURLParts parts;
  if (!CefParseURL(std::string(url), parts)) return std::nullopt;
  const std::string scheme = Lowercase(UrlPart(parts.scheme));
  if (scheme != "https" && scheme != "http" && scheme != "commet") {
    return std::nullopt;
  }
  if (UrlPart(parts.host).empty() || !UrlPart(parts.username).empty() ||
      !UrlPart(parts.password).empty()) {
    return std::nullopt;
  }
  std::string host = Lowercase(UrlPart(parts.host));
  if (host.find(':') != std::string::npos && host.front() != '[') {
    host = "[" + host + "]";
  }
  std::string origin = scheme + "://" + host;
  const std::string port = UrlPart(parts.port);
  if (!port.empty()) origin += ":" + port;
  return origin;
}

bool IsLoopbackOrigin(std::string_view origin) {
  CefURLParts parts;
  if (!CefParseURL(std::string(origin), parts) ||
      Lowercase(UrlPart(parts.scheme)) != "http" || UrlPart(parts.port).empty()) {
    return false;
  }
  std::string host = Lowercase(UrlPart(parts.host));
  if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
    host = host.substr(1, host.size() - 2);
  }
  return host == "localhost" || host == "127.0.0.1" || host == "::1";
}

bool IsExactOrigin(std::string_view declared) {
  const auto origin = UrlOrigin(declared);
  if (!origin.has_value()) return false;
  return Lowercase(std::string(declared)) == *origin;
}

bool IsControlledFixture(std::string_view url) {
  constexpr std::string_view fixture_origin = "commet://fixture";
  constexpr std::string_view fixture = kFixtureUrl;
  return url == fixture_origin || url == fixture ||
         (url.size() > fixture.size() && url.substr(0, fixture.size()) == fixture);
}

bool ParseNavigationPolicy(CefRefPtr<CefDictionaryValue> value,
                           NavigationPolicy& policy) {
  if (value == nullptr) {
    return false;
  }
  const auto origins_type = value->GetType("allowed_origins");
  const auto loopback_type = value->GetType("allowed_loopback_origins");
  if ((origins_type != VTYPE_LIST && origins_type != VTYPE_INVALID &&
       origins_type != VTYPE_NULL) ||
      (loopback_type != VTYPE_LIST && loopback_type != VTYPE_INVALID &&
       loopback_type != VTYPE_NULL)) {
    return false;
  }
  CefRefPtr<CefListValue> origins;
  CefRefPtr<CefListValue> loopback_origins;
  if (origins_type == VTYPE_LIST) {
    origins = value->GetList("allowed_origins");
  }
  if (loopback_type == VTYPE_LIST) {
    loopback_origins = value->GetList("allowed_loopback_origins");
  }
  if (origins_type == VTYPE_LIST && origins == nullptr) return false;
  if (loopback_type == VTYPE_LIST && loopback_origins == nullptr) return false;
  const auto external_type = value->GetType("allow_external_navigation");
  if (external_type != VTYPE_BOOL && external_type != VTYPE_INVALID &&
      external_type != VTYPE_NULL) {
    return false;
  }
  for (size_t index = 0; origins != nullptr && index < origins->GetSize(); ++index) {
    if (origins->GetType(index) != VTYPE_STRING) return false;
    const std::string origin = origins->GetString(index).ToString();
    const auto normalized = UrlOrigin(origin);
    if (!normalized.has_value() || !IsExactOrigin(origin) ||
        (normalized->rfind("https://", 0) != 0 &&
         normalized->rfind("commet://", 0) != 0)) {
      return false;
    }
    policy.allowed_origins.push_back(*normalized);
  }
  for (size_t index = 0;
       loopback_origins != nullptr && index < loopback_origins->GetSize();
       ++index) {
    if (loopback_origins->GetType(index) != VTYPE_STRING) return false;
    const std::string origin = loopback_origins->GetString(index).ToString();
    const auto normalized = UrlOrigin(origin);
    if (!normalized.has_value() || !IsExactOrigin(origin) ||
        !IsLoopbackOrigin(*normalized)) {
      return false;
    }
    policy.allowed_loopback_origins.push_back(*normalized);
  }
  policy.allow_external_navigation = external_type == VTYPE_BOOL &&
                                     value->GetBool("allow_external_navigation");
  // Capability flags are optional routing data.  Only boolean entries are
  // interpreted; anything else is ignored so a future capability shape
  // cannot silently change mediation.
  const auto capabilities_type = value->GetType("capabilities");
  if (capabilities_type != VTYPE_DICTIONARY &&
      capabilities_type != VTYPE_INVALID &&
      capabilities_type != VTYPE_NULL) {
    return false;
  }
  if (capabilities_type == VTYPE_DICTIONARY) {
    const auto capabilities = value->GetDictionary("capabilities");
    if (capabilities == nullptr) return false;
    std::vector<CefString> capability_keys;
    capabilities->GetKeys(capability_keys);
    for (const auto& key : capability_keys) {
      const std::string name = key.ToString();
      if (name.empty()) return false;
      if (capabilities->GetType(key) != VTYPE_BOOL) continue;
      policy.capabilities[name] = capabilities->GetBool(key);
    }
  }
  return true;
}

bool PolicyAllowsInProcess(const NavigationPolicy& policy,
                           std::string_view url) {
  if (IsControlledFixture(url)) return true;
  const auto origin = UrlOrigin(url);
  if (!origin.has_value()) return false;
  return std::find(policy.allowed_origins.begin(), policy.allowed_origins.end(),
                   *origin) != policy.allowed_origins.end() ||
         std::find(policy.allowed_loopback_origins.begin(),
                   policy.allowed_loopback_origins.end(),
                   *origin) != policy.allowed_loopback_origins.end();
}

NavigationDecision EvaluateNavigation(const NavigationPolicy& policy,
                                       std::string_view url,
                                       std::string_view disposition,
                                       bool user_gesture) {
  if (disposition == "external") {
    return user_gesture && policy.allow_external_navigation &&
                   (UrlOrigin(url).has_value() || IsControlledFixture(url))
               ? NavigationDecision::External
               : NavigationDecision::Cancel;
  }
  if (disposition != "current" && disposition != "new_surface") {
    return NavigationDecision::Cancel;
  }
  if (PolicyAllowsInProcess(policy, url)) return NavigationDecision::InProcess;
  if (!UrlOrigin(url).has_value() && !IsControlledFixture(url)) {
    return NavigationDecision::Cancel;
  }
  return user_gesture && policy.allow_external_navigation
              ? NavigationDecision::External
              : NavigationDecision::Cancel;
}

// --- Mediated file access (downloads, clipboard, uploads) -----------------
//
// The page never receives a native clipboard handle, a real filesystem path,
// or a directory enumeration.  Downloads require an explicit app approval and
// commit atomically from temporary staging; clipboard reads need a gesture
// plus a one-shot prompt and writes need a gesture plus an admitted origin;
// uploads proceed only through one OS file chooser whose selection is handed
// over as read-only staged copies.  Pending requests cancel terminally on
// navigation, close, host loss, timeout, denial, or unavailable UI.

bool IsReservedDownloadStem(std::string_view stem) {
  static constexpr std::array<std::string_view, 22> kReserved = {
      "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
      "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5",
      "LPT6", "LPT7", "LPT8", "LPT9",
  };
  std::string upper(stem);
  std::transform(upper.begin(), upper.end(), upper.begin(), [](unsigned char c) {
    return static_cast<char>(std::toupper(c));
  });
  return std::find(kReserved.begin(), kReserved.end(), upper) != kReserved.end();
}

// Returns a safe destination leaf for a page-suggested download name, or
// nullopt when the suggestion is hostile.  Mirrors the Dart
// `sanitizeSuggestedDownloadName` and Rust `sanitize_suggested_download_name`
// policy: no separators, drive prefixes, control characters, dot segments,
// reserved device names, or overlong names.
std::optional<std::string> SanitizeDownloadName(std::string_view suggested) {
  if (suggested.empty() || suggested.size() > 255) return std::nullopt;
  for (const unsigned char c : suggested) {
    if (c < 0x20 || c == 0x7f) return std::nullopt;
  }
  if (suggested.find('/') != std::string_view::npos ||
      suggested.find('\\') != std::string_view::npos ||
      suggested.find('\0') != std::string_view::npos) {
    return std::nullopt;
  }
  if (suggested.size() > 2 && suggested[1] == ':') return std::nullopt;
  std::string leaf(suggested);
  while (!leaf.empty() && (leaf.back() == '.' || leaf.back() == ' ')) {
    leaf.pop_back();
  }
  // Trim surrounding whitespace the same way the Dart/Rust policy does.
  const auto first = leaf.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return std::nullopt;
  const auto last = leaf.find_last_not_of(" \t\r\n");
  leaf = leaf.substr(first, last - first + 1);
  while (!leaf.empty() && (leaf.back() == '.' || leaf.back() == ' ')) {
    leaf.pop_back();
  }
  if (leaf.empty() || leaf == "." || leaf == "..") return std::nullopt;
  const auto dot = leaf.find('.');
  const std::string stem = dot == std::string::npos ? leaf : leaf.substr(0, dot);
  if (IsReservedDownloadStem(stem)) return std::nullopt;
  if (leaf.size() > 255) return std::nullopt;
  return leaf;
}

// Returns a leaf that does not silently overwrite an existing sibling.
// `existing_lower` holds lower-cased names already in the safe destination.
std::optional<std::string> ResolveNonOverwritingLeaf(
    std::string_view leaf, const std::set<std::string>& existing_lower) {
  std::string lower(leaf);
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (existing_lower.find(lower) == existing_lower.end()) {
    return std::string(leaf);
  }
  const auto dot = leaf.rfind('.');
  const std::string stem = (dot == std::string_view::npos || dot == 0)
                               ? std::string(leaf)
                               : std::string(leaf.substr(0, dot));
  const std::string extension = (dot == std::string_view::npos || dot == 0)
                                    ? std::string()
                                    : std::string(leaf.substr(dot));
  for (int counter = 1; counter <= 9999; ++counter) {
    const std::string candidate =
        stem + " (" + std::to_string(counter) + ")" + extension;
    if (candidate.size() > 255) return std::nullopt;
    std::string candidate_lower = candidate;
    std::transform(candidate_lower.begin(), candidate_lower.end(),
                   candidate_lower.begin(), [](unsigned char c) {
                     return static_cast<char>(std::tolower(c));
                   });
    if (existing_lower.find(candidate_lower) == existing_lower.end()) {
      return candidate;
    }
  }
  return std::nullopt;
}

// Atomically commits a fully-written temporary file to its final destination.
// The destination must already be a resolved non-overwriting leaf inside the
// safe account/user directory; when the destination exists the commit fails
// instead of overwriting.  Reparse points are rejected on both ends.
bool AtomicCommitDownload(const std::filesystem::path& temp_path,
                          const std::filesystem::path& destination) {
  std::error_code error;
  if (std::filesystem::exists(destination, error) || error) return false;
  const DWORD temp_attributes = GetFileAttributesW(temp_path.c_str());
  const DWORD dest_parent_attributes =
      GetFileAttributesW(destination.parent_path().c_str());
  if (temp_attributes == INVALID_FILE_ATTRIBUTES ||
      (temp_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
      (temp_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    return false;
  }
  if (dest_parent_attributes == INVALID_FILE_ATTRIBUTES ||
      (dest_parent_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return false;
  }
  return MoveFileExW(temp_path.c_str(), destination.c_str(),
                     MOVEFILE_WRITE_THROUGH) != FALSE;
}

// Clipboard read policy: gesture plus an explicit one-shot prompt.  The host
// hands the page a text snapshot, never a native clipboard handle.
bool AllowClipboardRead(bool user_gesture, bool prompt_accepted) {
  return user_gesture && prompt_accepted;
}

// Clipboard write policy: gesture plus an admitted origin.  No standing
// grant: every write is checked against the surface's declared origins.
bool AllowClipboardWrite(bool user_gesture, std::string_view origin,
                         const NavigationPolicy& policy) {
  if (!user_gesture || origin.empty()) return false;
  const auto origin_string = std::string(origin);
  return std::find(policy.allowed_origins.begin(), policy.allowed_origins.end(),
                   origin_string) != policy.allowed_origins.end() ||
         std::find(policy.allowed_loopback_origins.begin(),
                   policy.allowed_loopback_origins.end(),
                   origin_string) != policy.allowed_loopback_origins.end();
}

// Upload policy: only an explicit OS/portal chooser result may proceed.  The
// chooser selection is staged as read-only copies under host-owned temporary
// storage; the page receives staged handles, never real paths, and the grant
// expires with the request.
bool AllowStagedUpload(bool chooser_shown, bool user_confirmed) {
  return chooser_shown && user_confirmed;
}

// Media and capture permission mediation.  Access is deny-by-default and
// fails closed through the qualified OS media path: every page request for
// camera, microphone, or display capture arrives here, is checked against
// scoped grants and current policy, and otherwise waits for an explicit app
// decision.  The host never captures directly and never bypasses the OS.
struct MediaGrantKey {
  std::string profile_key;
  std::string requesting_origin;
  std::string top_level_origin;
  std::string capability;

  bool operator<(const MediaGrantKey& other) const {
    return std::tie(profile_key, requesting_origin, top_level_origin,
                    capability) <
           std::tie(other.profile_key, other.requesting_origin,
                    other.top_level_origin, other.capability);
  }
};

enum class MediaGrantKind { Session, Persistent };

struct PendingMediaRequest {
  std::string request_id;
  std::string requesting_origin;
  std::string top_level_origin;
  std::string capability;
  uint32_t requested_permissions = 0;
  CefRefPtr<CefMediaAccessCallback> callback;
};

std::string ClassifyMediaCapability(uint32_t requested_permissions) {
  constexpr uint32_t kKnown =
      CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE |
      CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE |
      CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE |
      CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE;
  if (requested_permissions == CEF_MEDIA_PERMISSION_NONE ||
      (requested_permissions & ~kKnown) != 0) {
    return "unknown_media";
  }
  const bool device_audio =
      (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) != 0;
  const bool device_video =
      (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) != 0;
  const bool desktop_audio =
      (requested_permissions & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) != 0;
  const bool desktop_video =
      (requested_permissions & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) != 0;
  if (desktop_audio || desktop_video) {
    // Mixed device and desktop bits are never mapped to a grantable scope.
    if (device_audio || device_video) return "unknown_media";
    if (desktop_video && desktop_audio) return "display_video+display_audio";
    if (desktop_video) return "display_video";
    return "display_audio";
  }
  if (device_video && device_audio) return "camera+microphone";
  if (device_video) return "camera";
  return "microphone";
}

bool IsDisplayCapability(std::string_view capability) {
  return capability == "display_video" || capability == "display_audio" ||
         capability == "display_video+display_audio";
}

bool CapabilitySupportsPersistentGrant(std::string_view capability) {
  return capability == "camera" || capability == "microphone" ||
         capability == "camera+microphone";
}

bool PolicyCapabilityAllowed(const NavigationPolicy& policy,
                             std::string_view capability) {
  const auto iterator = policy.capabilities.find(std::string(capability));
  return iterator == policy.capabilities.end() || iterator->second;
}

// Fixed sanitized denial text.  Failures never carry origins, paths, tokens,
// or page contents.
std::string_view SanitizedMediaDeniedMessage(std::string_view capability) {
  if (IsDisplayCapability(capability)) {
    return "display capture was denied; each request needs fresh consent";
  }
  if (capability == "unknown_media") {
    return "media access was denied by policy";
  }
  return "camera or microphone access was denied by policy";
}

// Standalone owned-window plumbing.  Each standalone surface owns one
// top-level roscord HWND; the windowed CEF browser is created as its child so
// geometry, focus, z-order, resize/DPI, input, IME, popup parenting, and
// close stay observable and never escape into an unowned native window.
// The window procedure only forwards close/destroy/size/dpi notifications to
// CEF; all policy decisions stay on the BrowserRuntime command stream.
constexpr wchar_t kStandaloneWindowClass[] = L"RoscordBrowserStandalone";
constexpr int kStandaloneDefaultWidth = 1024;
constexpr int kStandaloneDefaultHeight = 768;

LRESULT CALLBACK StandaloneWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) {
  switch (message) {
    case WM_CLOSE:
      // Owned-window close routes through the Runtime close path so the
      // surface emits event/closed and releases its request context.
      ::DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      return 0;
    default:
      break;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

bool RegisterStandaloneWindowClass() {
  static bool registered = false;
  if (registered) return true;
  WNDCLASSEXW clazz = {};
  clazz.cbSize = sizeof(clazz);
  clazz.style = CS_HREDRAW | CS_VREDRAW;
  clazz.lpfnWndProc = &StandaloneWindowProc;
  clazz.hInstance = ::GetModuleHandleW(nullptr);
  clazz.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
  clazz.lpszClassName = kStandaloneWindowClass;
  if (::RegisterClassExW(&clazz) == 0) {
    const DWORD error = ::GetLastError();
    return error == ERROR_CLASS_ALREADY_EXISTS;
  }
  registered = true;
  return true;
}

HWND CreateStandaloneWindow(int width, int height) {
  if (!RegisterStandaloneWindowClass()) return nullptr;
  if (width <= 0) width = kStandaloneDefaultWidth;
  if (height <= 0) height = kStandaloneDefaultHeight;
  if (width > 7680) width = 7680;
  if (height > 4320) height = 4320;
  HWND hwnd = ::CreateWindowExW(
      WS_EX_APPWINDOW, kStandaloneWindowClass, L"roscord Browser",
      WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
      width, height, nullptr, nullptr, ::GetModuleHandleW(nullptr), nullptr);
  if (hwnd == nullptr) return nullptr;
  ::ShowWindow(hwnd, SW_SHOW);
  ::UpdateWindow(hwnd);
  return hwnd;
}

void DestroyStandaloneWindow(HWND hwnd) {
  if (hwnd == nullptr) return;
  ::DestroyWindow(hwnd);
}

// One embedded surface's shared-memory frame ring: a named file mapping the
// app's browser_surface plugin maps read-only (browser_frame_ring.h).  Every
// OnPaint is copied in synchronously, converted to RGBA, and published by
// slot; each slot's seqlock lets the reader drop a frame this host has
// overwritten meanwhile, so CEF's buffer never has to be retained.  Only the
// CEF UI thread publishes.
class SharedFrameRing {
 public:
  SharedFrameRing() = default;
  SharedFrameRing(const SharedFrameRing&) = delete;
  SharedFrameRing& operator=(const SharedFrameRing&) = delete;
  ~SharedFrameRing() { Release(); }

  bool Publish(const std::string& frame_namespace, uint64_t surface_id,
               const void* bgra, int width, int height, uint32_t& slot,
               uint64_t& sequence) {
    if (width <= 0 || height <= 0 ||
        static_cast<uint32_t>(width) > browser_surface::kFrameRingMaxDimension ||
        static_cast<uint32_t>(height) > browser_surface::kFrameRingMaxDimension) {
      return false;
    }
    const uint64_t needed = browser_surface::FrameRingSlotBytesFor(
        static_cast<uint32_t>(width), static_cast<uint32_t>(height));
    if (view_ == nullptr || needed > slot_bytes_) {
      if (!Allocate(frame_namespace, surface_id, needed)) return false;
    }
    slot = next_slot_;
    next_slot_ = (next_slot_ + 1) % browser_surface::kFrameRingSlots;
    sequence = next_sequence_++;
    return browser_surface::FrameRingWriteBgra(
        view_, slot, sequence, bgra, static_cast<uint32_t>(width),
        static_cast<uint32_t>(height));
  }

  const std::string& name() const { return name_; }

  void Release() {
    if (view_ != nullptr) ::UnmapViewOfFile(view_);
    if (mapping_ != nullptr) ::CloseHandle(mapping_);
    view_ = nullptr;
    mapping_ = nullptr;
    slot_bytes_ = 0;
    name_.clear();
  }

 private:
  // A larger frame gets a new, larger mapping under a new name; the reader
  // follows the name in each frame_ready.
  bool Allocate(const std::string& frame_namespace, uint64_t surface_id,
                uint64_t slot_bytes) {
    Release();
    ++generation_;
    const std::string name = "Local\\roscord-cef-" + frame_namespace + "-" +
                             std::to_string(surface_id) + "-" +
                             std::to_string(generation_);
    const std::wstring wide_name(name.begin(), name.end());  // ASCII only
    const uint64_t bytes = browser_surface::FrameRingRegionBytes(slot_bytes);
    HANDLE mapping = ::CreateFileMappingW(
        INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
        static_cast<DWORD>(bytes >> 32),
        static_cast<DWORD>(bytes & 0xffffffffu), wide_name.c_str());
    if (mapping == nullptr) return false;
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      ::CloseHandle(mapping);
      return false;
    }
    void* view = ::MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0,
                                 static_cast<SIZE_T>(bytes));
    if (view == nullptr) {
      ::CloseHandle(mapping);
      return false;
    }
    browser_surface::FrameRingInitialize(view, slot_bytes);
    mapping_ = mapping;
    view_ = view;
    slot_bytes_ = slot_bytes;
    name_ = name;
    next_slot_ = 0;
    return true;
  }

  HANDLE mapping_ = nullptr;
  void* view_ = nullptr;
  uint64_t slot_bytes_ = 0;
  uint32_t generation_ = 0;
  uint32_t next_slot_ = 0;
  uint64_t next_sequence_ = 1;
  std::string name_;
};

struct SurfaceState {
  uint64_t id = 0;
  std::string profile_key;
  uint64_t context_id = 0;
  CefRefPtr<CefRequestContext> request_context;
  std::string presentation;
  std::string privacy;
  std::string initial_url;
  NavigationPolicy policy;
  int last_command_sequence = 0;
  uint64_t next_event_sequence = 2;
  CefRefPtr<CefBrowser> browser;
  bool close_requested = false;
  // Standalone owned-window state.  The HWND is a roscord-owned top-level
  // window created on the CEF UI thread; the windowed browser is its child.
  // Geometry (view_width/view_height), DPI (device_scale_factor), focus, and
  // z-order are driven by ordered resize/focus commands so embedded and
  // standalone surfaces share one host, one profile context, and one policy.
  HWND owned_window = nullptr;
  int window_x = CW_USEDEFAULT;
  int window_y = CW_USEDEFAULT;
  bool window_visible = false;
  bool window_focused = false;
  // Embedded OSR presentation state.  The view rectangle is owned here so
  // GetViewRect/GetScreenInfo stay consistent with the last validated resize
  // command; DPI is carried as a device scale factor and applied on resize.
  int view_width = 1024;
  int view_height = 768;
  double device_scale_factor = 1.0;
  // Shared-memory frame ring.  OnPaint copies CEF's buffer into the next
  // slot (the CEF pointer must never be retained) and publishes a
  // frame_ready event that references only ring/slot/size/stride/format/
  // sequence.  The newest frame coalesces older pending frames on the Dart
  // side; release_frame is accounting only and never exposes a CEF handle.
  std::shared_ptr<SharedFrameRing> frame_ring;
  // Pointer state: buttons held, and the last click for click counting.
  uint32_t pressed_buttons = 0;
  int last_click_button = -1;
  int last_click_count = 0;
  std::chrono::steady_clock::time_point last_click_time{};
  int last_click_x = 0;
  int last_click_y = 0;
  std::string last_cursor;
  struct PendingPopup {
    int popup_id = 0;
    std::string url;
    bool user_gesture = false;
  };
  std::map<std::string, PendingPopup> pending_popups;
  uint64_t next_popup_request = 1;
  struct PendingDownload {
    std::string url;
    std::string suggested_name;
  };
  std::map<std::string, PendingDownload> pending_downloads;
  uint64_t next_download_request = 1;
  struct PendingClipboard {
    bool write = false;
    bool user_gesture = false;
  };
  std::map<std::string, PendingClipboard> pending_clipboards;
  uint64_t next_clipboard_request = 1;
  struct PendingUpload {
    bool multiple = false;
    std::vector<std::string> accept;
  };
  std::map<std::string, PendingUpload> pending_uploads;
  uint64_t next_upload_request = 1;
  std::map<std::string, PendingMediaRequest> pending_media;
  uint64_t next_media_request = 1;
};

class BrowserClient final : public CefClient,
                            public CefLifeSpanHandler,
                            public CefRenderHandler,
                            public CefRequestHandler,
                            public CefDownloadHandler,
                            public CefDialogHandler,
                            public CefDisplayHandler,
                            public CefPermissionHandler {
 public:
  BrowserClient(HostController* controller, uint64_t surface_id)
      : controller_(controller), surface_id_(surface_id) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }

  // Embedded surfaces have no window: the page cursor goes to the app and
  // native tooltips are suppressed.  Standalone windows keep CEF's own.
  bool OnCursorChange(CefRefPtr<CefBrowser> browser, CefCursorHandle cursor,
                      cef_cursor_type_t type,
                      const CefCursorInfo& custom_cursor_info) override;
  bool OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) override;

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        CefRequestHandler::WindowOpenDisposition target_disposition,
                        bool user_gesture) override;
  bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                          cef_errorcode_t cert_error,
                          const CefString& request_url,
                          CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override;
  bool OnSelectClientCertificate(
      CefRefPtr<CefBrowser> browser,
      bool is_proxy,
      const CefString& host,
      int port,
      const X509CertificateList& certificates,
      CefRefPtr<CefSelectClientCertificateCallback> callback) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                 uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;
  bool OnRenderProcessUnresponsive(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefUnresponsiveProcessCallback> callback) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;
  // Mediated file access: downloads always pause for an explicit app
  // approval and commit atomically from temporary staging; file dialogs
  // never open inline and instead emit one upload_request per gesture.
  bool OnBeforeDownload(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> download_item,
      const CefString& suggested_name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;
  bool OnFileDialog(
      CefRefPtr<CefBrowser> browser,
      CefDialogHandler::FileDialogMode mode,
      const CefString& title,
      const CefString& default_file_path,
      const std::vector<CefString>& accept_filters,
      const std::vector<CefString>& accept_extensions,
      const std::vector<CefString>& accept_descriptions,
      CefRefPtr<CefFileDialogCallback> callback) override;

  // Defined after HostController, which they call into.
  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override;
  bool GetScreenInfo(CefRefPtr<CefBrowser> browser,
                     CefScreenInfo& screen_info) override;
  void OnPaint(CefRefPtr<CefBrowser> browser,
               PaintElementType type,
               const RectList& dirty_rects,
               const void* buffer,
               int width,
               int height) override;

  uint64_t surface_id() const { return surface_id_; }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

class HostController {
 public:
  HostController(const HostArgs& args, PipeChannel& pipe)
      : args_(args),
        pipe_(pipe),
        profiles_(args.profile_root),
        frame_namespace_(NewFrameNamespace()) {}
  HostController(const HostController&) = delete;
  HostController& operator=(const HostController&) = delete;

  void Run();
  void Shutdown();
  void CreateBrowserOnUi(uint64_t surface_id, std::string url,
                         std::string presentation);
  void NavigateBrowserOnUi(uint64_t surface_id, std::string url);
  void CloseBrowserOnUi(uint64_t surface_id);
  void OnBrowserCreated(uint64_t surface_id, CefRefPtr<CefBrowser> browser);
  void OnBrowserClosed(uint64_t surface_id);
  void OnBrowserRuntimeSend(uint64_t surface_id,
                            CefRefPtr<CefBrowser> browser,
                            std::string payload);
  bool OnNavigationRequested(uint64_t surface_id, std::string_view url,
                             std::string_view disposition, bool user_gesture,
                             bool is_redirect);
  bool OnPopupRequested(uint64_t surface_id, int popup_id,
                        std::string_view url, bool user_gesture);
  void OnCertificateError(uint64_t surface_id, std::string_view request_url,
                          int cert_error);
  void OnClientCertificateRequest(uint64_t surface_id);
  // File-access mediation: CEF callbacks pause here and resume only on an
  // explicit app decision.  `CancelPendingFileAccess` terminates every
  // outstanding download/clipboard/upload request for a surface on
  // navigation, close, host loss, timeout, denial, or unavailable UI.
  std::optional<std::string> OnDownloadRequested(
      uint64_t surface_id, std::string_view url,
      std::string_view suggested_name);
  std::optional<std::string> OnClipboardRequested(
      uint64_t surface_id, bool write, bool user_gesture);
  std::optional<std::string> OnUploadRequested(
      uint64_t surface_id, bool multiple,
      const std::vector<std::string>& accept);
  bool ResolveFileAccessCommand(uint64_t surface_id, int request_id,
                                std::string_view command_type,
                                CefRefPtr<CefDictionaryValue> command_payload);
  void CancelPendingFileAccess(uint64_t surface_id, std::string_view reason);
  void CancelAllPendingFileAccess(std::string_view reason);
  bool OnMediaAccessRequested(uint64_t surface_id,
                              CefRefPtr<CefBrowser> browser,
                              std::string_view requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefMediaAccessCallback> callback);
  void OnPermissionPrompt(uint64_t surface_id, uint64_t prompt_id,
                          std::string_view requesting_origin);
  void ResolveMediaDecision(uint64_t surface_id, int request_id,
                            const std::string& permission_request_id,
                            const std::string& decision);
  void ResolveMediaOnUi(uint64_t surface_id, std::string request_id,
                        bool allow, uint32_t allowed_permissions);
  void CancelPendingMediaOnUi(uint64_t surface_id);
  void ExecuteScriptOnUi(uint64_t surface_id, int request_id,
                         CefRefPtr<CefDictionaryValue> envelope);
  void OnRendererFailure(uint64_t surface_id, std::string_view code,
                         std::string_view message);
  // Called by BrowserClient's render handler and the resize, focus and
  // input tasks posted to the UI thread.
  void OnPaintFrame(uint64_t surface_id, const void* buffer, int width,
                    int height);
  bool GetViewSize(uint64_t surface_id, int& width, int& height,
                   double& device_scale_factor);
  void ApplyResizeOnUi(uint64_t surface_id, int width, int height,
                       double device_scale_factor);
  void ApplyFocusOnUi(uint64_t surface_id, bool focused);
  void ApplyInputOnUi(uint64_t surface_id,
                      CefRefPtr<CefDictionaryValue> input);
  // Embedded surfaces report the page cursor to the app; standalone windows
  // keep CEF's native cursor.  Returns true when the change was handled.
  bool OnCursorChanged(uint64_t surface_id, std::string_view cursor);
  bool IsEmbedded(uint64_t surface_id);
  bool ClearData(std::string_view profile_key, std::string& error) {
    std::lock_guard lock(state_mutex_);
    if (std::any_of(surfaces_.begin(), surfaces_.end(),
                    [&](const auto& entry) {
                      return entry.second.profile_key == profile_key;
                    })) {
      error = "profile is busy";
      return false;
    }
    // Account browser state includes media grants: persistent camera and
    // microphone grants do not survive clear-data.
    ClearMediaGrants(profile_key);
    return profiles_.ClearData(profile_key, error);
  }

 private:
  bool HandleFrame(std::string_view body);
  bool AuthenticateEnvelope(CefRefPtr<CefDictionaryValue> envelope,
                            CefRefPtr<CefDictionaryValue>& message,
                            std::string& error);
  bool HandleOpen(CefRefPtr<CefDictionaryValue> payload);
  bool HandleClose(CefRefPtr<CefDictionaryValue> payload);
  bool HandleCommand(CefRefPtr<CefDictionaryValue> payload);
  bool HandleHeartbeat(CefRefPtr<CefDictionaryValue> payload);
  void SendMessage(CefRefPtr<CefDictionaryValue> message);
  void SendError(std::optional<int> request_id, std::string_view code,
                 std::string_view message);
  void SendAck(int request_id);
  void SendHeartbeatAck(int request_id);
  void SendOpened(int request_id, uint64_t surface_id);
  void SendReady(const SurfaceState& surface, std::string_view url);
  void SendClosed(uint64_t surface_id, uint64_t sequence);
  void SendNavigation(uint64_t surface_id, std::string_view url,
                      std::string_view disposition,
                      std::string_view outcome);
  void SendSurfaceFailure(uint64_t surface_id, std::string_view kind,
                          std::string_view message);
  void SendPopupRequest(uint64_t surface_id, std::string_view request_id,
                        std::string_view url, bool user_gesture);
  void SendDownloadRequest(uint64_t surface_id, std::string_view request_id,
                           std::string_view url);
  void SendClipboardRequest(uint64_t surface_id, std::string_view request_id,
                            bool write, bool user_gesture);
  void SendUploadRequest(uint64_t surface_id, std::string_view request_id,
                         bool multiple,
                         const std::vector<std::string>& accept);
  void SendPermissionRequest(uint64_t surface_id, std::string_view request_id,
                             std::string_view origin,
                             std::string_view top_level_origin,
                             std::string_view capability);
  bool MediaGrantCovers(const SurfaceState& surface, const MediaGrantKey& key);
  void RememberMediaGrant(const MediaGrantKey& key,
                          const std::string& decision, bool is_private);
  void ClearMediaGrants(std::string_view profile_key);
  void SendScriptComplete(uint64_t surface_id,
                          CefRefPtr<CefDictionaryValue> envelope,
                          std::string_view operation);
  void SendScriptMessage(uint64_t surface_id,
                         CefRefPtr<CefDictionaryValue> envelope);
  void SendFrameReady(uint64_t surface_id, const std::string& buffer,
                      int slot, int width, int height, int stride,
                      uint64_t frame_sequence);
  void SendWindowChanged(uint64_t surface_id, bool resized, int width,
                         int height, double device_scale_factor, bool focused);
  void DestroyStandaloneWindowOnUi(uint64_t surface_id);
  void ApplyReleaseFrame(uint64_t surface_id, int frame_sequence);
  std::optional<SurfaceState> GetSurface(uint64_t surface_id);
  bool HasSurface(uint64_t surface_id);

  HostArgs args_;
  PipeChannel& pipe_;
  std::mutex state_mutex_;
  std::mutex pipe_mutex_;
  std::map<uint64_t, SurfaceState> surfaces_;
  // Scoped media grants: (account, requesting origin, top-level origin,
  // capability) -> session or persistent.  Stored grants are re-checked
  // against current policy on every use; display capture is never stored.
  std::map<MediaGrantKey, MediaGrantKind> media_grants_;
  ProfileManager profiles_;
  uint64_t next_surface_id_ = 1;
  std::atomic<bool> stopping_ = false;
  std::condition_variable closed_condition_;
  bool shutdown_timed_out_ = false;
  // Shared-memory ring names are Local\\roscord-cef-<namespace>-...; the
  // namespace is random so names reveal nothing about the pipe nonce.
  const std::string frame_namespace_;

  static std::string NewFrameNamespace() {
    std::random_device random;
    char hex[17] = {};
    for (int index = 0; index < 16; index += 8) {
      std::snprintf(hex + index, 9, "%08x", random());
    }
    return std::to_string(::GetCurrentProcessId()) + "-" + hex;
  }
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

class NavigateBrowserTask final : public CefTask {
 public:
  NavigateBrowserTask(HostController* controller, uint64_t surface_id,
                      std::string url)
      : controller_(controller), surface_id_(surface_id), url_(std::move(url)) {}

  void Execute() override;

 private:
  HostController* controller_;
  uint64_t surface_id_;
  std::string url_;
  IMPLEMENT_REFCOUNTING(NavigateBrowserTask);
};

void NavigateBrowserTask::Execute() {
  controller_->NavigateBrowserOnUi(surface_id_, std::move(url_));
}

class ResizeSurfaceTask final : public CefTask {
 public:
  ResizeSurfaceTask(HostController* controller, uint64_t surface_id, int width,
                    int height, double device_scale_factor)
      : controller_(controller),
        surface_id_(surface_id),
        width_(width),
        height_(height),
        device_scale_factor_(device_scale_factor) {}

  void Execute() override {
    controller_->ApplyResizeOnUi(surface_id_, width_, height_,
                                 device_scale_factor_);
  }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  int width_;
  int height_;
  double device_scale_factor_;
  IMPLEMENT_REFCOUNTING(ResizeSurfaceTask);
};

class FocusSurfaceTask final : public CefTask {
 public:
  FocusSurfaceTask(HostController* controller, uint64_t surface_id,
                   bool focused)
      : controller_(controller),
        surface_id_(surface_id),
        focused_(focused) {}

  void Execute() override { controller_->ApplyFocusOnUi(surface_id_, focused_); }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  bool focused_;
  IMPLEMENT_REFCOUNTING(FocusSurfaceTask);
};

class InputSurfaceTask final : public CefTask {
 public:
  InputSurfaceTask(HostController* controller, uint64_t surface_id,
                   CefRefPtr<CefDictionaryValue> input)
      : controller_(controller),
        surface_id_(surface_id),
        input_(std::move(input)) {}

  void Execute() override {
    controller_->ApplyInputOnUi(surface_id_, input_);
  }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  CefRefPtr<CefDictionaryValue> input_;
  IMPLEMENT_REFCOUNTING(InputSurfaceTask);
};

class ExecuteScriptTask final : public CefTask {
 public:
  ExecuteScriptTask(HostController* controller, uint64_t surface_id,
                    int request_id,
                    CefRefPtr<CefDictionaryValue> envelope)
      : controller_(controller),
        surface_id_(surface_id),
        request_id_(request_id),
        envelope_(std::move(envelope)) {}

  void Execute() override {
    controller_->ExecuteScriptOnUi(surface_id_, request_id_, envelope_);
  }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  int request_id_;
  CefRefPtr<CefDictionaryValue> envelope_;
  IMPLEMENT_REFCOUNTING(ExecuteScriptTask);
};

class ResolveMediaTask final : public CefTask {
 public:
  ResolveMediaTask(HostController* controller, uint64_t surface_id,
                   std::string request_id, bool allow,
                   uint32_t allowed_permissions)
      : controller_(controller),
        surface_id_(surface_id),
        request_id_(std::move(request_id)),
        allow_(allow),
        allowed_permissions_(allowed_permissions) {}

  void Execute() override {
    controller_->ResolveMediaOnUi(surface_id_, std::move(request_id_), allow_,
                                  allowed_permissions_);
  }

 private:
  HostController* controller_;
  uint64_t surface_id_;
  std::string request_id_;
  bool allow_;
  uint32_t allowed_permissions_;
  IMPLEMENT_REFCOUNTING(ResolveMediaTask);
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
  std::lock_guard lock(pipe_mutex_);
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

void HostController::SendAck(int request_id) {
  auto payload = NewDictionary();
  payload->SetInt("request_id", request_id);
  auto wire = NewDictionary();
  wire->SetString("type", "ack");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendHeartbeatAck(int request_id) {
  auto payload = NewDictionary();
  payload->SetInt("request_id", request_id);
  auto wire = NewDictionary();
  wire->SetString("type", "heartbeat_ack");
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

void HostController::SendFrameReady(uint64_t surface_id,
                                    const std::string& buffer, int slot,
                                    int width, int height, int stride,
                                    uint64_t frame_sequence) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    // Embedded presentation only: standalone HWND surfaces never emit frames
    // through Flutter.
    if (iterator->second.presentation != "embedded") return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto frame = NewDictionary();
  frame->SetInt("slot", slot);
  frame->SetInt("width", width);
  frame->SetInt("height", height);
  frame->SetInt("stride", stride);
  // The ring converts CEF's BGRA into the RGBA Flutter textures upload.
  frame->SetString("format", "rgba_premultiplied");
  frame->SetInt("sequence", static_cast<int>(frame_sequence));
  frame->SetString("buffer", buffer);

  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetDictionary("frame", frame);
  auto event = NewDictionary();
  event->SetString("type", "frame_ready");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendWindowChanged(uint64_t surface_id, bool resized,
                                        int width, int height,
                                        double device_scale_factor,
                                        bool focused) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    // Standalone owned-window observations only: embedded surfaces track
    // geometry through the OSR view rectangle and Flutter layout.
    if (iterator->second.presentation != "standalone") return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto change_value = NewDictionary();
  auto change = NewDictionary();
  if (resized) {
    change_value->SetInt("width", width);
    change_value->SetInt("height", height);
    change_value->SetDouble("device_scale_factor", device_scale_factor);
    change->SetString("kind", "resized");
  } else {
    change_value->SetBool("focused", focused);
    change->SetString("kind", "focused");
  }
  change->SetDictionary("value", change_value);
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetDictionary("change", change);
  auto event = NewDictionary();
  event->SetString("type", "window_changed");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::DestroyStandaloneWindowOnUi(uint64_t surface_id) {
  CEF_REQUIRE_UI_THREAD();
  HWND hwnd = nullptr;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    hwnd = iterator->second.owned_window;
    iterator->second.owned_window = nullptr;
    iterator->second.window_visible = false;
  }
  DestroyStandaloneWindow(hwnd);
}

void HostController::OnPaintFrame(uint64_t surface_id, const void* buffer,
                                  int width, int height) {
  CEF_REQUIRE_UI_THREAD();
  if (buffer == nullptr || width <= 0 || height <= 0) return;
  // Clamp absurd dimensions before touching shared memory.
  if (width > 7680 || height > 4320) return;
  std::shared_ptr<SharedFrameRing> ring;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    if (iterator->second.presentation != "embedded") return;
    if (!iterator->second.frame_ring) {
      iterator->second.frame_ring = std::make_shared<SharedFrameRing>();
    }
    ring = iterator->second.frame_ring;
  }
  // The copy is synchronous: CEF's buffer is only valid for this callback
  // and must never be retained.  The shared ring is the only pixel data the
  // Flutter texture presenter reads.
  uint32_t slot = 0;
  uint64_t frame_sequence = 0;
  if (!ring->Publish(frame_namespace_, surface_id, buffer, width, height,
                     slot, frame_sequence)) {
    return;
  }
  SendFrameReady(surface_id, ring->name(), static_cast<int>(slot), width,
                 height, width * 4, frame_sequence);
}

bool HostController::GetViewSize(uint64_t surface_id, int& width, int& height,
                                 double& device_scale_factor) {
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) return false;
  width = iterator->second.view_width;
  height = iterator->second.view_height;
  device_scale_factor = iterator->second.device_scale_factor;
  return true;
}

void HostController::ApplyResizeOnUi(uint64_t surface_id, int width,
                                     int height,
                                     double device_scale_factor) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefBrowser> browser;
  HWND hwnd = nullptr;
  bool is_standalone = false;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    iterator->second.view_width = width;
    iterator->second.view_height = height;
    iterator->second.device_scale_factor = device_scale_factor;
    browser = iterator->second.browser;
    hwnd = iterator->second.owned_window;
    is_standalone = iterator->second.presentation == "standalone";
  }
  if (browser != nullptr) {
    if (is_standalone && hwnd != nullptr) {
      // Owned-window geometry: move the roscord HWND and notify the windowed
      // browser so it repaints at the new size. DPI travels as the device
      // scale factor; WM_DPICHANGED handling keeps GetScreenInfo consistent.
      ::SetWindowPos(hwnd, nullptr, 0, 0, width, height,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
      browser->GetHost()->NotifyMoveOrResizeStarted();
      browser->GetHost()->NotifyScreenInfoChanged();
      SendWindowChanged(surface_id, true, width, height, device_scale_factor,
                        false);
    } else {
      browser->GetHost()->WasResized();
      browser->GetHost()->NotifyScreenInfoChanged();
    }
  }
}

void HostController::ApplyFocusOnUi(uint64_t surface_id, bool focused) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefBrowser> browser;
  HWND hwnd = nullptr;
  bool is_standalone = false;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    browser = iterator->second.browser;
    hwnd = iterator->second.owned_window;
    iterator->second.window_focused = focused;
    is_standalone = iterator->second.presentation == "standalone";
  }
  if (browser != nullptr) {
    if (is_standalone && hwnd != nullptr) {
      // Owned-window focus and z-order: focusing brings the HWND to the front
      // without stealing activation from unrelated apps; unfocusing keeps
      // z-order and only releases CEF focus.
      if (focused) {
        ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        ::BringWindowToTop(hwnd);
        ::SetForegroundWindow(hwnd);
        ::SetFocus(hwnd);
      }
      browser->GetHost()->SetFocus(focused);
      SendWindowChanged(surface_id, false, 0, 0, 1.0, focused);
    } else {
      browser->GetHost()->SetFocus(focused);
    }
  }
}

void HostController::ApplyReleaseFrame(uint64_t surface_id,
                                       int frame_sequence) {
  // Release is accounting-only: the client-owned ring slot becomes reusable
  // for the next OnPaint copy.  Unknown or stale sequences are ignored rather
  // than treated as protocol violations so coalesced frames stay lossless.
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) return;
  (void)frame_sequence;
}

void HostController::ApplyInputOnUi(
    uint64_t surface_id, CefRefPtr<CefDictionaryValue> input) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefBrowser> browser;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    browser = iterator->second.browser;
  }
  if (browser == nullptr || input == nullptr ||
      input->GetType("type") != VTYPE_STRING) {
    return;
  }
  const std::string input_type = input->GetString("type").ToString();
  const auto payload = input->GetDictionary("payload");
  if (payload == nullptr) return;
  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host == nullptr) return;
  if (input_type == "pointer") {
    const std::string kind = payload->GetType("kind") == VTYPE_STRING
                                 ? payload->GetString("kind").ToString()
                                 : "move";
    const auto number = [&payload](const char* name) {
      switch (payload->GetType(name)) {
        case VTYPE_DOUBLE:
          return payload->GetDouble(name);
        case VTYPE_INT:
          return static_cast<double>(payload->GetInt(name));
        default:
          return 0.0;
      }
    };
    const auto flags = [&payload](const char* name) {
      return payload->GetType(name) == VTYPE_INT
                 ? static_cast<uint32_t>(payload->GetInt(name))
                 : 0u;
    };
    const uint32_t buttons = flags("buttons");
    const uint32_t modifiers = flags("modifiers");
    CefMouseEvent event;
    event.x = static_cast<int>(std::lround(number("x")));
    event.y = static_cast<int>(std::lround(number("y")));
    // Resolve button state and click count under the lock, then call CEF
    // without it.
    int button = MBT_LEFT;
    int clicks = 1;
    {
      std::lock_guard lock(state_mutex_);
      const auto iterator = surfaces_.find(surface_id);
      if (iterator == surfaces_.end()) return;
      SurfaceState& surface = iterator->second;
      if (kind == "down") {
        uint32_t changed = buttons & ~surface.pressed_buttons;
        if (changed == 0) {
          changed =
              buttons != 0 ? buttons : browser_surface::kWireButtonPrimary;
        }
        changed &= ~(changed - 1);  // the lowest button that went down
        surface.pressed_buttons |= changed;
        button = browser_surface::CefMouseButtonFor(changed);
        const auto now = std::chrono::steady_clock::now();
        if (button == surface.last_click_button &&
            now - surface.last_click_time < std::chrono::milliseconds(500) &&
            std::abs(event.x - surface.last_click_x) <= 4 &&
            std::abs(event.y - surface.last_click_y) <= 4) {
          surface.last_click_count = std::min(surface.last_click_count + 1, 3);
        } else {
          surface.last_click_count = 1;
        }
        surface.last_click_button = button;
        surface.last_click_time = now;
        surface.last_click_x = event.x;
        surface.last_click_y = event.y;
        clicks = surface.last_click_count;
      } else if (kind == "up") {
        uint32_t released = buttons;
        if (released == 0) {
          released = surface.pressed_buttons != 0
                         ? surface.pressed_buttons
                         : browser_surface::kWireButtonPrimary;
        }
        released &= ~(released - 1);
        surface.pressed_buttons &= ~released;
        button = browser_surface::CefMouseButtonFor(released);
        clicks = surface.last_click_count > 0 ? surface.last_click_count : 1;
      } else if (kind == "move" || kind == "enter") {
        // A move carries the buttons held right now.
        surface.pressed_buttons = buttons;
      }
      event.modifiers =
          browser_surface::CefFlagsFor(modifiers, surface.pressed_buttons);
    }
    if (kind == "down" || kind == "up") {
      host->SendMouseClickEvent(event,
                                static_cast<cef_mouse_button_type_t>(button),
                                kind == "up", clicks);
    } else if (kind == "wheel") {
      // Flutter scroll deltas grow downwards; CEF wheel deltas grow upwards.
      host->SendMouseWheelEvent(
          event, static_cast<int>(std::lround(-number("delta_x"))),
          static_cast<int>(std::lround(-number("delta_y"))));
    } else {
      // move and enter are mouse moves; leave tells CEF the pointer left.
      host->SendMouseMoveEvent(event, kind == "leave");
    }
  } else if (input_type == "keyboard") {
    const auto text = [&payload](const char* name) {
      return payload->GetType(name) == VTYPE_STRING
                 ? payload->GetString(name).ToString()
                 : std::string();
    };
    const std::string key = text("key");
    const std::string code = text("code");
    const bool pressed = payload->GetType("pressed") == VTYPE_BOOL
                             ? payload->GetBool("pressed")
                             : true;
    const uint32_t modifiers =
        payload->GetType("modifiers") == VTYPE_INT
            ? static_cast<uint32_t>(payload->GetInt("modifiers"))
            : 0u;
    browser_surface::KeyCodes codes{};
    const bool known = browser_surface::KeyCodesForCode(code, &codes);
    CefKeyEvent event;
    event.windows_key_code =
        known ? codes.windows_key_code
              : browser_surface::WindowsKeyCodeForKey(key);
    // native_key_code is the WM_KEYDOWN/WM_KEYUP lParam: repeat count, scan
    // code, extended-key flag and, for a release, the previous-state and
    // transition bits.
    const int scan = known ? codes.windows_scan : 0;
    uint32_t lparam = 1u | (static_cast<uint32_t>(scan & 0xff) << 16);
    if ((scan & 0xff00) == 0xe000) lparam |= 1u << 24;
    if (!pressed) lparam |= (1u << 30) | (1u << 31);
    event.native_key_code = static_cast<int>(lparam);
    event.modifiers = browser_surface::CefFlagsFor(modifiers, 0) |
                      (known ? codes.location_flags : 0u);
    event.is_system_key =
        (modifiers & browser_surface::kWireModifierAlt) != 0 &&
        (modifiers & browser_surface::kWireModifierControl) == 0;
    // What the press typed, as the app's keyboard layout produced it: AltGr
    // arrives as Ctrl+Alt and still types, Ctrl shortcuts type nothing.
    const std::u16string typed =
        pressed ? browser_surface::TypedUnits(text("text")) : u"";
    event.character = typed.empty() ? 0 : typed.front();
    event.unmodified_character = event.character;
    if (pressed) {
      event.type = KEYEVENT_RAWKEYDOWN;
      host->SendKeyEvent(event);
      // Text typed with Ctrl+Alt held came from AltGr (the text proves the
      // layout produced it).  Chromium only inserts it flagged that way, so
      // its characters carry AltGr instead of Ctrl+Alt, as in cefclient.
      if ((modifiers & browser_surface::kWireModifierControl) != 0 &&
          (modifiers & browser_surface::kWireModifierAlt) != 0) {
        event.modifiers &= ~static_cast<uint32_t>(EVENTFLAG_CONTROL_DOWN |
                                                  EVENTFLAG_ALT_DOWN);
        event.modifiers |= EVENTFLAG_ALTGR_DOWN;
      }
      for (const char16_t unit : typed) {
        // WM_CHAR carries the character itself as the key code.
        event.type = KEYEVENT_CHAR;
        event.windows_key_code = unit;
        event.character = unit;
        event.unmodified_character = unit;
        host->SendKeyEvent(event);
      }
    } else {
      event.type = KEYEVENT_KEYUP;
      host->SendKeyEvent(event);
    }
  } else if (input_type == "ime") {
    const std::string phase =
        payload->GetType("phase") == VTYPE_STRING
            ? payload->GetString("phase").ToString()
            : "commit";
    const std::string text =
        payload->GetType("text") == VTYPE_STRING
            ? payload->GetString("text").ToString()
            : std::string();
    if (phase == "cancel") {
      host->ImeCancelComposition();
    } else if (phase == "start" || phase == "update") {
      CefString cef_text(text);
      std::vector<CefCompositionUnderline> underlines;
      CefRange selection_range(0, static_cast<int>(text.size()));
      host->ImeSetComposition(cef_text, underlines, CefRange(0, 0),
                              selection_range);
    } else {
      // commit (and unknown phases fail closed to commit): deliver text and
      // finish composition so focus transitions stay ordered.
      host->ImeCommitText(CefString(text), CefRange::InvalidRange(), 0);
      host->ImeFinishComposingText(false);
    }
  }
}

bool HostController::IsEmbedded(uint64_t surface_id) {
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  return iterator != surfaces_.end() &&
         iterator->second.presentation == "embedded";
}

bool HostController::OnCursorChanged(uint64_t surface_id,
                                     std::string_view cursor) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return false;
    if (iterator->second.presentation != "embedded") return false;
    if (iterator->second.last_cursor == cursor) return true;
    iterator->second.last_cursor = std::string(cursor);
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("cursor", std::string(cursor));
  auto event = NewDictionary();
  event->SetString("type", "cursor_changed");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
  return true;
}

void HostController::SendNavigation(uint64_t surface_id, std::string_view url,
                                     std::string_view disposition,
                                     std::string_view outcome) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto navigation = NewDictionary();
  navigation->SetString("url", std::string(url));
  navigation->SetString("disposition", std::string(disposition));
  navigation->SetString("outcome", std::string(outcome));

  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetDictionary("navigation", navigation);
  auto event = NewDictionary();
  event->SetString("type", "navigation");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendSurfaceFailure(uint64_t surface_id,
                                         std::string_view kind,
                                         std::string_view message) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto failure = NewDictionary();
  failure->SetString("kind", std::string(kind));
  failure->SetString("message", std::string(message));
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetDictionary("failure", failure);
  auto event = NewDictionary();
  event->SetString("type", "failed");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendPopupRequest(uint64_t surface_id,
                                      std::string_view request_id,
                                      std::string_view url,
                                      bool user_gesture) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("request_id", std::string(request_id));
  event_payload->SetString("url", std::string(url));
  event_payload->SetBool("user_gesture", user_gesture);
  auto event = NewDictionary();
  event->SetString("type", "popup_request");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendDownloadRequest(uint64_t surface_id,
                                            std::string_view request_id,
                                            std::string_view url) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("request_id", std::string(request_id));
  event_payload->SetString("url", std::string(url));
  auto event = NewDictionary();
  event->SetString("type", "download_request");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendPermissionRequest(uint64_t surface_id,
                                              std::string_view request_id,
                                              std::string_view origin,
                                              std::string_view top_level_origin,
                                              std::string_view capability) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("request_id", std::string(request_id));
  event_payload->SetString("origin", std::string(origin));
  event_payload->SetString("top_level_origin", std::string(top_level_origin));
  event_payload->SetString("capability", std::string(capability));
  event_payload->SetBool("user_gesture", false);
  auto event = NewDictionary();
  event->SetString("type", "permission_request");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendClipboardRequest(uint64_t surface_id,
                                            std::string_view request_id,
                                            bool write, bool user_gesture) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("request_id", std::string(request_id));
  event_payload->SetBool("write", write);
  event_payload->SetBool("user_gesture", user_gesture);
  auto event = NewDictionary();
  event->SetString("type", "clipboard_request");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendUploadRequest(uint64_t surface_id,
                                         std::string_view request_id,
                                         bool multiple,
                                         const std::vector<std::string>& accept) {
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto accept_list = CefListValue::Create();
  for (size_t index = 0; index < accept.size(); ++index) {
    accept_list->SetString(index, accept[index]);
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetString("request_id", std::string(request_id));
  event_payload->SetBool("multiple", multiple);
  event_payload->SetList("accept", accept_list);
  auto event = NewDictionary();
  event->SetString("type", "upload_request");
  event->SetDictionary("payload", event_payload);
  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

std::optional<std::string> HostController::OnDownloadRequested(
    uint64_t surface_id, std::string_view url,
    std::string_view suggested_name) {
  std::string request_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return std::nullopt;
    // Downloads require approval: register the pending request and pause the
    // CEF download.  The sanitized suggested name is advisory only; the final
    // destination is resolved inside the safe account/user directory at
    // decision time, written to temporary staging, and committed atomically
    // with AtomicCommitDownload (no traversal, reparse paths, or silent
    // overwrite).
    const auto sanitized = SanitizeDownloadName(suggested_name);
    if (!sanitized.has_value()) {
      SendSurfaceFailure(surface_id, "policy_violation",
                         "download filename was rejected by policy");
      return std::nullopt;
    }
    request_id = "download-" + std::to_string(surface_id) + "-" +
                 std::to_string(iterator->second.next_download_request++);
    iterator->second.pending_downloads.emplace(
        request_id,
        SurfaceState::PendingDownload{std::string(url), *sanitized});
  }
  SendDownloadRequest(surface_id, request_id, url);
  return request_id;
}

std::optional<std::string> HostController::OnClipboardRequested(
    uint64_t surface_id, bool write, bool user_gesture) {
  std::string request_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return std::nullopt;
    // Clipboard reads require a gesture and a one-shot prompt; writes require
    // a gesture and an admitted origin.  The page receives only a mediated
    // text snapshot: no native clipboard handle ever crosses this boundary.
    // A request without a gesture is denied without emitting a prompt.
    if (!user_gesture) {
      SendSurfaceFailure(surface_id, "policy_violation",
                         write ? "clipboard write without a gesture was denied"
                               : "clipboard read without a gesture was denied");
      return std::nullopt;
    }
    request_id = "clipboard-" + std::to_string(surface_id) + "-" +
                 std::to_string(iterator->second.next_clipboard_request++);
    iterator->second.pending_clipboards.emplace(
        request_id,
        SurfaceState::PendingClipboard{write, user_gesture});
  }
  SendClipboardRequest(surface_id, request_id, write, user_gesture);
  return request_id;
}

std::optional<std::string> HostController::OnUploadRequested(
    uint64_t surface_id, bool multiple,
    const std::vector<std::string>& accept) {
  std::string request_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return std::nullopt;
    // Uploads use exactly one OS file chooser (FILE_DIALOG_OPEN) per request.
    // The host stages the explicit selection as read-only copies; the page
    // never enumerates the filesystem and never keeps a persistent path grant.
    request_id = "upload-" + std::to_string(surface_id) + "-" +
                 std::to_string(iterator->second.next_upload_request++);
    iterator->second.pending_uploads.emplace(
        request_id, SurfaceState::PendingUpload{multiple, accept});
  }
  SendUploadRequest(surface_id, request_id, multiple, accept);
  return request_id;
}

void HostController::CancelPendingFileAccess(uint64_t surface_id,
                                             std::string_view reason) {
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) return;
  // Terminal cancellation: navigation, close, host loss, timeout, denial, or
  // unavailable UI all drop the pending requests so no late approval can
  // stage bytes, touch the clipboard, or open a chooser afterwards.
  (void)reason;
  iterator->second.pending_downloads.clear();
  iterator->second.pending_clipboards.clear();
  iterator->second.pending_uploads.clear();
}

void HostController::CancelAllPendingFileAccess(std::string_view reason) {
  std::lock_guard lock(state_mutex_);
  (void)reason;
  for (auto& entry : surfaces_) {
    entry.second.pending_downloads.clear();
    entry.second.pending_clipboards.clear();
    entry.second.pending_uploads.clear();
  }
}

bool HostController::ResolveFileAccessCommand(
    uint64_t surface_id, int request_id,
    std::string_view command_type,
    CefRefPtr<CefDictionaryValue> command_payload) {
  if (command_type != "download" && command_type != "clipboard" &&
      command_type != "upload") {
    return false;
  }
  if (command_payload == nullptr ||
      command_payload->GetType("request_id") != VTYPE_STRING ||
      command_payload->GetType("decision") != VTYPE_DICTIONARY) {
    SendError(request_id, "invalid_command",
              "file-access command is malformed");
    return true;
  }
  const std::string file_request_id =
      command_payload->GetString("request_id").ToString();
  const auto decision = command_payload->GetDictionary("decision");
  if (decision == nullptr || decision->GetType("kind") != VTYPE_STRING) {
    SendError(request_id, "invalid_command",
              "file-access decision is malformed");
    return true;
  }
  const std::string kind = decision->GetString("kind").ToString();
  if (kind != "deny" && kind != "cancel" && kind != "allow" &&
      kind != "accept") {
    SendError(request_id, "invalid_command",
              "file-access decision kind is unknown");
    return true;
  }
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) {
    SendError(request_id, "stale_surface", "surface id is not active");
    return true;
  }
  // Denial and cancellation are terminal: drop the pending request so the
  // CEF callback can never resume it afterwards.
  if (kind == "deny" || kind == "cancel") {
    iterator->second.pending_downloads.erase(file_request_id);
    iterator->second.pending_clipboards.erase(file_request_id);
    iterator->second.pending_uploads.erase(file_request_id);
    return true;
  }
  if (command_type == "download") {
    const auto pending =
        iterator->second.pending_downloads.find(file_request_id);
    if (pending == iterator->second.pending_downloads.end()) {
      SendError(request_id, "stale_surface",
                "download request is no longer pending");
      return true;
    }
    // Approval resolves the destination inside the safe account/user
    // downloads directory, stages bytes to a temporary file first, and
    // commits with AtomicCommitDownload under a non-overwriting leaf.
    if (decision->GetType("value") != VTYPE_DICTIONARY) {
      SendError(request_id, "invalid_command",
                "download approval needs a destination");
      return true;
    }
  } else if (command_type == "clipboard") {
    const auto pending =
        iterator->second.pending_clipboards.find(file_request_id);
    if (pending == iterator->second.pending_clipboards.end()) {
      SendError(request_id, "stale_surface",
                "clipboard request is no longer pending");
      return true;
    }
    // One-shot: consume the pending prompt.  Reads additionally require the
    // prompt acceptance checked by the app; the host only releases the text
    // snapshot for this request id.
    iterator->second.pending_clipboards.erase(pending);
    return true;
  } else {
    const auto pending =
        iterator->second.pending_uploads.find(file_request_id);
    if (pending == iterator->second.pending_uploads.end()) {
      SendError(request_id, "stale_surface",
                "upload request is no longer pending");
      return true;
    }
    // Accept shows exactly one OS chooser (FILE_DIALOG_OPEN).  The selection
    // is copied to host-owned read-only staging (StagedUpload) and the real
    // paths are never sent to the page; the staged copies are deleted after
    // the handoff so no persistent grant remains.
  }
  return true;
}

bool HostController::MediaGrantCovers(const SurfaceState& surface,
                                      const MediaGrantKey& key) {
  // Display capture always needs fresh source consent; stored grants never
  // satisfy it.  Unknown capabilities are never grantable.
  if (IsDisplayCapability(key.capability) ||
      !CapabilitySupportsPersistentGrant(key.capability)) {
    return false;
  }
  const auto grant = media_grants_.find(key);
  if (grant == media_grants_.end()) return false;
  if (grant->second == MediaGrantKind::Persistent &&
      surface.privacy == "private") {
    return false;
  }
  // Every use re-checks current policy: both origins must still be declared
  // and the capability must still be enabled.  The OS-level check is the
  // qualified Windows media path itself, which mediates synchronously when
  // the host continues the request; a grant never bypasses it.
  if (!PolicyCapabilityAllowed(surface.policy, key.capability)) return false;
  return PolicyAllowsInProcess(surface.policy, key.requesting_origin) &&
         PolicyAllowsInProcess(surface.policy, key.top_level_origin);
}

void HostController::RememberMediaGrant(const MediaGrantKey& key,
                                        const std::string& decision,
                                        bool is_private) {
  if (decision == "deny") {
    media_grants_.erase(key);
    return;
  }
  if (decision == "allow_once") return;
  if (decision == "allow_session") {
    media_grants_[key] = MediaGrantKind::Session;
    return;
  }
  if (decision == "allow_always") {
    if (!CapabilitySupportsPersistentGrant(key.capability)) {
      // Display capture (and anything unclassifiable) always needs fresh
      // consent: the pending request may proceed once, but nothing is
      // stored for the next request.
      return;
    }
    media_grants_[key] =
        is_private ? MediaGrantKind::Session : MediaGrantKind::Persistent;
  }
}

void HostController::ClearMediaGrants(std::string_view profile_key) {
  for (auto iterator = media_grants_.begin();
       iterator != media_grants_.end();) {
    if (iterator->first.profile_key == profile_key) {
      iterator = media_grants_.erase(iterator);
    } else {
      ++iterator;
    }
  }
}

bool HostController::OnMediaAccessRequested(
    uint64_t surface_id, CefRefPtr<CefBrowser> browser,
    std::string_view requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (callback == nullptr) return true;
  const std::string capability = ClassifyMediaCapability(requested_permissions);
  std::string top_level_origin;
  if (browser != nullptr && browser->GetMainFrame() != nullptr) {
    const auto top_origin =
        UrlOrigin(browser->GetMainFrame()->GetURL().ToString());
    if (top_origin.has_value()) top_level_origin = *top_origin;
  }
  std::string profile_key;
  NavigationPolicy policy;
  bool has_surface = false;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator != surfaces_.end()) {
      profile_key = iterator->second.profile_key;
      policy = iterator->second.policy;
      has_surface = true;
    }
  }
  if (!has_surface || top_level_origin.empty() ||
      !PolicyCapabilityAllowed(policy, capability) ||
      !PolicyAllowsInProcess(policy, requesting_origin) ||
      !PolicyAllowsInProcess(policy, top_level_origin)) {
    // Deny-by-default: unknown surfaces, undeclared origins, disabled
    // capabilities, and unclassifiable requests never reach the app.
    callback->Cancel();
    if (has_surface) {
      SendSurfaceFailure(surface_id, "permission_denied",
                         SanitizedMediaDeniedMessage(capability));
    }
    return true;
  }
  const MediaGrantKey key{profile_key, std::string(requesting_origin),
                          top_level_origin, capability};
  std::string request_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) {
      callback->Cancel();
      return true;
    }
    if (MediaGrantCovers(iterator->second, key)) {
      // A stored grant covers this exact scope under current policy: the
      // qualified OS media path still mediates the actual capture when the
      // host continues the request.
      callback->Continue(requested_permissions);
      return true;
    }
    request_id = "media-" + std::to_string(surface_id) + "-" +
                 std::to_string(iterator->second.next_media_request++);
    iterator->second.pending_media.emplace(
        request_id,
        PendingMediaRequest{request_id, std::string(requesting_origin),
                            top_level_origin, capability, requested_permissions,
                            callback});
  }
  SendPermissionRequest(surface_id, request_id, requesting_origin,
                        top_level_origin, capability);
  return true;
}

void HostController::OnPermissionPrompt(uint64_t surface_id,
                                        uint64_t prompt_id,
                                        std::string_view requesting_origin) {
  (void)prompt_id;
  (void)requesting_origin;
  // Generic permission prompts (geolocation, notifications, and similar)
  // are always denied: there is no grant store for them and no bypass.
  SendSurfaceFailure(surface_id, "permission_denied",
                     "permission prompt was denied by policy");
}

void HostController::ResolveMediaDecision(
    uint64_t surface_id, int request_id,
    const std::string& permission_request_id, const std::string& decision) {
  // The pending entry stays alive until the UI task consumes it, so a close
  // racing the decision still cancels exactly once via
  // CancelPendingMediaOnUi.
  bool found_surface = false;
  bool found_pending = false;
  bool allow = false;
  uint32_t requested_permissions = 0;
  std::string failure_kind;
  std::string failure_message;
  {
    std::lock_guard lock(state_mutex_);
    const auto surface = surfaces_.find(surface_id);
    if (surface == surfaces_.end()) {
      found_surface = false;
    } else {
      found_surface = true;
      const auto pending =
          surface->second.pending_media.find(permission_request_id);
      if (pending == surface->second.pending_media.end()) {
        found_pending = false;
      } else {
        found_pending = true;
        const MediaGrantKey key{surface->second.profile_key,
                                pending->second.requesting_origin,
                                pending->second.top_level_origin,
                                pending->second.capability};
        requested_permissions = pending->second.requested_permissions;
        const bool is_private = surface->second.privacy == "private";
        // Every decision re-checks current policy before anything is stored
        // or continued: origins may have left the policy while the prompt
        // was open.
        const bool policy_current =
            PolicyCapabilityAllowed(surface->second.policy,
                                    pending->second.capability) &&
            PolicyAllowsInProcess(surface->second.policy,
                                  pending->second.requesting_origin) &&
            PolicyAllowsInProcess(surface->second.policy,
                                  pending->second.top_level_origin);
        const std::string capability = pending->second.capability;
        if (decision == "deny") {
          RememberMediaGrant(key, "deny", is_private);
          failure_kind = "permission_denied";
          failure_message = std::string(SanitizedMediaDeniedMessage(capability));
        } else if (!policy_current || capability == "unknown_media") {
          // Policy drift denies without revoking the stored scope: the
          // grant simply does not apply until the policy declares the
          // origins again.  Unknown capabilities are never grantable.
          failure_kind = "permission_denied";
          failure_message = std::string(SanitizedMediaDeniedMessage(capability));
        } else {
          if (IsDisplayCapability(capability)) {
            // Display allow_always degrades to once: proceed once, store
            // nothing for the next request.
            RememberMediaGrant(
                key, decision == "allow_always" ? "allow_once" : decision,
                is_private);
          } else {
            RememberMediaGrant(key, decision, is_private);
          }
          allow = true;
        }
      }
    }
  }
  if (!found_surface) {
    SendError(request_id, "stale_surface", "surface id is not active");
    return;
  }
  if (!found_pending) {
    SendError(request_id, "unknown_permission_request",
              "permission request is not pending");
    return;
  }
  if (!failure_kind.empty()) {
    SendSurfaceFailure(surface_id, failure_kind, failure_message);
  }
  CefTaskRunner::GetForThread(TID_UI)->PostTask(new ResolveMediaTask(
      this, surface_id, permission_request_id, allow, requested_permissions));
}

void HostController::ResolveMediaOnUi(uint64_t surface_id,
                                       std::string request_id, bool allow,
                                       uint32_t allowed_permissions) {
  CEF_REQUIRE_UI_THREAD();
  CefRefPtr<CefMediaAccessCallback> callback;
  {
    std::lock_guard lock(state_mutex_);
    const auto surface = surfaces_.find(surface_id);
    if (surface == surfaces_.end()) {
      // The surface closed first; CancelPendingMediaOnUi already canceled
      // every pending callback.  Fail closed: do nothing.
      return;
    }
    const auto pending = surface->second.pending_media.find(request_id);
    if (pending == surface->second.pending_media.end()) {
      // Already canceled on close.  Fail closed: do nothing.
      return;
    }
    callback = pending->second.callback;
    surface->second.pending_media.erase(pending);
  }
  if (callback == nullptr) return;
  if (allow) {
    callback->Continue(allowed_permissions);
  } else {
    callback->Cancel();
  }
}

void HostController::CancelPendingMediaOnUi(uint64_t surface_id) {
  CEF_REQUIRE_UI_THREAD();
  std::lock_guard lock(state_mutex_);
  const auto iterator = surfaces_.find(surface_id);
  if (iterator == surfaces_.end()) return;
  for (auto& [request_id, pending] : iterator->second.pending_media) {
    (void)request_id;
    if (pending.callback != nullptr) pending.callback->Cancel();
  }
  iterator->second.pending_media.clear();
}

void HostController::SendScriptMessage(
    uint64_t surface_id, CefRefPtr<CefDictionaryValue> envelope) {
  if (envelope == nullptr || !HasSurface(surface_id)) return;
  uint64_t sequence = 0;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return;
    sequence = iterator->second.next_event_sequence++;
  }
  auto event_payload = NewDictionary();
  event_payload->SetInt("surface_id", static_cast<int>(surface_id));
  event_payload->SetInt("sequence", static_cast<int>(sequence));
  event_payload->SetDictionary("envelope", envelope);

  auto event = NewDictionary();
  event->SetString("type", "script_message");
  event->SetDictionary("payload", event_payload);

  auto payload = NewDictionary();
  payload->SetDictionary("event", event);
  auto wire = NewDictionary();
  wire->SetString("type", "event");
  wire->SetDictionary("payload", payload);
  SendMessage(wire);
}

void HostController::SendScriptComplete(
    uint64_t surface_id, CefRefPtr<CefDictionaryValue> envelope,
    std::string_view operation) {
  if (envelope == nullptr) return;
  auto value = NewDictionary();
  value->SetString("operation", std::string(operation));
  value->SetString("status", "executed");

  auto completion = NewDictionary();
  completion->SetString("source", "host");
  completion->SetString("origin", envelope->GetString("origin"));
  completion->SetString("channel", envelope->GetString("channel"));
  completion->SetString(
      "request_id", envelope->GetString("request_id").ToString() +
                         ":complete");
  completion->SetDictionary("value", value);
  SendScriptMessage(surface_id, completion);
}

void HostController::OnBrowserRuntimeSend(uint64_t surface_id,
                                           CefRefPtr<CefBrowser> browser,
                                           std::string payload) {
  CEF_REQUIRE_UI_THREAD();
  if (browser == nullptr || !HasSurface(surface_id)) return;
  auto decoded = CefParseJSON(payload, JSON_PARSER_RFC);
  const auto value = Dictionary(decoded);
  if (value == nullptr || value->GetType("origin") != VTYPE_STRING ||
      value->GetType("channel") != VTYPE_STRING ||
      value->GetType("storage_key") != VTYPE_STRING ||
      value->GetType("payload") != VTYPE_STRING) {
    SendError(std::nullopt, "invalid_command",
              "BrowserRuntime page message is malformed");
    return;
  }
  auto envelope = NewDictionary();
  envelope->SetString("source", "page");
  envelope->SetString("origin", value->GetString("origin"));
  envelope->SetString("channel", value->GetString("channel"));
  if (value->GetType("request_id") == VTYPE_STRING) {
    envelope->SetString("request_id", value->GetString("request_id"));
  } else {
    envelope->SetString("request_id", "browser-runtime-page-message");
  }
  envelope->SetValue("value", decoded);
  SendScriptMessage(surface_id, envelope);
}

bool HostController::OnNavigationRequested(uint64_t surface_id,
                                            std::string_view url,
                                            std::string_view disposition,
                                            bool user_gesture,
                                            bool is_redirect) {
  const auto surface = GetSurface(surface_id);
  if (!surface) return true;
  if (is_redirect && !PolicyAllowsInProcess(surface->policy, url)) {
    SendNavigation(surface_id, url, disposition, "cancelled");
    return true;
  }
  const auto decision = EvaluateNavigation(surface->policy, url, disposition,
                                            user_gesture);
  switch (decision) {
    case NavigationDecision::InProcess:
      SendNavigation(surface_id, url, disposition, "allowed");
      return false;
    case NavigationDecision::External:
      // The app owns the external action.  Returning true prevents CEF from
      // silently opening an unowned browser or native window.
      SendNavigation(surface_id, url, "external", "external");
      return true;
    case NavigationDecision::Cancel:
      SendNavigation(surface_id, url, disposition, "cancelled");
      return true;
  }
  return true;
}

bool HostController::OnPopupRequested(uint64_t surface_id, int popup_id,
                                      std::string_view url,
                                      bool user_gesture) {
  std::string request_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) return true;
    request_id = "popup-" + std::to_string(surface_id) + "-" +
                 std::to_string(iterator->second.next_popup_request++);
    iterator->second.pending_popups.emplace(
        request_id, SurfaceState::PendingPopup{popup_id, std::string(url),
                                               user_gesture});
  }
  // Popups are always canceled synchronously.  The app can explicitly choose
  // an owned child surface or the external action through a later
  // PopupCommand; no unowned native popup is ever created behind the policy
  // boundary.  Standalone popups inherit the opener account context and close
  // with the opener, same as embedded.
  SendPopupRequest(surface_id, request_id, url, user_gesture);
  return true;
}

void HostController::OnCertificateError(uint64_t surface_id,
                                        std::string_view request_url,
                                        int cert_error) {
  (void)cert_error;
  SendNavigation(surface_id, request_url, "current", "cancelled");
  SendSurfaceFailure(surface_id, "certificate_denied",
                     "certificate validation failed; navigation was denied");
}

void HostController::OnClientCertificateRequest(uint64_t surface_id) {
  SendSurfaceFailure(surface_id, "client_certificate_denied",
                     "client-certificate selection is disabled by policy");
}

void HostController::ExecuteScriptOnUi(
    uint64_t surface_id, int request_id,
    CefRefPtr<CefDictionaryValue> envelope) {
  CEF_REQUIRE_UI_THREAD();
  const auto surface = GetSurface(surface_id);
  if (!surface || surface->browser == nullptr || envelope == nullptr) {
    SendError(request_id, "runtime_failed", "surface browser is not ready");
    return;
  }
  const auto value = envelope->GetDictionary("value");
  if (value == nullptr || value->GetType("operation") != VTYPE_STRING) {
    SendError(request_id, "invalid_command", "script operation is missing");
    return;
  }
  const std::string operation = value->GetString("operation").ToString();
  const auto frame = surface->browser->GetMainFrame();
  if (frame == nullptr) {
    SendError(request_id, "runtime_failed", "surface frame is unavailable");
    return;
  }
  if (operation == kEvaluateJavaScriptOperation) {
    frame->ExecuteJavaScript(value->GetString("script"), frame->GetURL(), 0);
  } else if (operation == kDispatchScriptMessageOperation) {
    auto argument = CefValue::Create();
    argument->SetDictionary(value);
    const std::string script =
        "window.__roscordBrowserRuntimeReceive(" + Json(argument) + ");";
    frame->ExecuteJavaScript(script, frame->GetURL(), 0);
  } else {
    SendError(request_id, "invalid_command", "script operation is not supported");
    return;
  }
  SendScriptComplete(surface_id, envelope, operation);
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
  if (type != "open" && type != "command" && type != "close" &&
      type != "heartbeat") {
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
  if (type == "heartbeat") {
    return HandleHeartbeat(payload);
  }
  return HandleCommand(payload);
}

bool HostController::HandleHeartbeat(CefRefPtr<CefDictionaryValue> payload) {
  if (payload == nullptr || payload->GetType("request_id") != VTYPE_INT ||
      payload->GetInt("request_id") <= 0) {
    SendError(std::nullopt, "invalid_command", "heartbeat payload is malformed");
    return false;
  }
  SendHeartbeatAck(payload->GetInt("request_id"));
  return true;
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
  const auto policy_value = spec->GetDictionary("policy");
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
      policy_value == nullptr) {
    SendError(request_id < 0 ? std::nullopt
                             : std::optional<int>(request_id),
              "invalid_spec",
              "surface policy or initial navigation is malformed");
    return true;
  }

  NavigationPolicy policy;
  if (!ParseNavigationPolicy(policy_value, policy) ||
      EvaluateNavigation(
          policy, url,
          navigation->GetString("disposition").ToString(),
          navigation->GetBool("user_initiated")) != NavigationDecision::InProcess) {
    SendError(request_id, "invalid_spec",
              "initial navigation is outside the declared policy");
    return true;
  }

  CefRefPtr<CefRequestContext> request_context;
  uint64_t context_id = 0;
  std::string profile_error;
  if (!profiles_.Open(profile, privacy, request_context, context_id,
                      profile_error)) {
    const std::string code = profile_error == "profile migration failed"
                                 ? "migration_failed"
                                 : profile_error == "profile is busy"
                                       ? "profile_busy"
                                       : "profile_unavailable";
    SendError(request_id, code, profile_error);
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
      surface.context_id = context_id;
      surface.request_context = request_context;
      surface.presentation = presentation;
      surface.privacy = privacy;
      surface.initial_url = url;
      surface.policy = policy;
      surfaces_.emplace(surface.id, surface);
    }
  }
  if (surface_ids_exhausted) {
    profiles_.Release(context_id);
    SendError(request_id, "runtime_failed", "surface id space is exhausted");
    return true;
  }
  SendOpened(request_id, surface.id);
  CefTaskRunner::GetForThread(TID_UI)->PostTask(
      new CreateBrowserTask(this, surface.id, url, presentation));
  return true;
}

bool HostController::HandleCommand(CefRefPtr<CefDictionaryValue> payload) {
  if (payload == nullptr || payload->GetType("request_id") != VTYPE_INT ||
      payload->GetInt("request_id") <= 0 ||
      payload->GetType("surface_id") != VTYPE_INT ||
      payload->GetType("command") != VTYPE_DICTIONARY) {
    SendError(std::nullopt, "invalid_command", "command payload is malformed");
    return false;
  }
  const int request_id = payload->GetInt("request_id");
  const int raw_surface_id = payload->GetInt("surface_id");
  if (raw_surface_id <= 0) {
    SendError(request_id, "invalid_command", "surface id must be positive");
    return false;
  }
  const uint64_t surface_id = static_cast<uint64_t>(raw_surface_id);
  const auto command = payload->GetDictionary("command");
  if (command->GetType("type") != VTYPE_STRING ||
      command->GetType("payload") != VTYPE_DICTIONARY) {
    SendError(request_id, "invalid_command", "command is malformed");
    return false;
  }
  const std::string command_type = command->GetString("type").ToString();
  constexpr std::array<std::string_view, 11> kCommandTypes = {
      "navigate",   "input",    "resize",   "focus",    "script",
      "permission", "popup",    "download", "clipboard", "upload",
      "release_frame",
  };
  if (std::find(kCommandTypes.begin(), kCommandTypes.end(),
                std::string_view(command_type)) ==
      kCommandTypes.end()) {
    SendError(request_id, "unknown_command", "command type is not supported");
    return false;
  }
  const auto command_payload = command->GetDictionary("payload");
  if (command_payload == nullptr) {
    SendError(request_id, "invalid_command", "command payload is malformed");
    return false;
  }
  if (command_payload->GetType("sequence") != VTYPE_INT ||
      command_payload->GetInt("sequence") <= 0) {
    SendError(request_id, "invalid_command", "command sequence is invalid");
    return false;
  }
  if (command_payload->GetType("profile_key") == VTYPE_STRING &&
      command_payload->GetString("profile_key").ToString().empty()) {
    SendError(request_id, "invalid_command", "profile key is empty");
    return false;
  }
  if (command_payload->GetType("profile_key") != VTYPE_STRING &&
      command_payload->GetType("profile_key") != VTYPE_NULL &&
      command_payload->GetType("profile_key") != VTYPE_INVALID) {
    SendError(request_id, "invalid_command", "profile key is malformed");
    return false;
  }
  CefRefPtr<CefDictionaryValue> navigation_command;
  std::string navigation_url;
  std::string navigation_disposition;
  bool navigation_user_gesture = false;
  if (command_type == "navigate") {
    if (command_payload->GetType("navigation") != VTYPE_DICTIONARY) {
      SendError(request_id, "invalid_command", "navigation command is malformed");
      return false;
    }
    navigation_command = command_payload->GetDictionary("navigation");
    if (navigation_command->GetType("url") != VTYPE_STRING ||
        navigation_command->GetType("disposition") != VTYPE_STRING ||
        navigation_command->GetType("user_initiated") != VTYPE_BOOL) {
      SendError(request_id, "invalid_command", "navigation request is malformed");
      return false;
    }
    navigation_url = navigation_command->GetString("url").ToString();
    navigation_disposition =
        navigation_command->GetString("disposition").ToString();
    navigation_user_gesture = navigation_command->GetBool("user_initiated");
    if (!UrlOrigin(navigation_url).has_value() &&
        !IsControlledFixture(navigation_url)) {
      SendError(request_id, "invalid_command", "navigation URL is invalid");
      return false;
    }
  }
  std::string popup_request_id;
  std::string popup_action;
  if (command_type == "popup") {
    if (command_payload->GetType("request_id") != VTYPE_STRING ||
        command_payload->GetType("action") != VTYPE_STRING) {
      SendError(request_id, "invalid_command", "popup command is malformed");
      return false;
    }
    popup_request_id = command_payload->GetString("request_id").ToString();
    popup_action = command_payload->GetString("action").ToString();
  }
  std::string permission_request_id;
  std::string permission_decision;
  if (command_type == "permission") {
    if (command_payload->GetType("request_id") != VTYPE_STRING ||
        command_payload->GetType("decision") != VTYPE_STRING) {
      SendError(request_id, "invalid_command", "permission command is malformed");
      return false;
    }
    permission_request_id =
        command_payload->GetString("request_id").ToString();
    permission_decision = command_payload->GetString("decision").ToString();
    if (permission_request_id.empty() ||
        (permission_decision != "deny" &&
         permission_decision != "allow_once" &&
         permission_decision != "allow_session" &&
         permission_decision != "allow_always")) {
      SendError(request_id, "invalid_command", "permission decision is invalid");
      return false;
    }
  }
  CefRefPtr<CefDictionaryValue> script_envelope;
  std::string script_operation;
  if (command_type == "script") {
    if (command_payload->GetType("envelope") != VTYPE_DICTIONARY) {
      SendError(request_id, "invalid_command", "script envelope is malformed");
      return false;
    }
    // Copied for the UI thread task, like the input below.
    script_envelope = command_payload->GetDictionary("envelope")->Copy(false);
    if (script_envelope->GetType("source") != VTYPE_STRING ||
        script_envelope->GetType("origin") != VTYPE_STRING ||
        script_envelope->GetType("channel") != VTYPE_STRING ||
        script_envelope->GetType("request_id") != VTYPE_STRING ||
        script_envelope->GetString("origin").ToString().empty() ||
        script_envelope->GetString("channel").ToString().empty() ||
        script_envelope->GetString("request_id").ToString().empty()) {
      SendError(request_id, "invalid_command", "script envelope metadata is malformed");
      return false;
    }
    const auto value = script_envelope->GetDictionary("value");
    if (value == nullptr || value->GetType("operation") != VTYPE_STRING) {
      SendError(request_id, "invalid_command", "script operation is missing");
      return false;
    }
    script_operation = value->GetString("operation").ToString();
    if (script_operation == kEvaluateJavaScriptOperation) {
      if (value->GetType("script") != VTYPE_STRING ||
          value->GetString("script").ToString().empty()) {
        SendError(request_id, "invalid_command", "javascript source is missing");
        return false;
      }
    } else if (script_operation == kDispatchScriptMessageOperation) {
      if (value->GetType("storage_key") != VTYPE_STRING ||
          value->GetType("payload") != VTYPE_STRING) {
        SendError(request_id, "invalid_command", "script message is malformed");
        return false;
      }
    } else {
      SendError(request_id, "invalid_command", "script operation is not supported");
      return false;
    }
  }
  CefRefPtr<CefDictionaryValue> input_value;
  if (command_type == "input") {
    if (command_payload->GetType("input") != VTYPE_DICTIONARY) {
      SendError(request_id, "invalid_command", "input command is malformed");
      return false;
    }
    // Copied: GetDictionary returns a reference into the parsed message,
    // which CEF invalidates once the message is released, before the UI
    // thread task that applies the input runs.
    input_value = command_payload->GetDictionary("input")->Copy(false);
    if (input_value->GetType("type") != VTYPE_STRING ||
        input_value->GetType("payload") != VTYPE_DICTIONARY) {
      SendError(request_id, "invalid_command", "input event is malformed");
      return false;
    }
    const std::string input_kind = input_value->GetString("type").ToString();
    if (input_kind != "pointer" && input_kind != "keyboard" &&
        input_kind != "ime") {
      SendError(request_id, "invalid_command", "input type is not supported");
      return false;
    }
  }
  int resize_width = 0;
  int resize_height = 0;
  double resize_scale = 1.0;
  if (command_type == "resize") {
    if (command_payload->GetType("width") != VTYPE_INT ||
        command_payload->GetType("height") != VTYPE_INT ||
        (command_payload->GetType("device_scale_factor") != VTYPE_DOUBLE &&
         command_payload->GetType("device_scale_factor") != VTYPE_INT)) {
      SendError(request_id, "invalid_command", "resize command is malformed");
      return false;
    }
    resize_width = command_payload->GetInt("width");
    resize_height = command_payload->GetInt("height");
    resize_scale = command_payload->GetType("device_scale_factor") == VTYPE_DOUBLE
                       ? command_payload->GetDouble("device_scale_factor")
                       : static_cast<double>(
                             command_payload->GetInt("device_scale_factor"));
    if (resize_width <= 0 || resize_height <= 0 || resize_width > 7680 ||
        resize_height > 4320 || !(resize_scale > 0) ||
        !(resize_scale <= 4.0)) {
      SendError(request_id, "invalid_command",
                "resize dimensions and scale must be positive");
      return false;
    }
  }
  bool focus_value = false;
  if (command_type == "focus") {
    if (command_payload->GetType("focused") != VTYPE_BOOL) {
      SendError(request_id, "invalid_command", "focus command is malformed");
      return false;
    }
    focus_value = command_payload->GetBool("focused");
  }
  int release_frame_sequence = 0;
  if (command_type == "release_frame") {
    if (command_payload->GetType("frame_sequence") != VTYPE_INT ||
        command_payload->GetInt("frame_sequence") <= 0) {
      SendError(request_id, "invalid_command",
                "frame sequence must be greater than zero");
      return false;
    }
    release_frame_sequence = command_payload->GetInt("frame_sequence");
  }
  const auto surface = GetSurface(surface_id);
  if (!surface) {
    SendError(request_id, "stale_surface", "surface id is not active");
    return true;
  }
  if (command_type == "script" && surface->browser == nullptr) {
    SendError(request_id, "runtime_failed", "surface browser is not ready");
    return true;
  }
  if (command_payload->GetType("profile_key") == VTYPE_STRING &&
      command_payload->GetString("profile_key").ToString() !=
          surface->profile_key) {
    SendError(request_id, "profile_mismatch", "surface profile key does not match");
    return true;
  }
  const int sequence = command_payload->GetInt("sequence");
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator == surfaces_.end()) {
      SendError(request_id, "stale_surface", "surface id is not active");
      return true;
    }
    if (sequence <= iterator->second.last_command_sequence) {
      SendError(request_id, "sequence_violation",
                "command sequence must increase");
      return true;
    }
    iterator->second.last_command_sequence = sequence;
  }
  // A command acknowledgement means only that the host accepted the command
  // for execution.  The client still treats an accepted command without a
  // terminal outcome as unknown if this process subsequently disappears.
  SendAck(request_id);
  if (command_type == "navigate") {
    const auto decision = EvaluateNavigation(surface->policy, navigation_url,
                                              navigation_disposition,
                                              navigation_user_gesture);
    if (decision == NavigationDecision::InProcess) {
      CefTaskRunner::GetForThread(TID_UI)->PostTask(
          new NavigateBrowserTask(this, surface_id, std::move(navigation_url)));
    } else if (decision == NavigationDecision::External) {
      SendNavigation(surface_id, navigation_url, "external", "external");
    } else {
      SendNavigation(surface_id, navigation_url, navigation_disposition,
                     navigation_disposition == "external" ? "cancelled"
                                                             : "blocked");
    }
    return true;
  }
  if (command_type == "popup") {
    SurfaceState::PendingPopup pending_popup;
    bool found_popup = false;
    {
      std::lock_guard lock(state_mutex_);
      const auto iterator = surfaces_.find(surface_id);
      if (iterator != surfaces_.end()) {
        const auto popup = iterator->second.pending_popups.find(popup_request_id);
        if (popup != iterator->second.pending_popups.end()) {
          pending_popup = popup->second;
          iterator->second.pending_popups.erase(popup);
          found_popup = true;
        }
      }
    }
    if (!found_popup) {
      SendError(request_id, "stale_popup", "popup request is no longer pending");
      return true;
    }
    if (popup_action == "open_external" &&
        EvaluateNavigation(surface->policy, pending_popup.url, "external",
                           pending_popup.user_gesture) ==
            NavigationDecision::External) {
      SendNavigation(surface_id, pending_popup.url, "external", "external");
    } else {
      SendNavigation(surface_id, pending_popup.url, "new_surface", "cancelled");
    }
    return true;
  }
  if (command_type == "permission") {
    ResolveMediaDecision(surface_id, request_id, permission_request_id,
                         permission_decision);
    return true;
  }
  if (command_type == "script") {
    CefTaskRunner::GetForThread(TID_UI)->PostTask(
        new ExecuteScriptTask(this, surface_id, request_id,
                              std::move(script_envelope)));
    return true;
  }
  if (command_type == "download" || command_type == "clipboard" ||
      command_type == "upload") {
    return ResolveFileAccessCommand(surface_id, request_id, command_type,
                                    command_payload);
  }
  if (command_type == "input") {
    // Pointer, keyboard, wheel, and IME input route to the browser on the CEF
    // UI thread for both presentations.  Windowed standalone browsers also
    // receive native HWND input and IME messages; the synthetic channel keeps
    // scripted and assistive input ordered.  Selection is owned by the page;
    // the host only delivers ordered input events and never synthesizes
    // clipboard or focus changes.
    CefTaskRunner::GetForThread(TID_UI)->PostTask(
        new InputSurfaceTask(this, surface_id, std::move(input_value)));
    return true;
  }
  if (command_type == "resize") {
    // Resize and DPI update the owned geometry.  Embedded updates the OSR view
    // rectangle so the next OnPaint matches Flutter layout; standalone moves
    // the roscord-owned HWND and notifies the windowed browser.  Both report
    // the validated size through the same ordered command stream.
    CefTaskRunner::GetForThread(TID_UI)->PostTask(new ResizeSurfaceTask(
        this, surface_id, resize_width, resize_height, resize_scale));
    return true;
  }
  if (command_type == "focus") {
    // Focus updates the owned window: embedded delivers SetFocus to the OSR
    // browser, standalone brings the roscord HWND to the front for z-order
    // and then focuses the windowed browser.  Unfocus never destroys z-order.
    CefTaskRunner::GetForThread(TID_UI)->PostTask(
        new FocusSurfaceTask(this, surface_id, focus_value));
    return true;
  }
  if (command_type == "release_frame") {
    // Frame release is ring accounting only; the Dart side coalesces to the
    // newest client-owned frame and releases older sequences.
    ApplyReleaseFrame(surface_id, release_frame_sequence);
    return true;
  }
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
    auto surface = GetSurface(surface_id);
    std::lock_guard lock(state_mutex_);
    if (surfaces_.erase(surface_id) != 0) {
      if (surface.has_value()) profiles_.Release(surface->context_id);
      closed_condition_.notify_all();
    }
    return;
  }
  auto surface = GetSurface(surface_id);
  if (!surface) {
    SendError(std::nullopt, "invalid_spec", "surface is no longer creatable");
    return;
  }

  CefWindowInfo window_info;
  HWND owned_window = nullptr;
  if (presentation == "embedded") {
    window_info.SetAsWindowless(nullptr);
  } else {
    // Standalone windowed CEF in a roscord-owned top-level HWND.  The host
    // creates and shows the window first, then parents the CEF browser as
    // its child so geometry, focus, z-order, DPI, input, IME, popup
    // parenting, and close stay owned. The same host, request context,
    // profile, policy, and permission mediation apply as embedded.
    int initial_width = surface->view_width;
    int initial_height = surface->view_height;
    owned_window = CreateStandaloneWindow(initial_width, initial_height);
    if (owned_window == nullptr) {
      SendError(std::nullopt, "runtime_failed",
                "roscord-owned standalone window could not be created");
      {
        std::lock_guard lock(state_mutex_);
        const auto iterator = surfaces_.find(surface_id);
        if (iterator != surfaces_.end()) {
          profiles_.Release(iterator->second.context_id);
          surfaces_.erase(iterator);
        }
      }
      closed_condition_.notify_all();
      return;
    }
    {
      std::lock_guard lock(state_mutex_);
      const auto iterator = surfaces_.find(surface_id);
      if (iterator != surfaces_.end()) {
        iterator->second.owned_window = owned_window;
        iterator->second.window_visible = true;
      }
    }
    CefRect child_rect(0, 0, initial_width, initial_height);
    window_info.SetAsChild(owned_window, child_rect);
  }
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 30;
  auto client = new BrowserClient(this, surface_id);
  // Asynchronous on purpose: a request context made by CreateContext starts
  // uninitialized, and CreateBrowserSync refuses one that is not ready yet
  // (it returns null without a word), while CreateBrowser waits for it.
  // OnAfterCreated records the browser and reports the surface ready.
  if (!CefBrowserHost::CreateBrowser(window_info, client, url, settings,
                                     nullptr, surface->request_context)) {
    SendError(std::nullopt, "runtime_failed", "CEF rejected the surface");
    HWND failed_window = nullptr;
    {
      std::lock_guard lock(state_mutex_);
      const auto iterator = surfaces_.find(surface_id);
      if (iterator != surfaces_.end()) {
        failed_window = iterator->second.owned_window;
        profiles_.Release(iterator->second.context_id);
        surfaces_.erase(iterator);
      }
    }
    DestroyStandaloneWindow(failed_window);
    closed_condition_.notify_all();
  }
}

void HostController::NavigateBrowserOnUi(uint64_t surface_id, std::string url) {
  CEF_REQUIRE_UI_THREAD();
  // A top-level navigation terminally cancels that surface's pending
  // download/clipboard/upload requests: a late approval must never stage
  // bytes, touch the clipboard, or open a chooser for the previous page.
  CancelPendingFileAccess(surface_id, "navigation");
  const auto surface = GetSurface(surface_id);
  if (!surface || surface->browser == nullptr) {
    SendError(std::nullopt, "runtime_failed", "surface browser is not ready");
    return;
  }
  const auto frame = surface->browser->GetMainFrame();
  if (frame == nullptr) {
    SendError(std::nullopt, "runtime_failed", "surface frame is unavailable");
    return;
  }
  frame->LoadURL(url);
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
  SendReady(*surface, surface->initial_url);
}

void HostController::OnBrowserClosed(uint64_t surface_id) {
  CEF_REQUIRE_UI_THREAD();
  // Closing a surface terminally cancels its pending file-access requests.
  CancelPendingFileAccess(surface_id, "close");
  // Pending media callbacks belong to the dead surface: cancel them before
  // the surface state is erased so a late app decision can never grant them.
  CancelPendingMediaOnUi(surface_id);
  bool was_active = false;
  std::optional<uint64_t> context_id;
  HWND owned_window = nullptr;
  uint64_t close_sequence = 2;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator != surfaces_.end()) {
      context_id = iterator->second.context_id;
      owned_window = iterator->second.owned_window;
      close_sequence = iterator->second.next_event_sequence;
      surfaces_.erase(iterator);
      was_active = true;
    }
  }
  // Standalone owned windows are destroyed on the UI thread after the browser
  // closes so no orphan HWND survives process cleanup. Embedded surfaces have
  // no window and skip this step; both paths share the same CPU/software
  // rendering shutdown and request-context release.
  DestroyStandaloneWindow(owned_window);
  if (context_id.has_value()) {
    profiles_.Release(*context_id);
  }
  if (was_active) {
    SendClosed(surface_id, close_sequence);
    closed_condition_.notify_all();
  }
}

void HostController::OnRendererFailure(uint64_t surface_id,
                                       std::string_view code,
                                       std::string_view message) {
  // Renderer callbacks are child scoped.  They are reported as correlated
  // lifecycle failures instead of being promoted to a host crash, so other
  // logical surfaces remain usable.
  if (!HasSurface(surface_id)) return;
  SendError(std::nullopt, code, message);
}

void HostController::Shutdown() {
  stopping_ = true;
  // Host loss is terminal for every pending file-access request.
  CancelAllPendingFileAccess("host_loss");
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
  shutdown_timed_out_ = !closed_condition_.wait_for(
      lock, std::chrono::seconds(5), [&] { return surfaces_.empty(); });
  if (!shutdown_timed_out_) profiles_.Shutdown();
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

bool BrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   bool user_gesture,
                                   bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  if (frame == nullptr || request == nullptr) return true;
  return controller_->OnNavigationRequested(surface_id_,
                                             request->GetURL().ToString(),
                                             "current", user_gesture,
                                             is_redirect);
}

bool BrowserClient::OnOpenURLFromTab(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    const CefString& target_url,
    CefRequestHandler::WindowOpenDisposition target_disposition,
    bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)frame;
  (void)target_disposition;
  return controller_->OnNavigationRequested(surface_id_, target_url.ToString(),
                                             "external", user_gesture, false);
}

bool BrowserClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                       cef_errorcode_t cert_error,
                                       const CefString& request_url,
                                       CefRefPtr<CefSSLInfo> ssl_info,
                                       CefRefPtr<CefCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)request_url;
  (void)ssl_info;
  if (callback != nullptr) callback->Cancel();
  controller_->OnCertificateError(surface_id_, request_url.ToString(),
                                  static_cast<int>(cert_error));
  return true;
}

bool BrowserClient::OnSelectClientCertificate(
    CefRefPtr<CefBrowser> browser, bool is_proxy, const CefString& host,
    int port, const X509CertificateList& certificates,
    CefRefPtr<CefSelectClientCertificateCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)is_proxy;
  (void)host;
  (void)port;
  (void)certificates;
  if (callback != nullptr) callback->Select(nullptr);
  controller_->OnClientCertificateRequest(surface_id_);
  return true;
}

bool BrowserClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
    const CefString& target_url, const CefString& target_frame_name,
    CefLifeSpanHandler::WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popup_features, CefWindowInfo& window_info,
    CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)frame;
  (void)target_frame_name;
  (void)target_disposition;
  (void)popup_features;
  (void)window_info;
  (void)client;
  (void)settings;
  (void)extra_info;
  (void)no_javascript_access;
  return controller_->OnPopupRequested(surface_id_, popup_id,
                                       target_url.ToString(), user_gesture);
}

bool BrowserClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  // Downloads pause for approval: cancel the inline CEF download path and
  // emit one download_request.  On AcceptDownload the host stages bytes to a
  // temporary file and commits them with AtomicCommitDownload into the safe
  // account/user destination (no traversal, reparse paths, or silent
  // overwrite).  Denial, timeout, navigation, close, or host loss cancels the
  // pending request terminally via CancelPendingFileAccess.
  //
  // Claiming the download (returning true) without ever calling
  // |callback|->Continue cancels it once CEF releases the callback.
  (void)callback;
  if (browser == nullptr || download_item == nullptr) return true;
  controller_->OnDownloadRequested(surface_id_,
                                   download_item->GetURL().ToString(),
                                   suggested_name.ToString());
  return true;
}

void BrowserClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)callback;
  // The inline download path is always canceled in OnBeforeDownload, so any
  // update here is terminal bookkeeping: a canceled or interrupted item must
  // leave no partial file behind.  Staged approvals complete through
  // AtomicCommitDownload instead of this callback.
  (void)download_item;
}

bool BrowserClient::OnFileDialog(
    CefRefPtr<CefBrowser> browser, CefDialogHandler::FileDialogMode mode,
    const CefString& title, const CefString& default_file_path,
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions,
    const std::vector<CefString>& accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)title;
  (void)default_file_path;
  (void)accept_extensions;
  (void)accept_descriptions;
  // Uploads never open inline: cancel the default dialog and emit one
  // upload_request.  On AcceptUpload the host shows exactly one OS chooser in
  // FILE_DIALOG_OPEN mode, stages the explicit selection as read-only copies
  // (StagedUpload), and hands the page staged handles only.  No directory is
  // enumerated and no persistent path grant is kept.  Save dialogs are never
  // admitted for uploads.
  if (callback != nullptr) callback->Cancel();
  if (mode != FILE_DIALOG_OPEN) return true;
  std::vector<std::string> accept;
  for (const auto& filter : accept_filters) accept.push_back(filter.ToString());
  controller_->OnUploadRequested(surface_id_, false, accept);
  return true;
}

bool BrowserClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)frame;
  // Always return true: the host mediates every media request and never
  // falls through to default handling (which would show unowned Chrome UI).
  // Deny-by-default lives in OnMediaAccessRequested; unregistered requests
  // are canceled there.
  return controller_->OnMediaAccessRequested(
      surface_id_, browser, requesting_origin.ToString(), requested_permissions,
      callback);
}

bool BrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
    const CefString& requesting_origin, uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)requested_permissions;
  // Generic permission prompts are always denied synchronously: there is no
  // grant store for them and no bypass.  The denial is reported once here;
  // dismissal needs no second event.
  if (callback != nullptr) callback->Continue(CEF_PERMISSION_RESULT_DENY);
  controller_->OnPermissionPrompt(surface_id_, prompt_id,
                                  requesting_origin.ToString());
  return true;
}

void BrowserClient::OnDismissPermissionPrompt(
    CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
    cef_permission_request_result_t result) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)prompt_id;
  (void)result;
  // Denials are already reported synchronously in OnShowPermissionPrompt, so
  // dismissal carries no additional event.  The handler exists to document
  // that dismissal can never grant: the prompt outcome was already deny.
}

bool BrowserClient::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    CefProcessId source_process, CefRefPtr<CefProcessMessage> message) {
  CEF_REQUIRE_UI_THREAD();
  (void)frame;
  if (source_process != PID_RENDERER || message == nullptr ||
      message->GetName() != "roscord_browser_runtime_send") {
    return false;
  }
  const auto arguments = message->GetArgumentList();
  if (arguments == nullptr || arguments->GetType(0) != VTYPE_STRING) {
    controller_->OnBrowserRuntimeSend(surface_id_, browser, {});
    return true;
  }
  controller_->OnBrowserRuntimeSend(surface_id_, browser,
                                     arguments->GetString(0).ToString());
  return true;
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  controller_->OnBrowserClosed(surface_id_);
}

void BrowserClient::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
    const CefString& error_string) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  const int raw_status = static_cast<int>(status);
  std::string_view code = "renderer_crash";
  if (raw_status == 0) {
    code = "renderer_abnormal_exit";
  } else if (raw_status == 1) {
    code = "renderer_killed";
  } else if (raw_status == 3) {
    code = "renderer_oom";
  } else if (raw_status == 4) {
    code = "renderer_launch_failed";
  } else if (raw_status == 5) {
    code = "renderer_integrity_failure";
  }
  const std::string detail = error_string.ToString();
  const std::string message = detail.empty()
                                  ? "renderer process terminated (status " +
                                        std::to_string(raw_status) + ", error " +
                                        std::to_string(error_code) + ")"
                                  : detail;
  controller_->OnRendererFailure(surface_id_, code, message);
}

bool BrowserClient::OnRenderProcessUnresponsive(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefUnresponsiveProcessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)callback;
  controller_->OnRendererFailure(surface_id_, "renderer_unresponsive",
                                 "renderer process is unresponsive");
  // Keep waiting without CEF's own "Page unresponsive" UI; recovery is the
  // app's decision.
  return true;
}

void BrowserClient::GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  int width = 1024;
  int height = 768;
  double device_scale_factor = 1.0;
  if (controller_->GetViewSize(surface_id_, width, height,
                               device_scale_factor)) {
    rect = CefRect(0, 0, width, height);
  } else {
    rect = CefRect(0, 0, 1024, 768);
  }
}

bool BrowserClient::GetScreenInfo(CefRefPtr<CefBrowser> browser,
                                  CefScreenInfo& screen_info) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  int width = 1024;
  int height = 768;
  double device_scale_factor = 1.0;
  controller_->GetViewSize(surface_id_, width, height, device_scale_factor);
  screen_info.device_scale_factor = static_cast<float>(device_scale_factor);
  screen_info.depth = 24;
  screen_info.depth_per_component = 8;
  screen_info.is_monochrome = false;
  screen_info.rect = CefRect(0, 0, width, height);
  screen_info.available_rect = CefRect(0, 0, width, height);
  return true;
}

bool BrowserClient::OnCursorChange(CefRefPtr<CefBrowser> browser,
                                   CefCursorHandle cursor,
                                   cef_cursor_type_t type,
                                   const CefCursorInfo& custom_cursor_info) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)cursor;
  (void)custom_cursor_info;
  return controller_->OnCursorChanged(surface_id_,
                                      browser_surface::CssCursorName(type));
}

bool BrowserClient::OnTooltip(CefRefPtr<CefBrowser> browser, CefString& text) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)text;
  return controller_->IsEmbedded(surface_id_);
}

void BrowserClient::OnPaint(CefRefPtr<CefBrowser> browser,
                            PaintElementType type,
                            const RectList& dirty_rects,
                            const void* buffer,
                            int width,
                            int height) {
  // Embedded OSR presentation: copy the CPU buffer into client-owned
  // memory synchronously.  |buffer| belongs to CEF only for the duration
  // of this callback and must never be retained or passed to Dart.
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  (void)dirty_rects;
  if (type != PET_VIEW || buffer == nullptr || width <= 0 || height <= 0) {
    return;
  }
  controller_->OnPaintFrame(surface_id_, buffer, width, height);
}

// A host that stops before its pipe exists leaves the app nothing but an exit
// code, so each startup failure says why on stderr (the app and the smoke test
// capture it) and, when it is set, in $ROSCORD_CEF_HOST_LOG.
int StartupFailure(std::wstring_view stage, const std::wstring& detail = {}) {
  std::wstring line = L"cef_host: ";
  line += stage;
  if (!detail.empty()) {
    line += L": ";
    line += detail;
  }
  line += L"\n";
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) return EXIT_FAILURE;
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
                      utf8.data(), size, nullptr, nullptr);
  DWORD written = 0;
  const HANDLE error_output = GetStdHandle(STD_ERROR_HANDLE);
  if (error_output != nullptr && error_output != INVALID_HANDLE_VALUE) {
    WriteFile(error_output, utf8.data(), static_cast<DWORD>(utf8.size()),
              &written, nullptr);
  }
  std::array<wchar_t, MAX_PATH> log_path{};
  const DWORD length = GetEnvironmentVariableW(
      L"ROSCORD_CEF_HOST_LOG", log_path.data(),
      static_cast<DWORD>(log_path.size()));
  if (length > 0 && length < log_path.size()) {
    const HANDLE log =
        CreateFileW(log_path.data(), FILE_APPEND_DATA,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log != INVALID_HANDLE_VALUE) {
      WriteFile(log, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
                nullptr);
      CloseHandle(log);
    }
  }
  return EXIT_FAILURE;
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
    return StartupFailure(L"invalid arguments", error);
  }
  if (!ValidateProfileRoot(args->profile_root)) {
    return StartupFailure(L"the profile root is not a private directory",
                          args->profile_root.wstring());
  }
  if (sandbox_info == nullptr) {
    return StartupFailure(L"the bootstrap passed no sandbox information");
  }
  if (!VerifyBundledRuntime(error)) {
    return StartupFailure(L"the bundled runtime is incomplete", error);
  }

  CefSettings settings;
  settings.no_sandbox = false;
  settings.multi_threaded_message_loop = true;
  settings.windowless_rendering_enabled = true;
  // $ROSCORD_CEF_LOG_FILE turns CEF's own log on, which is the only account
  // of a host that stops inside CEF.
  std::array<wchar_t, MAX_PATH> cef_log{};
  const DWORD cef_log_length = GetEnvironmentVariableW(
      L"ROSCORD_CEF_LOG_FILE", cef_log.data(),
      static_cast<DWORD>(cef_log.size()));
  if (cef_log_length > 0 && cef_log_length < cef_log.size()) {
    CefString(&settings.log_file) = std::wstring(cef_log.data(), cef_log_length);
    settings.log_severity = LOGSEVERITY_INFO;
  } else {
    settings.log_severity = LOGSEVERITY_DISABLE;
  }
  // CEF requires every request context's cache_path to sit below this root,
  // and each persistent account profile is a directory of the profile root.
  CefString(&settings.root_cache_path) = args->profile_root.wstring();

  // Forced software rendering keeps CPU rendering authoritative when GPU
  // import is unavailable.  Embedded keeps the same CPU OnPaint frame ring;
  // standalone windowed browsers render in software with the same
  // input/resize/focus/close contract.  No alternate engine is selected.  The
  // switches go in through OnBeforeCommandLineProcessing: the global command
  // line CEF hands out before CefInitialize is read-only.
  app->SetSoftwareRendering(args->software_rendering);

  const bool initialized = CefInitialize(main_args, settings, app, sandbox_info);
  if (!initialized) {
    return StartupFailure(L"CefInitialize failed");
  }
  if (!VerifyLoadedBundledRuntime(error)) {
    CefShutdown();
    return StartupFailure(L"CEF was loaded from elsewhere", error);
  }
  if (!app->WaitForContext(std::chrono::seconds(10))) {
    CefShutdown();
    return StartupFailure(L"CEF did not initialize its context in time");
  }

  PipeChannel pipe(*args);
  if (!pipe.ConnectAndAuthenticate(error)) {
    CefShutdown();
    return StartupFailure(L"the app did not connect", error);
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

// The M138+ bootstrap, renamed cef_host.exe, loads cef_host.dll from its own
// directory and calls this exact export.  It must be signed like the
// executable, or both unsigned.  The bootstrap supplies the sandbox
// information object; dropping it or replacing the bootstrap with a
// hand-written subprocess would disable the supported Windows sandbox
// arrangement.
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
