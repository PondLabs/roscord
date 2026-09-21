//! Mediated file access for BrowserRuntime surfaces: downloads, clipboard,
//! and uploads.
//!
//! The page's download filename is untrusted, clipboard reads and writes
//! require explicit app decisions, and uploads only proceed through one
//! OS/portal chooser with a read-only staged handoff.  This module owns the
//! pure policy; the CEF hosts enforce it at their download, clipboard, and
//! file-dialog callbacks and the Dart adapter mirrors it in
//! `commet/lib/browser_runtime/file_access.dart`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::browser_runtime::{ClipboardDecision, SurfaceId, UploadDecision};

/// One-shot prompt budget for file-access requests in milliseconds.
pub const FILE_ACCESS_REQUEST_TIMEOUT_MS: u64 = 30_000;

/// Maximum accepted download filename length in bytes.
pub const MAX_DOWNLOAD_FILE_NAME_BYTES: usize = 255;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FileAccessError {
    InvalidName(String),
    NoFreeName,
    UnknownRequest,
    DuplicateRequest,
    EmptyRequestId,
}

impl std::fmt::Display for FileAccessError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidName(message) => write!(formatter, "invalid download name: {message}"),
            Self::NoFreeName => formatter.write_str("no free non-overwriting download name"),
            Self::UnknownRequest => formatter.write_str("unknown file-access request"),
            Self::DuplicateRequest => formatter.write_str("request id is already pending"),
            Self::EmptyRequestId => formatter.write_str("request id must not be empty"),
        }
    }
}

impl std::error::Error for FileAccessError {}

/// Returns a safe destination leaf for a page-suggested download name.
///
/// Rejects traversal, separators, drive prefixes, control characters,
/// dot segments, and Windows reserved device names.  Trailing dots and
/// spaces are stripped (Windows forbids them); a name that is empty after
/// stripping is rejected.
pub fn sanitize_suggested_download_name(suggested: &str) -> Result<String, FileAccessError> {
    if suggested.is_empty() {
        return Err(FileAccessError::InvalidName("name is empty".into()));
    }
    if suggested.chars().any(|c| c.is_control())
        || suggested.contains('/')
        || suggested.contains('\\')
        || suggested.contains('\0')
    {
        return Err(FileAccessError::InvalidName(
            "name contains a forbidden character".into(),
        ));
    }
    if suggested.len() > 2 && suggested.as_bytes()[1] == b':' {
        return Err(FileAccessError::InvalidName(
            "name must not contain a drive prefix".into(),
        ));
    }
    let mut leaf = suggested.trim().to_owned();
    while leaf.ends_with('.') || leaf.ends_with(' ') {
        leaf.pop();
    }
    if leaf.is_empty() || leaf == "." || leaf == ".." {
        return Err(FileAccessError::InvalidName("name is a dot segment".into()));
    }
    let stem = leaf.split('.').next().unwrap_or("").to_ascii_uppercase();
    const RESERVED: &[&str] = &[
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7",
        "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8",
        "LPT9",
    ];
    if RESERVED.contains(&stem.as_str()) {
        return Err(FileAccessError::InvalidName(
            "name is a reserved device name".into(),
        ));
    }
    if leaf.len() > MAX_DOWNLOAD_FILE_NAME_BYTES {
        return Err(FileAccessError::InvalidName("name is too long".into()));
    }
    Ok(leaf)
}

/// Returns a leaf that does not silently overwrite a sibling.  `existing`
/// holds the lower-cased names already present in the safe destination.
pub fn resolve_non_overwriting_leaf(
    leaf: &str,
    existing: &BTreeSet<String>,
) -> Result<String, FileAccessError> {
    let lower: BTreeSet<String> = existing.iter().map(|name| name.to_ascii_lowercase()).collect();
    if !lower.contains(&leaf.to_ascii_lowercase()) {
        return Ok(leaf.to_owned());
    }
    let (stem, extension) = match leaf.rfind('.') {
        Some(dot) if dot > 0 => leaf.split_at(dot),
        _ => (leaf, ""),
    };
    for counter in 1..=9999_u32 {
        let candidate = format!("{stem} ({counter}){extension}");
        if candidate.len() > MAX_DOWNLOAD_FILE_NAME_BYTES {
            return Err(FileAccessError::NoFreeName);
        }
        if !lower.contains(&candidate.to_ascii_lowercase()) {
            return Ok(candidate);
        }
    }
    Err(FileAccessError::NoFreeName)
}

/// Clipboard reads require a user gesture and an explicit one-shot prompt.
/// The prompt is consumed by a single read; pages never receive a native
/// clipboard handle, only the mediated snapshot.
pub fn decide_clipboard_read(user_gesture: bool, prompt_accepted: bool) -> ClipboardDecision {
    if !user_gesture || !prompt_accepted {
        ClipboardDecision::Deny
    } else {
        ClipboardDecision::Allow
    }
}

/// Clipboard writes require a user gesture and an admitted origin.  There is
/// no standing grant: every write is checked against the declared origins.
pub fn decide_clipboard_write(
    user_gesture: bool,
    origin: &str,
    admitted_origins: &[String],
) -> ClipboardDecision {
    if !user_gesture || origin.is_empty() {
        return ClipboardDecision::Deny;
    }
    if admitted_origins.iter().any(|admitted| admitted == origin) {
        ClipboardDecision::Allow
    } else {
        ClipboardDecision::Deny
    }
}

/// Uploads proceed only after the app shows exactly one OS/portal chooser
/// for the request.  Accept means "show the chooser"; the host stages the
/// user's explicit selection as read-only copies and never reveals a real
/// path, enumerates a directory, or keeps a persistent grant.
pub fn decide_upload(chooser_shown: bool, user_confirmed: bool) -> UploadDecision {
    if !chooser_shown {
        UploadDecision::Deny
    } else if user_confirmed {
        UploadDecision::Accept
    } else {
        UploadDecision::Cancel
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileAccessKind {
    Download,
    ClipboardRead,
    ClipboardWrite,
    Upload,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileAccessCancelReason {
    Navigation,
    Close,
    HostLoss,
    Timeout,
    Denied,
    UnavailableUi,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingFileAccessRequest {
    pub surface_id: SurfaceId,
    pub request_id: String,
    pub kind: FileAccessKind,
    pub created_ms: u64,
    pub timeout_ms: u64,
}

impl PendingFileAccessRequest {
    pub fn new(
        surface_id: SurfaceId,
        request_id: impl Into<String>,
        kind: FileAccessKind,
        created_ms: u64,
    ) -> Self {
        Self {
            surface_id,
            request_id: request_id.into(),
            kind,
            created_ms,
            timeout_ms: FILE_ACCESS_REQUEST_TIMEOUT_MS,
        }
    }

    pub fn expired_at(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.created_ms) >= self.timeout_ms
    }
}

/// Deterministic registry for pending download/clipboard/upload requests.
///
/// The adapter registers a host request and cancels it when the surface
/// navigates, closes, the host is lost, the one-shot prompt times out, the
/// app denies it, or no UI can be shown.  Cancellation is idempotent and
/// terminal.
#[derive(Clone, Debug, Default)]
pub struct PendingFileAccessRegistry {
    pending: BTreeMap<String, PendingFileAccessRequest>,
}

impl PendingFileAccessRegistry {
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    pub fn contains(&self, request_id: &str) -> bool {
        self.pending.contains_key(request_id)
    }

    pub fn register(&mut self, request: PendingFileAccessRequest) -> Result<(), FileAccessError> {
        if request.request_id.is_empty() {
            return Err(FileAccessError::EmptyRequestId);
        }
        if self.pending.contains_key(&request.request_id) {
            return Err(FileAccessError::DuplicateRequest);
        }
        self.pending.insert(request.request_id.clone(), request);
        Ok(())
    }

    /// Removes a request after the app produced a terminal decision.
    pub fn resolve(&mut self, request_id: &str) -> bool {
        self.pending.remove(request_id).is_some()
    }

    pub fn cancel_for_navigation(
        &mut self,
        surface_id: SurfaceId,
    ) -> Vec<PendingFileAccessRequest> {
        self.remove_where(|request| request.surface_id == surface_id)
    }

    pub fn cancel_for_close(&mut self, surface_id: SurfaceId) -> Vec<PendingFileAccessRequest> {
        self.remove_where(|request| request.surface_id == surface_id)
    }

    pub fn cancel_for_host_loss(&mut self) -> Vec<PendingFileAccessRequest> {
        self.remove_where(|_| true)
    }

    pub fn cancel_for_unavailable_ui(
        &mut self,
        surface_id: SurfaceId,
    ) -> Vec<PendingFileAccessRequest> {
        self.remove_where(|request| request.surface_id == surface_id)
    }

    pub fn cancel_denied(&mut self, request_id: &str) -> Vec<PendingFileAccessRequest> {
        let id = request_id.to_owned();
        self.remove_where(move |request| request.request_id == id)
    }

    pub fn expire(&mut self, now_ms: u64) -> Vec<PendingFileAccessRequest> {
        self.remove_where(|request| request.expired_at(now_ms))
    }

    fn remove_where(
        &mut self,
        matches: impl Fn(&PendingFileAccessRequest) -> bool,
    ) -> Vec<PendingFileAccessRequest> {
        let ids = self
            .pending
            .values()
            .filter(|request| matches(request))
            .map(|request| request.request_id.clone())
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| self.pending.remove(&id))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str, surface: u64) -> PendingFileAccessRequest {
        PendingFileAccessRequest::new(SurfaceId(surface), id, FileAccessKind::Download, 1000)
    }

    #[test]
    fn safe_leaf_names_are_accepted() {
        assert_eq!(
            sanitize_suggested_download_name("report.pdf").unwrap(),
            "report.pdf"
        );
        assert_eq!(
            sanitize_suggested_download_name("trailing. ").unwrap(),
            "trailing"
        );
    }

    #[test]
    fn traversal_separators_and_drive_prefixes_are_rejected() {
        for name in ["../secret", "a/b", "a\\b", "C:secret", "", "..", "."] {
            assert!(sanitize_suggested_download_name(name).is_err(), "{name}");
        }
        assert!(sanitize_suggested_download_name("a\x01b").is_err());
        for name in ["CON", "con.txt", "NUL", "COM1", "lpt9.dat"] {
            assert!(sanitize_suggested_download_name(name).is_err(), "{name}");
        }
    }

    #[test]
    fn destinations_never_silently_overwrite() {
        let existing = BTreeSet::from(["a.pdf".to_owned()]);
        assert_eq!(
            resolve_non_overwriting_leaf("a.pdf", &existing).unwrap(),
            "a (1).pdf"
        );
        let existing = BTreeSet::from(["a.pdf".to_owned(), "a (1).pdf".to_owned()]);
        assert_eq!(
            resolve_non_overwriting_leaf("a.pdf", &existing).unwrap(),
            "a (2).pdf"
        );
        assert_eq!(
            resolve_non_overwriting_leaf("README", &BTreeSet::from(["readme".to_owned()]))
                .unwrap(),
            "README (1)"
        );
        assert_eq!(
            resolve_non_overwriting_leaf("a.pdf", &BTreeSet::new()).unwrap(),
            "a.pdf"
        );
    }

    #[test]
    fn clipboard_reads_need_gesture_and_prompt() {
        assert_eq!(
            decide_clipboard_read(false, true),
            ClipboardDecision::Deny
        );
        assert_eq!(
            decide_clipboard_read(true, false),
            ClipboardDecision::Deny
        );
        assert_eq!(
            decide_clipboard_read(true, true),
            ClipboardDecision::Allow
        );
    }

    #[test]
    fn clipboard_writes_need_gesture_and_admitted_origin() {
        let admitted = ["https://widgets.test".to_owned()];
        assert_eq!(
            decide_clipboard_write(false, "https://widgets.test", &admitted),
            ClipboardDecision::Deny
        );
        assert_eq!(
            decide_clipboard_write(true, "https://attacker.test", &admitted),
            ClipboardDecision::Deny
        );
        assert_eq!(
            decide_clipboard_write(true, "https://widgets.test", &admitted),
            ClipboardDecision::Allow
        );
    }

    #[test]
    fn uploads_require_an_explicit_chooser() {
        assert_eq!(decide_upload(false, true), UploadDecision::Deny);
        assert_eq!(decide_upload(true, false), UploadDecision::Cancel);
        assert_eq!(decide_upload(true, true), UploadDecision::Accept);
    }

    #[test]
    fn pending_requests_cancel_by_scope_and_timeout() {
        let mut registry = PendingFileAccessRegistry::default();
        registry.register(request("a", 1)).unwrap();
        registry.register(request("b", 2)).unwrap();
        let cancelled = registry.cancel_for_navigation(SurfaceId(1));
        assert_eq!(cancelled.len(), 1);
        assert!(!registry.contains("a"));
        assert!(registry.contains("b"));
        assert_eq!(registry.cancel_for_close(SurfaceId(2)).len(), 1);
        assert!(registry.is_empty());

        registry.register(request("c", 1)).unwrap();
        registry.register(request("d", 2)).unwrap();
        assert_eq!(registry.cancel_denied("c").len(), 1);
        assert_eq!(registry.cancel_for_host_loss().len(), 1);

        registry.register(request("e", 1)).unwrap();
        assert_eq!(
            registry.expire(1000 + FILE_ACCESS_REQUEST_TIMEOUT_MS).len(),
            1
        );
        registry.register(request("f", 1)).unwrap();
        assert_eq!(registry.cancel_for_unavailable_ui(SurfaceId(1)).len(), 1);
        assert!(!registry.resolve("missing"));
    }

    #[test]
    fn duplicate_registration_is_rejected() {
        let mut registry = PendingFileAccessRegistry::default();
        registry.register(request("a", 1)).unwrap();
        assert_eq!(
            registry.register(request("a", 1)),
            Err(FileAccessError::DuplicateRequest)
        );
    }
}
