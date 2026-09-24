#include "include/browser_surface/browser_surface_plugin_c_api.h"

// clang-format off
#include <windows.h>
// clang-format on

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "browser_frame_ring.h"

namespace {

// Rings are created by cef_host as Local\roscord-cef-<namespace>-<surface>-<gen>.
constexpr wchar_t kRingPrefix[] = L"Local\\roscord-cef-";

std::wstring Widen(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), wide.data(), length);
  return wide;
}

bool IsRingName(const std::wstring& name) {
  const size_t prefix = sizeof(kRingPrefix) / sizeof(wchar_t) - 1;
  return name.size() > prefix && name.size() < MAX_PATH &&
         name.compare(0, prefix, kRingPrefix) == 0 &&
         name.find(L'\\', prefix) == std::wstring::npos;
}

struct FrameRequest {
  std::wstring buffer;
  uint32_t slot = 0;
  uint64_t sequence = 0;
};

// One Flutter texture fed from a host frame ring.  Present runs on the
// platform thread; CopyPixels runs on the raster thread.
class SurfaceTexture {
 public:
  explicit SurfaceTexture(flutter::TextureRegistrar* registrar)
      : registrar_(registrar),
        texture_(flutter::PixelBufferTexture(
            [this](size_t, size_t) { return CopyPixels(); })) {
    id_ = registrar_->RegisterTexture(&texture_);
  }

  SurfaceTexture(const SurfaceTexture&) = delete;
  SurfaceTexture& operator=(const SurfaceTexture&) = delete;

  ~SurfaceTexture() { Unmap(); }

  int64_t id() const { return id_; }

  void Present(FrameRequest request) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      request_ = std::move(request);
      has_request_ = true;
    }
    registrar_->MarkTextureFrameAvailable(id_);
  }

 private:
  const FlutterDesktopPixelBuffer* CopyPixels() {
    FrameRequest request;
    bool has_request = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (has_request_) {
        request = request_;
        has_request = true;
        has_request_ = false;
      }
    }
    if (has_request) {
      if (request.buffer != mapped_name_) Map(request.buffer);
      if (mapped_ != nullptr) {
        const auto* header =
            browser_surface::FrameRingValidate(mapped_, mapped_bytes_);
        if (header != nullptr && pixels_.size() < header->slot_bytes) {
          pixels_.resize(static_cast<size_t>(header->slot_bytes));
        }
        uint32_t width = 0;
        uint32_t height = 0;
        // A frame the host already replaced is skipped; the texture keeps
        // the previous one until the next request.
        if (header != nullptr &&
            browser_surface::FrameRingRead(mapped_, mapped_bytes_,
                                           request.slot, request.sequence,
                                           pixels_.data(), pixels_.size(),
                                           &width, &height)) {
          width_ = width;
          height_ = height;
        }
      }
    }
    if (width_ == 0 || height_ == 0) {
      // Nothing presented yet: one transparent pixel.
      pixels_.assign(4, 0);
      width_ = 1;
      height_ = 1;
    }
    buffer_.buffer = pixels_.data();
    buffer_.width = width_;
    buffer_.height = height_;
    buffer_.release_callback = nullptr;
    buffer_.release_context = nullptr;
    return &buffer_;
  }

  void Map(const std::wstring& name) {
    Unmap();
    if (!IsRingName(name)) return;
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
    if (mapping == nullptr) return;
    void* view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(mapping);
    if (view == nullptr) return;
    MEMORY_BASIC_INFORMATION info{};
    if (VirtualQuery(view, &info, sizeof(info)) == 0 ||
        info.RegionSize < browser_surface::kFrameRingHeaderBytes) {
      UnmapViewOfFile(view);
      return;
    }
    mapped_ = view;
    mapped_bytes_ = info.RegionSize;
    mapped_name_ = name;
  }

  void Unmap() {
    if (mapped_ != nullptr) UnmapViewOfFile(mapped_);
    mapped_ = nullptr;
    mapped_bytes_ = 0;
    mapped_name_.clear();
  }

  flutter::TextureRegistrar* registrar_;
  flutter::TextureVariant texture_;
  int64_t id_ = -1;

  std::mutex mutex_;
  FrameRequest request_;
  bool has_request_ = false;

  // Raster thread only.
  std::wstring mapped_name_;
  const void* mapped_ = nullptr;
  size_t mapped_bytes_ = 0;
  std::vector<uint8_t> pixels_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  FlutterDesktopPixelBuffer buffer_{};
};

std::optional<int64_t> IntArgument(const flutter::EncodableMap& arguments,
                                   const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return *value;
  }
  return std::nullopt;
}

const std::string* StringArgument(const flutter::EncodableMap& arguments,
                                  const char* key) {
  const auto iterator = arguments.find(flutter::EncodableValue(key));
  if (iterator == arguments.end()) return nullptr;
  return std::get_if<std::string>(&iterator->second);
}

class BrowserSurfacePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "browser_surface",
            &flutter::StandardMethodCodec::GetInstance());
    auto plugin =
        std::make_unique<BrowserSurfacePlugin>(registrar->texture_registrar());
    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });
    plugin->channel_ = std::move(channel);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit BrowserSurfacePlugin(flutter::TextureRegistrar* textures)
      : textures_(textures) {}

  ~BrowserSurfacePlugin() override {
    for (auto& entry : surfaces_) Unregister(std::move(entry.second));
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (call.method_name() == "create") {
      auto texture = std::make_unique<SurfaceTexture>(textures_);
      const int64_t id = texture->id();
      if (id < 0) {
        result->Error("texture_unavailable",
                      "the texture could not be registered");
        return;
      }
      surfaces_[id] = std::move(texture);
      result->Success(flutter::EncodableValue(id));
      return;
    }
    if (call.method_name() == "present") {
      SurfaceTexture* texture = Lookup(arguments);
      const std::string* buffer =
          arguments != nullptr ? StringArgument(*arguments, "buffer") : nullptr;
      const auto slot = arguments != nullptr
                            ? IntArgument(*arguments, "slot")
                            : std::nullopt;
      const auto sequence = arguments != nullptr
                                ? IntArgument(*arguments, "sequence")
                                : std::nullopt;
      if (texture == nullptr || buffer == nullptr || !slot || !sequence ||
          *slot < 0 || *sequence <= 0) {
        result->Error("invalid_frame", "the frame reference is invalid");
        return;
      }
      FrameRequest request;
      request.buffer = Widen(*buffer);
      request.slot = static_cast<uint32_t>(*slot);
      request.sequence = static_cast<uint64_t>(*sequence);
      texture->Present(std::move(request));
      result->Success();
      return;
    }
    if (call.method_name() == "dispose") {
      const auto id = arguments != nullptr
                          ? IntArgument(*arguments, "textureId")
                          : std::nullopt;
      if (id) {
        const auto iterator = surfaces_.find(*id);
        if (iterator != surfaces_.end()) {
          Unregister(std::move(iterator->second));
          surfaces_.erase(iterator);
        }
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  SurfaceTexture* Lookup(const flutter::EncodableMap* arguments) {
    if (arguments == nullptr) return nullptr;
    const auto id = IntArgument(*arguments, "textureId");
    if (!id) return nullptr;
    const auto iterator = surfaces_.find(*id);
    return iterator == surfaces_.end() ? nullptr : iterator->second.get();
  }

  // The raster thread may still be copying; the engine calls back once the
  // texture is really gone.
  void Unregister(std::unique_ptr<SurfaceTexture> texture) {
    if (texture == nullptr) return;
    const int64_t id = texture->id();
    SurfaceTexture* raw = texture.release();
    textures_->UnregisterTexture(id, [raw]() { delete raw; });
  }

  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int64_t, std::unique_ptr<SurfaceTexture>> surfaces_;
};

}  // namespace

void BrowserSurfacePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  BrowserSurfacePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
