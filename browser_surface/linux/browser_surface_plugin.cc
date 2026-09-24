#include "include/browser_surface/browser_surface_plugin.h"

#include <fcntl.h>
#include <flutter_linux/flutter_linux.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "browser_frame_ring.h"

namespace {

// Rings are created by cef_host as /roscord-cef-<namespace>-<surface>-<gen>.
constexpr char kRingPrefix[] = "/roscord-cef-";

bool IsRingName(const std::string& name) {
  return name.size() > sizeof(kRingPrefix) - 1 && name.size() < 255 &&
         name.compare(0, sizeof(kRingPrefix) - 1, kRingPrefix) == 0 &&
         name.find('/', 1) == std::string::npos;
}

// The frame the app asked for last, shared between the platform thread
// (present) and the raster thread (copy_pixels).
struct FrameRequest {
  std::string buffer;
  uint32_t slot = 0;
  uint64_t sequence = 0;
};

struct TextureState {
  std::mutex mutex;
  FrameRequest request;
  bool has_request = false;

  // Raster thread only.
  std::string mapped_name;
  void* mapped = nullptr;
  size_t mapped_bytes = 0;
  std::vector<uint8_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;

  void Unmap() {
    if (mapped != nullptr) munmap(mapped, mapped_bytes);
    mapped = nullptr;
    mapped_bytes = 0;
    mapped_name.clear();
  }

  // Maps the host's ring read-only.  The ring must belong to this user and
  // be private to it, like the host created it.
  void Map(const std::string& name) {
    Unmap();
    if (!IsRingName(name)) return;
    const int fd = shm_open(name.c_str(), O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) return;
    struct stat info {};
    if (fstat(fd, &info) != 0 || info.st_uid != geteuid() ||
        (info.st_mode & 077) != 0 ||
        info.st_size < static_cast<off_t>(browser_surface::kFrameRingHeaderBytes)) {
      close(fd);
      return;
    }
    void* region = mmap(nullptr, static_cast<size_t>(info.st_size), PROT_READ,
                        MAP_SHARED, fd, 0);
    close(fd);
    if (region == MAP_FAILED) return;
    mapped = region;
    mapped_bytes = static_cast<size_t>(info.st_size);
    mapped_name = name;
  }

  ~TextureState() { Unmap(); }
};

}  // namespace

// ---------------------------------------------------------------------------
// BrowserSurfaceTexture: an FlPixelBufferTexture fed from the frame ring.

G_DECLARE_FINAL_TYPE(BrowserSurfaceTexture, browser_surface_texture,
                     BROWSER_SURFACE, TEXTURE, FlPixelBufferTexture)

struct _BrowserSurfaceTexture {
  FlPixelBufferTexture parent_instance;
  TextureState* state;
};

G_DEFINE_TYPE(BrowserSurfaceTexture, browser_surface_texture,
              fl_pixel_buffer_texture_get_type())

// Runs on the raster thread whenever the texture was marked available.
static gboolean browser_surface_texture_copy_pixels(
    FlPixelBufferTexture* texture, const uint8_t** out_buffer,
    uint32_t* width, uint32_t* height, GError** error) {
  TextureState* state = BROWSER_SURFACE_TEXTURE(texture)->state;
  FrameRequest request;
  bool has_request = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->has_request) {
      request = state->request;
      has_request = true;
      state->has_request = false;
    }
  }
  if (has_request) {
    if (request.buffer != state->mapped_name) state->Map(request.buffer);
    if (state->mapped != nullptr) {
      const auto* header = browser_surface::FrameRingValidate(
          state->mapped, state->mapped_bytes);
      if (header != nullptr && state->pixels.size() < header->slot_bytes) {
        state->pixels.resize(header->slot_bytes);
      }
      uint32_t frame_width = 0;
      uint32_t frame_height = 0;
      // A frame the host already replaced is skipped; the texture keeps the
      // previous one until the next request.
      if (header != nullptr &&
          browser_surface::FrameRingRead(
              state->mapped, state->mapped_bytes, request.slot,
              request.sequence, state->pixels.data(), state->pixels.size(),
              &frame_width, &frame_height)) {
        state->width = frame_width;
        state->height = frame_height;
      }
    }
  }
  if (state->width == 0 || state->height == 0) {
    // Nothing presented yet: one transparent pixel.
    state->pixels.assign(4, 0);
    state->width = 1;
    state->height = 1;
  }
  *out_buffer = state->pixels.data();
  *width = state->width;
  *height = state->height;
  return TRUE;
}

static void browser_surface_texture_dispose(GObject* object) {
  BrowserSurfaceTexture* self = BROWSER_SURFACE_TEXTURE(object);
  delete self->state;
  self->state = nullptr;
  G_OBJECT_CLASS(browser_surface_texture_parent_class)->dispose(object);
}

static void browser_surface_texture_class_init(
    BrowserSurfaceTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      browser_surface_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = browser_surface_texture_dispose;
}

static void browser_surface_texture_init(BrowserSurfaceTexture* self) {
  self->state = new TextureState();
}

// ---------------------------------------------------------------------------
// BrowserSurfacePlugin: the method channel.

#define BROWSER_SURFACE_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), browser_surface_plugin_get_type(), \
                              BrowserSurfacePlugin))

struct _BrowserSurfacePlugin {
  GObject parent_instance;
  FlTextureRegistrar* registrar;
  std::map<int64_t, BrowserSurfaceTexture*>* textures;
};

G_DEFINE_TYPE(BrowserSurfacePlugin, browser_surface_plugin, g_object_get_type())

static FlValue* LookupArgument(FlValue* args, const char* key,
                               FlValueType type) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == type ? value
                                                              : nullptr;
}

static BrowserSurfaceTexture* LookupTexture(BrowserSurfacePlugin* self,
                                            FlValue* args) {
  FlValue* id = LookupArgument(args, "textureId", FL_VALUE_TYPE_INT);
  if (id == nullptr) return nullptr;
  const auto iterator = self->textures->find(fl_value_get_int(id));
  return iterator == self->textures->end() ? nullptr : iterator->second;
}

static FlMethodResponse* Create(BrowserSurfacePlugin* self) {
  auto* texture = BROWSER_SURFACE_TEXTURE(
      g_object_new(browser_surface_texture_get_type(), nullptr));
  if (!fl_texture_registrar_register_texture(self->registrar,
                                             FL_TEXTURE(texture))) {
    g_object_unref(texture);
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "texture_unavailable", "the texture could not be registered",
        nullptr));
  }
  const int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
  (*self->textures)[id] = texture;
  g_autoptr(FlValue) result = fl_value_new_int(id);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* Present(BrowserSurfacePlugin* self, FlValue* args) {
  BrowserSurfaceTexture* texture = LookupTexture(self, args);
  FlValue* buffer = LookupArgument(args, "buffer", FL_VALUE_TYPE_STRING);
  FlValue* slot = LookupArgument(args, "slot", FL_VALUE_TYPE_INT);
  FlValue* sequence = LookupArgument(args, "sequence", FL_VALUE_TYPE_INT);
  if (texture == nullptr || buffer == nullptr || slot == nullptr ||
      sequence == nullptr || fl_value_get_int(slot) < 0 ||
      fl_value_get_int(sequence) <= 0) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_frame", "the frame reference is invalid", nullptr));
  }
  {
    std::lock_guard<std::mutex> lock(texture->state->mutex);
    texture->state->request.buffer = fl_value_get_string(buffer);
    texture->state->request.slot =
        static_cast<uint32_t>(fl_value_get_int(slot));
    texture->state->request.sequence =
        static_cast<uint64_t>(fl_value_get_int(sequence));
    texture->state->has_request = true;
  }
  fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                    FL_TEXTURE(texture));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// The raster thread may still be inside copy_pixels for a texture that was
// just unregistered, so the last reference is dropped a little later.
static gboolean ReleaseTextureLater(gpointer texture) {
  g_object_unref(texture);
  return G_SOURCE_REMOVE;
}

static void Unregister(BrowserSurfacePlugin* self,
                       BrowserSurfaceTexture* texture) {
  fl_texture_registrar_unregister_texture(self->registrar,
                                          FL_TEXTURE(texture));
  g_timeout_add_seconds(1, ReleaseTextureLater, texture);
}

static FlMethodResponse* Dispose(BrowserSurfacePlugin* self, FlValue* args) {
  BrowserSurfaceTexture* texture = LookupTexture(self, args);
  if (texture != nullptr) {
    self->textures->erase(fl_texture_get_id(FL_TEXTURE(texture)));
    Unregister(self, texture);
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void browser_surface_plugin_handle_method_call(
    BrowserSurfacePlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "create") == 0) {
    response = Create(self);
  } else if (strcmp(method, "present") == 0) {
    response = Present(self, args);
  } else if (strcmp(method, "dispose") == 0) {
    response = Dispose(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void browser_surface_plugin_dispose(GObject* object) {
  BrowserSurfacePlugin* self = BROWSER_SURFACE_PLUGIN(object);
  if (self->textures != nullptr) {
    for (const auto& entry : *self->textures) Unregister(self, entry.second);
    delete self->textures;
    self->textures = nullptr;
  }
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(browser_surface_plugin_parent_class)->dispose(object);
}

static void browser_surface_plugin_class_init(
    BrowserSurfacePluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = browser_surface_plugin_dispose;
}

static void browser_surface_plugin_init(BrowserSurfacePlugin* self) {
  self->textures = new std::map<int64_t, BrowserSurfaceTexture*>();
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  browser_surface_plugin_handle_method_call(BROWSER_SURFACE_PLUGIN(user_data),
                                            method_call);
}

void browser_surface_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  BrowserSurfacePlugin* plugin = BROWSER_SURFACE_PLUGIN(
      g_object_new(browser_surface_plugin_get_type(), nullptr));
  plugin->registrar = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "browser_surface", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
