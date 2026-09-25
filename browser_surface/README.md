# browser_surface

Presents frames from roscord's out-of-process CEF host (`cef_host`) as Flutter
textures, on Linux and Windows.

The host copies every off-screen paint into a shared-memory frame ring (POSIX
shared memory on Linux, a named file mapping on Windows) and reports the ring,
slot and sequence in a `frame_ready` event. `BrowserSurfaceTexture.present`
hands that reference to the plugin, and the raster thread copies the slot into
the texture, dropping frames the host has already replaced.

`native/` holds headers shared with the hosts:

- `browser_frame_ring.h`: the ring layout, and the writer and reader.
- `browser_input.h`: mapping BrowserRuntime input to CEF key codes and event flags.
- `cef_cursor_names.h`: CEF cursor types as CSS cursor names.
