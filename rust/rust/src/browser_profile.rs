//! Account-bound browser profile storage and request-context lifetime policy.
//!
//! This module deliberately knows nothing about CEF.  The native hosts use
//! the paths and context lifetime returned here to create request contexts;
//! the profile key is the stable local account-record identity, never a
//! Matrix user id or a caller-provided path.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;

use crate::browser_runtime::{PrivacyMode, ProfileKey};

const PROFILE_SCHEMA: &str = "1";
const PROFILE_MANIFEST: &str = "profile.manifest";
const QUARANTINE_PREFIX: &str = "quarantine-";

/// Coarse profile failures used by the host boundary.  Paths and profile keys
/// are intentionally not included in the display text sent to the caller.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProfileError {
    /// The profile is busy with a live surface or popup.
    Busy,
    /// The profile is not safe to open (permissions, links, or path shape).
    Security,
    /// The profile cannot be read or created.
    Unavailable,
    /// A profile manifest or directory is corrupt or belongs to another key.
    Corrupt,
    /// Existing bytes were quarantined and require re-authentication or an
    /// explicit, versioned migration.
    MigrationFailed,
    /// A filesystem operation failed after validation.
    Io,
}

impl ProfileError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Busy => "profile_busy",
            Self::Security | Self::Unavailable | Self::Io => "profile_unavailable",
            Self::Corrupt | Self::MigrationFailed => "profile_corrupt",
        }
    }
}

/// The kind of CEF request context a surface owns.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProfileContextKind {
    Persistent,
    Private,
}

/// A host-owned request-context lease.  Persistent leases for one account
/// share `context_id`; private leases always receive a fresh id and no path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProfileContext {
    context_id: u64,
    profile_key: ProfileKey,
    kind: ProfileContextKind,
    path: Option<PathBuf>,
}

impl ProfileContext {
    pub fn context_id(&self) -> u64 {
        self.context_id
    }

    pub fn profile_key(&self) -> &ProfileKey {
        &self.profile_key
    }

    pub fn kind(&self) -> ProfileContextKind {
        self.kind
    }

    /// Persistent contexts expose their generated directory.  Private
    /// contexts intentionally return `None` and never create one.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }
}

/// Evidence returned only after an account profile has been quiesced, closed,
/// cleared, and recreated successfully.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProfileClearResult {
    profile_key: ProfileKey,
    profile_path: PathBuf,
    preserved_downloads: bool,
}

impl ProfileClearResult {
    pub fn profile_key(&self) -> &ProfileKey {
        &self.profile_key
    }

    pub fn profile_path(&self) -> &Path {
        &self.profile_path
    }

    pub fn preserved_downloads(&self) -> bool {
        self.preserved_downloads
    }
}

#[derive(Clone, Debug)]
struct PersistentContext {
    context: ProfileContext,
    active_surfaces: usize,
}

/// Account profile and request-context registry owned by one host process.
///
/// The registry is the authoritative sharing boundary: all persistent
/// surfaces for a key receive the same context id, while each private surface
/// receives an in-memory context that is removed when its lease is released.
pub struct ProfileStore {
    root: PathBuf,
    next_context_id: u64,
    persistent: BTreeMap<ProfileKey, PersistentContext>,
    private: BTreeMap<u64, ProfileContext>,
    clearing: BTreeSet<ProfileKey>,
}

impl ProfileStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            next_context_id: 1,
            persistent: BTreeMap::new(),
            private: BTreeMap::new(),
            clearing: BTreeSet::new(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Open or share a context for a surface.
    pub fn open(
        &mut self,
        key: &ProfileKey,
        privacy: PrivacyMode,
    ) -> Result<ProfileContext, ProfileError> {
        if ProfileKey::new(key.as_str().to_owned()).is_err() {
            return Err(ProfileError::Security);
        }
        if self.clearing.contains(key) {
            return Err(ProfileError::Busy);
        }
        match privacy {
            PrivacyMode::Persistent => {
                if self.persistent.contains_key(key) {
                    // Re-check the generated directory before handing an
                    // existing request context to a new surface.  A profile
                    // replaced while the host was alive is never silently
                    // adopted by another surface.
                    let expected_path = self
                        .persistent
                        .get(key)
                        .ok_or(ProfileError::Unavailable)?
                        .context
                        .path()
                        .ok_or(ProfileError::Unavailable)?
                        .to_owned();
                    let path = self.ensure_existing_profile(key, &expected_path)?;
                    let existing = self
                        .persistent
                        .get_mut(key)
                        .ok_or(ProfileError::Unavailable)?;
                    if existing.context.path() != Some(path.as_path()) {
                        return Err(ProfileError::Corrupt);
                    }
                    existing.active_surfaces = existing.active_surfaces.saturating_add(1);
                    return Ok(existing.context.clone());
                }
                let path = self.ensure_profile(key)?;
                let context = ProfileContext {
                    context_id: self.allocate_context_id()?,
                    profile_key: key.clone(),
                    kind: ProfileContextKind::Persistent,
                    path: Some(path),
                };
                self.persistent.insert(
                    key.clone(),
                    PersistentContext {
                        context: context.clone(),
                        active_surfaces: 1,
                    },
                );
                Ok(context)
            }
            PrivacyMode::Private => {
                // A private context has no cache path and is never inserted
                // into the persistent registry.  The private map only tracks
                // its lifetime until the last surface releases it.
                let context = ProfileContext {
                    context_id: self.allocate_context_id()?,
                    profile_key: key.clone(),
                    kind: ProfileContextKind::Private,
                    path: None,
                };
                self.private.insert(context.context_id, context.clone());
                Ok(context)
            }
        }
    }

    /// Release one surface's context lease.  Persistent contexts stay alive
    /// for the host lifetime so a later same-account surface sees the same
    /// request context; private contexts disappear immediately.
    pub fn release(&mut self, context_id: u64) -> Result<(), ProfileError> {
        if self.private.remove(&context_id).is_some() {
            return Ok(());
        }
        if let Some(context) = self
            .persistent
            .values_mut()
            .find(|context| context.context.context_id == context_id)
        {
            if context.active_surfaces == 0 {
                return Err(ProfileError::Unavailable);
            }
            context.active_surfaces -= 1;
            return Ok(());
        }
        Err(ProfileError::Unavailable)
    }

    /// Number of live surface leases for an account, including private
    /// contexts.  Clear-data uses this to enforce account-wide quiescence.
    pub fn active_surfaces(&self, key: &ProfileKey) -> usize {
        let persistent = self
            .persistent
            .get(key)
            .map(|context| context.active_surfaces)
            .unwrap_or(0);
        persistent
            + self
                .private
                .values()
                .filter(|context| context.profile_key == *key)
                .count()
    }

    /// Clear every browser-owned byte for an account after quiescence.  The
    /// manifest and an explicitly committed `downloads` directory are kept;
    /// Matrix/app data are outside this root and are never touched.
    pub fn clear_data(&mut self, key: &ProfileKey) -> Result<ProfileClearResult, ProfileError> {
        if ProfileKey::new(key.as_str().to_owned()).is_err() {
            return Err(ProfileError::Security);
        }
        if self.active_surfaces(key) != 0 {
            return Err(ProfileError::Busy);
        }
        if self.clearing.contains(key) {
            return Err(ProfileError::Busy);
        }
        self.clearing.insert(key.clone());
        // Drop the old request context before touching its directory.  A
        // successful result therefore cannot race an old context.
        self.persistent.remove(key);
        let result = (|| {
            let path = self.ensure_profile(key)?;
            let preserved_downloads = clear_browser_data(&path)?;
            // Re-validate the manifest after cleanup.  This is the point at
            // which the old profile is unreachable by this registry.
            self.ensure_profile(key)?;
            Ok(ProfileClearResult {
                profile_key: key.clone(),
                profile_path: path,
                preserved_downloads,
            })
        })();
        self.clearing.remove(key);
        result
    }

    pub fn shutdown(&mut self) {
        self.persistent.clear();
        self.private.clear();
        self.clearing.clear();
    }

    fn allocate_context_id(&mut self) -> Result<u64, ProfileError> {
        let id = self.next_context_id;
        self.next_context_id = self
            .next_context_id
            .checked_add(1)
            .ok_or(ProfileError::Unavailable)?;
        Ok(id)
    }

    fn ensure_profile(&self, key: &ProfileKey) -> Result<PathBuf, ProfileError> {
        let root = self.ensure_root()?;
        let directory = root.join(profile_directory_name(key));
        if !is_direct_child(&root, &directory) {
            return Err(ProfileError::Security);
        }

        let created = match symlink_metadata(&directory) {
            Ok(metadata) => {
                ensure_owner_directory(&directory, &metadata)?;
                false
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {
                create_private_directory(&directory).map_err(map_io)?;
                true
            }
            Err(_) => return Err(ProfileError::Unavailable),
        };
        let metadata = symlink_metadata(&directory).map_err(map_io)?;
        ensure_owner_directory(&directory, &metadata)?;
        reject_links_below(&directory)?;

        let manifest = directory.join(PROFILE_MANIFEST);
        let expected = profile_manifest(key);
        match read_manifest(&manifest) {
            Ok(actual) if actual == expected => Ok(directory),
            Ok(_) => self.quarantine(&directory),
            Err(error) if error.kind() == ErrorKind::NotFound && created => {
                write_manifest(&directory, &expected).map_err(map_io)?;
                Ok(directory)
            }
            Err(error) if error.kind() == ErrorKind::NotFound => self.quarantine(&directory),
            Err(_) => self.quarantine(&directory),
        }
    }

    fn ensure_existing_profile(
        &self,
        key: &ProfileKey,
        expected_path: &Path,
    ) -> Result<PathBuf, ProfileError> {
        match symlink_metadata(expected_path) {
            Ok(_) => {
                let path = self.ensure_profile(key)?;
                if path != expected_path {
                    return Err(ProfileError::Corrupt);
                }
                Ok(path)
            }
            Err(error) if error.kind() == ErrorKind::NotFound => Err(ProfileError::MigrationFailed),
            Err(_) => Err(ProfileError::Unavailable),
        }
    }

    fn ensure_root(&self) -> Result<PathBuf, ProfileError> {
        validate_path_shape(&self.root)?;
        match symlink_metadata(&self.root) {
            Ok(metadata) => {
                ensure_owner_directory(&self.root, &metadata)?;
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {
                let parent = self.root.parent().ok_or(ProfileError::Security)?;
                validate_existing_ancestors(parent)?;
                create_private_directory(&self.root).map_err(map_io)?;
                let metadata = symlink_metadata(&self.root).map_err(map_io)?;
                ensure_owner_directory(&self.root, &metadata)?;
            }
            Err(_) => return Err(ProfileError::Unavailable),
        }
        validate_existing_ancestors(&self.root)?;
        Ok(self.root.clone())
    }

    fn quarantine(&self, directory: &Path) -> Result<PathBuf, ProfileError> {
        let root = self.ensure_root()?;
        if !is_direct_child(&root, directory) {
            return Err(ProfileError::Security);
        }
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ProfileError::Unavailable)?
            .as_nanos();
        let quarantine = root.join(format!(
            "{QUARANTINE_PREFIX}{stamp:x}-{}",
            profile_directory_name_from_path(directory)
        ));
        if symlink_metadata(&quarantine).is_ok() {
            return Err(ProfileError::Unavailable);
        }
        fs::rename(directory, &quarantine).map_err(map_io)?;
        Err(ProfileError::MigrationFailed)
    }
}

fn map_io(error: io::Error) -> ProfileError {
    match error.kind() {
        ErrorKind::PermissionDenied => ProfileError::Security,
        ErrorKind::NotFound => ProfileError::Unavailable,
        _ => ProfileError::Io,
    }
}

fn profile_manifest(key: &ProfileKey) -> String {
    format!(
        "schema={PROFILE_SCHEMA}\nprofile_key={}\n",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(key.as_str())
    )
}

fn profile_directory_name(key: &ProfileKey) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in key.as_str().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("profile-{hash:016x}")
}

fn profile_directory_name_from_path(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("unknown")
        .to_owned()
}

fn validate_path_shape(path: &Path) -> Result<(), ProfileError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
    {
        return Err(ProfileError::Security);
    }
    Ok(())
}

fn is_direct_child(root: &Path, child: &Path) -> bool {
    child.parent() == Some(root)
        && child
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| {
                name.starts_with("profile-")
                    && !name.bytes().any(|byte| byte == b'/' || byte == b'\\')
            })
}

fn validate_existing_ancestors(path: &Path) -> Result<(), ProfileError> {
    let mut current = Some(path);
    while let Some(candidate) = current {
        match symlink_metadata(candidate) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err(ProfileError::Security);
                }
                if !metadata.is_dir() {
                    return Err(ProfileError::Security);
                }
            }
            Err(error) if error.kind() == ErrorKind::NotFound => {}
            Err(_) => return Err(ProfileError::Unavailable),
        }
        current = candidate.parent();
    }
    Ok(())
}

fn ensure_owner_directory(_path: &Path, metadata: &fs::Metadata) -> Result<(), ProfileError> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(ProfileError::Security);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(ProfileError::Security);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(ProfileError::Security);
        }
    }
    Ok(())
}

fn symlink_metadata(path: &Path) -> io::Result<fs::Metadata> {
    fs::symlink_metadata(path)
}

fn reject_links_below(directory: &Path) -> Result<(), ProfileError> {
    let entries = fs::read_dir(directory).map_err(map_io)?;
    for entry in entries {
        let entry = entry.map_err(map_io)?;
        let metadata = symlink_metadata(&entry.path()).map_err(map_io)?;
        if metadata.file_type().is_symlink() {
            return Err(ProfileError::Security);
        }
        if metadata.is_dir() {
            reject_links_below(&entry.path())?;
        }
    }
    Ok(())
}

fn read_manifest(path: &Path) -> io::Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "invalid profile manifest",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                ErrorKind::PermissionDenied,
                "manifest ownership",
            ));
        }
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(path)?;
    let mut contents = String::new();
    file.read_to_string(&mut contents)?;
    Ok(contents)
}

fn write_manifest(directory: &Path, contents: &str) -> io::Result<()> {
    let temporary = directory.join("profile.manifest.new");
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // create_new plus O_NOFOLLOW protects against an attacker-created
        // symlink; chmod makes the owner-only contract explicit.
        options.custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&temporary)?;
    #[cfg(unix)]
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
    fs::rename(temporary, directory.join(PROFILE_MANIFEST))?;
    Ok(())
}

#[cfg(unix)]
fn create_private_directory(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().mode(0o700).create(path)
}

#[cfg(not(unix))]
fn create_private_directory(path: &Path) -> io::Result<()> {
    fs::create_dir(path)
}

fn clear_browser_data(directory: &Path) -> Result<bool, ProfileError> {
    let mut preserved_downloads = false;
    for entry in fs::read_dir(directory).map_err(map_io)? {
        let entry = entry.map_err(map_io)?;
        let name = entry.file_name();
        if name == PROFILE_MANIFEST {
            continue;
        }
        if name == "downloads" {
            let metadata = symlink_metadata(&entry.path()).map_err(map_io)?;
            if metadata.file_type().is_symlink() {
                return Err(ProfileError::Security);
            }
            preserved_downloads = true;
            continue;
        }
        let metadata = symlink_metadata(&entry.path()).map_err(map_io)?;
        if metadata.file_type().is_symlink() {
            return Err(ProfileError::Security);
        }
        remove_tree(&entry.path())?;
    }
    Ok(preserved_downloads)
}

fn remove_tree(path: &Path) -> Result<(), ProfileError> {
    let metadata = symlink_metadata(path).map_err(map_io)?;
    if metadata.file_type().is_symlink() {
        return Err(ProfileError::Security);
    }
    if metadata.is_dir() {
        for entry in fs::read_dir(path).map_err(map_io)? {
            remove_tree(&entry.map_err(map_io)?.path())?;
        }
        fs::remove_dir(path).map_err(map_io)?;
    } else {
        fs::remove_file(path).map_err(map_io)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs::{self, File};
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = env::temp_dir().join(format!(
            "roscord-profile-{name}-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        #[cfg(unix)]
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        root
    }

    #[test]
    fn same_account_shares_persistent_context_but_accounts_do_not() {
        let root = temp_root("sharing");
        let mut store = ProfileStore::new(root.clone());
        let account_a = ProfileKey::new("account-a").unwrap();
        let account_b = ProfileKey::new("account-b").unwrap();
        let first = store.open(&account_a, PrivacyMode::Persistent).unwrap();
        let second = store.open(&account_a, PrivacyMode::Persistent).unwrap();
        let other = store.open(&account_b, PrivacyMode::Persistent).unwrap();
        assert_eq!(first.context_id(), second.context_id());
        assert_ne!(first.context_id(), other.context_id());
        assert_eq!(first.kind(), ProfileContextKind::Persistent);
        assert_ne!(first.path(), other.path());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn private_contexts_are_distinct_and_leave_no_profile_directory() {
        let root = temp_root("private");
        let mut store = ProfileStore::new(root.clone());
        let key = ProfileKey::new("account-a").unwrap();
        let first = store.open(&key, PrivacyMode::Private).unwrap();
        let second = store.open(&key, PrivacyMode::Private).unwrap();
        assert_ne!(first.context_id(), second.context_id());
        assert_eq!(first.kind(), ProfileContextKind::Private);
        assert!(first.path().is_none());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
        store.release(first.context_id()).unwrap();
        store.release(second.context_id()).unwrap();
        assert_eq!(store.active_surfaces(&key), 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn missing_or_mismatched_manifests_are_quarantined_without_reset() {
        let root = temp_root("quarantine");
        let key = ProfileKey::new("account-a").unwrap();
        let directory = root.join(profile_directory_name(&key));
        fs::create_dir(&directory).unwrap();
        File::create(directory.join("old-cookie.sqlite")).unwrap();
        let mut store = ProfileStore::new(root.clone());
        assert_eq!(
            store.open(&key, PrivacyMode::Persistent),
            Err(ProfileError::MigrationFailed)
        );
        assert!(!directory.exists());
        let quarantined = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(QUARANTINE_PREFIX)
            })
            .unwrap();
        assert!(quarantined.path().join("old-cookie.sqlite").exists());

        let mismatched = root.join(profile_directory_name(&key));
        fs::create_dir(&mismatched).unwrap();
        let other_key = ProfileKey::new("account-b").unwrap();
        fs::write(
            mismatched.join(PROFILE_MANIFEST),
            profile_manifest(&other_key),
        )
        .unwrap();
        assert_eq!(
            store.open(&key, PrivacyMode::Persistent),
            Err(ProfileError::MigrationFailed)
        );
        assert!(fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(QUARANTINE_PREFIX)
            }));

        let stable_key = ProfileKey::new("account-c").unwrap();
        let stable_context = store.open(&stable_key, PrivacyMode::Persistent).unwrap();
        let stable_directory = stable_context.path().unwrap();
        fs::remove_file(stable_directory.join(PROFILE_MANIFEST)).unwrap();
        assert_eq!(
            store.open(&stable_key, PrivacyMode::Persistent),
            Err(ProfileError::MigrationFailed)
        );
        assert_eq!(
            store.open(&stable_key, PrivacyMode::Persistent),
            Err(ProfileError::MigrationFailed)
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn clear_data_requires_quiescence_and_preserves_downloads() {
        let root = temp_root("clear");
        let key = ProfileKey::new("account-a").unwrap();
        let mut store = ProfileStore::new(root.clone());
        let context = store.open(&key, PrivacyMode::Persistent).unwrap();
        let directory = context.path().unwrap().to_owned();
        fs::create_dir(directory.join("downloads")).unwrap();
        File::create(directory.join("downloads").join("committed.bin")).unwrap();
        File::create(directory.join("old-cache.bin")).unwrap();
        assert_eq!(store.clear_data(&key), Err(ProfileError::Busy));
        store.release(context.context_id()).unwrap();
        let private = store.open(&key, PrivacyMode::Private).unwrap();
        assert_eq!(store.clear_data(&key), Err(ProfileError::Busy));
        store.release(private.context_id()).unwrap();
        let result = store.clear_data(&key).unwrap();
        assert!(result.preserved_downloads());
        assert!(directory.join("downloads").join("committed.bin").exists());
        assert!(!directory.join("old-cache.bin").exists());
        assert!(directory.join(PROFILE_MANIFEST).exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn profile_root_and_manifest_reject_links_and_unsafe_permissions() {
        let root = temp_root("security");
        let outside = temp_root("outside");
        let link = root.join("profile-link");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        let key = ProfileKey::new("link-key").unwrap();
        let mut store = ProfileStore::new(root.clone());
        // The generated name cannot select the arbitrary link, and a link used
        // as the app-data root is rejected before any profile is opened.
        let linked_store = ProfileStore::new(link);
        assert_eq!(
            linked_store.open(&key, PrivacyMode::Persistent),
            Err(ProfileError::Security)
        );
        let directory = root.join(profile_directory_name(&key));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            store.open(&key, PrivacyMode::Persistent),
            Err(ProfileError::Security)
        );
        fs::remove_dir_all(root).unwrap();
        fs::remove_dir_all(outside).unwrap();
    }
}
