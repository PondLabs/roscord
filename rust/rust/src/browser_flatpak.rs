//! Flatpak Matrix presentations: bundled CEF OSR/CPU frames on X11 and
//! Wayland through the Flutter texture path (embedded) and roscord-owned
//! windows (standalone).
//!
//! Both Flatpak compositor cells share one release-authoritative presenter:
//! CEF windowless rendering with CPU `OnPaint` copied into client-owned
//! memory. The payload loads only from the bundled `/app` root: no host CEF,
//! no host WebKitGTK, and no GPU availability is required. User-namespace and
//! seccomp sandboxing stay enforced inside GNOME Platform 48 with
//! least-privilege `finish-args`; file, camera, microphone, and screen
//! capture use XDG portals and portal denial never broadens the sandbox.
//! There is no native child embedding, no dynamic permission broadening, and
//! no host filesystem access.
//!
//! This module owns the pure presentation policy; the Linux `cef_host`
//! enforces it at its OSR callbacks while the Dart `flatpak_presenter`
//! mirrors these rules for adapter tests. Matrix protocol behavior stays in
//! `MatrixWidgetAdapter`; only typed [`crate::browser_runtime`] commands,
//! frame references, and owned-window state cross this seam.

use crate::browser_runtime::{FrameReference, PixelFormat, RuntimeError};

/// The only supported backend name for Flatpak surfaces.
pub const FLATPAK_BACKEND: &str = "cef-osr-cpu";

/// Bundled CEF payload root inside the Flatpak sandbox.
pub const FLATPAK_CEF_BUNDLE_ROOT: &str = "/app";

/// Bundled CEF library resolved from the payload (never a host path).
pub const FLATPAK_CEF_LIBRARY_PATH: &str = "/app/cef/libcef.so";

/// Embedded presentation path (Flutter texture).
pub const FLATPAK_EMBEDDED_PRESENTATION_PATH: &str = "osr-cpu-flutter-texture";

/// Standalone presentation path (roscord-owned window).
pub const FLATPAK_STANDALONE_PRESENTATION_PATH: &str = "osr-cpu-owned-window";

/// Required Flatpak compositor cells. Unknown compositors fail closed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlatpakCompositor {
    X11,
    Wayland,
}

/// Flatpak presentation modes sharing the same OSR/CPU engine.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlatpakPresentation {
    Embedded,
    Standalone,
}

/// Release-authoritative rendering. CPU/OSR is the only production value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlatpakRendering {
    CpuOsr,
}

/// Owned-window stacking requested by the app.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlatpakStandaloneZOrder {
    Background,
    Normal,
    Foreground,
}

/// Parses the compositor from the session type. Matching is exact and
/// lowercase so an unknown compositor cannot silently select a fallback.
pub fn parse_flatpak_compositor(value: &str) -> Result<FlatpakCompositor, RuntimeError> {
    match value {
        "x11" => Ok(FlatpakCompositor::X11),
        "wayland" => Ok(FlatpakCompositor::Wayland),
        _ => Err(RuntimeError::InvalidSpec(
            "unknown Flatpak compositor; X11 and Wayland are the only cells".into(),
        )),
    }
}

pub fn embedded_presentation_path(compositor: FlatpakCompositor) -> &'static str {
    match compositor {
        FlatpakCompositor::X11 | FlatpakCompositor::Wayland => {
            FLATPAK_EMBEDDED_PRESENTATION_PATH
        }
    }
}

pub fn standalone_presentation_path(compositor: FlatpakCompositor) -> &'static str {
    match compositor {
        FlatpakCompositor::X11 | FlatpakCompositor::Wayland => {
            FLATPAK_STANDALONE_PRESENTATION_PATH
        }
    }
}

pub fn presentation_path(
    compositor: FlatpakCompositor,
    presentation: FlatpakPresentation,
) -> &'static str {
    match presentation {
        FlatpakPresentation::Embedded => embedded_presentation_path(compositor),
        FlatpakPresentation::Standalone => standalone_presentation_path(compositor),
    }
}

pub fn uses_osr_cpu_frames() -> bool {
    true
}

pub fn uses_bundled_cef() -> bool {
    true
}

pub fn uses_host_cef() -> bool {
    false
}

pub fn uses_host_webkitgtk() -> bool {
    false
}

pub fn works_without_gpu() -> bool {
    true
}

pub fn forced_cpu_rendering() -> bool {
    true
}

pub fn uses_native_child_embedding() -> bool {
    false
}

pub fn uses_unowned_browser_window() -> bool {
    false
}

pub fn requires_portals() -> bool {
    true
}

pub fn uses_user_namespace_sandbox() -> bool {
    true
}

pub fn uses_seccomp_sandbox() -> bool {
    true
}

/// Portal denial never broadens the sandbox.
pub fn portal_denial_broadens_sandbox() -> bool {
    false
}

/// Capabilities that must go through XDG portals on Flatpak.
pub fn uses_portal_for_capability(capability: &str) -> bool {
    matches!(
        capability,
        "camera"
            | "microphone"
            | "camera+microphone"
            | "display_video"
            | "display_audio"
            | "display_video+display_audio"
            | "file"
            | "download"
            | "upload"
    )
}

/// Asserts that a portal denial keeps the sandbox intact.
pub fn assert_portal_denial_keeps_sandbox(sandbox_broadened: bool) -> Result<(), RuntimeError> {
    if sandbox_broadened {
        return Err(RuntimeError::InvalidCommand(
            "portal denial must never broaden the Flatpak sandbox".into(),
        ));
    }
    Ok(())
}

/// Resolves the bundled CEF library path. Only paths under `/app` resolve.
pub fn resolve_cef_bundle_path(path: &str) -> Result<&str, RuntimeError> {
    if path.is_empty() {
        return Err(RuntimeError::InvalidSpec(
            "Flatpak CEF bundle path is empty; CEF loads only from /app".into(),
        ));
    }
    if !path.starts_with("/app/") {
        return Err(RuntimeError::InvalidCommand(
            "Flatpak CEF loads only from the bundled /app payload".into(),
        ));
    }
    if path.contains("..") || path.contains('\0') || path.chars().any(|c| c.is_control()) {
        return Err(RuntimeError::InvalidSpec(
            "Flatpak CEF bundle path is not a safe /app path".into(),
        ));
    }
    Ok(path)
}

/// Returns true for host CEF locations that must never back a Flatpak surface.
pub fn is_host_cef_path(path: &str) -> bool {
    let lowered = path.to_ascii_lowercase();
    lowered.starts_with("/usr/lib")
        || lowered.starts_with("/usr/local/lib")
        || lowered.starts_with("/opt/")
        || lowered.starts_with("/run/host")
        || lowered.starts_with("/host")
        || lowered.contains("host cef")
        || lowered.contains("host-cef")
}

/// Returns true for host WebKitGTK locations that must never back a surface.
pub fn is_host_webkitgtk_path(path: &str) -> bool {
    let lowered = path.to_ascii_lowercase();
    lowered.contains("webkit")
        || lowered.contains("wry")
        || (lowered.starts_with("/usr/lib") && lowered.contains("gtk"))
}

/// Backend names that must never back a Flatpak surface.
pub fn is_forbidden_backend(name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    lowered.contains("webkit")
        || lowered.contains("wry")
        || lowered.contains("webview2")
        || lowered.contains("system cef")
        || lowered.contains("system-cef")
        || lowered.contains("host cef")
        || lowered.contains("host-cef")
        || lowered.contains("host webkit")
        || lowered.contains("host-webkit")
        || lowered.contains("external chromium")
        || lowered.contains("external-chromium")
        || lowered.contains("chromium external")
        || lowered.contains("unowned browser")
        || lowered.contains("unowned-browser")
        || lowered.contains("unowned window")
        || lowered.contains("unowned-window")
        || lowered.contains("unowned")
        || lowered.contains("native child")
        || lowered.contains("native-child")
        || lowered.contains("child embedding")
        || lowered.contains("child-embedding")
        || lowered.contains("child")
}

/// Rejects fallback engines, host engines, child embedding, and unowned
/// windows without guessing an alternative.
pub fn assert_no_fallback_engine(name: &str) -> Result<(), RuntimeError> {
    if is_forbidden_backend(name) {
        return Err(RuntimeError::InvalidCommand(
            "fallback engines, host engines, child embedding, and unowned windows are not used for Flatpak surfaces"
                .into(),
        ));
    }
    Ok(())
}

/// Resolves the requested backend to the single supported value.
pub fn resolve_flatpak_backend(requested: &str) -> Result<&'static str, RuntimeError> {
    assert_no_fallback_engine(requested)?;
    if requested == FLATPAK_BACKEND || requested == "cef" {
        return Ok(FLATPAK_BACKEND);
    }
    Err(RuntimeError::InvalidSpec(
        "unknown Flatpak backend; cef-osr-cpu is the only backend".into(),
    ))
}

/// Returns true for `finish-args` values that violate least privilege.
pub fn is_forbidden_finish_arg(arg: &str) -> bool {
    let lowered = arg.to_ascii_lowercase();
    lowered.contains("--device=all")
        || lowered.contains("filesystem=host")
        || lowered.contains("filesystem=home")
        || lowered.contains("/run/host")
        || lowered.contains("host-os")
        || lowered.contains("flatpak-spawn")
        || lowered.contains("org.freedesktop.flatpak.spawn")
        || lowered.contains("dynamic permission")
        || lowered.contains("broadening")
}

/// Validates a `finish-args` list against least privilege.
pub fn validate_finish_args(args: &[&str]) -> Result<(), RuntimeError> {
    for arg in args {
        if is_forbidden_finish_arg(arg) {
            return Err(RuntimeError::InvalidCommand(
                "Flatpak finish-args broaden the sandbox beyond least privilege".into(),
            ));
        }
    }
    const REQUIRED: &[&str] = &[
        "--share=ipc",
        "--socket=fallback-x11",
        "--socket=wayland",
        "--socket=pulseaudio",
        "--share=network",
        "--device=dri",
    ];
    for need in REQUIRED {
        if !args.contains(need) {
            return Err(RuntimeError::InvalidSpec(
                "Flatpak finish-args miss a least-privilege permission".into(),
            ));
        }
    }
    Ok(())
}

/// Returns true for host filesystem paths a Flatpak surface must never touch.
pub fn is_host_filesystem_path(path: &str) -> bool {
    let lowered = path.to_ascii_lowercase();
    lowered.starts_with("/host")
        || lowered.starts_with("/run/host")
        || lowered.starts_with("/home/")
        || lowered == "/home"
        || lowered.starts_with("/root")
        || (lowered.contains("/usr/lib") && lowered.contains("cef"))
        || (lowered.contains("/usr/lib") && lowered.contains("webkit"))
        || lowered.contains("host filesystem")
}

/// Rejects host filesystem access without guessing an alternative.
pub fn assert_no_host_filesystem_access(path: &str) -> Result<(), RuntimeError> {
    if is_host_filesystem_path(path) {
        return Err(RuntimeError::InvalidCommand(
            "Flatpak surfaces never access the host filesystem directly".into(),
        ));
    }
    if path.contains("..") && !path.starts_with("/app") {
        return Err(RuntimeError::InvalidCommand(
            "Flatpak surfaces never escape the sandbox via traversal".into(),
        ));
    }
    Ok(())
}

/// Returns true for operations that would dynamically broaden permissions.
pub fn is_dynamic_broadening(operation: &str) -> bool {
    let lowered = operation.to_ascii_lowercase();
    lowered.contains("flatpak-spawn")
        || lowered.contains("flatpak override")
        || lowered.contains("dynamic permission")
        || lowered.contains("broaden")
        || lowered.contains("add device")
        || lowered.contains("add filesystem")
        || lowered.contains("add talk-name")
        || lowered.contains("widen the manifest")
}

/// Rejects dynamic permission broadening.
pub fn assert_no_dynamic_broadening(operation: &str) -> Result<(), RuntimeError> {
    if is_dynamic_broadening(operation) {
        return Err(RuntimeError::InvalidCommand(
            "Flatpak permissions are never broadened dynamically".into(),
        ));
    }
    Ok(())
}

/// Validates one OSR/CPU frame reference for the Flatpak paths.
#[allow(clippy::too_many_arguments)]
pub fn validate_flatpak_frame(
    slot: i64,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    sequence: u64,
    max_frame_bytes: usize,
) -> Result<FrameReference, RuntimeError> {
    if slot < 0 {
        return Err(RuntimeError::InvalidCommand("frame slot is negative".into()));
    }
    let frame = FrameReference::new(
        u32::try_from(slot).map_err(|_| RuntimeError::InvalidCommand("frame slot is negative".into()))?,
        width,
        height,
        stride,
        format,
        sequence,
    )?;
    if max_frame_bytes == 0 {
        return Err(RuntimeError::InvalidCommand(
            "frame budget must be positive".into(),
        ));
    }
    let bytes = (stride as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| RuntimeError::InvalidCommand("frame size overflows".into()))?;
    if bytes > max_frame_bytes {
        return Err(RuntimeError::InvalidCommand(
            "frame exceeds the client-owned frame budget".into(),
        ));
    }
    Ok(frame)
}

/// Owned-window geometry shared by both Flatpak compositor cells.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlatpakWindowGeometry {
    pub x: f64,
    pub y: f64,
    pub width: u32,
    pub height: u32,
    pub device_scale_factor: f64,
    pub visible: bool,
    pub z_order: FlatpakStandaloneZOrder,
}

impl FlatpakWindowGeometry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        x: f64,
        y: f64,
        width: u32,
        height: u32,
        device_scale_factor: f64,
        visible: bool,
        z_order: FlatpakStandaloneZOrder,
    ) -> Result<Self, RuntimeError> {
        if !x.is_finite() || !y.is_finite() {
            return Err(RuntimeError::InvalidCommand(
                "standalone window origin must be finite".into(),
            ));
        }
        if width == 0 || height == 0 {
            return Err(RuntimeError::InvalidCommand(
                "standalone window size must be positive".into(),
            ));
        }
        if !device_scale_factor.is_finite() || device_scale_factor <= 0.0 {
            return Err(RuntimeError::InvalidCommand(
                "standalone window scale must be positive".into(),
            ));
        }
        Ok(Self {
            x,
            y,
            width,
            height,
            device_scale_factor,
            visible,
            z_order,
        })
    }
}

/// Owned-window state for one Flatpak standalone surface.
#[derive(Clone, Debug, PartialEq)]
pub struct FlatpakWindowState {
    pub geometry: FlatpakWindowGeometry,
    pub focused: bool,
    pub closed: bool,
    pub host_lost: bool,
    pub pending_frame_sequence: Option<u64>,
}

impl FlatpakWindowState {
    pub fn new(geometry: FlatpakWindowGeometry, focused: bool) -> Self {
        Self {
            geometry,
            focused,
            closed: false,
            host_lost: false,
            pending_frame_sequence: None,
        }
    }

    pub fn is_reconnecting(&self) -> bool {
        self.host_lost && !self.closed
    }

    pub fn note_frame(&mut self, sequence: u64) {
        if self.closed {
            return;
        }
        self.pending_frame_sequence = Some(sequence);
    }

    pub fn take_frame(&mut self) -> Option<u64> {
        self.pending_frame_sequence.take()
    }

    pub fn note_host_lost(&mut self) {
        if self.closed {
            return;
        }
        self.host_lost = true;
        self.pending_frame_sequence = None;
    }

    pub fn close(&mut self) -> Result<(), RuntimeError> {
        if self.closed {
            return Err(RuntimeError::StaleSurface(crate::browser_runtime::SurfaceId(0)));
        }
        self.closed = true;
        self.pending_frame_sequence = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_runtime::DEFAULT_MAX_FRAME_BYTES;

    #[test]
    fn both_compositors_and_presentations_share_the_bundled_osr_cpu_path() {
        assert_eq!(parse_flatpak_compositor("x11"), Ok(FlatpakCompositor::X11));
        assert_eq!(
            parse_flatpak_compositor("wayland"),
            Ok(FlatpakCompositor::Wayland)
        );
        assert_eq!(
            embedded_presentation_path(FlatpakCompositor::X11),
            "osr-cpu-flutter-texture"
        );
        assert_eq!(
            embedded_presentation_path(FlatpakCompositor::Wayland),
            "osr-cpu-flutter-texture"
        );
        assert_eq!(
            standalone_presentation_path(FlatpakCompositor::X11),
            "osr-cpu-owned-window"
        );
        assert_eq!(
            standalone_presentation_path(FlatpakCompositor::Wayland),
            "osr-cpu-owned-window"
        );
        assert_eq!(
            presentation_path(FlatpakCompositor::X11, FlatpakPresentation::Embedded),
            "osr-cpu-flutter-texture"
        );
        assert_eq!(
            presentation_path(FlatpakCompositor::Wayland, FlatpakPresentation::Standalone),
            "osr-cpu-owned-window"
        );
        assert!(uses_osr_cpu_frames());
        assert!(uses_bundled_cef());
        assert!(!uses_host_cef());
        assert!(!uses_host_webkitgtk());
        assert!(works_without_gpu());
        assert!(forced_cpu_rendering());
        assert!(!uses_native_child_embedding());
        assert!(!uses_unowned_browser_window());
        assert!(requires_portals());
        assert!(uses_user_namespace_sandbox());
        assert!(uses_seccomp_sandbox());
        assert!(!portal_denial_broadens_sandbox());
    }

    #[test]
    fn unknown_compositors_fail_closed() {
        for unknown in ["", "unknown", "X11", "WAYLAND", "mir"] {
            assert!(parse_flatpak_compositor(unknown).is_err(), "{unknown}");
        }
    }

    #[test]
    fn bundled_cef_resolves_only_under_app() {
        assert_eq!(
            resolve_cef_bundle_path("/app/cef/libcef.so"),
            Ok("/app/cef/libcef.so")
        );
        for bad in [
            "",
            "/usr/lib/libcef.so",
            "/opt/cef/libcef.so",
            "/run/host/usr/lib/libcef.so",
            "/host/app/libcef.so",
            "/app/../host/libcef.so",
        ] {
            assert!(resolve_cef_bundle_path(bad).is_err(), "{bad}");
        }
        assert!(is_host_cef_path("/usr/lib/x86_64-linux-gnu/libcef.so"));
        assert!(is_host_cef_path("/run/host/usr/lib/libcef.so"));
        assert!(!is_host_cef_path("/app/cef/libcef.so"));
        assert!(is_host_webkitgtk_path("/usr/lib/webkit2gtk-4.1/libwebkit.so"));
        assert!(!is_host_webkitgtk_path("/app/cef/libcef.so"));
    }

    #[test]
    fn portals_cover_file_and_capture_and_denial_keeps_the_sandbox() {
        for capability in [
            "camera",
            "microphone",
            "display_video",
            "display_audio",
            "file",
            "download",
            "upload",
        ] {
            assert!(uses_portal_for_capability(capability), "{capability}");
        }
        assert!(!uses_portal_for_capability("geolocation"));
        assert!(assert_portal_denial_keeps_sandbox(false).is_ok());
        assert!(assert_portal_denial_keeps_sandbox(true).is_err());
    }

    #[test]
    fn finish_args_enforce_least_privilege_without_broadening() {
        let least_privilege = [
            "--share=ipc",
            "--socket=fallback-x11",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--share=network",
            "--device=dri",
        ];
        assert!(validate_finish_args(&least_privilege).is_ok());
        for bad in [
            "--device=all",
            "--filesystem=host",
            "--filesystem=home",
            "--filesystem=xdg-download --device=all",
            "flatpak-spawn --host sh",
        ] {
            assert!(is_forbidden_finish_arg(bad), "{bad}");
        }
        let with_broadening = [
            "--share=ipc",
            "--socket=fallback-x11",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--share=network",
            "--device=all",
        ];
        assert!(validate_finish_args(&with_broadening).is_err());
        let missing_dri = [
            "--share=ipc",
            "--socket=fallback-x11",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--share=network",
        ];
        assert!(validate_finish_args(&missing_dri).is_err());
    }

    #[test]
    fn host_filesystem_and_dynamic_broadening_are_rejected() {
        for path in [
            "/run/host/usr/lib/libcef.so",
            "/host/home/user/Downloads/x",
            "/home/user/.config/cef",
            "/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/libwebkit.so",
        ] {
            assert!(is_host_filesystem_path(path), "{path}");
            assert!(assert_no_host_filesystem_access(path).is_err(), "{path}");
        }
        assert!(!is_host_filesystem_path("/app/cef/libcef.so"));
        assert!(assert_no_host_filesystem_access("/app/cef/libcef.so").is_ok());
        for operation in [
            "flatpak-spawn --host sh",
            "flatpak override --device=all",
            "broaden permissions after denial",
            "add filesystem=xdg-download after denial",
        ] {
            assert!(is_dynamic_broadening(operation), "{operation}");
            assert!(assert_no_dynamic_broadening(operation).is_err(), "{operation}");
        }
        assert!(!is_dynamic_broadening("show portal chooser"));
    }

    #[test]
    fn frame_validation_rejects_bad_geometry_and_over_budget_frames() {
        assert!(
            validate_flatpak_frame(
                0,
                64,
                48,
                256,
                PixelFormat::BgraPremultiplied,
                1,
                DEFAULT_MAX_FRAME_BYTES
            )
            .is_ok()
        );
        assert!(
            validate_flatpak_frame(
                -1,
                64,
                48,
                256,
                PixelFormat::BgraPremultiplied,
                1,
                DEFAULT_MAX_FRAME_BYTES
            )
            .is_err()
        );
        assert!(
            validate_flatpak_frame(
                0,
                4096,
                4096,
                16384,
                PixelFormat::BgraPremultiplied,
                1,
                1024
            )
            .is_err()
        );
    }

    #[test]
    fn only_cef_osr_cpu_resolves() {
        assert_eq!(resolve_flatpak_backend("cef-osr-cpu"), Ok(FLATPAK_BACKEND));
        assert_eq!(resolve_flatpak_backend("cef"), Ok(FLATPAK_BACKEND));
        for requested in ["native", "wayland-child", "gpu", "host cef", ""] {
            assert!(resolve_flatpak_backend(requested).is_err(), "{requested}");
        }
    }

    #[test]
    fn fallback_host_engines_child_embedding_and_unowned_windows_are_rejected() {
        for name in [
            "WebKitGTK",
            "webkit2gtk",
            "wry",
            "system CEF",
            "host CEF",
            "host-cef",
            "external Chromium",
            "WebView2",
            "unowned browser",
            "native child",
            "wayland child embedding",
        ] {
            assert!(is_forbidden_backend(name), "{name}");
            assert!(assert_no_fallback_engine(name).is_err(), "{name}");
            assert!(resolve_flatpak_backend(name).is_err(), "{name}");
        }
        assert!(!is_forbidden_backend("cef-osr-cpu"));
        assert!(!is_forbidden_backend("cef"));
    }

    #[test]
    fn standalone_window_state_tracks_host_loss_without_new_host() {
        let geometry =
            FlatpakWindowGeometry::new(10.0, 20.0, 800, 600, 2.0, true, FlatpakStandaloneZOrder::Normal)
                .unwrap();
        let mut state = FlatpakWindowState::new(geometry, false);
        state.note_frame(7);
        assert_eq!(state.pending_frame_sequence, Some(7));
        state.note_host_lost();
        assert!(state.is_reconnecting());
        assert_eq!(state.pending_frame_sequence, None);
        assert!(state.close().is_ok());
        assert!(!state.is_reconnecting());
        assert!(state.close().is_err());
    }
}
