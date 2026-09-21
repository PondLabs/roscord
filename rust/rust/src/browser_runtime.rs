//! The typed seam between roscord callers and the out-of-process browser host.
//!
//! This module deliberately contains no CEF or platform types.  The production
//! host will sit behind this interface; the fake implementation is used by
//! contract tests and by the platform bring-up work.

use std::collections::{BTreeMap, VecDeque};
use std::fmt;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;

// Keep the lifecycle vocabulary available from the same module as the
// original four-operation seam.  The implementation lives in its own module
// so platform adapters can share it without pulling in CEF types.
pub use crate::browser_runtime_lifecycle::{
    CommandOutcome, CommandOutcomeReason, CommandToken, FailureClass, FailureScope, FaultPoint,
    LifecycleBrowserRuntime, LifecycleError, RuntimeEvent, RuntimeEventKind, RuntimeFailure,
    RuntimeLifecycle, RuntimeState,
};

// Media and capture mediation shares the four-operation seam.  The decision
// table lives in its own module so both hosts can share it without pulling
// in CEF or portal types.
pub use crate::browser_media::{
    sanitized_permission_denied_message, CapturePortalOutcome, HostPermissionRegistry,
    MediaCapability, MediaGrantScope, MediaGrantStore, MediaPolicyView, PendingPermissionRequest,
    PermissionResolution, FAILURE_CAPTURE_DENIED, FAILURE_PERMISSION_DENIED,
};

pub const PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_MAX_FRAME_BYTES: usize = 1024 * 1024;
const MAX_PROFILE_KEY_BYTES: usize = 256;

/// An opaque, stable local-account identity.  It is intentionally not a
/// Matrix user id, homeserver URL, display name, or a path.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ProfileKey(String);

impl ProfileKey {
    pub fn new(value: impl Into<String>) -> Result<Self, RuntimeError> {
        let value = value.into();
        if value.is_empty() {
            return Err(RuntimeError::InvalidSpec("profile key is empty".into()));
        }
        if value.len() > MAX_PROFILE_KEY_BYTES {
            return Err(RuntimeError::InvalidSpec("profile key is too long".into()));
        }
        if value
            .chars()
            .any(|character| character.is_control() || matches!(character, '/' | '\\'))
        {
            return Err(RuntimeError::InvalidSpec(
                "profile key contains a forbidden character".into(),
            ));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ProfileKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresentationMode {
    Embedded,
    Standalone,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyMode {
    Persistent,
    Private,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NavigationDisposition {
    Current,
    NewSurface,
    External,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NavigationRequest {
    url: String,
    disposition: NavigationDisposition,
    user_initiated: bool,
}

impl NavigationRequest {
    pub fn new(
        url: impl Into<String>,
        disposition: NavigationDisposition,
        user_initiated: bool,
    ) -> Result<Self, RuntimeError> {
        let url = url.into();
        validate_url(&url)?;
        Ok(Self {
            url,
            disposition,
            user_initiated,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn disposition(&self) -> NavigationDisposition {
        self.disposition
    }

    pub fn user_initiated(&self) -> bool {
        self.user_initiated
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NavigationPolicyDecision {
    InProcess,
    External,
    Blocked,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SurfacePolicy {
    allowed_origins: Vec<String>,
    #[serde(default)]
    allowed_loopback_origins: Vec<String>,
    #[serde(default)]
    allow_external_navigation: bool,
    capabilities: BTreeMap<String, bool>,
}

impl SurfacePolicy {
    pub fn new(
        allowed_origins: impl IntoIterator<Item = String>,
        capabilities: impl IntoIterator<Item = (String, bool)>,
    ) -> Result<Self, RuntimeError> {
        let allowed_origins = allowed_origins.into_iter().collect::<Vec<_>>();
        for origin in &allowed_origins {
            if origin.is_empty() || origin.chars().any(char::is_control) {
                return Err(RuntimeError::InvalidSpec(
                    "policy contains an invalid origin".into(),
                ));
            }
        }
        let capabilities = capabilities.into_iter().collect::<BTreeMap<_, _>>();
        if capabilities
            .keys()
            .any(|capability| capability.is_empty() || capability.chars().any(char::is_control))
        {
            return Err(RuntimeError::InvalidSpec(
                "policy contains an invalid capability".into(),
            ));
        }
        let policy = Self {
            allowed_origins,
            allowed_loopback_origins: Vec::new(),
            allow_external_navigation: false,
            capabilities,
        };
        policy.validate()?;
        Ok(policy)
    }

    /// Builds a policy with the controlled loopback and explicit external
    /// routing controls used by desktop surfaces.  Keeping `new` above small
    /// preserves the original call sites while making the security-sensitive
    /// fields impossible to omit accidentally at their dedicated seam.
    pub fn with_navigation(
        allowed_origins: impl IntoIterator<Item = String>,
        allowed_loopback_origins: impl IntoIterator<Item = String>,
        allow_external_navigation: bool,
        capabilities: impl IntoIterator<Item = (String, bool)>,
    ) -> Result<Self, RuntimeError> {
        let policy = Self {
            allowed_origins: allowed_origins.into_iter().collect(),
            allowed_loopback_origins: allowed_loopback_origins.into_iter().collect(),
            allow_external_navigation,
            capabilities: capabilities.into_iter().collect(),
        };
        policy.validate()?;
        Ok(policy)
    }

    pub fn allowed_origins(&self) -> &[String] {
        &self.allowed_origins
    }

    pub fn allowed_loopback_origins(&self) -> &[String] {
        &self.allowed_loopback_origins
    }

    pub fn allow_external_navigation(&self) -> bool {
        self.allow_external_navigation
    }

    pub fn capabilities(&self) -> &BTreeMap<String, bool> {
        &self.capabilities
    }

    pub(crate) fn validate(&self) -> Result<(), RuntimeError> {
        for origin in &self.allowed_origins {
            validate_declared_origin(origin, false)?;
        }
        for origin in &self.allowed_loopback_origins {
            validate_declared_origin(origin, true)?;
        }
        if self
            .capabilities
            .keys()
            .any(|capability| capability.is_empty() || capability.chars().any(char::is_control))
        {
            return Err(RuntimeError::InvalidSpec(
                "policy contains an invalid capability".into(),
            ));
        }
        Ok(())
    }

    pub fn allows_url(&self, url: &str) -> bool {
        let Some(origin) = url_origin(url) else {
            return false;
        };
        if is_controlled_fixture(url) {
            // The host-owned validation fixture is a controlled roscord
            // destination even when a smoke-test policy is intentionally
            // empty.  All other roscord destinations must be declared.
            return true;
        }
        self.allowed_origins
            .iter()
            .chain(self.allowed_loopback_origins.iter())
            .filter_map(|allowed| url_origin(allowed))
            .any(|allowed| allowed == origin)
    }

    pub fn navigation_decision(&self, navigation: &NavigationRequest) -> NavigationPolicyDecision {
        if navigation.disposition() == NavigationDisposition::External {
            return if navigation.user_initiated() && self.allow_external_navigation {
                NavigationPolicyDecision::External
            } else {
                NavigationPolicyDecision::Blocked
            };
        }
        if self.allows_url(navigation.url()) {
            NavigationPolicyDecision::InProcess
        } else if navigation.user_initiated() && self.allow_external_navigation {
            NavigationPolicyDecision::External
        } else {
            NavigationPolicyDecision::Blocked
        }
    }
}

fn is_controlled_fixture(url: &str) -> bool {
    const FIXTURE_ORIGIN: &str = "commet://fixture";
    url == FIXTURE_ORIGIN || url.starts_with("commet://fixture/")
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SurfaceSpec {
    profile_key: ProfileKey,
    presentation: PresentationMode,
    privacy: PrivacyMode,
    initial_navigation: NavigationRequest,
    policy: SurfacePolicy,
}

impl SurfaceSpec {
    pub fn new(
        profile_key: ProfileKey,
        presentation: PresentationMode,
        privacy: PrivacyMode,
        initial_navigation: NavigationRequest,
        policy: SurfacePolicy,
    ) -> Result<Self, RuntimeError> {
        let spec = Self {
            profile_key,
            presentation,
            privacy,
            initial_navigation,
            policy,
        };
        spec.validate()?;
        Ok(spec)
    }

    pub fn profile_key(&self) -> &ProfileKey {
        &self.profile_key
    }

    pub fn presentation(&self) -> PresentationMode {
        self.presentation
    }

    pub fn privacy(&self) -> PrivacyMode {
        self.privacy
    }

    pub fn initial_navigation(&self) -> &NavigationRequest {
        &self.initial_navigation
    }

    pub fn policy(&self) -> &SurfacePolicy {
        &self.policy
    }

    pub(crate) fn validate(&self) -> Result<(), RuntimeError> {
        self.policy.validate()?;
        if self.privacy == PrivacyMode::Private && self.profile_key.as_str().is_empty() {
            return Err(RuntimeError::InvalidSpec(
                "private surfaces still require an opaque profile key".into(),
            ));
        }
        if self.policy.navigation_decision(&self.initial_navigation)
            != NavigationPolicyDecision::InProcess
        {
            return Err(RuntimeError::InvalidSpec(
                "initial navigation is outside the declared policy".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScriptSource {
    Page,
    App,
    Host,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScriptEnvelope {
    source: ScriptSource,
    origin: String,
    channel: String,
    request_id: String,
    value: Value,
}

impl ScriptEnvelope {
    pub fn new(
        source: ScriptSource,
        origin: impl Into<String>,
        channel: impl Into<String>,
        request_id: impl Into<String>,
        value: Value,
    ) -> Result<Self, RuntimeError> {
        let origin = origin.into();
        let channel = channel.into();
        let request_id = request_id.into();
        if origin.is_empty() || channel.is_empty() || request_id.is_empty() {
            return Err(RuntimeError::InvalidCommand(
                "script envelope metadata must not be empty".into(),
            ));
        }
        validate_script_value(&value)?;
        Ok(Self {
            source,
            origin,
            channel,
            request_id,
            value,
        })
    }

    pub fn source(&self) -> ScriptSource {
        self.source
    }

    pub fn origin(&self) -> &str {
        &self.origin
    }

    pub fn channel(&self) -> &str {
        &self.channel
    }

    pub fn request_id(&self) -> &str {
        &self.request_id
    }

    pub fn value(&self) -> &Value {
        &self.value
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerKind {
    Down,
    Up,
    Move,
    Enter,
    Leave,
    Wheel,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum InputEvent {
    Pointer {
        kind: PointerKind,
        x: f64,
        y: f64,
        buttons: u32,
        delta_x: f64,
        delta_y: f64,
    },
    Keyboard {
        key: String,
        code: String,
        modifiers: u32,
        pressed: bool,
    },
    Ime {
        phase: ImePhase,
        text: String,
        selection_start: u32,
        selection_end: u32,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImePhase {
    Start,
    Update,
    Commit,
    Cancel,
}

impl InputEvent {
    fn validate(&self) -> Result<(), RuntimeError> {
        match self {
            Self::Pointer {
                x,
                y,
                delta_x,
                delta_y,
                ..
            } if [*x, *y, *delta_x, *delta_y]
                .iter()
                .any(|value| !value.is_finite()) =>
            {
                Err(RuntimeError::InvalidCommand(
                    "pointer coordinates must be finite".into(),
                ))
            }
            Self::Keyboard { key, code, .. } if key.is_empty() || code.is_empty() => Err(
                RuntimeError::InvalidCommand("keyboard key and code must not be empty".into()),
            ),
            Self::Ime {
                selection_start,
                selection_end,
                ..
            } if selection_start > selection_end => Err(RuntimeError::InvalidCommand(
                "IME selection is inverted".into(),
            )),
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionDecision {
    Deny,
    AllowOnce,
    AllowSession,
    AllowAlways,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PopupAction {
    Deny,
    OpenOwned,
    OpenExternal,
    Close,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum DownloadDecision {
    Deny,
    Cancel,
    Accept { destination: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardDecision {
    Deny,
    Allow,
    Cancel,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum SurfaceCommand {
    Navigate {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        navigation: NavigationRequest,
    },
    Input {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        input: InputEvent,
    },
    Resize {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        width: u32,
        height: u32,
        device_scale_factor: f64,
    },
    Focus {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        focused: bool,
    },
    Script {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        envelope: ScriptEnvelope,
    },
    Permission {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        request_id: String,
        decision: PermissionDecision,
    },
    Popup {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        request_id: String,
        action: PopupAction,
    },
    Download {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        request_id: String,
        decision: DownloadDecision,
    },
    Clipboard {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        request_id: String,
        decision: ClipboardDecision,
    },
    ReleaseFrame {
        sequence: u64,
        profile_key: Option<ProfileKey>,
        frame_sequence: u64,
    },
}

impl SurfaceCommand {
    pub fn sequence(&self) -> u64 {
        match self {
            Self::Navigate { sequence, .. }
            | Self::Input { sequence, .. }
            | Self::Resize { sequence, .. }
            | Self::Focus { sequence, .. }
            | Self::Script { sequence, .. }
            | Self::Permission { sequence, .. }
            | Self::Popup { sequence, .. }
            | Self::Download { sequence, .. }
            | Self::Clipboard { sequence, .. }
            | Self::ReleaseFrame { sequence, .. } => *sequence,
        }
    }

    pub fn profile_key(&self) -> Option<&ProfileKey> {
        match self {
            Self::Navigate { profile_key, .. }
            | Self::Input { profile_key, .. }
            | Self::Resize { profile_key, .. }
            | Self::Focus { profile_key, .. }
            | Self::Script { profile_key, .. }
            | Self::Permission { profile_key, .. }
            | Self::Popup { profile_key, .. }
            | Self::Download { profile_key, .. }
            | Self::Clipboard { profile_key, .. }
            | Self::ReleaseFrame { profile_key, .. } => profile_key.as_ref(),
        }
    }

    pub(crate) fn validate(&self) -> Result<(), RuntimeError> {
        if self.sequence() == 0 {
            return Err(RuntimeError::InvalidCommand(
                "command sequence must be greater than zero".into(),
            ));
        }
        match self {
            Self::Navigate { navigation, .. } => validate_url(navigation.url()),
            Self::Input { input, .. } => input.validate(),
            Self::Resize {
                width,
                height,
                device_scale_factor,
                ..
            } if *width == 0
                || *height == 0
                || *device_scale_factor <= 0.0
                || !device_scale_factor.is_finite() =>
            {
                Err(RuntimeError::InvalidCommand(
                    "resize dimensions and scale must be positive".into(),
                ))
            }
            Self::Script { envelope, .. } => validate_script_value(envelope.value()),
            Self::Permission { request_id, .. }
            | Self::Popup { request_id, .. }
            | Self::Download { request_id, .. }
            | Self::Clipboard { request_id, .. }
                if request_id.is_empty() =>
            {
                Err(RuntimeError::InvalidCommand(
                    "request id must not be empty".into(),
                ))
            }
            Self::ReleaseFrame { frame_sequence, .. } if *frame_sequence == 0 => Err(
                RuntimeError::InvalidCommand("frame sequence must be greater than zero".into()),
            ),
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SurfaceId(pub u64);

impl fmt::Display for SurfaceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PixelFormat {
    BgraPremultiplied,
    RgbaPremultiplied,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FrameReference {
    slot: u32,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    sequence: u64,
}

impl FrameReference {
    pub fn new(
        slot: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: PixelFormat,
        sequence: u64,
    ) -> Result<Self, RuntimeError> {
        if width == 0 || height == 0 || sequence == 0 {
            return Err(RuntimeError::InvalidCommand(
                "frame dimensions and sequence must be positive".into(),
            ));
        }
        let minimum_stride = width
            .checked_mul(4)
            .ok_or_else(|| RuntimeError::InvalidCommand("frame width overflows".into()))?;
        if stride < minimum_stride {
            return Err(RuntimeError::InvalidCommand(
                "frame stride is smaller than one row".into(),
            ));
        }
        Ok(Self {
            slot,
            width,
            height,
            stride,
            format,
            sequence,
        })
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn stride(&self) -> u32 {
        self.stride
    }

    pub fn format(&self) -> PixelFormat {
        self.format
    }

    pub fn sequence(&self) -> u64 {
        self.sequence
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NavigationEvent {
    url: String,
    disposition: NavigationDisposition,
    outcome: NavigationOutcome,
}

impl NavigationEvent {
    pub fn new(
        url: impl Into<String>,
        disposition: NavigationDisposition,
        outcome: NavigationOutcome,
    ) -> Result<Self, RuntimeError> {
        let url = url.into();
        validate_url(&url)?;
        Ok(Self {
            url,
            disposition,
            outcome,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn disposition(&self) -> NavigationDisposition {
        self.disposition
    }

    pub fn outcome(&self) -> NavigationOutcome {
        self.outcome
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NavigationOutcome {
    Allowed,
    External,
    Blocked,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseReason {
    User,
    Host,
    Replaced,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    RuntimeLost,
    ProfileMismatch,
    ProtocolViolation,
    NavigationBlocked,
    CertificateDenied,
    ClientCertificateDenied,
    PolicyViolation,
    PermissionDenied,
    CaptureDenied,
    MalformedMessage,
    OversizedMessage,
    UnknownMessage,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SurfaceFailure {
    kind: FailureKind,
    message: String,
}

impl SurfaceFailure {
    pub fn new(kind: FailureKind, message: impl Into<String>) -> Result<Self, RuntimeError> {
        let message = message.into();
        if message.is_empty() {
            return Err(RuntimeError::InvalidCommand(
                "surface failure message must not be empty".into(),
            ));
        }
        Ok(Self { kind, message })
    }

    pub fn kind(&self) -> &FailureKind {
        &self.kind
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum WindowChange {
    Resized {
        width: u32,
        height: u32,
        device_scale_factor: f64,
    },
    Focused {
        focused: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum SurfaceEvent {
    Ready {
        surface_id: SurfaceId,
        sequence: u64,
        initial_navigation: NavigationRequest,
    },
    Closed {
        surface_id: SurfaceId,
        sequence: u64,
        reason: CloseReason,
    },
    Failed {
        surface_id: SurfaceId,
        sequence: u64,
        failure: SurfaceFailure,
    },
    FrameReady {
        surface_id: SurfaceId,
        sequence: u64,
        frame: FrameReference,
    },
    Navigation {
        surface_id: SurfaceId,
        sequence: u64,
        navigation: NavigationEvent,
    },
    ScriptMessage {
        surface_id: SurfaceId,
        sequence: u64,
        envelope: ScriptEnvelope,
    },
    PermissionRequest {
        surface_id: SurfaceId,
        sequence: u64,
        request_id: String,
        origin: String,
        top_level_origin: String,
        capability: String,
        user_gesture: bool,
    },
    PopupRequest {
        surface_id: SurfaceId,
        sequence: u64,
        request_id: String,
        url: String,
        user_gesture: bool,
    },
    DownloadRequest {
        surface_id: SurfaceId,
        sequence: u64,
        request_id: String,
        url: String,
    },
    ClipboardRequest {
        surface_id: SurfaceId,
        sequence: u64,
        request_id: String,
        write: bool,
        user_gesture: bool,
    },
    WindowChanged {
        surface_id: SurfaceId,
        sequence: u64,
        change: WindowChange,
    },
}

impl SurfaceEvent {
    pub fn surface_id(&self) -> SurfaceId {
        match self {
            Self::Ready { surface_id, .. }
            | Self::Closed { surface_id, .. }
            | Self::Failed { surface_id, .. }
            | Self::FrameReady { surface_id, .. }
            | Self::Navigation { surface_id, .. }
            | Self::ScriptMessage { surface_id, .. }
            | Self::PermissionRequest { surface_id, .. }
            | Self::PopupRequest { surface_id, .. }
            | Self::DownloadRequest { surface_id, .. }
            | Self::ClipboardRequest { surface_id, .. }
            | Self::WindowChanged { surface_id, .. } => *surface_id,
        }
    }

    pub fn sequence(&self) -> u64 {
        match self {
            Self::Ready { sequence, .. }
            | Self::Closed { sequence, .. }
            | Self::Failed { sequence, .. }
            | Self::FrameReady { sequence, .. }
            | Self::Navigation { sequence, .. }
            | Self::ScriptMessage { sequence, .. }
            | Self::PermissionRequest { sequence, .. }
            | Self::PopupRequest { sequence, .. }
            | Self::DownloadRequest { sequence, .. }
            | Self::ClipboardRequest { sequence, .. }
            | Self::WindowChanged { sequence, .. } => *sequence,
        }
    }

    fn is_frame_ready_for(&self, surface_id: SurfaceId) -> bool {
        matches!(self, Self::FrameReady { surface_id: id, .. } if *id == surface_id)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeError {
    InvalidSpec(String),
    InvalidCommand(String),
    UnknownSurface(SurfaceId),
    StaleSurface(SurfaceId),
    SequenceViolation { expected_after: u64, received: u64 },
    ProfileMismatch,
    Protocol(ProtocolError),
}

impl fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSpec(message) => write!(formatter, "invalid surface spec: {message}"),
            Self::InvalidCommand(message) => {
                write!(formatter, "invalid surface command: {message}")
            }
            Self::UnknownSurface(id) => write!(formatter, "unknown surface {id}"),
            Self::StaleSurface(id) => write!(formatter, "stale surface {id}"),
            Self::SequenceViolation {
                expected_after,
                received,
            } => write!(
                formatter,
                "sequence must be greater than {expected_after}, received {received}"
            ),
            Self::ProfileMismatch => formatter.write_str("surface profile key does not match"),
            Self::Protocol(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for RuntimeError {}

/// The only caller-facing operations of the browser runtime.
pub trait BrowserRuntime {
    fn open(&mut self, spec: SurfaceSpec) -> Result<SurfaceId, RuntimeError>;
    fn command(
        &mut self,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<(), RuntimeError>;
    fn events(&mut self) -> Vec<SurfaceEvent>;
    fn close(&mut self, surface_id: SurfaceId) -> Result<(), RuntimeError>;
}

struct FakeSurface {
    spec: SurfaceSpec,
    last_command_sequence: u64,
    next_event_sequence: u64,
}

/// A deterministic host adapter.  It emits ready/closed events, echoes domain
/// commands as normalized events, and keeps only the newest pending frame for
/// each surface while preserving every control event.
pub struct FakeBrowserRuntime {
    next_surface_id: u64,
    surfaces: BTreeMap<SurfaceId, FakeSurface>,
    pending_events: VecDeque<SurfaceEvent>,
}

impl Default for FakeBrowserRuntime {
    fn default() -> Self {
        Self {
            next_surface_id: 1,
            surfaces: BTreeMap::new(),
            pending_events: VecDeque::new(),
        }
    }
}

impl FakeBrowserRuntime {
    pub fn publish_frame(
        &mut self,
        surface_id: SurfaceId,
        frame: FrameReference,
    ) -> Result<(), RuntimeError> {
        let sequence = self.next_event_sequence(surface_id)?;
        self.enqueue(SurfaceEvent::FrameReady {
            surface_id,
            sequence,
            frame,
        });
        Ok(())
    }

    fn next_event_sequence(&mut self, surface_id: SurfaceId) -> Result<u64, RuntimeError> {
        let surface = self
            .surfaces
            .get_mut(&surface_id)
            .ok_or(RuntimeError::StaleSurface(surface_id))?;
        let sequence = surface.next_event_sequence;
        surface.next_event_sequence = surface
            .next_event_sequence
            .checked_add(1)
            .ok_or_else(|| RuntimeError::InvalidCommand("event sequence overflow".into()))?;
        Ok(sequence)
    }

    fn enqueue(&mut self, event: SurfaceEvent) {
        if event.is_frame_ready_for(event.surface_id()) {
            let surface_id = event.surface_id();
            self.pending_events
                .retain(|pending| !pending.is_frame_ready_for(surface_id));
        }
        self.pending_events.push_back(event);
    }
}

impl BrowserRuntime for FakeBrowserRuntime {
    fn open(&mut self, spec: SurfaceSpec) -> Result<SurfaceId, RuntimeError> {
        spec.validate()?;
        let surface_id = SurfaceId(self.next_surface_id);
        self.next_surface_id = self
            .next_surface_id
            .checked_add(1)
            .ok_or_else(|| RuntimeError::InvalidSpec("surface id overflow".into()))?;
        self.surfaces.insert(
            surface_id,
            FakeSurface {
                spec: spec.clone(),
                last_command_sequence: 0,
                next_event_sequence: 2,
            },
        );
        self.enqueue(SurfaceEvent::Ready {
            surface_id,
            sequence: 1,
            initial_navigation: spec.initial_navigation().clone(),
        });
        Ok(surface_id)
    }

    fn command(
        &mut self,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<(), RuntimeError> {
        command.validate()?;
        let surface = self
            .surfaces
            .get_mut(&surface_id)
            .ok_or(RuntimeError::StaleSurface(surface_id))?;
        if let Some(profile_key) = command.profile_key() {
            if profile_key != surface.spec.profile_key() {
                return Err(RuntimeError::ProfileMismatch);
            }
        }
        let sequence = command.sequence();
        if sequence <= surface.last_command_sequence {
            return Err(RuntimeError::SequenceViolation {
                expected_after: surface.last_command_sequence,
                received: sequence,
            });
        }
        surface.last_command_sequence = sequence;

        let event = match command {
            SurfaceCommand::Navigate { navigation, .. } => {
                let outcome = match surface.spec.policy().navigation_decision(&navigation) {
                    NavigationPolicyDecision::InProcess => NavigationOutcome::Allowed,
                    NavigationPolicyDecision::External => NavigationOutcome::External,
                    NavigationPolicyDecision::Blocked => {
                        if navigation.disposition() == NavigationDisposition::External {
                            NavigationOutcome::Cancelled
                        } else {
                            NavigationOutcome::Blocked
                        }
                    }
                };
                let event_sequence = surface.next_event_sequence;
                surface.next_event_sequence += 1;
                SurfaceEvent::Navigation {
                    surface_id,
                    sequence: event_sequence,
                    navigation: NavigationEvent::new(
                        navigation.url().to_owned(),
                        navigation.disposition(),
                        outcome,
                    )
                    .expect("validated navigation request"),
                }
            }
            SurfaceCommand::Script { envelope, .. } => {
                let event_sequence = surface.next_event_sequence;
                surface.next_event_sequence += 1;
                SurfaceEvent::ScriptMessage {
                    surface_id,
                    sequence: event_sequence,
                    envelope,
                }
            }
            SurfaceCommand::Resize {
                width,
                height,
                device_scale_factor,
                ..
            } => {
                let event_sequence = surface.next_event_sequence;
                surface.next_event_sequence += 1;
                SurfaceEvent::WindowChanged {
                    surface_id,
                    sequence: event_sequence,
                    change: WindowChange::Resized {
                        width,
                        height,
                        device_scale_factor,
                    },
                }
            }
            SurfaceCommand::Focus { focused, .. } => {
                let event_sequence = surface.next_event_sequence;
                surface.next_event_sequence += 1;
                SurfaceEvent::WindowChanged {
                    surface_id,
                    sequence: event_sequence,
                    change: WindowChange::Focused { focused },
                }
            }
            SurfaceCommand::Input { .. }
            | SurfaceCommand::Permission { .. }
            | SurfaceCommand::Popup { .. }
            | SurfaceCommand::Download { .. }
            | SurfaceCommand::Clipboard { .. }
            | SurfaceCommand::ReleaseFrame { .. } => return Ok(()),
        };
        self.enqueue(event);
        Ok(())
    }

    fn events(&mut self) -> Vec<SurfaceEvent> {
        self.pending_events.drain(..).collect()
    }

    fn close(&mut self, surface_id: SurfaceId) -> Result<(), RuntimeError> {
        let Some(mut surface) = self.surfaces.remove(&surface_id) else {
            return Err(RuntimeError::StaleSurface(surface_id));
        };
        let sequence = surface.next_event_sequence;
        surface.next_event_sequence += 1;
        self.enqueue(SurfaceEvent::Closed {
            surface_id,
            sequence,
            reason: CloseReason::User,
        });
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProtocolError {
    EmptyFrame,
    FrameTooLarge { size: usize, max: usize },
    TruncatedFrame { expected: usize, actual: usize },
    MalformedJson(String),
    UnsupportedVersion { expected: u16, received: u16 },
    NonceMismatch,
    InvalidMessage(String),
    UnknownMessageType(String),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyFrame => formatter.write_str("empty protocol frame"),
            Self::FrameTooLarge { size, max } => {
                write!(formatter, "protocol frame of {size} bytes exceeds {max}")
            }
            Self::TruncatedFrame { expected, actual } => {
                write!(
                    formatter,
                    "protocol frame needs {expected} bytes, received {actual}"
                )
            }
            Self::MalformedJson(message) => write!(formatter, "malformed protocol JSON: {message}"),
            Self::UnsupportedVersion { expected, received } => {
                write!(
                    formatter,
                    "protocol version {received} is not supported (expected {expected})"
                )
            }
            Self::NonceMismatch => formatter.write_str("protocol nonce does not match"),
            Self::InvalidMessage(message) => {
                write!(formatter, "invalid protocol message: {message}")
            }
            Self::UnknownMessageType(message) => {
                write!(formatter, "unknown protocol message type: {message}")
            }
        }
    }
}

impl std::error::Error for ProtocolError {}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum WireMessage {
    Open {
        request_id: u64,
        spec: SurfaceSpec,
    },
    Command {
        request_id: u64,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    },
    Close {
        surface_id: SurfaceId,
    },
    Event {
        event: SurfaceEvent,
    },
    Opened {
        request_id: u64,
        surface_id: SurfaceId,
    },
    Ack {
        request_id: u64,
    },
    /// Transport-level liveness probe.  It carries no surface or profile
    /// state, so a host can answer it while the browser UI is idle.
    Heartbeat {
        request_id: u64,
    },
    HeartbeatAck {
        request_id: u64,
    },
    Error {
        request_id: Option<u64>,
        code: String,
        message: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct WireEnvelope {
    version: u16,
    nonce: String,
    message: Value,
}

/// Length-prefixed JSON transport used by the Windows named-pipe and Linux
/// Unix-socket adapters.  The fake host uses the same codec as the real host.
#[derive(Clone, Debug)]
pub struct FramedCodec {
    version: u16,
    nonce: String,
    max_frame_bytes: usize,
}

impl FramedCodec {
    pub fn new(nonce: impl Into<String>) -> Result<Self, ProtocolError> {
        Self::with_limit(nonce, DEFAULT_MAX_FRAME_BYTES)
    }

    pub fn with_limit(
        nonce: impl Into<String>,
        max_frame_bytes: usize,
    ) -> Result<Self, ProtocolError> {
        let nonce = nonce.into();
        if nonce.is_empty() {
            return Err(ProtocolError::InvalidMessage("nonce is empty".into()));
        }
        if max_frame_bytes == 0 || max_frame_bytes > u32::MAX as usize {
            return Err(ProtocolError::InvalidMessage(
                "max frame size is outside the wire limit".into(),
            ));
        }
        Ok(Self {
            version: PROTOCOL_VERSION,
            nonce,
            max_frame_bytes,
        })
    }

    pub fn encode(&self, message: &WireMessage) -> Result<Vec<u8>, ProtocolError> {
        let payload = serde_json::to_value(message)
            .map_err(|error| ProtocolError::InvalidMessage(error.to_string()))?;
        let body = serde_json::to_vec(&WireEnvelope {
            version: self.version,
            nonce: self.nonce.clone(),
            message: payload,
        })
        .map_err(|error| ProtocolError::InvalidMessage(error.to_string()))?;
        if body.is_empty() {
            return Err(ProtocolError::EmptyFrame);
        }
        if body.len() > self.max_frame_bytes {
            return Err(ProtocolError::FrameTooLarge {
                size: body.len(),
                max: self.max_frame_bytes,
            });
        }
        let length = u32::try_from(body.len()).map_err(|_| ProtocolError::FrameTooLarge {
            size: body.len(),
            max: self.max_frame_bytes,
        })?;
        let mut frame = Vec::with_capacity(body.len() + 4);
        frame.extend_from_slice(&length.to_be_bytes());
        frame.extend_from_slice(&body);
        Ok(frame)
    }

    #[cfg(target_os = "linux")]
    pub(crate) fn max_frame_bytes(&self) -> usize {
        self.max_frame_bytes
    }

    pub fn decode(&self, frame: &[u8]) -> Result<WireMessage, ProtocolError> {
        if frame.len() < 4 {
            return Err(ProtocolError::TruncatedFrame {
                expected: 4,
                actual: frame.len(),
            });
        }
        let declared = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        if declared == 0 {
            return Err(ProtocolError::EmptyFrame);
        }
        if declared > self.max_frame_bytes {
            return Err(ProtocolError::FrameTooLarge {
                size: declared,
                max: self.max_frame_bytes,
            });
        }
        if frame.len() != declared + 4 {
            return Err(ProtocolError::TruncatedFrame {
                expected: declared + 4,
                actual: frame.len(),
            });
        }
        let envelope: WireEnvelope = serde_json::from_slice(&frame[4..])
            .map_err(|error| ProtocolError::MalformedJson(error.to_string()))?;
        if envelope.version != self.version {
            return Err(ProtocolError::UnsupportedVersion {
                expected: self.version,
                received: envelope.version,
            });
        }
        if envelope.nonce != self.nonce {
            return Err(ProtocolError::NonceMismatch);
        }
        let message_type = envelope
            .message
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| ProtocolError::InvalidMessage("message type is missing".into()))?;
        if !matches!(
            message_type,
            "open"
                | "command"
                | "close"
                | "event"
                | "opened"
                | "ack"
                | "heartbeat"
                | "heartbeat_ack"
                | "error"
        ) {
            return Err(ProtocolError::UnknownMessageType(message_type.into()));
        }
        serde_json::from_value(envelope.message)
            .map_err(|error| ProtocolError::InvalidMessage(error.to_string()))
    }

    pub fn decode_next(&self, buffer: &mut Vec<u8>) -> Result<Option<WireMessage>, ProtocolError> {
        if buffer.len() < 4 {
            return Ok(None);
        }
        let declared = u32::from_be_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
        if declared == 0 {
            return Err(ProtocolError::EmptyFrame);
        }
        if declared > self.max_frame_bytes {
            return Err(ProtocolError::FrameTooLarge {
                size: declared,
                max: self.max_frame_bytes,
            });
        }
        let total = declared + 4;
        if buffer.len() < total {
            return Ok(None);
        }
        let frame = buffer.drain(..total).collect::<Vec<_>>();
        self.decode(&frame).map(Some)
    }
}

fn validate_url(url: &str) -> Result<(), RuntimeError> {
    if url.is_empty()
        || url
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(RuntimeError::InvalidSpec(
            "navigation URL is invalid".into(),
        ));
    }
    let scheme = url
        .split_once("://")
        .map(|(scheme, _)| scheme.to_ascii_lowercase());
    if !matches!(scheme.as_deref(), Some("http" | "https" | "commet")) {
        return Err(RuntimeError::InvalidSpec(
            "navigation scheme is not declared by the runtime".into(),
        ));
    }
    if url_origin(url).is_none() {
        return Err(RuntimeError::InvalidSpec(
            "navigation URL has no valid authority".into(),
        ));
    }
    Ok(())
}

fn url_origin(url: &str) -> Option<String> {
    let (raw_scheme, rest) = url.split_once("://")?;
    let scheme = raw_scheme.to_ascii_lowercase();
    if !matches!(scheme.as_str(), "http" | "https" | "commet") {
        return None;
    }
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    if authority.is_empty()
        || authority.contains('@')
        || (!authority.starts_with('[') && authority.matches(':').count() > 1)
        || authority
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return None;
    }
    // A port, when present, must be numeric.  IPv6 authorities keep their
    // brackets so the origin remains unambiguous.
    let (host, port) = if authority.starts_with('[') {
        let close = authority.find(']')?;
        let host = authority.get(1..close)?;
        if host.is_empty() {
            return None;
        }
        let suffix = authority.get(close + 1..)?;
        let port = if suffix.is_empty() {
            None
        } else {
            let port = suffix.strip_prefix(':')?;
            if port.is_empty() || !port.chars().all(|character| character.is_ascii_digit()) {
                return None;
            }
            Some(port)
        };
        (host, port)
    } else if let Some((host, port)) = authority.rsplit_once(':') {
        if host.is_empty() || port.is_empty() || !port.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        (host, Some(port))
    } else {
        (authority, None)
    };
    if host.is_empty() {
        return None;
    }
    let host = host.to_ascii_lowercase();
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!(
        "{}://{}{}",
        scheme,
        host,
        port.map(|value| format!(":{value}")).unwrap_or_default()
    ))
}

fn validate_declared_origin(origin: &str, loopback: bool) -> Result<(), RuntimeError> {
    let normalized = url_origin(origin)
        .ok_or_else(|| RuntimeError::InvalidSpec("policy contains an invalid origin".into()))?;
    if origin.to_ascii_lowercase() != normalized {
        return Err(RuntimeError::InvalidSpec(
            "policy origin must contain only an origin".into(),
        ));
    }
    let expected = if loopback { "http" } else { "https" };
    if !normalized.starts_with(&format!("{expected}://"))
        && !(expected == "https" && normalized.starts_with("commet://"))
    {
        return Err(RuntimeError::InvalidSpec(
            "policy origin uses an undeclared scheme".into(),
        ));
    }
    if loopback {
        let authority = normalized.strip_prefix("http://").unwrap_or_default();
        let (host, has_port) = if let Some(close) = authority.find(']') {
            (
                authority
                    .get(1..close)
                    .unwrap_or_default()
                    .to_ascii_lowercase(),
                authority
                    .get(close + 1..)
                    .is_some_and(|value| value.starts_with(':')),
            )
        } else if let Some((host, _port)) = authority.rsplit_once(':') {
            (host.to_ascii_lowercase(), true)
        } else {
            (authority.to_ascii_lowercase(), false)
        };
        if !matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1") || !has_port {
            return Err(RuntimeError::InvalidSpec(
                "loopback policy origin must name localhost with a port".into(),
            ));
        }
    }
    Ok(())
}

fn validate_script_value(value: &Value) -> Result<(), RuntimeError> {
    match value {
        Value::Array(values) => values.iter().try_for_each(validate_script_value),
        Value::Object(object) => {
            if let Some(kind) = object.get("__type") {
                let kind = kind.as_str().ok_or_else(|| {
                    RuntimeError::InvalidCommand("binary __type must be a string".into())
                })?;
                if kind == "ArrayBuffer" || kind == "Blob" {
                    let data = object.get("data").and_then(Value::as_str).ok_or_else(|| {
                        RuntimeError::InvalidCommand("binary value must contain base64 data".into())
                    })?;
                    base64::engine::general_purpose::STANDARD
                        .decode(data)
                        .map_err(|_| {
                            RuntimeError::InvalidCommand(
                                "binary value contains invalid base64".into(),
                            )
                        })?;
                }
            }
            object.values().try_for_each(validate_script_value)
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec() -> SurfaceSpec {
        SurfaceSpec::new(
            ProfileKey::new("account-a").unwrap(),
            PresentationMode::Embedded,
            PrivacyMode::Persistent,
            NavigationRequest::new(
                "https://widget.test/index",
                NavigationDisposition::Current,
                false,
            )
            .unwrap(),
            SurfacePolicy::new(["https://widget.test".to_owned()], std::iter::empty()).unwrap(),
        )
        .unwrap()
    }

    #[test]
    fn fake_host_completes_open_command_and_close_lifecycle() {
        let mut runtime = FakeBrowserRuntime::default();
        let surface = runtime.open(spec()).unwrap();
        assert!(matches!(
            runtime.events().as_slice(),
            [SurfaceEvent::Ready { .. }]
        ));

        runtime
            .command(
                surface,
                SurfaceCommand::Resize {
                    sequence: 1,
                    profile_key: None,
                    width: 640,
                    height: 480,
                    device_scale_factor: 1.0,
                },
            )
            .unwrap();
        assert!(matches!(
            runtime.events().as_slice(),
            [SurfaceEvent::WindowChanged { .. }]
        ));

        runtime.close(surface).unwrap();
        assert!(matches!(
            runtime.events().as_slice(),
            [SurfaceEvent::Closed { .. }]
        ));
        assert!(matches!(
            runtime.close(surface),
            Err(RuntimeError::StaleSurface(_))
        ));
    }

    #[test]
    fn frame_events_coalesce_but_control_events_are_lossless() {
        let mut runtime = FakeBrowserRuntime::default();
        let surface = runtime.open(spec()).unwrap();
        runtime.events();
        runtime
            .publish_frame(
                surface,
                FrameReference::new(0, 10, 10, 40, PixelFormat::BgraPremultiplied, 1).unwrap(),
            )
            .unwrap();
        runtime
            .command(
                surface,
                SurfaceCommand::Focus {
                    sequence: 1,
                    profile_key: None,
                    focused: true,
                },
            )
            .unwrap();
        runtime
            .publish_frame(
                surface,
                FrameReference::new(0, 10, 10, 40, PixelFormat::BgraPremultiplied, 2).unwrap(),
            )
            .unwrap();

        let events = runtime.events();
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], SurfaceEvent::WindowChanged { .. }));
        assert!(matches!(
            &events[1],
            SurfaceEvent::FrameReady { frame, .. } if frame.sequence() == 2
        ));
    }

    #[test]
    fn stale_sequence_and_profile_are_rejected() {
        let mut runtime = FakeBrowserRuntime::default();
        let surface = runtime.open(spec()).unwrap();
        runtime.events();
        let command = SurfaceCommand::Focus {
            sequence: 1,
            profile_key: Some(ProfileKey::new("other-account").unwrap()),
            focused: true,
        };
        assert_eq!(
            runtime.command(surface, command),
            Err(RuntimeError::ProfileMismatch)
        );
        runtime
            .command(
                surface,
                SurfaceCommand::Focus {
                    sequence: 1,
                    profile_key: None,
                    focused: true,
                },
            )
            .unwrap();
        assert!(matches!(
            runtime.command(
                surface,
                SurfaceCommand::Focus {
                    sequence: 1,
                    profile_key: None,
                    focused: false,
                }
            ),
            Err(RuntimeError::SequenceViolation { .. })
        ));
    }

    #[test]
    fn recursive_binary_script_values_round_trip() {
        let envelope = ScriptEnvelope::new(
            ScriptSource::Page,
            "https://widget.test",
            "widget",
            "request-1",
            json!({
                "nested": [
                    {"__type": "ArrayBuffer", "data": "AQID"},
                    {"deep": {"__type": "Blob", "data": "BAU="}}
                ]
            }),
        )
        .unwrap();
        let encoded = serde_json::to_vec(&envelope).unwrap();
        let decoded: ScriptEnvelope = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded, envelope);
    }

    #[test]
    fn policy_matches_full_origins_not_only_hostnames() {
        let policy =
            SurfacePolicy::new(vec!["https://widget.test".to_owned()], std::iter::empty()).unwrap();
        assert!(policy.allows_url("https://widget.test/index"));
        assert!(!policy.allows_url("http://widget.test/index"));
        assert!(!policy.allows_url("https://other.test/index"));
    }

    #[test]
    fn policy_allows_declared_https_roscord_and_controlled_loopback_only() {
        let policy = SurfacePolicy::with_navigation(
            [
                "https://widget.test".to_owned(),
                "commet://widget".to_owned(),
            ],
            ["http://127.0.0.1:43123".to_owned()],
            true,
            std::iter::empty(),
        )
        .unwrap();
        assert!(policy.allows_url("https://widget.test/path"));
        assert!(policy.allows_url("commet://widget/bridge"));
        assert!(policy.allows_url("http://127.0.0.1:43123/bootstrap"));
        assert!(policy.allows_url("commet://fixture"));
        assert!(policy.allows_url("commet://fixture/health"));
        assert!(!policy.allows_url("commet://fixture?redirect=https://evil"));
        assert!(SurfacePolicy::with_navigation(
            std::iter::empty(),
            ["http://[::1]:43123".to_owned()],
            false,
            std::iter::empty(),
        )
        .unwrap()
        .allows_url("http://[::1]:43123/bootstrap"));
        assert!(policy.allows_url("commet://fixture/"));
        assert!(!policy.allows_url("http://widget.test/path"));
        assert!(!policy.allows_url("http://127.0.0.1:43124/bootstrap"));
        assert!(!policy.allows_url("file:///C:/secret"));
        assert!(!policy.allows_url("javascript:alert(1)"));
        assert!(!policy.allows_url("data:text/html,unsafe"));
    }

    #[test]
    fn navigation_policy_requires_explicit_user_externalization() {
        let policy = SurfacePolicy::with_navigation(
            ["https://widget.test".to_owned()],
            std::iter::empty(),
            true,
            std::iter::empty(),
        )
        .unwrap();
        let external = NavigationRequest::new(
            "https://sso.example/login",
            NavigationDisposition::External,
            true,
        )
        .unwrap();
        assert_eq!(
            policy.navigation_decision(&external),
            NavigationPolicyDecision::External
        );
        let automatic = NavigationRequest::new(
            "https://sso.example/login",
            NavigationDisposition::External,
            false,
        )
        .unwrap();
        assert_eq!(
            policy.navigation_decision(&automatic),
            NavigationPolicyDecision::Blocked
        );
        let unsafe_redirect = NavigationRequest::new(
            "https://evil.example/redirect",
            NavigationDisposition::Current,
            false,
        )
        .unwrap();
        assert_eq!(
            policy.navigation_decision(&unsafe_redirect),
            NavigationPolicyDecision::Blocked
        );
        let deliberate_link = NavigationRequest::new(
            "https://sso.example/login",
            NavigationDisposition::Current,
            true,
        )
        .unwrap();
        assert_eq!(
            policy.navigation_decision(&deliberate_link),
            NavigationPolicyDecision::External
        );
    }

    #[test]
    fn policy_rejects_non_https_and_non_loopback_declarations() {
        assert!(SurfacePolicy::new(["http://widget.test".to_owned()], std::iter::empty()).is_err());
        assert!(
            SurfacePolicy::new(["https://widget.test/path".to_owned()], std::iter::empty())
                .is_err()
        );
        assert!(SurfacePolicy::new(["https://evil:1:2".to_owned()], std::iter::empty()).is_err());
        assert!(NavigationRequest::new(
            "https://widget.test:",
            NavigationDisposition::Current,
            false,
        )
        .is_err());
        assert!(NavigationRequest::new(
            "https://widget.test:not-a-port",
            NavigationDisposition::Current,
            false,
        )
        .is_err());
        assert!(SurfacePolicy::with_navigation(
            std::iter::empty(),
            ["http://10.0.0.1:43123".to_owned()],
            false,
            std::iter::empty(),
        )
        .is_err());
        assert!(SurfacePolicy::with_navigation(
            std::iter::empty(),
            ["http://127.0.0.1".to_owned()],
            false,
            std::iter::empty(),
        )
        .is_err());
    }

    #[test]
    fn framed_codec_rejects_malformed_oversized_and_unknown_messages() {
        let codec = FramedCodec::with_limit("nonce", 256).unwrap();
        let message = WireMessage::Ack { request_id: 1 };
        let encoded = codec.encode(&message).unwrap();
        assert_eq!(codec.decode(&encoded).unwrap(), message);
        let heartbeat = WireMessage::Heartbeat { request_id: 9 };
        let encoded = codec.encode(&heartbeat).unwrap();
        assert_eq!(codec.decode(&encoded).unwrap(), heartbeat);

        let mut partial = encoded[..encoded.len() - 1].to_vec();
        assert!(codec.decode_next(&mut partial).unwrap().is_none());

        let mut unknown_body = serde_json::to_vec(&json!({
            "version": PROTOCOL_VERSION,
            "nonce": "nonce",
            "message": {"type": "future", "payload": {}}
        }))
        .unwrap();
        let length = u32::try_from(unknown_body.len()).unwrap();
        let mut unknown = length.to_be_bytes().to_vec();
        unknown.append(&mut unknown_body);
        assert!(matches!(
            codec.decode(&unknown),
            Err(ProtocolError::UnknownMessageType(type_name)) if type_name == "future"
        ));

        let mut oversized = (257_u32).to_be_bytes().to_vec();
        oversized.extend_from_slice(&[0; 257]);
        assert!(matches!(
            codec.decode(&oversized),
            Err(ProtocolError::FrameTooLarge {
                size: 257,
                max: 256
            })
        ));
    }
}
