//! Native Linux embedded Matrix presentation: OSR/CPU frames on X11 and
//! Wayland through the Flutter texture path.
//!
//! Both compositor cells share one release-authoritative presenter: CEF
//! windowless rendering with CPU `OnPaint` copied into client-owned memory
//! and exposed as a Flutter texture. There is no native child embedding on
//! either compositor, forced CPU/software rendering satisfies the full
//! functional contract, and WebKitGTK, Wry, system CEF, external Chromium,
//! and other fallback engines are never selected.
//!
//! This module owns the pure presentation policy; the Linux `cef_host`
//! enforces it at its OSR callbacks while the Dart
//! `linux_embedded_presenter` mirrors these rules for adapter tests. Matrix
//! protocol behavior stays in `MatrixWidgetAdapter`; only typed
//! [`crate::browser_runtime`] commands and frame references cross this seam.

use crate::browser_runtime::{FrameReference, PixelFormat, RuntimeError};

/// The only supported backend name for Linux embedded surfaces.
pub const EMBEDDED_BACKEND: &str = "cef-osr-cpu";

/// Shared presentation path reported by both compositor cells.
pub const EMBEDDED_PRESENTATION_PATH: &str = "osr-cpu-flutter-texture";

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
pub enum LinuxEmbeddedRendering {
    CpuOsr,
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
        LinuxCompositor::X11 | LinuxCompositor::Wayland => EMBEDDED_PRESENTATION_PATH,
    }
}

pub fn uses_osr_cpu_frames() -> bool {
    true
}

pub fn uses_flutter_texture() -> bool {
    true
}

pub fn uses_native_child_embedding() -> bool {
    false
}

pub fn forced_cpu_rendering() -> bool {
    true
}

/// Backend names that must never back a Linux embedded surface. Matching is
/// case-insensitive and substring-based so a renamed fallback cannot slip
/// through the presentation seam.
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
}

/// Rejects fallback engines without guessing an alternative. The caller must
/// route through the bundled CEF OSR/CPU host instead.
pub fn assert_no_fallback_engine(name: &str) -> Result<(), RuntimeError> {
    if is_forbidden_backend(name) {
        return Err(RuntimeError::InvalidCommand(
            "fallback browser engines are not used for Linux embedded surfaces".into(),
        ));
    }
    Ok(())
}

/// Resolves the requested backend to the single supported value. Anything
/// else is a fail-closed error, never a silent substitution.
pub fn resolve_embedded_backend(requested: &str) -> Result<&'static str, RuntimeError> {
    assert_no_fallback_engine(requested)?;
    if requested == EMBEDDED_BACKEND || requested == "cef" {
        return Ok(EMBEDDED_BACKEND);
    }
    Err(RuntimeError::InvalidSpec(
        "unknown Linux embedded backend; cef-osr-cpu is the only backend".into(),
    ))
}

/// Validates one OSR/CPU frame reference for the Flutter texture path.
/// Mirrors [`FrameReference::new`] plus the client-owned frame budget; CEF
/// pointers and borrowed buffers never reach this seam.
#[allow(clippy::too_many_arguments)]
pub fn validate_embedded_frame(
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_runtime::DEFAULT_MAX_FRAME_BYTES;

    #[test]
    fn both_compositors_share_the_osr_cpu_texture_path() {
        assert_eq!(parse_linux_compositor("x11"), Ok(LinuxCompositor::X11));
        assert_eq!(
            parse_linux_compositor("wayland"),
            Ok(LinuxCompositor::Wayland)
        );
        assert_eq!(
            presentation_path(LinuxCompositor::X11),
            "osr-cpu-flutter-texture"
        );
        assert_eq!(
            presentation_path(LinuxCompositor::Wayland),
            "osr-cpu-flutter-texture"
        );
        assert!(uses_osr_cpu_frames());
        assert!(uses_flutter_texture());
        assert!(!uses_native_child_embedding());
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
            validate_embedded_frame(
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
            validate_embedded_frame(
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
            validate_embedded_frame(
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
            validate_embedded_frame(
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
            validate_embedded_frame(
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
        assert_eq!(resolve_embedded_backend("cef-osr-cpu"), Ok(EMBEDDED_BACKEND));
        assert_eq!(resolve_embedded_backend("cef"), Ok(EMBEDDED_BACKEND));
        for requested in ["native", "wayland-child", "gpu", ""] {
            assert!(resolve_embedded_backend(requested).is_err(), "{requested}");
        }
    }

    #[test]
    fn fallback_engines_are_rejected() {
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
        ] {
            assert!(is_forbidden_backend(name), "{name}");
            assert!(assert_no_fallback_engine(name).is_err(), "{name}");
            assert!(resolve_embedded_backend(name).is_err(), "{name}");
        }
        assert!(!is_forbidden_backend("cef-osr-cpu"));
        assert!(!is_forbidden_backend("cef"));
    }
}
