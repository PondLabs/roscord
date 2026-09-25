// Shared-memory frame ring between an out-of-process CEF host (the writer)
// and the browser_surface Flutter plugin (the reader).
//
// A region is one page of headers followed by kFrameRingSlots slots of
// slot_bytes each.  The host copies every OnPaint into the next slot,
// converting CEF's BGRA to the tightly packed RGBA that Flutter pixel-buffer
// textures upload, and then publishes a frame_ready event naming the region,
// slot and sequence.  Nothing is locked across processes: each slot carries a
// seqlock (begin/end sequence), so a reader that races the writer sees a
// mismatch and drops that frame instead of showing a torn one.
//
// The layout is shared by C++17 (plugins) and newer toolchains (hosts), so it
// only uses lock-free std::atomic<uint64_t>, which has the same size and
// representation as uint64_t on every supported target.

#ifndef BROWSER_SURFACE_NATIVE_BROWSER_FRAME_RING_H_
#define BROWSER_SURFACE_NATIVE_BROWSER_FRAME_RING_H_

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

namespace browser_surface {

inline constexpr uint32_t kFrameRingMagic = 0x52464352u;  // "RCFR"
inline constexpr uint32_t kFrameRingVersion = 1u;
inline constexpr uint32_t kFrameRingSlots = 3u;
inline constexpr uint64_t kFrameRingHeaderBytes = 4096u;
// Matches the hosts' own clamp: larger frames are never published.
inline constexpr uint32_t kFrameRingMaxDimension = 8192u;

struct FrameRingSlot {
  // Sequence being written.  Stored before the pixels change.
  std::atomic<uint64_t> begin;
  // Sequence completely written.  Stored after the pixels and size.
  std::atomic<uint64_t> end;
  // Written between begin and end; readers only trust them once end matches.
  std::atomic<uint32_t> width;
  std::atomic<uint32_t> height;
  uint8_t reserved[40];
};

struct FrameRingHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t slot_count;
  uint32_t reserved0;
  uint64_t slot_bytes;
  uint8_t reserved[40];
  FrameRingSlot slots[kFrameRingSlots];
};

static_assert(sizeof(std::atomic<uint64_t>) == sizeof(uint64_t),
              "frame ring atomics must match the shared layout");
static_assert(sizeof(std::atomic<uint32_t>) == sizeof(uint32_t),
              "frame ring atomics must match the shared layout");
static_assert(std::atomic<uint64_t>::is_always_lock_free &&
                  std::atomic<uint32_t>::is_always_lock_free,
              "frame ring atomics must be lock-free across processes");
static_assert(sizeof(FrameRingSlot) == 64, "frame ring slot layout changed");
static_assert(sizeof(FrameRingHeader) == 64 + 64 * kFrameRingSlots,
              "frame ring header layout changed");
static_assert(sizeof(FrameRingHeader) <= kFrameRingHeaderBytes,
              "frame ring header must fit in its page");

inline uint64_t FrameRingRegionBytes(uint64_t slot_bytes) {
  return kFrameRingHeaderBytes + slot_bytes * kFrameRingSlots;
}

// Bytes a slot needs for a width x height RGBA frame, rounded up to a page so
// small resizes do not force a new region.
inline uint64_t FrameRingSlotBytesFor(uint32_t width, uint32_t height) {
  const uint64_t bytes = static_cast<uint64_t>(width) * height * 4u;
  return (bytes + 4095u) & ~static_cast<uint64_t>(4095u);
}

inline uint8_t* FrameRingSlotPixels(void* region, uint64_t slot_bytes,
                                    uint32_t slot) {
  return static_cast<uint8_t*>(region) + kFrameRingHeaderBytes +
         slot_bytes * slot;
}

inline const uint8_t* FrameRingSlotPixels(const void* region,
                                          uint64_t slot_bytes, uint32_t slot) {
  return static_cast<const uint8_t*>(region) + kFrameRingHeaderBytes +
         slot_bytes * slot;
}

// Converts little-endian BGRA words to RGBA while copying.  Alpha and green
// stay in place; red and blue swap.
inline void CopyBgraToRgba(const uint8_t* source, uint8_t* destination,
                           size_t pixel_count) {
  for (size_t index = 0; index < pixel_count; ++index) {
    uint32_t pixel;
    std::memcpy(&pixel, source + index * 4u, sizeof(pixel));
    pixel = (pixel & 0xff00ff00u) | ((pixel >> 16) & 0x000000ffu) |
            ((pixel << 16) & 0x00ff0000u);
    std::memcpy(destination + index * 4u, &pixel, sizeof(pixel));
  }
}

// Writer: formats a zero-filled region of FrameRingRegionBytes(slot_bytes).
inline FrameRingHeader* FrameRingInitialize(void* region,
                                            uint64_t slot_bytes) {
  auto* header = new (region) FrameRingHeader();
  header->magic = kFrameRingMagic;
  header->version = kFrameRingVersion;
  header->slot_count = kFrameRingSlots;
  header->slot_bytes = slot_bytes;
  for (auto& slot : header->slots) {
    slot.begin.store(0, std::memory_order_relaxed);
    slot.end.store(0, std::memory_order_relaxed);
    slot.width.store(0, std::memory_order_relaxed);
    slot.height.store(0, std::memory_order_relaxed);
  }
  std::atomic_thread_fence(std::memory_order_release);
  return header;
}

// Writer: copies one BGRA frame into `slot` as RGBA and publishes `sequence`.
// Returns false when the frame does not fit the region.
inline bool FrameRingWriteBgra(void* region, uint32_t slot, uint64_t sequence,
                               const void* bgra, uint32_t width,
                               uint32_t height) {
  auto* header = static_cast<FrameRingHeader*>(region);
  if (slot >= kFrameRingSlots || width == 0 || height == 0 ||
      width > kFrameRingMaxDimension || height > kFrameRingMaxDimension ||
      static_cast<uint64_t>(width) * height * 4u > header->slot_bytes) {
    return false;
  }
  FrameRingSlot& target = header->slots[slot];
  target.begin.store(sequence, std::memory_order_relaxed);
  std::atomic_thread_fence(std::memory_order_release);
  CopyBgraToRgba(static_cast<const uint8_t*>(bgra),
                 FrameRingSlotPixels(region, header->slot_bytes, slot),
                 static_cast<size_t>(width) * height);
  target.width.store(width, std::memory_order_relaxed);
  target.height.store(height, std::memory_order_relaxed);
  target.end.store(sequence, std::memory_order_release);
  return true;
}

// Reader: validates a mapped region of `region_bytes`.
inline const FrameRingHeader* FrameRingValidate(const void* region,
                                                uint64_t region_bytes) {
  if (region == nullptr || region_bytes < kFrameRingHeaderBytes) {
    return nullptr;
  }
  const auto* header = static_cast<const FrameRingHeader*>(region);
  if (header->magic != kFrameRingMagic ||
      header->version != kFrameRingVersion ||
      header->slot_count != kFrameRingSlots || header->slot_bytes == 0 ||
      header->slot_bytes > region_bytes ||
      FrameRingRegionBytes(header->slot_bytes) > region_bytes) {
    return nullptr;
  }
  return header;
}

// Reader: copies frame `sequence` from `slot` into `out` (tightly packed RGBA,
// `out_capacity` bytes).  Returns false when the slot no longer holds that
// frame or the writer started overwriting it during the copy.
inline bool FrameRingRead(const void* region, uint64_t region_bytes,
                          uint32_t slot, uint64_t sequence, uint8_t* out,
                          uint64_t out_capacity, uint32_t* width,
                          uint32_t* height) {
  const FrameRingHeader* header = FrameRingValidate(region, region_bytes);
  if (header == nullptr || slot >= kFrameRingSlots || sequence == 0) {
    return false;
  }
  const FrameRingSlot& source = header->slots[slot];
  if (source.end.load(std::memory_order_acquire) != sequence) return false;
  const uint32_t frame_width = source.width.load(std::memory_order_relaxed);
  const uint32_t frame_height = source.height.load(std::memory_order_relaxed);
  const uint64_t bytes = static_cast<uint64_t>(frame_width) * frame_height * 4u;
  if (frame_width == 0 || frame_height == 0 ||
      frame_width > kFrameRingMaxDimension ||
      frame_height > kFrameRingMaxDimension || bytes > header->slot_bytes ||
      bytes > out_capacity) {
    return false;
  }
  std::memcpy(out, FrameRingSlotPixels(region, header->slot_bytes, slot),
              static_cast<size_t>(bytes));
  std::atomic_thread_fence(std::memory_order_acquire);
  if (source.begin.load(std::memory_order_relaxed) != sequence) return false;
  *width = frame_width;
  *height = frame_height;
  return true;
}

}  // namespace browser_surface

#endif  // BROWSER_SURFACE_NATIVE_BROWSER_FRAME_RING_H_
