//! Native Linux standalone Matrix presentation: OSR/CPU frames in
//! roscord-owned X11 and Wayland windows.
//!
//! Both compositor cells share one release-authoritative presenter: CEF
//! windowless rendering with CPU `OnPaint` copied into client-owned memory
//! and presented inside a roscord-owned top-level window. There is no native
//! child embedding on either compositor, no unowned browser window, and
//! forced CPU/software rendering satisfies the full functional contract.
//!
//! This module owns the pure presentation policy; the Linux `cef_host`
//! enforces it at its OSR callbacks while the Dart
//! `linux_standalone_presenter` mirrors these rules for adapter tests.
//! Matrix protocol behavior stays in `MatrixWidgetAdapter`; only typed
//! [`crate::browser_runtime`] commands, frame references, and owned-window
//! state cross this seam.

use crate::browser_runtime::{FrameReference, PixelFormat, RuntimeError};

/// The only supported backend name for Linux standalone surfaces.
pub const STANDALONE_BACKEND: &str = "cef-osr-cpu";

/// Shared owned-window presentation path reported by both compositor cells.
/// Distinct from the embedded Flutter-texture path so fixtures can tell the
/// two presentations apart while proving the same OSR/CPU engine.
pub const STANDALONE_PRESENTATION_PATH: &str = "osr-cpu-owned-window";

/// Required Linux compositor cells. Unknown compositors fail closed instead
/// of selecting a fallback presentation path.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LinuxCompositor {
    X11,
    Wayland,
}

/// Release-authoritative rendering. CPU/OSR is the only production value;
/// accelerated imports remain gated experiments and are never required.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LinuxStandaloneRendering {
    CpuOsr,
}

/// Owned-window stacking requested by the app. The window manager owns the
/// final stacking; this value only records intent for fixtures.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LinuxStandaloneZOrder {
    Background,
    Normal,
    Foreground,
}

/// Parses the compositor from the session type. Matching is exact and
/// lowercase so an unknown compositor cannot silently select a fallback.
pub fn parse_linux_compositor(value: &str) -> Result<LinuxCompositor, RuntimeError> {
    match value {
        "x11" => Ok(LinuxCompositor::X11),
        "wayland" => Ok(LinuxCompositor::Wayland),
        _ => Err(RuntimeError::InvalidSpec(
            "unknown Linux compositor; X11 and Wayland are the only cells".into(),
        )),
    }
}

pub fn presentation_path(compositor: LinuxCompositor) -> &'static str {
    match compositor {
        LinuxCompositor::X11 | LinuxCompositor::Wayland => STANDALONE_PRESENTATION_PATH,
    }
}

pub fn uses_osr_cpu_frames() -> bool {
    true
}

pub fn uses_owned_window() -> bool {
    true
}

pub fn uses_native_child_embedding() -> bool {
    false
}

pub fn uses_unowned_browser_window() -> bool {
    false
}

pub fn forced_cpu_rendering() -> bool {
    true
}

/// Backend names that must never back a Linux standalone surface. Matching
/// is case-insensitive and substring-based so a renamed fallback cannot slip
/// through the presentation seam. Native child embedding and unowned windows
/// are denied alongside the engine names.
pub fn is_forbidden_backend(name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    lowered.contains("webkit")
        || lowered.contains("wry")
        || lowered.contains("webview2")
        || lowered.contains("system cef")
        || lowered.contains("system-cef")
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

/// Rejects fallback engines, native child embedding, and unowned windows
/// without guessing an alternative. The caller must route through the bundled
/// CEF OSR/CPU host inside a roscord-owned window instead.
pub fn assert_no_fallback_engine(name: &str) -> Result<(), RuntimeError> {
    if is_forbidden_backend(name) {
        return Err(RuntimeError::InvalidCommand(
            "fallback engines, child embedding, and unowned windows are not used for Linux standalone surfaces"
                .into(),
        ));
    }
    Ok(())
}

/// Resolves the requested backend to the single supported value. Anything
/// else is a fail-closed error, never a silent substitution.
pub fn resolve_standalone_backend(requested: &str) -> Result<&'static str, RuntimeError> {
    assert_no_fallback_engine(requested)?;
    if requested == STANDALONE_BACKEND || requested == "cef" {
        return Ok(STANDALONE_BACKEND);
    }
    Err(RuntimeError::InvalidSpec(
        "unknown Linux standalone backend; cef-osr-cpu is the only backend".into(),
    ))
}

/// Validates one OSR/CPU frame reference for the owned-window path.
/// Mirrors [`FrameReference::new`] plus the client-owned frame budget; CEF
/// pointers and borrowed buffers never reach this seam.
#[allow(clippy::too_many_arguments)]
pub fn validate_standalone_frame(
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

/// Owned-window geometry shared by both compositor cells.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StandaloneWindowGeometry {
    pub x: f64,
    pub y: f64,
    pub width: u32,
    pub height: u32,
    pub device_scale_factor: f64,
    pub visible: bool,
    pub z_order: LinuxStandaloneZOrder,
}

impl StandaloneWindowGeometry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        x: f64,
        y: f64,
        width: u32,
        height: u32,
        device_scale_factor: f64,
        visible: bool,
        z_order: LinuxStandaloneZOrder,
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

/// Validates an owned-window geometry without constructing presenter state.
#[allow(clippy::too_many_arguments)]
pub fn validate_standalone_geometry(
    x: f64,
    y: f64,
    width: u32,
    height: u32,
    device_scale_factor: f64,
    visible: bool,
    z_order: LinuxStandaloneZOrder,
) -> Result<StandaloneWindowGeometry, RuntimeError> {
    StandaloneWindowGeometry::new(
        x,
        y,
        width,
        height,
        device_scale_factor,
        visible,
        z_order,
    )
}

/// Owned-window state for one standalone surface.
///
/// Tracks geometry, focus, and host-loss so X11 and Wayland fixtures share
/// one contract. Host loss drops the pending frame sequence and reports
/// reconnecting while leaving the runtime usable; close still wins.
#[derive(Clone, Debug, PartialEq)]
pub struct StandaloneWindowState {
    pub geometry: StandaloneWindowGeometry,
    pub focused: bool,
    pub closed: bool,
    pub host_lost: bool,
    pub pending_frame_sequence: Option<u64>,
}

impl StandaloneWindowState {
    pub fn new(geometry: StandaloneWindowGeometry, focused: bool) -> Self {
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

    pub fn apply_resize(&mut self, width: u32, height: u32, scale: f64) -> Result<(), RuntimeError> {
        let geometry = StandaloneWindowGeometry::new(
            self.geometry.x,
            self.geometry.y,
            width,
            height,
            scale,
            self.geometry.visible,
            self.geometry.z_order,
        )?;
        self.geometry = geometry;
        Ok(())
    }

    pub fn apply_move(&mut self, x: f64, y: f64) -> Result<(), RuntimeError> {
        let geometry = StandaloneWindowGeometry::new(
            x,
            y,
            self.geometry.width,
            self.geometry.height,
            self.geometry.device_scale_factor,
            self.geometry.visible,
            self.geometry.z_order,
        )?;
        self.geometry = geometry;
        Ok(())
    }

    pub fn set_focus(&mut self, focused: bool) {
        self.focused = focused;
    }

    pub fn bring_to_front(&mut self) {
        self.geometry.z_order = LinuxStandaloneZOrder::Foreground;
        self.focused = true;
    }

    pub fn send_to_back(&mut self) {
        self.geometry.z_order = LinuxStandaloneZOrder::Background;
        self.focused = false;
    }

    pub fn set_visibility(&mut self, visible: bool) {
        self.geometry.visible = visible;
        if !visible {
            self.focused = false;
        }
    }

    /// Records host loss without taking down the runtime. Drops the pending
    /// frame and reports reconnecting; close still wins afterwards.
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
    fn both_compositors_share_the_owned_window_osr_cpu_path() {
        assert_eq!(parse_linux_compositor("x11"), Ok(LinuxCompositor::X11));
        assert_eq!(
            parse_linux_compositor("wayland"),
            Ok(LinuxCompositor::Wayland)
        );
        assert_eq!(
            presentation_path(LinuxCompositor::X11),
            "osr-cpu-owned-window"
        );
        assert_eq!(
            presentation_path(LinuxCompositor::Wayland),
            "osr-cpu-owned-window"
        );
        assert!(uses_osr_cpu_frames());
        assert!(uses_owned_window());
        assert!(!uses_native_child_embedding());
        assert!(!uses_unowned_browser_window());
        assert!(forced_cpu_rendering());
    }

    #[test]
    fn unknown_compositors_fail_closed() {
        for unknown in ["", "unknown", "X11", "WAYLAND", "mir"] {
            assert!(parse_linux_compositor(unknown).is_err(), "{unknown}");
        }
    }

    #[test]
    fn frame_validation_rejects_bad_geometry_and_over_budget_frames() {
        assert!(
            validate_standalone_frame(
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
            validate_standalone_frame(
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
            validate_standalone_frame(
                0,
                0,
                48,
                256,
                PixelFormat::BgraPremultiplied,
                1,
                DEFAULT_MAX_FRAME_BYTES
            )
            .is_err()
        );
        assert!(
            validate_standalone_frame(
                0,
                64,
                48,
                8,
                PixelFormat::BgraPremultiplied,
                1,
                DEFAULT_MAX_FRAME_BYTES
            )
            .is_err()
        );
        assert!(
            validate_standalone_frame(
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
    fn geometry_validation_covers_origin_size_and_scale() {
        assert!(
            validate_standalone_geometry(
                0.0,
                0.0,
                800,
                600,
                1.0,
                true,
                LinuxStandaloneZOrder::Normal
            )
            .is_ok()
        );
        assert!(
            validate_standalone_geometry(
                f64::NAN,
                0.0,
                800,
                600,
                1.0,
                true,
                LinuxStandaloneZOrder::Normal
            )
            .is_err()
        );
        assert!(
            validate_standalone_geometry(
                0.0,
                0.0,
                0,
                600,
                1.0,
                true,
                LinuxStandaloneZOrder::Normal
            )
            .is_err()
        );
        assert!(
            validate_standalone_geometry(
                0.0,
                0.0,
                800,
                600,
                0.0,
                true,
                LinuxStandaloneZOrder::Normal
            )
            .is_err()
        );
    }

    #[test]
    fn window_state_tracks_geometry_focus_zorder_and_host_loss() {
        let geometry = validate_standalone_geometry(
            10.0,
            20.0,
            800,
            600,
            2.0,
            true,
            LinuxStandaloneZOrder::Normal,
        )
        .unwrap();
        let mut state = StandaloneWindowState::new(geometry, false);
        state.apply_resize(1024, 768, 1.0).unwrap();
        assert_eq!(state.geometry.width, 1024);
        state.apply_move(30.0, 40.0).unwrap();
        assert_eq!(state.geometry.x, 30.0);
        state.bring_to_front();
        assert_eq!(state.geometry.z_order, LinuxStandaloneZOrder::Foreground);
        assert!(state.focused);
        state.send_to_back();
        assert_eq!(state.geometry.z_order, LinuxStandaloneZOrder::Background);
        assert!(!state.focused);
        state.note_frame(7);
        assert_eq!(state.pending_frame_sequence, Some(7));
        state.note_host_lost();
        assert!(state.is_reconnecting());
        assert_eq!(state.pending_frame_sequence, None);
        assert!(state.close().is_ok());
        assert!(!state.is_reconnecting());
        assert!(state.close().is_err());
    }

    #[test]
    fn only_cef_osr_cpu_resolves() {
        assert_eq!(resolve_standalone_backend("cef-osr-cpu"), Ok(STANDALONE_BACKEND));
        assert_eq!(resolve_standalone_backend("cef"), Ok(STANDALONE_BACKEND));
        for requested in ["native", "wayland-child", "gpu", ""] {
            assert!(resolve_standalone_backend(requested).is_err(), "{requested}");
        }
    }

    #[test]
    fn fallback_engines_child_embedding_and_unowned_windows_are_rejected() {
        for name in [
            "WebKitGTK",
            "webkit2gtk",
            "wry",
            "system CEF",
            "system-cef",
            "external Chromium",
            "external-chromium",
            "WebView2",
            "unowned browser",
            "unowned window",
            "native child",
            "wayland child embedding",
            "x11 child",
        ] {
            assert!(is_forbidden_backend(name), "{name}");
            assert!(assert_no_fallback_engine(name).is_err(), "{name}");
            assert!(resolve_standalone_backend(name).is_err(), "{name}");
        }
        assert!(!is_forbidden_backend("cef-osr-cpu"));
        assert!(!is_forbidden_backend("cef"));
    }
}
