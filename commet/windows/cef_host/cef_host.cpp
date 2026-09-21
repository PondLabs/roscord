#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <aclapi.h>
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
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <tchar.h>
#include <cwctype>
#include <utility>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_request_context.h"
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
  std::filesystem::path profile_root;
  std::string nonce;
  std::wstring module_name;
  bool validation = false;
  std::optional<std::string> fault;
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

bool IsKnownFaultPoint(std::wstring_view fault) {
  static constexpr std::array<std::wstring_view, 11> kFaultPoints = {
      L"host_crash",       L"host_unresponsive", L"renderer_crash",
      L"renderer_oom",     L"renderer_hang",     L"gpu_crash",
      L"utility_crash",    L"bad_bundle",        L"bad_protocol",
      L"sandbox_failure",  L"profile_lock",
  };
  return std::find(kFaultPoints.begin(), kFaultPoints.end(), fault) !=
         kFaultPoints.end();
}

std::optional<HostArgs> ValidateHostArgs(const ParsedCommandLine& command_line,
                                          std::wstring& error) {
  bool validation = false;
  std::optional<std::wstring> fault_name;
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
    if (lowered == L"--cef-validation") {
#ifdef NDEBUG
      error = L"CEF validation controls are disabled in production builds";
      return std::nullopt;
#else
      validation = true;
#endif
    } else if (StartsWith(lowered, L"--cef-fault=")) {
#ifdef NDEBUG
      error = L"CEF fault injection is disabled in production builds";
      return std::nullopt;
#else
      const auto value_name = value.substr(std::wstring(L"--cef-fault=").size());
      if (value_name.empty()) {
        error = L"CEF fault point is empty";
        return std::nullopt;
      }
      fault_name = value_name;
#endif
    }
  }

  const auto module = ValueForSwitch(command_line.values, L"--module");
  const auto pipe = ValueForSwitch(command_line.values, L"--pipe");
  const auto nonce = ValueForSwitch(command_line.values, L"--nonce");
  const auto parent = ValueForSwitch(command_line.values, L"--parent-pid");
  const auto profile_root = ValueForSwitch(command_line.values, L"--profile-root");
  if (!module || Lowercase(*module) != L"client.dll" || !pipe || !nonce ||
      !parent || !profile_root) {
    error = L"cef_host requires --module=client.dll, --pipe, --nonce, --parent-pid, and --profile-root";
    return std::nullopt;
  }

#ifndef NDEBUG
  std::optional<std::string> fault;
  if (fault_name.has_value()) {
    if (!validation) {
      error = L"CEF fault injection requires --cef-validation";
      return std::nullopt;
    }
    const auto lowered_fault = Lowercase(*fault_name);
    if (!IsKnownFaultPoint(lowered_fault)) {
      error = L"unknown CEF fault point";
      return std::nullopt;
    }
    fault = std::string(fault_name->begin(), fault_name->end());
  }
#else
  std::optional<std::string> fault;
#endif

  HostArgs result;
  result.module_name = *module;
  result.validation = validation;
  result.fault = fault;
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
        !EqualSid(&ace->SidStart, owner)) {
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
  HANDLE file = CreateFileW(
      path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
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
  if (!security.Create()) return false;
  PACL dacl = nullptr;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  if (!GetSecurityDescriptorDacl(security.get(), &present, &dacl,
                                 &defaulted) ||
      !present || dacl == nullptr) {
    return false;
  }
  return SetNamedSecurityInfoW(
             const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
             DACL_SECURITY_INFORMATION, nullptr, nullptr, dacl, nullptr) ==
         ERROR_SUCCESS;
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
      settings.cache_path = profile_path.wstring();
      settings.persist_session_cookies = true;
      settings.persist_user_preferences = true;
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
    settings.cache_path.clear();
    settings.persist_session_cookies = false;
    settings.persist_user_preferences = false;
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

struct SurfaceState {
  uint64_t id = 0;
  std::string profile_key;
  uint64_t context_id = 0;
  CefRefPtr<CefRequestContext> request_context;
  std::string presentation;
  int last_command_sequence = 0;
  CefRefPtr<CefBrowser> browser;
  bool close_requested = false;
};

class BrowserClient final : public CefClient,
                            public CefLifeSpanHandler,
                            public CefRenderHandler,
                            public CefRequestHandler {
 public:
  BrowserClient(HostController* controller, uint64_t surface_id)
      : controller_(controller), surface_id_(surface_id) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override;
  void OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> browser) override;

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
      : args_(args), pipe_(pipe), profiles_(args.profile_root) {}
  HostController(const HostController&) = delete;
  HostController& operator=(const HostController&) = delete;

  void Run();
  void Shutdown();
  void CreateBrowserOnUi(uint64_t surface_id, std::string url,
                         std::string presentation);
  void CloseBrowserOnUi(uint64_t surface_id);
  void OnBrowserCreated(uint64_t surface_id, CefRefPtr<CefBrowser> browser);
  void OnBrowserClosed(uint64_t surface_id);
  void OnRendererFailure(uint64_t surface_id, std::string_view code,
                         std::string_view message);
  bool ClearData(std::string_view profile_key, std::string& error) {
    std::lock_guard lock(state_mutex_);
    if (std::any_of(surfaces_.begin(), surfaces_.end(),
                    [&](const auto& entry) {
                      return entry.second.profile_key == profile_key;
                    })) {
      error = "profile is busy";
      return false;
    }
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
  std::optional<SurfaceState> GetSurface(uint64_t surface_id);
  bool HasSurface(uint64_t surface_id);

  HostArgs args_;
  PipeChannel& pipe_;
  std::mutex state_mutex_;
  std::map<uint64_t, SurfaceState> surfaces_;
  ProfileManager profiles_;
  uint64_t next_surface_id_ = 1;
  std::atomic<bool> stopping_ = false;
  std::condition_variable closed_condition_;
  bool validation_fault_consumed_ = false;
  bool shutdown_timed_out_ = false;
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
  if (args_.fault.has_value() && *args_.fault == "host_crash" &&
      !validation_fault_consumed_) {
    validation_fault_consumed_ = true;
    stopping_ = true;
    return false;
  }
  if (args_.fault.has_value() && *args_.fault == "bad_protocol" &&
      !validation_fault_consumed_) {
    validation_fault_consumed_ = true;
    SendError(std::nullopt, "malformed_message",
              "validation protocol fault");
    stopping_ = true;
    return false;
  }
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
  if (args_.fault.has_value() && *args_.fault == "host_unresponsive") {
    return true;
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
      spec->GetType("policy") != VTYPE_DICTIONARY || url != kFixtureUrl) {
    SendError(request_id < 0 ? std::nullopt
                             : std::optional<int>(request_id),
              "invalid_spec",
              "the Windows host smoke fixture requires the commet URL");
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
  if (args_.fault.has_value() && *args_.fault == "profile_lock" &&
      !validation_fault_consumed_) {
    validation_fault_consumed_ = true;
    SendError(request_id, "profile_locked", "validation profile lock fault");
    return true;
  }
  const int raw_surface_id = payload->GetInt("surface_id");
  if (raw_surface_id <= 0) {
    SendError(request_id, "invalid_command", "surface id must be positive");
    return false;
  }
  const uint64_t surface_id = static_cast<uint64_t>(raw_surface_id);
  if (args_.fault.has_value() && !validation_fault_consumed_) {
    std::string_view code;
    std::string_view message;
    if (*args_.fault == "renderer_crash") {
      code = "renderer_crash";
      message = "validation renderer crash";
    } else if (*args_.fault == "renderer_oom") {
      code = "renderer_oom";
      message = "validation renderer OOM";
    } else if (*args_.fault == "renderer_hang") {
      code = "renderer_unresponsive";
      message = "validation renderer hang";
    } else if (*args_.fault == "gpu_crash") {
      code = "gpu_crash";
      message = "validation GPU crash";
    } else if (*args_.fault == "utility_crash") {
      code = "utility_crash";
      message = "validation utility crash";
    }
    if (!code.empty()) {
      validation_fault_consumed_ = true;
      SendError(request_id, code, message);
      return true;
    }
  }
  const auto command = payload->GetDictionary("command");
  if (command->GetType("type") != VTYPE_STRING ||
      command->GetType("payload") != VTYPE_DICTIONARY) {
    SendError(request_id, "invalid_command", "command is malformed");
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
    SendError(request_id, "unknown_command", "command type is not supported");
    return false;
  }
  const auto command_payload = command->GetDictionary("payload");
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
  const auto surface = GetSurface(surface_id);
  if (!surface) {
    SendError(request_id, "stale_surface", "surface id is not active");
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
  if (presentation == "embedded") {
    window_info.SetAsWindowless(nullptr, false);
  } else {
    window_info.SetAsPopup(nullptr, "roscord Browser");
  }
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 30;
  auto client = new BrowserClient(this, surface_id);
  auto browser = CefBrowserHost::CreateBrowserSync(
      window_info, client, url, settings, nullptr, surface->request_context);
  if (browser == nullptr) {
    SendError(std::nullopt, "runtime_failed", "CEF rejected the fixture surface");
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
  std::optional<uint64_t> context_id;
  {
    std::lock_guard lock(state_mutex_);
    const auto iterator = surfaces_.find(surface_id);
    if (iterator != surfaces_.end()) {
      context_id = iterator->second.context_id;
      surfaces_.erase(iterator);
      was_active = true;
    }
  }
  if (context_id.has_value()) {
    profiles_.Release(*context_id);
  }
  if (was_active) {
    SendClosed(surface_id, 2);
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

void BrowserClient::OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  (void)browser;
  controller_->OnRendererFailure(surface_id_, "renderer_unresponsive",
                                 "renderer process is unresponsive");
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
  if (args->fault.has_value() &&
      (*args->fault == "bad_bundle" || *args->fault == "sandbox_failure")) {
    // Fault injection is intentionally deterministic and validation-only.  A
    // production binary cannot reach this branch because argument validation
    // rejects both switches under NDEBUG.
    return EXIT_FAILURE;
  }
  if (!ValidateProfileRoot(args->profile_root) || sandbox_info == nullptr ||
      !VerifyBundledRuntime(error)) {
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
