//! Mediated camera, microphone, and screen-capture permissions.
//!
//! Media and capture access is deny-by-default and fails closed through
//! OS/portal mediation.  This module owns the shared decision table used by
//! every host:
//!
//! - Camera/microphone decisions support deny, once/session, and explicitly
//!   scoped persistent grants.  Every grant is keyed by the account profile,
//!   the requesting origin, the top-level origin, and the capability.
//! - A stored grant is only honored when the surface's *current* policy still
//!   declares both origins, the capability is not disabled, and the OS-level
//!   mediation check still passes.  Every use re-validates.
//! - Display capture never receives a persistent grant.  Every display-capture
//!   request needs fresh source consent.
//! - Portal outcomes that are not an explicit grant (denial, dismissal,
//!   timeout, disconnect, unsupported capability) all produce a normal page
//!   denial plus a sanitized failure that carries no origin, path, token, or
//!   page content.
//!
//! The Windows host reimplements this exact table in C++ next to its CEF
//! permission callbacks; the Linux host uses this module directly.  The Dart
//! `media_permission.dart` library mirrors the same vocabulary for fixtures
//! and adapter tests.

use std::collections::BTreeMap;

use crate::browser_runtime::{
    FailureKind, PermissionDecision, PrivacyMode, ProfileKey, RuntimeError, SurfaceFailure,
    SurfaceId,
};

/// Canonical wire names for mediated media capabilities.
pub const CAPABILITY_CAMERA: &str = "camera";
pub const CAPABILITY_MICROPHONE: &str = "microphone";
pub const CAPABILITY_CAMERA_MICROPHONE: &str = "camera+microphone";
pub const CAPABILITY_DISPLAY_VIDEO: &str = "display_video";
pub const CAPABILITY_DISPLAY_AUDIO: &str = "display_audio";
pub const CAPABILITY_DISPLAY_VIDEO_AUDIO: &str = "display_video+display_audio";

/// Wire names of the sanitized denial failures.  The Windows host emits
/// `permission_denied`; the Linux host additionally emits `capture_denied`
/// for XDG portal outcomes.
pub const FAILURE_PERMISSION_DENIED: &str = "permission_denied";
pub const FAILURE_CAPTURE_DENIED: &str = "capture_denied";

/// Classified form of a permission-request capability string.
///
/// Anything that does not match a canonical name classifies as [`Unknown`]
/// and is denied.  Unknown capabilities are never grantable.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum MediaCapability {
    Camera,
    Microphone,
    CameraAndMicrophone,
    DisplayVideo,
    DisplayAudio,
    DisplayVideoAndAudio,
    Unknown,
}

impl MediaCapability {
    /// Classify a wire capability string.  Matching is exact and
    /// case-sensitive so a near-miss capability cannot inherit a grant.
    pub fn classify(capability: &str) -> Self {
        match capability {
            CAPABILITY_CAMERA => Self::Camera,
            CAPABILITY_MICROPHONE => Self::Microphone,
            CAPABILITY_CAMERA_MICROPHONE => Self::CameraAndMicrophone,
            CAPABILITY_DISPLAY_VIDEO => Self::DisplayVideo,
            CAPABILITY_DISPLAY_AUDIO => Self::DisplayAudio,
            CAPABILITY_DISPLAY_VIDEO_AUDIO => Self::DisplayVideoAndAudio,
            _ => Self::Unknown,
        }
    }

    /// Canonical wire name.  `Unknown` has no wire name and is never emitted
    /// by a host; it only appears on classification of foreign input.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Camera => CAPABILITY_CAMERA,
            Self::Microphone => CAPABILITY_MICROPHONE,
            Self::CameraAndMicrophone => CAPABILITY_CAMERA_MICROPHONE,
            Self::DisplayVideo => CAPABILITY_DISPLAY_VIDEO,
            Self::DisplayAudio => CAPABILITY_DISPLAY_AUDIO,
            Self::DisplayVideoAndAudio => CAPABILITY_DISPLAY_VIDEO_AUDIO,
            Self::Unknown => "unknown_media",
        }
    }

    /// Display (screen/window) capture always needs fresh source consent, so
    /// it is never satisfied by a stored grant of any kind.
    pub fn is_display(self) -> bool {
        matches!(
            self,
            Self::DisplayVideo | Self::DisplayAudio | Self::DisplayVideoAndAudio
        )
    }

    /// Only classified camera/microphone capabilities can hold a persistent
    /// grant.  Display capture and unknown capabilities cannot.
    pub fn supports_persistent_grant(self) -> bool {
        matches!(
            self,
            Self::Camera | Self::Microphone | Self::CameraAndMicrophone
        )
    }
}

/// The scope of one stored media grant: account, requesting origin,
/// top-level origin, and capability.  A grant never crosses any of these
/// boundaries.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct MediaGrantScope {
    profile_key: String,
    requesting_origin: String,
    top_level_origin: String,
    capability: MediaCapability,
}

impl MediaGrantScope {
    pub fn new(
        profile_key: &ProfileKey,
        requesting_origin: impl Into<String>,
        top_level_origin: impl Into<String>,
        capability: MediaCapability,
    ) -> Result<Self, RuntimeError> {
        let requesting_origin = requesting_origin.into();
        let top_level_origin = top_level_origin.into();
        validate_scope_origin(&requesting_origin)?;
        validate_scope_origin(&top_level_origin)?;
        if capability == MediaCapability::Unknown {
            return Err(RuntimeError::InvalidCommand(
                "media capability is not grantable".into(),
            ));
        }
        Ok(Self {
            profile_key: profile_key.as_str().to_owned(),
            requesting_origin,
            top_level_origin,
            capability,
        })
    }

    pub fn profile_key(&self) -> &str {
        &self.profile_key
    }

    pub fn requesting_origin(&self) -> &str {
        &self.requesting_origin
    }

    pub fn top_level_origin(&self) -> &str {
        &self.top_level_origin
    }

    pub fn capability(&self) -> MediaCapability {
        self.capability
    }
}

fn validate_scope_origin(origin: &str) -> Result<(), RuntimeError> {
    if origin.is_empty()
        || origin
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
        || !origin.contains("://")
    {
        return Err(RuntimeError::InvalidCommand(
            "media grant origin is invalid".into(),
        ));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StoredGrant {
    Session,
    Persistent,
}

/// In-memory media grant store owned by the host process.
///
/// Session grants evaporate on [`clear_session`], which the host calls on
/// restart and recovery.  Persistent grants survive surface close but are
/// dropped by [`clear_profile`], which the host calls as part of clear-data.
/// Private surfaces never receive persistent storage: an `allow_always`
/// decision there is kept as a session grant only.
#[derive(Clone, Debug, Default)]
pub struct MediaGrantStore {
    grants: BTreeMap<MediaGrantScope, StoredGrant>,
}

impl MediaGrantStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an app decision for `scope`.
    ///
    /// Returns `true` when a grant was stored for later requests and `false`
    /// when the decision applies to the pending request only (`deny`,
    /// `allow_once`, display-capture `allow_always`, or an explicit deny
    /// that also revokes any stored grant for the scope).
    pub fn remember(
        &mut self,
        scope: MediaGrantScope,
        decision: PermissionDecision,
        private_context: bool,
    ) -> Result<bool, RuntimeError> {
        match decision {
            PermissionDecision::Deny => {
                self.grants.remove(&scope);
                Ok(false)
            }
            PermissionDecision::AllowOnce => Ok(false),
            PermissionDecision::AllowSession => {
                self.grants.insert(scope, StoredGrant::Session);
                Ok(true)
            }
            PermissionDecision::AllowAlways => {
                if !scope.capability.supports_persistent_grant() {
                    // Display capture (and anything unclassifiable, which
                    // cannot reach this scope) always needs fresh consent.
                    return Ok(false);
                }
                let stored = if private_context {
                    StoredGrant::Session
                } else {
                    StoredGrant::Persistent
                };
                self.grants.insert(scope, stored);
                Ok(true)
            }
        }
    }

    /// Returns `true` when a stored grant covers `scope` for one more use.
    ///
    /// Every use re-checks the surface's current policy (`policy_origins`
    /// must still declare both the requesting and the top-level origin and
    /// `capability_allowed` must still hold) and the OS-level mediation
    /// result (`os_mediated`).  Display capture always returns `false`:
    /// stored grants never satisfy it.
    pub fn take_grant(
        &self,
        scope: &MediaGrantScope,
        policy_origins: &[String],
        capability_allowed: bool,
        os_mediated: bool,
        private_context: bool,
    ) -> bool {
        if scope.capability.is_display() || !capability_allowed || !os_mediated {
            return false;
        }
        let Some(stored) = self.grants.get(scope) else {
            return false;
        };
        if private_context && *stored == StoredGrant::Persistent {
            return false;
        }
        policy_origins
            .iter()
            .any(|origin| origin == &scope.requesting_origin)
            && policy_origins
                .iter()
                .any(|origin| origin == &scope.top_level_origin)
    }

    /// Drop every session grant.  Called on host restart and recovery:
    /// navigation history, page state, pending permissions, and session
    /// grants are never recreated implicitly.
    pub fn clear_session(&mut self) {
        self.grants
            .retain(|_, stored| *stored != StoredGrant::Session);
    }

    /// Drop every grant (session and persistent) for one account.  Called as
    /// part of clear-data after all of the account's surfaces are quiescent.
    pub fn clear_profile(&mut self, profile_key: &ProfileKey) {
        self.grants
            .retain(|scope, _| scope.profile_key != profile_key.as_str());
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.grants.len()
    }
}

/// Outcome of the OS-level capture mediation for one request.
///
/// On Windows this is the result of the qualified OS media path behind
/// `OnRequestMediaAccessPermission`.  On Linux and Flatpak it is the result
/// of the qualified XDG ScreenCast/PipeWire portal dialog.  Only [`Granted`]
/// continues the page request; every other outcome denies the page and
/// additionally emits a sanitized `capture_denied` failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CapturePortalOutcome {
    Granted,
    Denied,
    Dismissed,
    TimedOut,
    Disconnected,
    Unsupported,
}

impl CapturePortalOutcome {
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "granted" => Self::Granted,
            "denied" => Self::Denied,
            "dismissed" => Self::Dismissed,
            "timeout" => Self::TimedOut,
            "disconnect" => Self::Disconnected,
            "unsupported" => Self::Unsupported,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Granted => "granted",
            Self::Denied => "denied",
            Self::Dismissed => "dismissed",
            Self::TimedOut => "timeout",
            Self::Disconnected => "disconnect",
            Self::Unsupported => "unsupported",
        }
    }

    /// Every outcome except an explicit grant denies the page request.
    pub fn denies_page(self) -> bool {
        self != Self::Granted
    }

    /// Fixed sanitized message for the `capture_denied` failure event.  The
    /// message never carries origins, paths, tokens, or page contents.
    pub fn sanitized_message(self) -> &'static str {
        match self {
            Self::Granted => "system capture granted the request",
            Self::Denied => "system capture dialog denied the request",
            Self::Dismissed => "system capture dialog was dismissed",
            Self::TimedOut => "system capture dialog timed out",
            Self::Disconnected => "system capture service disconnected during the request",
            Self::Unsupported => "system capture is not supported for this capability",
        }
    }
}

/// Fixed sanitized message for the `permission_denied` failure event.  The
/// message never carries origins, paths, tokens, or page contents.
pub fn sanitized_permission_denied_message(capability: MediaCapability) -> &'static str {
    if capability.is_display() {
        "display capture was denied; each request needs fresh consent"
    } else if capability == MediaCapability::Unknown {
        "media access was denied by policy"
    } else {
        "camera or microphone access was denied by policy"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_runtime::PermissionDecision;

    fn profile() -> ProfileKey {
        ProfileKey::new("account-a").unwrap()
    }

    fn grant_scope(capability: MediaCapability) -> MediaGrantScope {
        MediaGrantScope::new(
            &profile(),
            "https://widget.test",
            "https://shell.test",
            capability,
        )
        .unwrap()
    }

    fn policy() -> Vec<String> {
        vec![
            "https://widget.test".to_owned(),
            "https://shell.test".to_owned(),
        ]
    }

    #[test]
    fn capabilities_classify_exact_names_and_reject_near_misses() {
        assert_eq!(
            MediaCapability::classify("camera"),
            MediaCapability::Camera
        );
        assert_eq!(
            MediaCapability::classify("microphone"),
            MediaCapability::Microphone
        );
        assert_eq!(
            MediaCapability::classify("display_video"),
            MediaCapability::DisplayVideo
        );
        assert_eq!(
            MediaCapability::classify("display_audio"),
            MediaCapability::DisplayAudio
        );
        // Near-misses and unlisted capabilities fail closed.
        for foreign in ["Camera", "camera ", " screen", "geolocation", "", "display"] {
            assert_eq!(MediaCapability::classify(foreign), MediaCapability::Unknown);
        }
        assert!(MediaCapability::Camera.supports_persistent_grant());
        assert!(MediaCapability::Microphone.supports_persistent_grant());
        assert!(!MediaCapability::DisplayVideo.supports_persistent_grant());
        assert!(!MediaCapability::DisplayAudio.supports_persistent_grant());
        assert!(!MediaCapability::Unknown.supports_persistent_grant());
        assert!(MediaCapability::DisplayVideo.is_display());
        assert!(!MediaCapability::Camera.is_display());
    }

    #[test]
    fn unknown_capabilities_are_never_grantable() {
        let scope = MediaGrantScope::new(
            &profile(),
            "https://widget.test",
            "https://shell.test",
            MediaCapability::Unknown,
        );
        assert!(scope.is_err());
    }

    #[test]
    fn deny_once_session_and_persistent_grants_behave() {
        let mut store = MediaGrantStore::new();
        let scope = grant_scope(MediaCapability::Camera);

        // Deny-by-default: nothing stored, nothing honored.
        assert!(!store.take_grant(&scope, &policy(), true, true, false));

        // Once applies to the pending request only: nothing is stored.
        assert!(!store.remember(scope.clone(), PermissionDecision::AllowOnce, false).unwrap());
        assert_eq!(store.len(), 0);
        assert!(!store.take_grant(&scope, &policy(), true, true, false));

        // Session grants apply while the session lives.
        assert!(store.remember(scope.clone(), PermissionDecision::AllowSession, false).unwrap());
        assert!(store.take_grant(&scope, &policy(), true, true, false));

        // An explicit deny revokes the stored grant.
        assert!(!store.remember(scope.clone(), PermissionDecision::Deny, false).unwrap());
        assert!(!store.take_grant(&scope, &policy(), true, true, false));

        // Persistent grants apply across surfaces of the same scope.
        assert!(store.remember(scope.clone(), PermissionDecision::AllowAlways, false).unwrap());
        assert!(store.take_grant(&scope, &policy(), true, true, false));
    }

    #[test]
    fn grants_are_scoped_to_account_origins_and_capability() {
        let mut store = MediaGrantStore::new();
        let scope = grant_scope(MediaCapability::Camera);
        store
            .remember(scope.clone(), PermissionDecision::AllowAlways, false)
            .unwrap();

        // A different account, requesting origin, top-level origin, or
        // capability must not inherit the grant.
        let other_account = MediaGrantScope::new(
            &ProfileKey::new("account-b").unwrap(),
            "https://widget.test",
            "https://shell.test",
            MediaCapability::Camera,
        )
        .unwrap();
        assert!(!store.take_grant(&other_account, &policy(), true, true, false));

        let other_requesting = MediaGrantScope::new(
            &profile(),
            "https://evil.test",
            "https://shell.test",
            MediaCapability::Camera,
        )
        .unwrap();
        let policy_with_evil = vec![
            "https://evil.test".to_owned(),
            "https://shell.test".to_owned(),
        ];
        assert!(!store.take_grant(&other_requesting, &policy_with_evil, true, true, false));

        let other_top = MediaGrantScope::new(
            &profile(),
            "https://widget.test",
            "https://other.test",
            MediaCapability::Camera,
        )
        .unwrap();
        let policy_with_other = vec![
            "https://widget.test".to_owned(),
            "https://other.test".to_owned(),
        ];
        assert!(!store.take_grant(&other_top, &policy_with_other, true, true, false));

        let other_capability = grant_scope(MediaCapability::Microphone);
        assert!(!store.take_grant(&other_capability, &policy(), true, true, false));

        // The exact scope still applies.
        assert!(store.take_grant(&scope, &policy(), true, true, false));
    }

    #[test]
    fn every_use_rechecks_current_policy_and_os_mediation() {
        let mut store = MediaGrantStore::new();
        let scope = grant_scope(MediaCapability::Microphone);
        store
            .remember(scope.clone(), PermissionDecision::AllowAlways, false)
            .unwrap();

        // The requesting origin left the current policy.
        assert!(!store.take_grant(
            &scope,
            &["https://shell.test".to_owned()],
            true,
            true,
            false
        ));
        // The capability was disabled by current policy.
        assert!(!store.take_grant(&scope, &policy(), false, true, false));
        // The OS-level check no longer passes.
        assert!(!store.take_grant(&scope, &policy(), true, false, false));
        // Everything current again: the grant applies.
        assert!(store.take_grant(&scope, &policy(), true, true, false));
    }

    #[test]
    fn display_capture_always_needs_fresh_consent() {
        let mut store = MediaGrantStore::new();
        for capability in [
            MediaCapability::DisplayVideo,
            MediaCapability::DisplayAudio,
            MediaCapability::DisplayVideoAndAudio,
        ] {
            let scope = grant_scope(capability);
            // Even allow_always is not stored for display capture.
            assert!(!store
                .remember(scope.clone(), PermissionDecision::AllowAlways, false)
                .unwrap());
            assert!(!store.take_grant(&scope, &policy(), true, true, false));
            // Session decisions are stored (the pending request may proceed)
            // but never satisfy a later display request.
            assert!(store
                .remember(scope.clone(), PermissionDecision::AllowSession, false)
                .unwrap());
            assert!(!store.take_grant(&scope, &policy(), true, true, false));
        }
    }

    #[test]
    fn private_contexts_never_hold_persistent_grants() {
        let mut store = MediaGrantStore::new();
        let scope = grant_scope(MediaCapability::Camera);
        assert!(store
            .remember(scope.clone(), PermissionDecision::AllowAlways, true)
            .unwrap());
        // A private allow_always degrades to a memory-only session grant: it
        // applies while the session lives but never becomes persistent.
        assert!(store.take_grant(&scope, &policy(), true, true, true));
        assert!(store.take_grant(&scope, &policy(), true, true, false));
        store.clear_session();
        assert!(!store.take_grant(&scope, &policy(), true, true, true));
        assert!(!store.take_grant(&scope, &policy(), true, true, false));

        // And a persistent grant stored outside private mode is not honored
        // for private use.
        let mut store = MediaGrantStore::new();
        store
            .remember(scope.clone(), PermissionDecision::AllowAlways, false)
            .unwrap();
        assert!(!store.take_grant(&scope, &policy(), true, true, true));
        assert!(store.take_grant(&scope, &policy(), true, true, false));
    }

    #[test]
    fn session_grants_evaporate_on_recovery_and_profiles_clear() {
        let mut store = MediaGrantStore::new();
        let scope = grant_scope(MediaCapability::Camera);
        store
            .remember(scope.clone(), PermissionDecision::AllowSession, false)
            .unwrap();
        store
            .remember(scope.clone(), PermissionDecision::AllowAlways, false)
            .unwrap();
        // Re-remembering as persistent overwrote the session entry; add a
        // second session scope to observe the session clear.
        let session_scope = grant_scope(MediaCapability::Microphone);
        store
            .remember(session_scope.clone(), PermissionDecision::AllowSession, false)
            .unwrap();
        store.clear_session();
        assert!(!store.take_grant(&session_scope, &policy(), true, true, false));
        assert!(store.take_grant(&scope, &policy(), true, true, false));

        store.clear_profile(&profile());
        assert!(!store.take_grant(&scope, &policy(), true, true, false));
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn denial_failures_serialize_to_documented_wire_names() {
        use crate::browser_runtime::FailureKind;

        let permission = serde_json::to_value(FailureKind::PermissionDenied).unwrap();
        assert_eq!(permission, serde_json::json!(FAILURE_PERMISSION_DENIED));
        let capture = serde_json::to_value(FailureKind::CaptureDenied).unwrap();
        assert_eq!(capture, serde_json::json!(FAILURE_CAPTURE_DENIED));
    }

    #[test]
    fn portal_outcomes_deny_the_page_with_sanitized_events() {
        for name in ["denied", "dismissed", "timeout", "disconnect", "unsupported"] {
            let outcome = CapturePortalOutcome::parse(name).unwrap();
            assert!(outcome.denies_page());
            let message = outcome.sanitized_message();
            assert!(!message.is_empty());
            for leaked in ["https://", "http://", "token", "profile", "/", "\\"] {
                assert!(
                    !message.to_ascii_lowercase().contains(leaked),
                    "portal message leaks {leaked:?}: {message:?}"
                );
            }
        }
        assert_eq!(CapturePortalOutcome::parse("granted"), Some(CapturePortalOutcome::Granted));
        assert!(!CapturePortalOutcome::Granted.denies_page());
        assert_eq!(CapturePortalOutcome::parse("bogus"), None);

        assert!(sanitized_permission_denied_message(MediaCapability::DisplayVideo)
            .contains("fresh consent"));
        let camera_message =
            sanitized_permission_denied_message(MediaCapability::Camera);
        assert!(!camera_message.contains("https://"));
    }
}

/// One page-originated media request awaiting mediation.
#[derive(Clone, Debug, PartialEq)]
pub struct PendingPermissionRequest {
    surface_id: SurfaceId,
    /// `None` for unclassifiable capabilities.  Such requests can only be
    /// denied; they never read or write the grant store.
    scope: Option<MediaGrantScope>,
    portal: Option<CapturePortalOutcome>,
}

impl PendingPermissionRequest {
    pub fn surface_id(&self) -> SurfaceId {
        self.surface_id
    }

    pub fn scope(&self) -> Option<&MediaGrantScope> {
        self.scope.as_ref()
    }

    pub fn portal(&self) -> Option<CapturePortalOutcome> {
        self.portal
    }
}

/// Current-policy view the host assembles from the requesting surface for
/// one grant decision or lookup.
#[derive(Clone, Debug)]
pub struct MediaPolicyView {
    /// Exact declared origins (allowed plus loopback) of the current policy.
    pub origins: Vec<String>,
    /// Whether the capability is still enabled by current policy.  A
    /// capability the policy explicitly disables is never granted.
    pub capability_allowed: bool,
    /// Private surfaces never read or write persistent grants.
    pub private_context: bool,
    /// The OS-level mediation check for this use (Windows OS media path
    /// consent, or a prior XDG portal grant on Linux).
    pub os_mediated: bool,
}

/// Outcome of resolving one app decision for a pending request.
#[derive(Clone, Debug, PartialEq)]
pub struct PermissionResolution {
    pub surface_id: SurfaceId,
    /// Whether the page request may proceed exactly once.
    pub granted_once: bool,
    /// Whether a grant was stored for later requests in the scope.
    pub stored: bool,
    /// Sanitized failure to report when the page is denied.  Carries no
    /// origin, path, token, or page content.
    pub failure: Option<SurfaceFailure>,
}

/// Host-side media permission state machine.
///
/// The registry is deny-by-default: a request the registry never saw, a
/// request for an unknown capability, and any use whose current-policy or
/// OS check fails all resolve to page denial.  Pending requests are dropped
/// when their surface closes, so a late app decision can never grant a dead
/// surface.
#[derive(Clone, Debug, Default)]
pub struct HostPermissionRegistry {
    pending: BTreeMap<String, PendingPermissionRequest>,
    grants: MediaGrantStore,
    /// When true (Linux/Flatpak), display-capture decisions additionally
    /// require a prior XDG portal grant recorded via
    /// [`HostPermissionRegistry::report_portal_outcome`].  When false
    /// (Windows), the qualified OS media path mediates synchronously inside
    /// the permission callback.
    portal_mediation_required: bool,
}

impl HostPermissionRegistry {
    pub fn new(portal_mediation_required: bool) -> Self {
        Self {
            pending: BTreeMap::new(),
            grants: MediaGrantStore::new(),
            portal_mediation_required,
        }
    }

    /// Record a page-originated request and return the classified capability.
    /// Duplicate request ids are rejected so a replayed event can never
    /// double-register a request.  Unclassifiable capabilities register with
    /// no grantable scope so their denial follows the sanitized path.
    pub fn register(
        &mut self,
        surface_id: SurfaceId,
        profile_key: &ProfileKey,
        request_id: impl Into<String>,
        requesting_origin: impl Into<String>,
        top_level_origin: impl Into<String>,
        capability_name: &str,
    ) -> Result<MediaCapability, RuntimeError> {
        let request_id = request_id.into();
        let requesting_origin = requesting_origin.into();
        let top_level_origin = top_level_origin.into();
        if request_id.is_empty() {
            return Err(RuntimeError::InvalidCommand(
                "permission request id must not be empty".into(),
            ));
        }
        if self.pending.contains_key(&request_id) {
            return Err(RuntimeError::InvalidCommand(
                "permission request id is already pending".into(),
            ));
        }
        let capability = MediaCapability::classify(capability_name);
        let scope = MediaGrantScope::new(
            profile_key,
            requesting_origin,
            top_level_origin,
            capability,
        )
        .ok();
        self.pending.insert(
            request_id,
            PendingPermissionRequest {
                surface_id,
                scope,
                portal: None,
            },
        );
        Ok(capability)
    }

    /// Fast path for the CEF callback: returns true when a stored grant
    /// covers this exact scope under the surface's current policy and OS
    /// mediation, without asking the app again.  Display capture always
    /// returns false: it needs fresh source consent every time.  Only a
    /// request the page actually made (and the host registered) can be
    /// auto-covered; stored grants never grant an unregistered request.
    pub fn stored_grant_covers(
        &self,
        surface_id: SurfaceId,
        profile_key: &ProfileKey,
        requesting_origin: &str,
        top_level_origin: &str,
        capability_name: &str,
        policy: &MediaPolicyView,
    ) -> bool {
        let capability = MediaCapability::classify(capability_name);
        if capability == MediaCapability::Unknown || capability.is_display() {
            return false;
        }
        let Ok(scope) = MediaGrantScope::new(
            profile_key,
            requesting_origin,
            top_level_origin,
            capability,
        ) else {
            return false;
        };
        if !self.pending.values().any(|pending| {
            pending.surface_id == surface_id && pending.scope.as_ref() == Some(&scope)
        }) {
            return false;
        }
        self.grants.take_grant(
            &scope,
            &policy.origins,
            policy.capability_allowed,
            policy.os_mediated,
            policy.private_context,
        )
    }

    /// Record the OS portal outcome for a pending display request (Linux
    /// XDG ScreenCast/PipeWire dialog).  A non-grant outcome denies the page
    /// and returns the sanitized `capture_denied` failure for the surface;
    /// the caller must additionally cancel the page callback.  The pending
    /// request is consumed in every non-grant case.
    pub fn report_portal_outcome(
        &mut self,
        request_id: &str,
        outcome: CapturePortalOutcome,
    ) -> Result<(SurfaceId, Option<SurfaceFailure>), RuntimeError> {
        let pending = self.pending.get_mut(request_id).ok_or_else(|| {
            RuntimeError::InvalidCommand("unknown permission request".into())
        })?;
        let surface_id = pending.surface_id;
        if outcome == CapturePortalOutcome::Granted {
            pending.portal = Some(outcome);
            return Ok((surface_id, None));
        }
        self.pending.remove(request_id);
        let failure = SurfaceFailure::new(
            FailureKind::CaptureDenied,
            outcome.sanitized_message(),
        )
        .map_err(|error| RuntimeError::InvalidCommand(error.to_string()))?;
        Ok((surface_id, Some(failure)))
    }

    /// Resolve one app decision for a pending request.  Unknown request ids
    /// are rejected; unknown capabilities, failed policy/OS checks, and a
    /// missing portal grant (where portal mediation is required) all deny
    /// the page with a sanitized failure.
    pub fn resolve(
        &mut self,
        request_id: &str,
        decision: PermissionDecision,
        policy: &MediaPolicyView,
    ) -> Result<PermissionResolution, RuntimeError> {
        let pending = self.pending.remove(request_id).ok_or_else(|| {
            RuntimeError::InvalidCommand("unknown permission request".into())
        })?;
        let surface_id = pending.surface_id;
        let deny = |capability: MediaCapability| {
            SurfaceFailure::new(
                FailureKind::PermissionDenied,
                sanitized_permission_denied_message(capability),
            )
            .map_err(|error| RuntimeError::InvalidCommand(error.to_string()))
        };
        let Some(scope) = pending.scope else {
            return Ok(PermissionResolution {
                surface_id,
                granted_once: false,
                stored: false,
                failure: Some(deny(MediaCapability::Unknown)?),
            });
        };
        let capability = scope.capability();
        if decision == PermissionDecision::Deny {
            self.grants
                .remember(scope, PermissionDecision::Deny, policy.private_context)
                .map_err(|error| RuntimeError::InvalidCommand(error.to_string()))?;
            return Ok(PermissionResolution {
                surface_id,
                granted_once: false,
                stored: false,
                failure: Some(deny(capability)?),
            });
        }
        // Display capture additionally requires the portal grant where the
        // platform mediates through the XDG portal dialog.
        if capability.is_display()
            && self.portal_mediation_required
            && pending.portal != Some(CapturePortalOutcome::Granted)
        {
            return Ok(PermissionResolution {
                surface_id,
                granted_once: false,
                stored: false,
                failure: Some(
                    SurfaceFailure::new(
                        FailureKind::CaptureDenied,
                        CapturePortalOutcome::Disconnected.sanitized_message(),
                    )
                    .map_err(|error| RuntimeError::InvalidCommand(error.to_string()))?,
                ),
            });
        }
        if !policy.capability_allowed
            || !policy.os_mediated
            || !policy
                .origins
                .iter()
                .any(|origin| origin == scope.requesting_origin())
            || !policy
                .origins
                .iter()
                .any(|origin| origin == scope.top_level_origin())
        {
            return Ok(PermissionResolution {
                surface_id,
                granted_once: false,
                stored: false,
                failure: Some(deny(capability)?),
            });
        }
        // Display allow_always degrades to once: the pending request may
        // proceed, but nothing is stored for the next request.
        let effective = if capability.is_display() && decision == PermissionDecision::AllowAlways {
            PermissionDecision::AllowOnce
        } else {
            decision
        };
        let stored = self
            .grants
            .remember(scope, effective, policy.private_context)
            .map_err(|error| RuntimeError::InvalidCommand(error.to_string()))?;
        Ok(PermissionResolution {
            surface_id,
            granted_once: true,
            stored,
            failure: None,
        })
    }

    /// Drop all pending requests for one surface.  Called when the surface
    /// closes so a late decision can never grant a dead surface.
    pub fn remove_surface(&mut self, surface_id: SurfaceId) {
        self.pending
            .retain(|_, pending| pending.surface_id != surface_id);
    }

    /// Inspect one pending request without consuming it.
    pub fn pending(&self, request_id: &str) -> Option<&PendingPermissionRequest> {
        self.pending.get(request_id)
    }

    /// Drop session grants (host restart and recovery).
    pub fn clear_session(&mut self) {
        self.grants.clear_session();
    }

    /// Drop every grant for one account (clear-data).
    pub fn clear_profile(&mut self, profile_key: &ProfileKey) {
        self.grants.clear_profile(profile_key);
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }
}

#[cfg(test)]
mod registry_tests {
    use super::*;
    use crate::browser_runtime::PermissionDecision;

    fn profile() -> ProfileKey {
        ProfileKey::new("account-a").unwrap()
    }

    fn policy() -> MediaPolicyView {
        MediaPolicyView {
            origins: vec![
                "https://widget.test".to_owned(),
                "https://shell.test".to_owned(),
            ],
            capability_allowed: true,
            private_context: false,
            os_mediated: true,
        }
    }

    fn register_camera(registry: &mut HostPermissionRegistry, request: &str) -> MediaCapability {
        registry
            .register(
                SurfaceId(1),
                &profile(),
                request,
                "https://widget.test",
                "https://shell.test",
                "camera",
            )
            .unwrap()
    }

    #[test]
    fn duplicate_and_empty_request_ids_are_rejected() {
        let mut registry = HostPermissionRegistry::new(false);
        assert_eq!(register_camera(&mut registry, "media-1"), MediaCapability::Camera);
        assert!(registry
            .register(
                SurfaceId(1),
                &profile(),
                "media-1",
                "https://widget.test",
                "https://shell.test",
                "camera",
            )
            .is_err());
        assert!(registry
            .register(
                SurfaceId(1),
                &profile(),
                "",
                "https://widget.test",
                "https://shell.test",
                "camera",
            )
            .is_err());
        assert_eq!(registry.pending_count(), 1);
    }

    #[test]
    fn unknown_requests_and_capabilities_deny_closed() {
        let mut registry = HostPermissionRegistry::new(false);
        // No such pending request: rejected, never granted.
        assert!(registry
            .resolve("media-missing", PermissionDecision::AllowAlways, &policy())
            .is_err());
        assert!(registry
            .report_portal_outcome("media-missing", CapturePortalOutcome::Denied)
            .is_err());

        // Unknown capabilities register but can only be denied with a
        // sanitized failure.
        assert_eq!(
            registry
                .register(
                    SurfaceId(1),
                    &profile(),
                    "media-foreign",
                    "https://widget.test",
                    "https://shell.test",
                    "geolocation",
                )
                .unwrap(),
            MediaCapability::Unknown
        );
        let resolution = registry
            .resolve("media-foreign", PermissionDecision::AllowAlways, &policy())
            .unwrap();
        assert!(!resolution.granted_once);
        assert!(!resolution.stored);
        let failure = resolution.failure.unwrap();
        assert_eq!(failure.kind(), &FailureKind::PermissionDenied);
        assert!(!failure.message().contains("https://"));
    }

    #[test]
    fn session_grants_auto_cover_later_requests_without_reprompting() {
        let mut registry = HostPermissionRegistry::new(false);
        register_camera(&mut registry, "media-1");
        let first = registry.resolve("media-1", PermissionDecision::AllowSession, &policy()).unwrap();
        assert!(first.granted_once);
        assert!(first.stored);
        assert!(first.failure.is_none());

        // A later request in the same scope is covered without a new
        // permission prompt, while policy and OS checks still pass.
        register_camera(&mut registry, "media-2");
        assert!(registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "camera",
            &policy(),
        ));
        // ... but not when the OS check fails or the policy moved on.
        let no_os = MediaPolicyView { os_mediated: false, ..policy() };
        assert!(!registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "camera",
            &no_os,
        ));
        let moved_policy = MediaPolicyView {
            origins: vec!["https://shell.test".to_owned()],
            ..policy()
        };
        assert!(!registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "camera",
            &moved_policy,
        ));
    }

    #[test]
    fn display_requests_need_fresh_consent_and_portal_grants_on_linux() {
        let mut registry = HostPermissionRegistry::new(true);
        registry
            .register(
                SurfaceId(1),
                &profile(),
                "media-display-1",
                "https://widget.test",
                "https://shell.test",
                "display_video",
            )
            .unwrap();
        // Stored grants never cover display capture ...
        assert!(!registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "display_video",
            &policy(),
        ));
        // ... and without the portal grant the app decision cannot proceed.
        let blocked = registry
            .resolve("media-display-1", PermissionDecision::AllowOnce, &policy())
            .unwrap();
        assert!(!blocked.granted_once);
        assert_eq!(blocked.failure.unwrap().kind(), &FailureKind::CaptureDenied);

        // After the portal grants source consent, one app decision grants
        // exactly this request; allow_always still stores nothing.
        registry
            .register(
                SurfaceId(1),
                &profile(),
                "media-display-2",
                "https://widget.test",
                "https://shell.test",
                "display_video",
            )
            .unwrap();
        let (surface, portal_failure) = registry
            .report_portal_outcome("media-display-2", CapturePortalOutcome::Granted)
            .unwrap();
        assert_eq!(surface, SurfaceId(1));
        assert!(portal_failure.is_none());
        let granted = registry
            .resolve("media-display-2", PermissionDecision::AllowAlways, &policy())
            .unwrap();
        assert!(granted.granted_once);
        assert!(!granted.stored);
        assert!(granted.failure.is_none());
    }

    #[test]
    fn every_portal_failure_denies_the_page_with_a_sanitized_event() {
        for outcome in [
            CapturePortalOutcome::Denied,
            CapturePortalOutcome::Dismissed,
            CapturePortalOutcome::TimedOut,
            CapturePortalOutcome::Disconnected,
            CapturePortalOutcome::Unsupported,
        ] {
            let mut registry = HostPermissionRegistry::new(true);
            registry
                .register(
                    SurfaceId(3),
                    &profile(),
                    "media-display",
                    "https://widget.test",
                    "https://shell.test",
                    "display_video",
                )
                .unwrap();
            let (surface, failure) = registry
                .report_portal_outcome("media-display", outcome)
                .unwrap();
            assert_eq!(surface, SurfaceId(3));
            let failure = failure.expect("portal failure must produce an event");
            assert_eq!(failure.kind(), &FailureKind::CaptureDenied);
            assert_eq!(failure.message(), outcome.sanitized_message());
            // The consumed request cannot be decided afterwards.
            assert!(registry
                .resolve("media-display", PermissionDecision::AllowOnce, &policy())
                .is_err());
        }
    }

    #[test]
    fn closing_a_surface_drops_its_pending_requests() {
        let mut registry = HostPermissionRegistry::new(false);
        register_camera(&mut registry, "media-1");
        registry.remove_surface(SurfaceId(1));
        assert_eq!(registry.pending_count(), 0);
        assert!(registry
            .resolve("media-1", PermissionDecision::AllowOnce, &policy())
            .is_err());
    }

    #[test]
    fn windows_path_grants_display_without_a_portal_step() {
        let mut registry = HostPermissionRegistry::new(false);
        registry
            .register(
                SurfaceId(1),
                &profile(),
                "media-display",
                "https://widget.test",
                "https://shell.test",
                "display_video",
            )
            .unwrap();
        let granted = registry
            .resolve("media-display", PermissionDecision::AllowOnce, &policy())
            .unwrap();
        assert!(granted.granted_once);
        assert!(!granted.stored);
    }

    #[test]
    fn privacy_modes_flow_through_to_the_grant_store() {
        let mut registry = HostPermissionRegistry::new(false);
        register_camera(&mut registry, "media-private");
        let private = MediaPolicyView { private_context: true, ..policy() };
        let granted = registry
            .resolve("media-private", PermissionDecision::AllowAlways, &private)
            .unwrap();
        assert!(granted.granted_once);
        assert!(granted.stored);

        // The private session grant still applies while the session lives.
        register_camera(&mut registry, "media-private-2");
        assert!(registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "camera",
            &private,
        ));
        registry.clear_session();
        assert_eq!(registry.pending_count(), 1);
        register_camera(&mut registry, "media-private-3");
        assert!(!registry.stored_grant_covers(
            SurfaceId(1),
            &profile(),
            "https://widget.test",
            "https://shell.test",
            "camera",
            &private,
        ));
    }
}
