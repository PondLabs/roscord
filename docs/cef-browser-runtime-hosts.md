# How the CEF hosts run

The other `cef-browser-runtime-*` notes describe the contract: policy,
profiles, media, recovery, packaging. This one describes the machinery behind
it: how each host drives CEF, how frames and input travel, how the hosts are
built and tested, and what to check when CEF is updated.

## Processes

The app starts one host per app process, lazily, on the first surface open.
Every surface shares it. Browsers are Alloy-style and windowless (CEF
off-screen rendering).

- **Windows**: `cef_host/cef_host.exe` is the locked CEF `bootstrap.exe`.
  Renamed, the bootstrap loads the DLL named after itself from its own
  directory, `cef_host.dll` (`commet/windows/cef_host/cef_host.cpp`).
  `--module` only applies while it is still called `bootstrap.exe`. The DLL
  must be signed with the bootstrap's certificate, or both must be unsigned,
  as the locked build is. The app talks to the host over a named pipe. The host
  creates the pipe with overlapped I/O, `FILE_FLAG_FIRST_PIPE_INSTANCE` and
  `PIPE_REJECT_REMOTE_CLIENTS`. Synchronous pipe handles serialize reads and
  writes across threads, so an event could not be sent while a read was
  pending.
- **Linux**: `cef_host` is Rust (`rust/rust/src/cef_host.rs`). It owns launch
  validation, the protocol, surface policy, profiles and the Unix-socket
  transport. It `dlopen`s `cef/Release/libcef.so` and then
  `lib/libroscord_cef_engine.so`, a small C++ library on CEF's C++ wrapper
  (`commet/linux/cef_engine/`), through a C ABI (`roscord_cef_engine.h`,
  checked by version). The engine has no link-time dependency on libcef, so
  nothing CEF is loaded from anywhere but the validated runtime. Chromium
  re-executes `cef_host` for its child processes (zygote, renderer, GPU,
  utilities) without the host's arguments. The children find the runtime
  through `ROSCORD_CEF_ROOT` and validate it again.

## Frames

Each surface has a shared-memory frame ring, laid out in
`browser_surface/native/browser_frame_ring.h`:

- a 4096-byte header page;
- three slots, each large enough for one frame (page-rounded);
- per slot, a seqlock (begin/end sequence) and the frame's width and height.

On every `OnPaint`, the host writes the frame into the next slot, converting
BGRA to RGBA. It then sends `frame_ready` with the ring's name in
`frame.buffer`, plus the slot and sequence.

- **Linux ring**: POSIX shared memory,
  `/roscord-cef-<host pid>-<random>-<surface>-<generation>`. It is created
  exclusively with mode 0600, with its pages allocated up front so a full
  `/dev/shm` drops the frame instead of crashing the host. It is unlinked
  when the surface closes, or when
  a bigger frame needs bigger slots and the ring is replaced by the next
  generation. A starting host removes rings left behind by dead hosts.
- **Windows ring**: a named file mapping, `Local\roscord-cef-...`, replaced
  the same way.

The app's `browser_surface` plugin draws the frames. It is an
`FlPixelBufferTexture` on Linux and a `PixelBufferTexture` on Windows.

- It maps the ring read-only, after checking the name prefix (and, on Linux,
  the owner and mode).
- It copies the requested slot on the raster thread.
- If the host rewrote the slot during the copy, the seqlock check fails and
  the frame is skipped, so a torn frame is never shown.
- Pixels never cross the platform channel or reach Dart. Dart only passes
  `(ring, slot, sequence, size)` to the plugin.

The Linux host paints at 30 fps by default (`ROSCORD_CEF_FRAME_RATE`, 1 to
60).

## Input

`EmbeddedBrowserView` drives the surface.

**What it sends:**

- its size and device pixel ratio, once the host is ready;
- pointer down and up, naming the button that changed;
- moves and hovers, and a leave when the pointer exits;
- wheel and trackpad pans;
- focus;
- keys as W3C `key` and `code` values with modifier bits, plus the text
  the press typed (`typedText`).

Escape also reaches the app, which uses it to close the dialog.

**What the hosts do with it:**

- translate `code` into Windows virtual-key and scan codes, and into X11
  evdev codes (`browser_surface/native/browser_input.h`);
- count clicks;
- send character events for the text a press typed.

The text comes from the platform's keyboard layout, so AltGr characters and
Windows dead keys type correctly. Windows reports AltGr as Ctrl+Alt, so a
rule based on modifiers would block them.

The page's cursor comes back as `cursor_changed` (a CSS keyword), and the view
shows the matching Flutter cursor.

**What else the hosts handle:**

- **Windows** mediates downloads, uploads and media permissions through
  request events the app answers.
- **The Linux engine** clears context menus, suppresses JavaScript dialogs,
  and denies file dialogs, permission prompts and downloads outright. It also
  composites `<select>` drop-downs into the frame.

## Popups

A page that opens a new window (`target=_blank`, `window.open`) produces a
`popup_request`. `MediaEmbedSession` answers it:

- if the user clicked ("Watch on YouTube", a channel link), it opens the URL
  in the system browser;
- otherwise it denies the popup.

Navigation follows the surface policy. On Windows the policy applies to
every frame. On Linux it applies to the main frame, and sub-frames (the
provider's player inside the embed page) may load `https`, `http`, `about`,
`data` and `blob` URLs.

## Chromium switches

Both hosts pass:

- `--no-first-run` and `--no-default-browser-check`. Without them, Chrome's
  first run on Linux shows a modal EULA dialog, and CEF never reports its
  context as initialized.
- `--autoplay-policy=no-user-gesture-required`, so embeds autoplay as they
  did in the old web views.

The Linux host also passes:

- `--ozone-platform=headless`, so off-screen rendering needs neither X11 nor
  Wayland. Override it with `ROSCORD_CEF_OZONE_PLATFORM`.
- `--password-store=basic`.

`--cef-software-rendering` (a host flag) adds the software GPU switches.

`root_cache_path` is the profile root. Each account's request context, and
each private surface's, lives below it.

## Building and packaging

**Runtime staging.** `tools/cef_runtime.py stage` stages the runtime, and
`--strip` strips the Linux libraries (`libcef.so` goes from 1.4 GB to
268 MB). Staged runtimes are flat on both platforms. CEF loads `icudtl.dat`,
the `.pak` files and `locales/` from the directory that holds `libcef`,
whatever `CefSettings` says, so staging moves the archive's `Resources/` into
`Release/` (`STAGED_PREFIXES`). The Windows install does the same, next to
`libcef.dll`. Without ICU data there, the host dies in `InitializeICU`.

**Build SDK.** `stage-sdk` stages the build SDK for both platforms: the
lock's `build_sdk` record (`cmake/`, `include/`, `libcef_dll/` on Linux).

**Linux build.** `commet/linux/CMakeLists.txt` does this when
`ROSCORD_BUILD_CEF_HOST=ON`:

- builds `cef_host` with cargo;
- builds the engine as an ExternalProject against `ROSCORD_CEF_SDK_ROOT`;
- installs `cef_host`, `lib/libroscord_cef_engine.so` and the staged runtime
  (`ROSCORD_CEF_RUNTIME_DIR`) as `cef/`.

The engine pins CEF's `api_version` (15200 for CEF 152). Without the pin, the
wrapper builds against the experimental API.

**CI.** `desktop-build.yml` does the following:

- caches the locked archives;
- stages the Linux SDK and the stripped runtime;
- builds;
- runs `tools/cef_host_smoke.py` against both bundles.

## Updating CEF

1. Update both platform records in `third_party/cef/cef.lock.json`: version,
   URLs, sizes, SHA-1 and SHA-256, and raw manifest digests. Then run
   `python3 tools/cef_runtime.py validate-lock`, `fetch-pair` and `verify`.
2. Move the Linux engine's `api_version`
   (`commet/linux/cef_engine/CMakeLists.txt`) to the new branch's stable API
   version (branch number x 100). Windows builds with
   `CEF_API_VERSION_LAST`.
3. Rebuild. Fix what the new CEF headers break in `roscord_cef_engine.cc` and
   `cef_host.cpp`.
4. Dispatch `desktop-build.yml` for Windows and Linux. Its smoke tests open a
   page in each host. Then play a YouTube embed in the app.

## Testing

- `python3 tools/cef_host_smoke.py --bundle <bundle>` acts as the app. It
  opens the fixture page, checks that frames arrive and are not blank, closes
  the surface, and checks that the host exits.
- Smoke-test options: `--youtube <video id>` opens the YouTube wrapper,
  `--png out.png` saves the newest frame, and `--click`/`--hover` send input.
  CI adds `--software`.
- `--type TEXT` types into the fixture's input field. It sends `@` the way
  Windows reports AltGr.
  - The page turns green only when the text arrived and every key press
    carried a `KeyboardEvent.code`.
  - It also lists the key events it received, which shows up in `--png`
    frames.
- `ROSCORD_CEF_HOST_LOG=<file>` makes the Linux host log its process starts
  and lifecycle. The Windows host writes the stage that stopped it there, and
  on stderr, when it exits before opening its pipe. `ROSCORD_CEF_LOG_FILE=<file>`
  turns on CEF's own log on Linux.
- Unit tests:
  - Dart: `unit_test/embedded_browser_surface_test.dart`,
    `browser_input_keys_test.dart`, `media_embed_adapter_test.dart` and
    `browser_runtime_test.dart`;
  - Rust: `cargo test -p rust_lib_commet`;
  - Python: `tools/test_cef_*.py`.

## Provisions for ad blocking

These exist but are off. They are where adblock-rust would plug in.

- **Network filtering.** The Linux engine takes `filter_requests` in its
  config. When it is on, every resource request goes through the
  `filter_request` callback, and returning true cancels the request.
  `HostShared::filter_request` currently allows everything.
- **Cosmetic filtering and scriptlets.** Each Linux browser can carry a
  `document_start_script`. The renderer evaluates it when a frame's
  JavaScript context is created, before the page's own scripts run.
- **Windows.** The Windows host has neither yet.

## Known limitations

- **Ubuntu 24.04 and other kernels with
  `kernel.apparmor_restrict_unprivileged_userns=1`.** These let a process
  create a user namespace but not map its user inside it, so CEF's sandbox
  needs the setuid `chrome-sandbox` helper (root-owned, mode 4755), which the
  portable bundle cannot have. The host's probe refuses to start there.
  - The app notices (`linuxCefSandboxUsable`) and keeps its old video path:
    mpv through yt-dlp, else the browser.
  - Matrix widgets fail closed.
  - Installing the helper root-owned with mode 4755 fixes it, and the Debian
    package job does that. So does an AppArmor profile that allows `userns`
    for `cef_host`.
- **Input methods.** Keys go through as key events with the text they
  typed. The view does not drive composition from an input method yet (the
  `ime` command exists). Dead keys work on Windows, where the layout composes
  the character. They do not work on Linux, where GTK composes only for text
  fields.
- **Windows `<select>`.** Drop-downs are not composited into the frame yet.
- **Linux standalone surfaces.** The engine only renders off-screen, and
  nothing presents standalone (owned-window) surfaces on Linux.
- **YouTube's embed referrer.** The embed page is served from
  `http://127.0.0.1:<port>`, while Google documents `https://<app id>`
  referrers for embedded apps. The loopback origin plays under CEF 152
  (no error 152 or 153). It is the first thing to check if YouTube starts
  refusing embeds.
- **Flatpak.** The Flatpak manifest does not bundle CEF yet.
