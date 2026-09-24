//! Linux `cef_host` transport and launch boundary.
//!
//! The host is deliberately a separate process.  It validates the bundled
//! CEF payload before opening a socket, executes CEF's shared-process entry
//! point when Chromium starts a child, and only exposes the typed
//! [`crate::browser_runtime::WireMessage`] protocol to the application.
//!
//! This module owns no Flutter objects and does not expose CEF pointers,
//! callbacks, or buffers.  The browser engine can therefore be brought up
//! behind the same transport without changing the BrowserRuntime seam.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, symlink_metadata};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt as UnixMetadataExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread;

use crate::browser_media::{
    CapturePortalOutcome, HostPermissionRegistry, MediaCapability, MediaPolicyView,
};
use crate::browser_profile::{ProfileContext, ProfileError, ProfileStore};
use crate::browser_runtime::{
    CloseReason, FailureKind, FrameReference, FramedCodec, NavigationDisposition,
    NavigationEvent, NavigationOutcome, NavigationPolicyDecision, NavigationRequest,
    PermissionDecision, PixelFormat, PopupAction, PrivacyMode, ProfileKey, RuntimeError,
    ScriptEnvelope, ScriptSource, SurfaceCommand, SurfaceEvent, SurfaceFailure, SurfaceId,
    SurfacePolicy, SurfaceSpec, WireMessage,
};
use crate::cef_engine::{
    bundled_engine_path, validate_engine_path, BrowserOptions, EngineEvents, EngineLibrary,
    EngineSettings, LOG_ERROR, LOG_WARNING,
};
use serde_json::{json, Value};

const SOCKET_PATH_MAX_BYTES: usize = 107;
const CEF_RELEASE: &str = "Release";
/// CEF child processes are started by Chromium, which does not pass the
/// host's own arguments on; they find the validated runtime through this.
const CEF_ROOT_ENV: &str = "ROSCORD_CEF_ROOT";
const FRAME_RATE_ENV: &str = "ROSCORD_CEF_FRAME_RATE";
const DEFAULT_FRAME_RATE: i32 = 30;
/// Shared-memory frame rings are named `/roscord-cef-<host pid>-<random>-...`.
const FRAME_RING_PREFIX: &str = "roscord-cef-";
/// The staged Linux runtime keeps every file CEF loads in `Release/`, next to
/// libcef.so: on Linux CEF resolves ICU data, the .pak resources and
/// `locales/` from the directory holding libcef.so (DIR_ASSETS), whatever
/// CefSettings says, so the archive's separate `Resources/` cannot be used.
const REQUIRED_CEF_FILES: &[&str] = &[
    "Release/libcef.so",
    "Release/chrome-sandbox",
    "Release/icudtl.dat",
    "Release/libEGL.so",
    "Release/libGLESv2.so",
    "Release/libvk_swiftshader.so",
    "Release/libvulkan.so.1",
    "Release/v8_context_snapshot.bin",
    "Release/vk_swiftshader_icd.json",
    "Release/chrome_100_percent.pak",
    "Release/chrome_200_percent.pak",
    "Release/resources.pak",
    "Release/locales",
];

/// Errors are intentionally coarse at the process boundary.  Detailed CEF
/// and filesystem paths must not cross the authenticated application protocol.
#[derive(Debug)]
pub enum HostError {
    Usage(String),
    Permission(String),
    Endpoint(String),
    Cef(String),
    Protocol(String),
    Runtime(String),
    ProfileBusy,
    ProfileCorrupt,
    ProfileUnavailable,
    MigrationFailed,
    Io(io::Error),
}

impl fmt::Display for HostError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Usage(message) => write!(formatter, "usage error: {message}"),
            Self::Permission(message) => write!(formatter, "permission error: {message}"),
            Self::Endpoint(message) => write!(formatter, "endpoint error: {message}"),
            Self::Cef(message) => write!(formatter, "CEF error: {message}"),
            Self::Protocol(message) => write!(formatter, "protocol error: {message}"),
            Self::Runtime(message) => write!(formatter, "runtime error: {message}"),
            Self::ProfileBusy => formatter.write_str("profile is busy"),
            Self::ProfileCorrupt => formatter.write_str("profile is corrupt"),
            Self::ProfileUnavailable => formatter.write_str("profile is unavailable"),
            Self::MigrationFailed => formatter.write_str("profile migration failed"),
            Self::Io(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for HostError {}

impl From<io::Error> for HostError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Explicit launch inputs supplied by the parent application.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostConfig {
    pub socket_path: PathBuf,
    pub parent_pid: u32,
    pub parent_nonce: String,
    pub cef_root: PathBuf,
    pub profile_root: PathBuf,
    pub max_frame_bytes: usize,
    /// `--cef-software-rendering`: keep rendering on the CPU when GPU
    /// compositing is unavailable.  The frame contract is unchanged.
    pub software_rendering: bool,
}

impl HostConfig {
    pub fn parse<I>(args: I) -> Result<Self, HostError>
    where
        I: IntoIterator<Item = OsString>,
    {
        let mut args = expand_value_arguments(args).into_iter();
        let _program = args.next();
        let mut socket_path = None;
        let mut parent_pid = None;
        let mut parent_nonce = None;
        let mut cef_root = None;
        let mut profile_root = None;
        let mut max_frame_bytes = crate::browser_runtime::DEFAULT_MAX_FRAME_BYTES;
        let mut software_rendering = false;

        while let Some(argument) = args.next() {
            let argument = argument
                .to_str()
                .ok_or_else(|| HostError::Usage("arguments must be valid UTF-8".to_owned()))?;
            match argument {
                "--socket" => socket_path = Some(PathBuf::from(next_value(&mut args, "--socket")?)),
                "--parent-pid" => {
                    let value = next_string(&mut args, "--parent-pid")?;
                    parent_pid = Some(value.parse::<u32>().map_err(|_| {
                        HostError::Usage("--parent-pid must be a non-zero integer".to_owned())
                    })?);
                }
                "--parent-nonce" => parent_nonce = Some(next_string(&mut args, "--parent-nonce")?),
                "--cef-root" => {
                    cef_root = Some(PathBuf::from(next_value(&mut args, "--cef-root")?))
                }
                "--profile-root" => {
                    profile_root = Some(PathBuf::from(next_value(&mut args, "--profile-root")?))
                }
                "--max-frame-bytes" => {
                    let value = next_string(&mut args, "--max-frame-bytes")?;
                    max_frame_bytes = value.parse::<usize>().map_err(|_| {
                        HostError::Usage("--max-frame-bytes must be a positive integer".to_owned())
                    })?;
                }
                "--cef-software-rendering" => software_rendering = true,
                "--cef-validation" | "--cef-validation=true" | "--cef-validation=false" => {
                    return Err(HostError::Usage(
                        "--cef-validation was removed by the cutover; production routing is unconditional"
                            .to_owned(),
                    ));
                }
                argument if argument.starts_with("--cef-fault=") => {
                    return Err(HostError::Usage(
                        "CEF fault injection was removed by the cutover".to_owned(),
                    ));
                }
                "--no-sandbox" | "--disable-sandbox" | "--disable-setuid-sandbox" => {
                    return Err(HostError::Permission(
                        "CEF sandbox bypass flags are not accepted".to_owned(),
                    ));
                }
                "--help" => {
                    return Err(HostError::Usage(
                        "--socket PATH --parent-pid PID --parent-nonce NONCE --cef-root DIR \
                         --profile-root DIR [--max-frame-bytes N] [--cef-software-rendering]"
                            .to_owned(),
                    ));
                }
                unknown if unknown.starts_with("--type=") => {
                    return Err(HostError::Usage(
                        "CEF child arguments must be handled before host configuration".to_owned(),
                    ));
                }
                unknown => {
                    return Err(HostError::Usage(format!("unknown argument {unknown}")));
                }
            }
        }

        let socket_path = socket_path.ok_or_else(|| missing("--socket"))?;
        let parent_pid = parent_pid.ok_or_else(|| missing("--parent-pid"))?;
        let parent_nonce = parent_nonce.ok_or_else(|| missing("--parent-nonce"))?;
        let cef_root = cef_root.ok_or_else(|| missing("--cef-root"))?;
        let profile_root = profile_root.ok_or_else(|| missing("--profile-root"))?;

        if parent_pid == 0 {
            return Err(HostError::Usage("--parent-pid must be non-zero".to_owned()));
        }
        validate_nonce(&parent_nonce)?;
        validate_absolute_path(&socket_path, "--socket")?;
        validate_absolute_path(&cef_root, "--cef-root")?;
        validate_absolute_path(&profile_root, "--profile-root")?;
        if max_frame_bytes == 0 || max_frame_bytes > u32::MAX as usize {
            return Err(HostError::Usage(
                "--max-frame-bytes is outside the protocol limit".to_owned(),
            ));
        }
        if socket_path.as_os_str().as_bytes().len() > SOCKET_PATH_MAX_BYTES {
            return Err(HostError::Usage(
                "--socket path is too long for AF_UNIX".to_owned(),
            ));
        }

        Ok(Self {
            socket_path,
            parent_pid,
            parent_nonce,
            cef_root,
            profile_root,
            max_frame_bytes,
            software_rendering,
        })
    }

    fn validate(&self) -> Result<ValidatedConfig, HostError> {
        reject_elevated_launch()?;
        let cef_root = validate_cef_root(&self.cef_root)?;
        validate_profile_root(&self.profile_root)?;
        let socket_parent = self
            .socket_path
            .parent()
            .ok_or_else(|| HostError::Endpoint("socket path has no parent".to_owned()))?;
        validate_owner_directory(socket_parent, "socket parent")?;
        validate_sandbox(&cef_root)?;
        Ok(ValidatedConfig {
            config: self.clone(),
            cef_root,
        })
    }
}

/// Flags that take a value, accepted as `--flag value` or `--flag=value`
/// (the app uses the second form).
const VALUE_FLAGS: &[&str] = &[
    "--socket",
    "--parent-pid",
    "--parent-nonce",
    "--cef-root",
    "--profile-root",
    "--max-frame-bytes",
];

fn expand_value_arguments<I>(args: I) -> Vec<OsString>
where
    I: IntoIterator<Item = OsString>,
{
    let mut expanded = Vec::new();
    for argument in args {
        if let Some((flag, value)) = argument.to_str().and_then(|text| text.split_once('=')) {
            if VALUE_FLAGS.contains(&flag) {
                expanded.push(OsString::from(flag));
                expanded.push(OsString::from(value));
                continue;
            }
        }
        expanded.push(argument);
    }
    expanded
}

fn next_value(
    args: &mut impl Iterator<Item = OsString>,
    name: &str,
) -> Result<OsString, HostError> {
    args.next()
        .ok_or_else(|| HostError::Usage(format!("{name} requires a value")))
}

fn next_string(args: &mut impl Iterator<Item = OsString>, name: &str) -> Result<String, HostError> {
    next_value(args, name)?
        .into_string()
        .map_err(|_| HostError::Usage("arguments must be valid UTF-8".to_owned()))
}

fn missing(argument: &str) -> HostError {
    HostError::Usage(format!("missing required argument {argument}"))
}

fn validate_nonce(nonce: &str) -> Result<(), HostError> {
    if nonce.len() < 16 || nonce.len() > 256 || !nonce.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(HostError::Usage(
            "--parent-nonce must be 16-256 printable ASCII bytes".to_owned(),
        ));
    }
    Ok(())
}

fn validate_absolute_path(path: &Path, argument: &str) -> Result<(), HostError> {
    if !path.is_absolute() {
        return Err(HostError::Usage(format!("{argument} must be absolute")));
    }
    if path.as_os_str().as_bytes().contains(&0) {
        return Err(HostError::Usage(format!("{argument} contains NUL")));
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct ValidatedConfig {
    config: HostConfig,
    cef_root: PathBuf,
}

fn reject_elevated_launch() -> Result<(), HostError> {
    // CEF's ordinary-user sandbox route must never be entered by a privileged
    // host.  A package manager should install the payload; it must not launch
    // the browser host as root or through a setuid wrapper.
    if unsafe { libc::geteuid() } == 0 {
        return Err(HostError::Permission(
            "cef_host refuses elevated launches".to_owned(),
        ));
    }
    Ok(())
}

fn validate_owner_directory(path: &Path, description: &str) -> Result<(), HostError> {
    let metadata = symlink_metadata(path)
        .map_err(|error| HostError::Endpoint(format!("cannot inspect {description}: {error}")))?;
    if !metadata.is_dir() {
        return Err(HostError::Endpoint(format!(
            "{description} is not a directory"
        )));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(HostError::Permission(format!(
            "{description} is not owner-controlled"
        )));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(HostError::Permission(format!(
            "{description} is writable by group or other users"
        )));
    }
    Ok(())
}

fn validate_profile_root(path: &Path) -> Result<(), HostError> {
    if let Ok(metadata) = symlink_metadata(path) {
        if metadata.file_type().is_symlink() {
            return Err(HostError::Permission(
                "profile root must not be a symlink".to_owned(),
            ));
        }
        if !metadata.is_dir() {
            return Err(HostError::Permission(
                "profile root is not a directory".to_owned(),
            ));
        }
    } else {
        // On first use the app's data directory may not exist yet.  Create
        // the missing directories below the nearest existing ancestor, which
        // must be owner-controlled; each new directory is private.
        let mut missing = vec![path.to_path_buf()];
        let mut ancestor = path
            .parent()
            .ok_or_else(|| HostError::Permission("profile root has no parent".to_owned()))?
            .to_path_buf();
        while symlink_metadata(&ancestor).is_err() {
            missing.push(ancestor.clone());
            ancestor = ancestor
                .parent()
                .ok_or_else(|| HostError::Permission("profile root has no parent".to_owned()))?
                .to_path_buf();
        }
        validate_owner_directory(&ancestor, "profile root parent")?;
        for directory in missing.iter().rev() {
            create_private_directory(directory).map_err(|error| {
                HostError::Permission(format!("cannot create profile root: {error}"))
            })?;
        }
    }
    validate_owner_directory(path, "profile root")
}

fn validate_cef_root(path: &Path) -> Result<PathBuf, HostError> {
    let metadata = symlink_metadata(path)
        .map_err(|_| HostError::Cef("explicit CEF root does not exist".to_owned()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(HostError::Cef(
            "explicit CEF root must be a real directory".to_owned(),
        ));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(HostError::Permission(
            "CEF root is writable by group or other users".to_owned(),
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } && metadata.uid() != 0 {
        return Err(HostError::Permission(
            "CEF root is not controlled by the user or system owner".to_owned(),
        ));
    }
    let root = fs::canonicalize(path)
        .map_err(|_| HostError::Cef("cannot canonicalize explicit CEF root".to_owned()))?;
    for relative in ["Release", "Release/locales"] {
        let directory = root.join(relative);
        let metadata = symlink_metadata(&directory)
            .map_err(|_| HostError::Cef(format!("CEF runtime is missing {relative}")))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(HostError::Cef(format!(
                "CEF runtime has an invalid directory at {relative}"
            )));
        }
        if metadata.mode() & 0o022 != 0
            || (metadata.uid() != unsafe { libc::geteuid() } && metadata.uid() != 0)
        {
            return Err(HostError::Permission(format!(
                "CEF runtime directory is not owner-controlled: {relative}"
            )));
        }
    }
    for relative in REQUIRED_CEF_FILES {
        let file = root.join(relative);
        let metadata = symlink_metadata(&file)
            .map_err(|_| HostError::Cef(format!("CEF runtime is missing {relative}")))?;
        if metadata.file_type().is_symlink() {
            return Err(HostError::Cef(format!(
                "CEF runtime contains a symlink at {relative}"
            )));
        }
        if metadata.mode() & 0o022 != 0 {
            return Err(HostError::Permission(format!(
                "CEF runtime input is writable by group or other users: {relative}"
            )));
        }
        let is_directory = *relative == "Release/locales";
        if metadata.is_dir() != is_directory || (!is_directory && !metadata.is_file()) {
            return Err(HostError::Cef(format!(
                "CEF runtime has invalid {relative}"
            )));
        }
    }
    Ok(root)
}

fn user_namespace_available() -> bool {
    let allowed = fs::read_to_string("/proc/sys/kernel/unprivileged_userns_clone")
        .ok()
        .map(|value| value.trim() == "1")
        .unwrap_or(true);
    let capacity = fs::read_to_string("/proc/sys/user/max_user_namespaces")
        .ok()
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(|value| value > 0)
        .unwrap_or(true);
    if !allowed || !capacity {
        return false;
    }

    // Sysctl values are only a hint in containers and hardened hosts.  Probe
    // the actual ordinary-user route in a short-lived child before accepting
    // a CEF payload without a setuid sandbox helper.  Chromium also maps its
    // user inside the new namespace, and hosts like Ubuntu 24.04 (AppArmor's
    // unprivileged user namespace restriction) allow the unshare but refuse
    // the mapping, so the probe maps too.  The child may only make
    // async-signal-safe calls, so the map is formatted before forking.
    let uid_map = format!("0 {} 1", unsafe { libc::getuid() });
    let child = unsafe { libc::fork() };
    if child < 0 {
        return false;
    }
    if child == 0 {
        let succeeded = unsafe {
            libc::unshare(libc::CLONE_NEWUSER) == 0
                && write_proc_file(c"/proc/self/setgroups", b"deny")
                && write_proc_file(c"/proc/self/uid_map", uid_map.as_bytes())
        };
        unsafe { libc::_exit(if succeeded { 0 } else { 1 }) };
    }
    let mut status = 0;
    let waited = unsafe { libc::waitpid(child, &mut status, 0) };
    waited == child
        && unsafe { libc::WIFEXITED(status) }
        && unsafe { libc::WEXITSTATUS(status) == 0 }
}

/// Writes `contents` to a /proc file with raw system calls only, so it is
/// safe between fork and exit.
unsafe fn write_proc_file(path: &std::ffi::CStr, contents: &[u8]) -> bool {
    let fd = libc::open(path.as_ptr(), libc::O_WRONLY | libc::O_CLOEXEC);
    if fd < 0 {
        return false;
    }
    let written = libc::write(fd, contents.as_ptr().cast(), contents.len());
    libc::close(fd);
    written == contents.len() as isize
}

fn validate_sandbox(cef_root: &Path) -> Result<(), HostError> {
    let helper = symlink_metadata(cef_root.join(CEF_RELEASE).join("chrome-sandbox"))
        .map_err(|_| HostError::Cef("CEF sandbox helper is missing".to_owned()))?;
    let setuid_root_helper = helper.is_file()
        && helper.uid() == 0
        && helper.mode() & 0o4000 != 0
        && helper.mode() & 0o022 == 0;
    if !setuid_root_helper && !user_namespace_available() {
        return Err(HostError::Permission(
            "CEF sandbox cannot use a root helper or an ordinary-user namespace".to_owned(),
        ));
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> io::Result<()> {
    fs::DirBuilder::new().mode(0o700).create(path)
}

/// Run the Linux host.  CEF child processes return before opening the socket;
/// only the browser process owns the endpoint and transport lifecycle.
pub fn run<I>(args: I) -> Result<(), HostError>
where
    I: IntoIterator<Item = OsString>,
{
    let args = args.into_iter().collect::<Vec<_>>();
    reject_insecure_arguments(&args)?;
    if has_cef_child_type(&args) {
        trace(&format!("child start: {args:?}"));
        let cef_root = child_cef_root(&args)?;
        let cef_root = validate_cef_root(&cef_root)?;
        reject_elevated_launch()?;
        validate_sandbox(&cef_root)?;
        trace("child validated");
        let engine = load_engine(&cef_root)?;
        trace("child engine loaded");
        let exit_code = engine.execute_process(&args)?;
        trace(&format!("child finished: {exit_code:?}"));
        if let Some(exit_code) = exit_code {
            std::process::exit(exit_code);
        }
        return Err(HostError::Cef(
            "CEF child invocation did not claim a child process".to_owned(),
        ));
    }

    // Parse and validate all parent-owned paths before loading or initializing
    // CEF.  Invalid transport inputs must not start an engine process.
    let config = HostConfig::parse(args.clone())?;
    let validated = config.validate()?;
    remove_stale_frame_rings();
    let engine = Arc::new(load_engine(&validated.cef_root)?);
    // Chromium re-executes this binary for its child processes without our
    // arguments; they find the runtime (already validated here) through the
    // environment and validate it again themselves.  No other thread exists
    // yet, so changing the environment is safe.
    std::env::set_var(CEF_ROOT_ENV, &validated.cef_root);
    // CEF expects its process entry point to run in every process, including
    // the browser process, where it only prepares state and returns.
    if engine.execute_process(std::slice::from_ref(&args[0]))?.is_some() {
        return Err(HostError::Cef(
            "CEF treated the browser process as a child".to_owned(),
        ));
    }
    trace("browser process: CEF entry point returned");
    let shared = Arc::new(HostShared::default());
    let frame_namespace = new_frame_namespace();
    let frame_rate = std::env::var(FRAME_RATE_ENV)
        .ok()
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|rate| (1..=60).contains(rate))
        .unwrap_or(DEFAULT_FRAME_RATE);
    engine.initialize(
        &args[0],
        &EngineSettings {
            cef_root: &validated.cef_root,
            profile_root: &validated.config.profile_root,
            frame_namespace: &frame_namespace,
            software_rendering: validated.config.software_rendering,
            filter_requests: false,
            frame_rate,
        },
        shared.clone(),
    )?;
    trace("browser process: CEF initialized");

    let codec = FramedCodec::with_limit(
        validated.config.parent_nonce.clone(),
        validated.config.max_frame_bytes,
    )
    .map_err(|error| HostError::Protocol(error.to_string()))?;
    let result = UnixEndpoint::bind(&validated.config.socket_path).and_then(|endpoint| {
        let mut core = HostCore::with_engine(
            validated.config.profile_root.clone(),
            engine.clone(),
            shared.clone(),
        );
        endpoint.serve(validated.config.parent_pid, &codec, &mut core)
    });
    trace(&format!("browser process: transport finished: {result:?}"));
    engine.shutdown();
    trace("browser process: CEF shut down");
    result
}

/// Appends a diagnostic line to `$ROSCORD_CEF_HOST_LOG` when it is set.
fn trace(message: &str) {
    let Some(path) = std::env::var_os("ROSCORD_CEF_HOST_LOG") else {
        return;
    };
    if let Ok(mut log) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(log, "[{}] {message}", std::process::id());
    }
}

fn load_engine(cef_root: &Path) -> Result<EngineLibrary, HostError> {
    let engine_path = bundled_engine_path()?;
    validate_engine_path(&engine_path)?;
    EngineLibrary::load(cef_root, &engine_path)
}

/// A random, per-host token for shared-memory names.  It carries the host
/// pid so a later host can remove rings left behind by a crashed one, and it
/// is unrelated to the transport nonce.
fn new_frame_namespace() -> String {
    let random = uuid::Uuid::new_v4().simple().to_string();
    format!("{}-{}", std::process::id(), &random[..16])
}

/// Removes `/dev/shm/roscord-cef-<pid>-*` rings whose host is gone.  Rings
/// are unlinked when their surface closes, so only a crashed host leaves any.
fn remove_stale_frame_rings() {
    let Ok(entries) = fs::read_dir("/dev/shm") else {
        return;
    };
    let uid = unsafe { libc::geteuid() };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(rest) = name.to_str().and_then(|name| name.strip_prefix(FRAME_RING_PREFIX))
        else {
            continue;
        };
        let Some(pid) = rest
            .split('-')
            .next()
            .and_then(|pid| pid.parse::<libc::pid_t>().ok())
        else {
            continue;
        };
        let alive = pid > 0
            && (unsafe { libc::kill(pid, 0) } == 0
                || io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH));
        let owned = entry
            .metadata()
            .map(|metadata| metadata.is_file() && metadata.uid() == uid)
            .unwrap_or(false);
        if !alive && owned {
            let _ = fs::remove_file(entry.path());
        }
    }
}

fn reject_insecure_arguments(args: &[OsString]) -> Result<(), HostError> {
    for argument in args {
        let Some(argument) = argument.to_str() else {
            return Err(HostError::Usage("arguments must be valid UTF-8".to_owned()));
        };
        let flag = argument.split_once('=').map_or(argument, |(flag, _)| flag);
        if matches!(
            flag,
            "--no-sandbox"
                | "--disable-sandbox"
                | "--disable-setuid-sandbox"
                | "--disable-gpu-sandbox"
                | "--disable-seccomp-filter-sandbox"
                | "--disable-namespace-sandbox"
                | "--disable-web-security"
                | "--allow-file-access-from-files"
                | "--remote-debugging-port"
                | "--remote-debugging-address"
                | "--use-fake-device-for-media-stream"
                | "--use-fake-ui-for-media-stream"
        ) {
            return Err(HostError::Permission(
                "CEF sandbox bypass flags are not accepted".to_owned(),
            ));
        }
    }
    Ok(())
}

/// The runtime root for a CEF child: an explicit `--cef-root`, or the root
/// the browser process validated and exported before starting CEF.
fn child_cef_root(args: &[OsString]) -> Result<PathBuf, HostError> {
    let mut root = None;
    let args = expand_value_arguments(args.iter().cloned());
    let mut arguments = args.iter();
    let _program = arguments.next();
    while let Some(argument) = arguments.next() {
        if argument == "--cef-root" {
            let value = arguments.next().ok_or_else(|| missing("--cef-root"))?;
            root = Some(PathBuf::from(value));
        }
    }
    let root = root.or_else(|| std::env::var_os(CEF_ROOT_ENV).map(PathBuf::from));
    let root = root.ok_or_else(|| {
        HostError::Cef(
            "CEF root must be supplied explicitly; system and host lookup is disabled".to_owned(),
        )
    })?;
    validate_absolute_path(&root, "--cef-root")?;
    Ok(root)
}

fn has_cef_child_type(args: &[OsString]) -> bool {
    args.iter().any(|argument| {
        argument
            .to_str()
            .is_some_and(|argument| argument.starts_with("--type="))
    })
}

struct UnixEndpoint {
    listener: UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl UnixEndpoint {
    fn bind(path: &Path) -> Result<Self, HostError> {
        if symlink_metadata(path).is_ok() {
            return Err(HostError::Endpoint(
                "socket endpoint already exists; stale endpoints are never replaced".to_owned(),
            ));
        }
        let previous_umask = unsafe { libc::umask(0o077) };
        let listener = UnixListener::bind(path);
        unsafe {
            libc::umask(previous_umask);
        }
        let listener = listener.map_err(|error| {
            HostError::Endpoint(format!("cannot bind owner-only Unix socket: {error}"))
        })?;
        if unsafe { libc::fchmod(listener.as_raw_fd(), 0o600) } != 0 {
            let _ = fs::remove_file(path);
            return Err(HostError::Permission(
                "cannot make Unix endpoint owner-only".to_owned(),
            ));
        }
        let mut socket_stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(listener.as_raw_fd(), socket_stat.as_mut_ptr()) } != 0 {
            let _ = fs::remove_file(path);
            return Err(HostError::Permission(
                "cannot inspect Unix endpoint ownership".to_owned(),
            ));
        }
        let socket_stat = unsafe { socket_stat.assume_init() };
        let mode = socket_stat.st_mode;
        let is_socket = mode & libc::S_IFMT == libc::S_IFSOCK;
        let owner_controlled = socket_stat.st_uid == unsafe { libc::geteuid() };
        if !is_socket || !owner_controlled || mode & 0o077 != 0 {
            let _ = fs::remove_file(path);
            return Err(HostError::Permission(
                "Unix endpoint is not an owner-only socket".to_owned(),
            ));
        }
        let metadata = match symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) => {
                let _ = fs::remove_file(path);
                return Err(error.into());
            }
        };
        // fstat on the listener describes its sockfs inode, which never
        // matches the filesystem inode bind() created, so the path is checked
        // on its own: it must still be an owner-only socket, not a link or
        // another file swapped in after bind.  Its identity is what Drop
        // compares against before removing the endpoint.
        if !metadata.file_type().is_socket()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            let _ = fs::remove_file(path);
            return Err(HostError::Permission(
                "Unix endpoint path changed during bind".to_owned(),
            ));
        }
        Ok(Self {
            listener,
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    fn serve(
        &self,
        parent_pid: u32,
        codec: &FramedCodec,
        core: &mut HostCore,
    ) -> Result<(), HostError> {
        loop {
            let (mut stream, _) = self.listener.accept()?;
            if !peer_matches(&stream, parent_pid)? {
                // The endpoint remains available to the expected parent, but
                // an unrelated process never gets a protocol error oracle.
                let _ = stream.shutdown(std::net::Shutdown::Both);
                continue;
            }
            let result = serve_connection(&mut stream, codec, core);
            let _ = stream.shutdown(std::net::Shutdown::Both);
            return result;
        }
    }
}

impl Drop for UnixEndpoint {
    fn drop(&mut self) {
        let Ok(metadata) = symlink_metadata(&self.path) else {
            return;
        };
        if metadata.dev() == self.device && metadata.ino() == self.inode {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn peer_matches(stream: &UnixStream, parent_pid: u32) -> Result<bool, HostError> {
    #[cfg(target_os = "linux")]
    {
        let mut credentials = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let result = unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut credentials as *mut libc::ucred).cast(),
                &mut length,
            )
        };
        if result != 0 || length as usize != std::mem::size_of::<libc::ucred>() {
            return Err(HostError::Permission(
                "cannot authenticate Unix peer credentials".to_owned(),
            ));
        }
        return Ok(credentials.pid == parent_pid as libc::pid_t
            && credentials.uid == unsafe { libc::geteuid() }
            && credentials.gid == unsafe { libc::getegid() });
    }
    #[allow(unreachable_code)]
    Err(HostError::Permission(
        "Linux peer credentials are unavailable".to_owned(),
    ))
}

fn serve_connection(
    stream: &mut UnixStream,
    codec: &FramedCodec,
    core: &mut HostCore,
) -> Result<(), HostError> {
    // Responses and CEF events share one writer, so frames never interleave
    // and no event can overtake the `opened` that introduces its surface.
    let mut writer_stream = stream.try_clone()?;
    let writer_codec = codec.clone();
    let (sender, receiver) = mpsc::channel::<WireMessage>();
    let writer = thread::spawn(move || {
        for message in receiver {
            if write_message(&mut writer_stream, &writer_codec, &message).is_err() {
                break;
            }
        }
    });
    core.attach_sink(sender.clone());
    let result = read_requests(stream, codec, core, &sender);
    trace(&format!("transport: requests ended: {result:?}"));
    core.shutdown();
    drop(sender);
    if result.is_err() {
        // A protocol failure ends the session; do not wait on a peer that may
        // no longer read.
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
    let _ = writer.join();
    trace("transport: writer stopped");
    result
}

fn read_requests(
    stream: &mut UnixStream,
    codec: &FramedCodec,
    core: &mut HostCore,
    sender: &mpsc::Sender<WireMessage>,
) -> Result<(), HostError> {
    loop {
        let Some(message) = read_message(stream, codec)? else {
            return Ok(());
        };
        for response in core.dispatch(message)? {
            sender
                .send(response)
                .map_err(|_| HostError::Endpoint("the transport writer stopped".to_owned()))?;
        }
        // Browser creation starts only after `opened` is queued.
        core.run_deferred();
    }
}

fn read_message(
    stream: &mut UnixStream,
    codec: &FramedCodec,
) -> Result<Option<WireMessage>, HostError> {
    let mut header = [0_u8; 4];
    // CEF's child processes make SIGCHLD common here; an interrupted read is
    // retried like read_exact does.
    let first = loop {
        match stream.read(&mut header[..1]) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            // A parent that exits with events still unread resets the
            // connection; between frames that is an ordinary disconnect.
            Err(error) if error.kind() == io::ErrorKind::ConnectionReset => break 0,
            result => break result?,
        }
    };
    if first == 0 {
        return Ok(None);
    }
    stream.read_exact(&mut header[1..])?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > codec.max_frame_bytes() {
        return Err(HostError::Protocol(
            "frame size is outside the wire limit".to_owned(),
        ));
    }
    let mut frame = Vec::with_capacity(size + 4);
    frame.extend_from_slice(&header);
    frame.resize(size + 4, 0);
    stream.read_exact(&mut frame[4..])?;
    codec
        .decode(&frame)
        .map(Some)
        .map_err(|error| HostError::Protocol(error.to_string()))
}

fn write_message(
    stream: &mut UnixStream,
    codec: &FramedCodec,
    message: &WireMessage,
) -> Result<(), HostError> {
    let frame = codec
        .encode(message)
        .map_err(|error| HostError::Protocol(error.to_string()))?;
    stream.write_all(&frame)?;
    Ok(())
}

struct SurfaceState {
    spec: SurfaceSpec,
    context: ProfileContext,
    last_command_sequence: u64,
}

/// A browser to create once `opened` has been queued.
struct PendingBrowser {
    surface_id: SurfaceId,
    url: String,
    cache_path: Option<PathBuf>,
}

/// View size used until the app sends its first resize.
const INITIAL_VIEW_WIDTH: u32 = 1024;
const INITIAL_VIEW_HEIGHT: u32 = 768;

/// The transport-facing host state.  It enforces the same surface ownership
/// rules as the fake host while CEF/browser callbacks are attached behind the
/// engine boundary.
pub struct HostCore {
    profile_store: ProfileStore,
    next_surface_id: u64,
    surfaces: BTreeMap<SurfaceId, SurfaceState>,
    stopped: bool,
    /// Mediated camera/microphone/capture decisions.  The Linux host
    /// requires XDG portal mediation for display capture; device grants are
    /// scoped to account, requesting origin, top-level origin, and
    /// capability, and are re-checked against current policy on every use.
    permissions: HostPermissionRegistry,
    /// The CEF engine, or `None` for the transport-only host the contract
    /// tests drive.  Without an engine, surfaces are ready at once and
    /// commands only produce their terminal events.
    engine: Option<Arc<EngineLibrary>>,
    /// Per-surface policy and event sequencing shared with CEF callbacks.
    shared: Arc<HostShared>,
    pending_browsers: Vec<PendingBrowser>,
}

impl HostCore {
    pub fn new(profile_root: PathBuf) -> Self {
        Self::build(profile_root, None, Arc::new(HostShared::default()))
    }

    /// A host whose surfaces are real CEF browsers.  `shared` must be the
    /// same object the engine reports its callbacks to.
    pub fn with_engine(
        profile_root: PathBuf,
        engine: Arc<EngineLibrary>,
        shared: Arc<HostShared>,
    ) -> Self {
        Self::build(profile_root, Some(engine), shared)
    }

    fn build(
        profile_root: PathBuf,
        engine: Option<Arc<EngineLibrary>>,
        shared: Arc<HostShared>,
    ) -> Self {
        Self {
            profile_store: ProfileStore::new(profile_root),
            next_surface_id: 1,
            surfaces: BTreeMap::new(),
            stopped: false,
            permissions: HostPermissionRegistry::new(true),
            engine,
            shared,
            pending_browsers: Vec::new(),
        }
    }

    /// Routes CEF events for this connection to its writer.
    pub fn attach_sink(&self, sink: mpsc::Sender<WireMessage>) {
        self.shared.attach_sink(sink);
    }

    /// Starts the browsers opened by the last request.  Called after the
    /// request's responses (including `opened`) are queued.
    pub fn run_deferred(&mut self) {
        let Some(engine) = self.engine.clone() else {
            self.pending_browsers.clear();
            return;
        };
        for pending in std::mem::take(&mut self.pending_browsers) {
            let options = BrowserOptions {
                url: &pending.url,
                cache_path: pending.cache_path.as_deref(),
                width: INITIAL_VIEW_WIDTH,
                height: INITIAL_VIEW_HEIGHT,
                device_scale_factor: 1.0,
                document_start_script: None,
            };
            if engine.create_browser(pending.surface_id, &options).is_err() {
                // The engine reports nothing for a browser it never scheduled.
                self.shared.browser_closed(pending.surface_id);
            }
        }
    }

    pub fn dispatch(&mut self, message: WireMessage) -> Result<Vec<WireMessage>, HostError> {
        if self.stopped {
            return Err(HostError::Runtime("host is stopping".to_owned()));
        }
        match message {
            WireMessage::Open { request_id, spec } => self
                .open(request_id, spec)
                .or_else(|error| wire_error_for(request_id, error)),
            WireMessage::Command {
                request_id,
                surface_id,
                command,
            } => self
                .command(request_id, surface_id, command)
                .or_else(|error| wire_error_for(request_id, error)),
            WireMessage::Close { surface_id } => self
                .close(surface_id)
                .or_else(|error| wire_error_for(0, error)),
            WireMessage::Heartbeat { request_id } => {
                Ok(vec![WireMessage::HeartbeatAck { request_id }])
            }
            WireMessage::Event { .. }
            | WireMessage::Opened { .. }
            | WireMessage::Ack { .. }
            | WireMessage::HeartbeatAck { .. }
            | WireMessage::Error { .. } => Err(HostError::Protocol(
                "host accepts only open, command, and close messages".to_owned(),
            )),
        }
    }

    fn open(&mut self, request_id: u64, spec: SurfaceSpec) -> Result<Vec<WireMessage>, HostError> {
        spec.validate().map_err(runtime_error)?;
        // Deserialization does not invoke ProfileKey::new, so revalidate the
        // opaque key at the host boundary before it participates in a path.
        ProfileKey::new(spec.profile_key().as_str().to_owned()).map_err(runtime_error)?;
        let context = self
            .profile_store
            .open(spec.profile_key(), spec.privacy())
            .map_err(profile_error)?;
        let surface_id = SurfaceId(self.next_surface_id);
        self.next_surface_id = self
            .next_surface_id
            .checked_add(1)
            .ok_or_else(|| HostError::Runtime("surface id exhausted".to_owned()))?;
        let cache_path = context.path().map(Path::to_path_buf);
        self.surfaces.insert(
            surface_id,
            SurfaceState {
                spec: spec.clone(),
                context,
                last_command_sequence: 0,
            },
        );
        let opened = WireMessage::Opened {
            request_id,
            surface_id,
        };
        if self.engine.is_some() {
            // `ready` follows from the engine once the browser exists.
            self.shared.register(surface_id, &spec, false);
            self.pending_browsers.push(PendingBrowser {
                surface_id,
                url: spec.initial_navigation().url().to_owned(),
                cache_path,
            });
            return Ok(vec![opened]);
        }
        self.shared.register(surface_id, &spec, true);
        Ok(vec![
            opened,
            WireMessage::Event {
                event: SurfaceEvent::Ready {
                    surface_id,
                    sequence: 1,
                    initial_navigation: spec.initial_navigation().clone(),
                },
            },
        ])
    }

    fn command(
        &mut self,
        request_id: u64,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<Vec<WireMessage>, HostError> {
        if matches!(command, SurfaceCommand::Permission { .. }) {
            return self.resolve_permission_command(request_id, surface_id, command);
        }
        command.validate().map_err(runtime_error)?;
        let surface = self
            .surfaces
            .get_mut(&surface_id)
            .ok_or_else(|| HostError::Runtime(format!("stale surface {surface_id}")))?;
        if let Some(profile_key) = command.profile_key() {
            if profile_key != surface.spec.profile_key() {
                return Err(HostError::Runtime(
                    "surface profile key mismatch".to_owned(),
                ));
            }
        }
        let sequence = command.sequence();
        if sequence <= surface.last_command_sequence {
            return Err(HostError::Runtime(format!(
                "command sequence must be greater than {}",
                surface.last_command_sequence
            )));
        }
        surface.last_command_sequence = sequence;
        let engine = self.engine.as_deref();
        let shared = &self.shared;
        let event = match command {
            SurfaceCommand::Navigate { navigation, .. } => {
                let decision = surface.spec.policy().navigation_decision(&navigation);
                let outcome = match decision {
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
                let event = NavigationEvent::new(
                    navigation.url().to_owned(),
                    navigation.disposition(),
                    outcome,
                )
                .map_err(runtime_error)?;
                if decision == NavigationPolicyDecision::InProcess {
                    if let Some(engine) = engine {
                        engine.navigate(surface_id, navigation.url());
                    }
                }
                shared
                    .next_sequence(surface_id)
                    .map(|sequence| SurfaceEvent::Navigation {
                        surface_id,
                        sequence,
                        navigation: event,
                    })
            }
            SurfaceCommand::Resize {
                width,
                height,
                device_scale_factor,
                ..
            } => {
                if let Some(engine) = engine {
                    engine.resize(surface_id, width, height, device_scale_factor);
                }
                shared
                    .next_sequence(surface_id)
                    .map(|sequence| SurfaceEvent::WindowChanged {
                        surface_id,
                        sequence,
                        change: crate::browser_runtime::WindowChange::Resized {
                            width,
                            height,
                            device_scale_factor,
                        },
                    })
            }
            SurfaceCommand::Focus { focused, .. } => {
                if let Some(engine) = engine {
                    engine.focus(surface_id, focused);
                }
                shared
                    .next_sequence(surface_id)
                    .map(|sequence| SurfaceEvent::WindowChanged {
                        surface_id,
                        sequence,
                        change: crate::browser_runtime::WindowChange::Focused { focused },
                    })
            }
            SurfaceCommand::Script { envelope, .. } => {
                let completion = script_completion_envelope(&envelope).map_err(runtime_error)?;
                if let Some(engine) = engine {
                    if let Some(script) = page_script(&envelope) {
                        engine.execute_script(surface_id, &script);
                    }
                }
                shared
                    .next_sequence(surface_id)
                    .map(|sequence| SurfaceEvent::ScriptMessage {
                        surface_id,
                        sequence,
                        envelope: completion,
                    })
            }
            SurfaceCommand::Input { input, .. } => {
                if let Some(engine) = engine {
                    engine.input(surface_id, &input);
                }
                None
            }
            SurfaceCommand::Popup {
                request_id: popup_id,
                action,
                ..
            } => shared.resolve_popup(surface_id, &popup_id, action),
            SurfaceCommand::Permission { .. }
            | SurfaceCommand::Download { .. }
            | SurfaceCommand::Clipboard { .. }
            | SurfaceCommand::Upload { .. }
            | SurfaceCommand::ReleaseFrame { .. } => None,
        };
        // NOTE: `Permission` commands never reach this arm: they are
        // intercepted above by `resolve_permission_command`, which applies
        // the mediated grant table and portal outcomes.  The arm remains so
        // the match stays exhaustive over every surface command.
        let mut responses = vec![WireMessage::Ack { request_id }];
        responses.extend(event.into_iter().map(|event| WireMessage::Event { event }));
        Ok(responses)
    }

    fn close(&mut self, surface_id: SurfaceId) -> Result<Vec<WireMessage>, HostError> {
        let surface = self
            .surfaces
            .remove(&surface_id)
            .ok_or_else(|| HostError::Runtime(format!("stale surface {surface_id}")))?;
        self.profile_store
            .release(surface.context.context_id())
            .map_err(profile_error)?;
        // A late app decision must never grant a closed surface.
        self.permissions.remove_surface(surface_id);
        if let Some(engine) = &self.engine {
            // `closed` follows from the engine once CEF has let the browser go.
            self.shared.mark_closing(surface_id);
            engine.close_browser(surface_id);
            return Ok(Vec::new());
        }
        let sequence = self.shared.next_sequence(surface_id).unwrap_or(1);
        self.shared.remove(surface_id);
        Ok(vec![WireMessage::Event {
            event: SurfaceEvent::Closed {
                surface_id,
                sequence,
                reason: CloseReason::User,
            },
        }])
    }

    fn shutdown(&mut self) {
        self.surfaces.clear();
        self.permissions.clear_session();
        self.profile_store.shutdown();
        self.stopped = true;
        self.shared.detach_sink();
    }

    /// Clear one account's browser state.  The operation is intentionally
    /// outside the four BrowserRuntime caller operations: the app invokes it
    /// through its account-data/settings bridge after closing all surfaces.
    /// The host still enforces quiescence so a stale caller cannot clear a
    /// context that remains reachable.
    pub fn clear_data(
        &mut self,
        profile_key: &ProfileKey,
    ) -> Result<crate::browser_profile::ProfileClearResult, HostError> {
        if self
            .surfaces
            .values()
            .any(|surface| surface.spec.profile_key() == profile_key)
        {
            return Err(HostError::ProfileBusy);
        }
        let result = self
            .profile_store
            .clear_data(profile_key)
            .map_err(profile_error)?;
        // Account browser state includes media grants: persistent camera and
        // microphone grants do not survive clear-data.
        self.permissions.clear_profile(profile_key);
        Ok(result)
    }

    /// Record a page-originated media request from the CEF permission
    /// callback.  The caller emits the `permission_request` event for the
    /// app unless a stored grant already covers the scope.  Unknown
    /// capabilities register (and are then always denied); replayed request
    /// ids and unknown surfaces are rejected.
    pub fn register_permission_request(
        &mut self,
        surface_id: SurfaceId,
        request_id: String,
        requesting_origin: String,
        top_level_origin: String,
        capability: &str,
    ) -> Result<MediaCapability, HostError> {
        let profile_key = self
            .surfaces
            .get(&surface_id)
            .ok_or_else(|| HostError::Runtime(format!("stale surface {surface_id}")))?
            .spec
            .profile_key()
            .clone();
        self.permissions
            .register(
                surface_id,
                &profile_key,
                request_id,
                requesting_origin,
                top_level_origin,
                capability,
            )
            .map_err(runtime_error)
    }

    /// Fast path for the CEF callback: true when a stored grant covers this
    /// exact scope under the surface's current policy and OS mediation, so
    /// the host can continue the request without reprompting the app.
    /// Display capture always returns false.
    pub fn stored_media_grant_covers(
        &self,
        surface_id: SurfaceId,
        requesting_origin: &str,
        top_level_origin: &str,
        capability: &str,
    ) -> bool {
        let Some(surface) = self.surfaces.get(&surface_id) else {
            return false;
        };
        let policy = Self::media_policy_view(surface, capability, true);
        self.permissions.stored_grant_covers(
            surface_id,
            surface.spec.profile_key(),
            requesting_origin,
            top_level_origin,
            capability,
            &policy,
        )
    }

    /// Record the XDG ScreenCast/PipeWire portal outcome for a pending
    /// display request.  Non-grant outcomes deny the page and return the
    /// sanitized `capture_denied` failure; the caller cancels the page
    /// callback.  Direct unmediated capture is never consulted: there is no
    /// X11 fallback path in this host.
    pub fn report_portal_outcome(
        &mut self,
        request_id: &str,
        outcome_name: &str,
    ) -> Result<Vec<WireMessage>, HostError> {
        let outcome = CapturePortalOutcome::parse(outcome_name).ok_or_else(|| {
            HostError::Runtime(format!("unknown portal outcome {outcome_name}"))
        })?;
        let (surface_id, failure) = self
            .permissions
            .report_portal_outcome(request_id, outcome)
            .map_err(runtime_error)?;
        Ok(self.failed_event(surface_id, failure).unwrap_or_default())
    }

    /// Resolve one app `Permission` command for a pending request.  The
    /// command is acknowledged; a denial additionally carries the sanitized
    /// `permission_denied` or `capture_denied` failure event.  Decisions for
    /// requests the host never issued are rejected without granting
    /// anything.
    fn resolve_permission_command(
        &mut self,
        request_id: u64,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<Vec<WireMessage>, HostError> {
        let (permission_id, decision): (String, PermissionDecision) = match &command {
            SurfaceCommand::Permission {
                request_id,
                decision,
                ..
            } => (request_id.clone(), *decision),
            _ => {
                return Err(HostError::Runtime(
                    "permission resolution requires a permission command".to_owned(),
                ));
            }
        };
        command.validate().map_err(runtime_error)?;
        // Mirror the shared surface ownership checks so stale, mismatched,
        // or replayed commands are rejected before touching permissions.
        // Decisions for requests the host never issued are rejected with a
        // wire error without granting anything.
        if self.permissions.pending(&permission_id).is_none() {
            return Ok(vec![WireMessage::Error {
                request_id: Some(request_id),
                code: "unknown_permission_request".to_owned(),
                message: "permission request is not pending".to_owned(),
            }]);
        }
        let policy = {
            let surface = self
                .surfaces
                .get_mut(&surface_id)
                .ok_or_else(|| HostError::Runtime(format!("stale surface {surface_id}")))?;
            if let Some(profile_key) = command.profile_key() {
                if profile_key != surface.spec.profile_key() {
                    return Err(HostError::Runtime(
                        "surface profile key mismatch".to_owned(),
                    ));
                }
            }
            let sequence = command.sequence();
            if sequence <= surface.last_command_sequence {
                return Err(HostError::Runtime(format!(
                    "command sequence must be greater than {}",
                    surface.last_command_sequence
                )));
            }
            surface.last_command_sequence = sequence;
            let capability = self
                .permissions
                .pending(&permission_id)
                .and_then(|pending| pending.scope())
                .map(|scope| scope.capability().as_str())
                .unwrap_or("unknown_media");
            Self::media_policy_view(surface, capability, true)
        };
        let resolution = self
            .permissions
            .resolve(&permission_id, decision, &policy)
            .map_err(runtime_error)?;
        if resolution.surface_id != surface_id {
            return Ok(vec![WireMessage::Error {
                request_id: Some(request_id),
                code: "unknown_permission_request".to_owned(),
                message: "permission request is not pending".to_owned(),
            }]);
        }
        let mut responses = vec![WireMessage::Ack { request_id }];
        if let Some(failure) = resolution.failure {
            responses.extend(self.failed_event(surface_id, Some(failure)).unwrap_or_default());
        }
        Ok(responses)
    }

    /// Assemble the current-policy view for one surface and capability.
    /// Both the requesting and the top-level origin must still be declared
    /// for a grant to apply, and an explicitly disabled capability never
    /// applies.  Device capture is OS-mediated synchronously by the capture
    /// stack; display capture additionally requires the portal grant, which
    /// the registry enforces separately.
    fn media_policy_view(
        surface: &SurfaceState,
        capability: &str,
        os_mediated: bool,
    ) -> MediaPolicyView {
        let mut origins = surface.spec.policy().allowed_origins().to_vec();
        origins.extend(
            surface
                .spec
                .policy()
                .allowed_loopback_origins()
                .iter()
                .cloned(),
        );
        let capability_allowed = surface
            .spec
            .policy()
            .capabilities()
            .get(capability)
            .copied()
            .unwrap_or(true);
        MediaPolicyView {
            origins,
            capability_allowed,
            private_context: surface.spec.privacy() == PrivacyMode::Private,
            os_mediated,
        }
    }

    /// Emit a surface-scoped `failed` event for a sanitized permission or
    /// capture denial, consuming one event sequence.  Returns an empty
    /// vector when there is no failure to report or the surface is gone.
    fn failed_event(
        &mut self,
        surface_id: SurfaceId,
        failure: Option<SurfaceFailure>,
    ) -> Option<Vec<WireMessage>> {
        let failure = failure?;
        self.surfaces.get(&surface_id)?;
        let sequence = self.shared.next_sequence(surface_id)?;
        Some(vec![WireMessage::Event {
            event: SurfaceEvent::Failed {
                surface_id,
                sequence,
                failure,
            },
        }])
    }
}

/// Script commands are a generic BrowserRuntime execution seam.  The native
/// CEF bridge evaluates the operation in the page; the transport-only Linux
/// host still emits a host-sourced terminal event so command acknowledgements
/// cannot remain pending or be mistaken for a page-originated message.
fn script_completion_envelope(envelope: &ScriptEnvelope) -> Result<ScriptEnvelope, RuntimeError> {
    let operation = envelope
        .value()
        .get("operation")
        .and_then(|value| value.as_str())
        .ok_or_else(|| RuntimeError::InvalidCommand("script operation is missing".into()))?;
    if operation != "evaluate_javascript" && operation != "dispatch_script_message" {
        return Err(RuntimeError::InvalidCommand(
            "script operation is not supported".into(),
        ));
    }
    ScriptEnvelope::new(
        ScriptSource::Host,
        envelope.origin().to_owned(),
        envelope.channel().to_owned(),
        format!("{}:complete", envelope.request_id()),
        json!({"operation": operation, "status": "executed"}),
    )
}

fn wire_error_for(request_id: u64, error: HostError) -> Result<Vec<WireMessage>, HostError> {
    let (code, message) = match error {
        HostError::Runtime(message) => ("runtime_failed", message),
        HostError::Permission(message) => ("profile_unavailable", message),
        HostError::ProfileBusy => ("profile_busy", "profile is busy".to_owned()),
        HostError::ProfileCorrupt => ("profile_corrupt", "profile is corrupt".to_owned()),
        HostError::ProfileUnavailable => {
            ("profile_unavailable", "profile is unavailable".to_owned())
        }
        HostError::MigrationFailed => (
            "migration_failed",
            "profile migration failed; re-authentication is required".to_owned(),
        ),
        HostError::Usage(message) => ("invalid_command", message),
        other => return Err(other),
    };
    Ok(vec![WireMessage::Error {
        request_id: (request_id != 0).then_some(request_id),
        code: code.to_owned(),
        message,
    }])
}

fn runtime_error(error: RuntimeError) -> HostError {
    HostError::Runtime(error.to_string())
}

fn profile_error(error: ProfileError) -> HostError {
    match error {
        ProfileError::Busy => HostError::ProfileBusy,
        ProfileError::Security | ProfileError::Unavailable | ProfileError::Io => {
            HostError::ProfileUnavailable
        }
        ProfileError::Corrupt => HostError::ProfileCorrupt,
        ProfileError::MigrationFailed => HostError::MigrationFailed,
    }
}

/// The JavaScript a script command runs in the page, if any.
fn page_script(envelope: &ScriptEnvelope) -> Option<String> {
    let value = envelope.value();
    match value.get("operation")?.as_str()? {
        "evaluate_javascript" => value.get("script")?.as_str().map(str::to_owned),
        "dispatch_script_message" => Some(format!(
            "window.__roscordBrowserRuntimeReceive && window.__roscordBrowserRuntimeReceive({value});"
        )),
        _ => None,
    }
}

/// State shared between the transport thread and CEF callbacks: each
/// surface's policy and event sequence, pending popups, and the writer the
/// events go to.
#[derive(Default)]
pub struct HostShared {
    state: Mutex<SharedState>,
}

#[derive(Default)]
struct SharedState {
    surfaces: BTreeMap<SurfaceId, SharedSurface>,
    sink: Option<mpsc::Sender<WireMessage>>,
    next_popup_request: u64,
}

struct SharedSurface {
    policy: SurfacePolicy,
    initial_navigation: NavigationRequest,
    next_event_sequence: u64,
    ready: bool,
    closing: bool,
    pending_popups: BTreeMap<String, PendingPopup>,
}

struct PendingPopup {
    url: String,
    user_gesture: bool,
}

impl SharedSurface {
    fn next_sequence(&mut self) -> u64 {
        let sequence = self.next_event_sequence;
        self.next_event_sequence = sequence.saturating_add(1);
        sequence
    }
}

impl SharedState {
    fn send(&self, event: SurfaceEvent) {
        if let Some(sink) = &self.sink {
            let _ = sink.send(WireMessage::Event { event });
        }
    }

    /// Sends the event `build` makes with the surface's next sequence.
    /// Nothing is sent for unknown surfaces or once a close was requested.
    fn emit(&mut self, surface_id: SurfaceId, build: impl FnOnce(u64) -> Option<SurfaceEvent>) {
        let Some(surface) = self.surfaces.get_mut(&surface_id) else {
            return;
        };
        if surface.closing {
            return;
        }
        let sequence = surface.next_sequence();
        if let Some(event) = build(sequence) {
            self.send(event);
        }
    }
}

impl HostShared {
    fn lock(&self) -> MutexGuard<'_, SharedState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn attach_sink(&self, sink: mpsc::Sender<WireMessage>) {
        self.lock().sink = Some(sink);
    }

    fn detach_sink(&self) {
        self.lock().sink = None;
    }

    /// Registers a surface.  `ready` says whether `ready` (sequence 1) was
    /// already sent by the caller.
    fn register(&self, surface_id: SurfaceId, spec: &SurfaceSpec, ready: bool) {
        self.lock().surfaces.insert(
            surface_id,
            SharedSurface {
                policy: spec.policy().clone(),
                initial_navigation: spec.initial_navigation().clone(),
                next_event_sequence: if ready { 2 } else { 1 },
                ready,
                closing: false,
                pending_popups: BTreeMap::new(),
            },
        );
    }

    fn remove(&self, surface_id: SurfaceId) {
        self.lock().surfaces.remove(&surface_id);
    }

    fn mark_closing(&self, surface_id: SurfaceId) {
        if let Some(surface) = self.lock().surfaces.get_mut(&surface_id) {
            surface.closing = true;
            surface.pending_popups.clear();
        }
    }

    fn next_sequence(&self, surface_id: SurfaceId) -> Option<u64> {
        self.lock()
            .surfaces
            .get_mut(&surface_id)
            .map(SharedSurface::next_sequence)
    }

    fn policy(&self, surface_id: SurfaceId) -> Option<SurfacePolicy> {
        self.lock()
            .surfaces
            .get(&surface_id)
            .filter(|surface| !surface.closing)
            .map(|surface| surface.policy.clone())
    }

    /// Applies the app's decision for a popup the page asked for.  The only
    /// way out is an explicit external action the surface policy permits.
    fn resolve_popup(
        &self,
        surface_id: SurfaceId,
        popup_id: &str,
        action: PopupAction,
    ) -> Option<SurfaceEvent> {
        let mut state = self.lock();
        let surface = state.surfaces.get_mut(&surface_id)?;
        let popup = surface.pending_popups.remove(popup_id)?;
        let external = action == PopupAction::OpenExternal
            && NavigationRequest::new(&popup.url, NavigationDisposition::External, popup.user_gesture)
                .map(|request| {
                    surface.policy.navigation_decision(&request) == NavigationPolicyDecision::External
                })
                .unwrap_or(false);
        let (disposition, outcome) = if external {
            (NavigationDisposition::External, NavigationOutcome::External)
        } else {
            (NavigationDisposition::NewSurface, NavigationOutcome::Cancelled)
        };
        let navigation = NavigationEvent::new(popup.url, disposition, outcome).ok()?;
        let sequence = surface.next_sequence();
        Some(SurfaceEvent::Navigation {
            surface_id,
            sequence,
            navigation,
        })
    }

    fn fail(&self, surface_id: SurfaceId, kind: FailureKind, message: &str) {
        let Ok(failure) = SurfaceFailure::new(kind, message) else {
            return;
        };
        self.lock().emit(surface_id, |sequence| {
            Some(SurfaceEvent::Failed {
                surface_id,
                sequence,
                failure,
            })
        });
    }
}

impl EngineEvents for HostShared {
    fn before_browse(
        &self,
        surface_id: SurfaceId,
        url: &str,
        main_frame: bool,
        user_gesture: bool,
        _is_redirect: bool,
    ) -> bool {
        if !main_frame {
            // The surface policy governs the top-level document.  Frames a
            // declared page embeds (the provider player inside the video
            // wrapper, for one) load normally, but only over web schemes.
            return subframe_url_allowed(url);
        }
        if url == "about:blank" {
            return true;
        }
        let Some(policy) = self.policy(surface_id) else {
            return false;
        };
        let Ok(request) = NavigationRequest::new(url, NavigationDisposition::Current, user_gesture)
        else {
            return false;
        };
        let (allowed, disposition, outcome) = match policy.navigation_decision(&request) {
            NavigationPolicyDecision::InProcess => {
                (true, NavigationDisposition::Current, NavigationOutcome::Allowed)
            }
            NavigationPolicyDecision::External => (
                false,
                NavigationDisposition::External,
                NavigationOutcome::External,
            ),
            NavigationPolicyDecision::Blocked => {
                (false, NavigationDisposition::Current, NavigationOutcome::Blocked)
            }
        };
        if let Ok(navigation) = NavigationEvent::new(url, disposition, outcome) {
            self.lock().emit(surface_id, |sequence| {
                Some(SurfaceEvent::Navigation {
                    surface_id,
                    sequence,
                    navigation,
                })
            });
        }
        allowed
    }

    fn open_url(&self, surface_id: SurfaceId, url: &str, user_gesture: bool) {
        let mut state = self.lock();
        state.next_popup_request = state.next_popup_request.saturating_add(1);
        let request_id = format!("popup-{}", state.next_popup_request);
        let Some(surface) = state.surfaces.get_mut(&surface_id) else {
            return;
        };
        if surface.closing {
            return;
        }
        surface.pending_popups.insert(
            request_id.clone(),
            PendingPopup {
                url: url.to_owned(),
                user_gesture,
            },
        );
        let sequence = surface.next_sequence();
        state.send(SurfaceEvent::PopupRequest {
            surface_id,
            sequence,
            request_id,
            url: url.to_owned(),
            user_gesture,
        });
    }

    fn frame_ready(
        &self,
        surface_id: SurfaceId,
        buffer: &str,
        slot: u32,
        width: u32,
        height: u32,
        frame_sequence: u64,
    ) {
        let Some(stride) = width.checked_mul(4) else {
            return;
        };
        let Ok(frame) = FrameReference::new(
            slot,
            width,
            height,
            stride,
            PixelFormat::RgbaPremultiplied,
            frame_sequence,
        )
        .and_then(|frame| frame.with_buffer(buffer)) else {
            return;
        };
        self.lock().emit(surface_id, |sequence| {
            Some(SurfaceEvent::FrameReady {
                surface_id,
                sequence,
                frame,
            })
        });
    }

    fn browser_created(&self, surface_id: SurfaceId) {
        let mut state = self.lock();
        let Some(surface) = state.surfaces.get_mut(&surface_id) else {
            return;
        };
        if surface.ready || surface.closing {
            return;
        }
        surface.ready = true;
        let initial_navigation = surface.initial_navigation.clone();
        let sequence = surface.next_sequence();
        state.send(SurfaceEvent::Ready {
            surface_id,
            sequence,
            initial_navigation,
        });
    }

    fn browser_closed(&self, surface_id: SurfaceId) {
        let mut state = self.lock();
        let Some(mut surface) = state.surfaces.remove(&surface_id) else {
            return;
        };
        if !surface.ready && !surface.closing {
            if let Ok(failure) = SurfaceFailure::new(
                FailureKind::RuntimeLost,
                "the browser could not be created",
            ) {
                let sequence = surface.next_sequence();
                state.send(SurfaceEvent::Failed {
                    surface_id,
                    sequence,
                    failure,
                });
            }
        }
        let reason = if surface.closing {
            CloseReason::User
        } else {
            CloseReason::Host
        };
        let sequence = surface.next_sequence();
        state.send(SurfaceEvent::Closed {
            surface_id,
            sequence,
            reason,
        });
    }

    fn load_failed(&self, surface_id: SurfaceId, error_code: i32, _url: &str) {
        self.log(
            LOG_WARNING,
            &format!("surface {surface_id} failed to load (net error {error_code})"),
        );
        self.fail(
            surface_id,
            FailureKind::NavigationBlocked,
            "the page could not be loaded",
        );
    }

    fn certificate_error(&self, surface_id: SurfaceId, _url: &str) {
        self.fail(
            surface_id,
            FailureKind::CertificateDenied,
            "certificate validation failed; navigation was denied",
        );
    }

    fn renderer_gone(&self, surface_id: SurfaceId, status: i32) {
        self.log(
            LOG_ERROR,
            &format!("surface {surface_id} renderer terminated (status {status})"),
        );
        self.fail(surface_id, FailureKind::RuntimeLost, "the page renderer stopped");
    }

    fn cursor_changed(&self, surface_id: SurfaceId, cursor: &str) {
        let cursor = cursor.to_owned();
        self.lock().emit(surface_id, |sequence| {
            Some(SurfaceEvent::CursorChanged {
                surface_id,
                sequence,
                cursor,
            })
        });
    }

    fn script_message(&self, surface_id: SurfaceId, frame_url: &str, json: &str) {
        // The frame's real origin is authoritative; the page cannot claim
        // another one.
        let Some(origin) = crate::browser_runtime::url_origin(frame_url) else {
            return;
        };
        let Ok(value) = serde_json::from_str::<Value>(json) else {
            return;
        };
        let Some(channel) = value.get("channel").and_then(Value::as_str).map(str::to_owned) else {
            return;
        };
        let request_id = value
            .get("request_id")
            .and_then(Value::as_str)
            .unwrap_or("browser-runtime-page-message")
            .to_owned();
        let Ok(envelope) =
            ScriptEnvelope::new(ScriptSource::Page, origin, channel, request_id, value)
        else {
            return;
        };
        self.lock().emit(surface_id, |sequence| {
            Some(SurfaceEvent::ScriptMessage {
                surface_id,
                sequence,
                envelope,
            })
        });
    }

    fn filter_request(
        &self,
        _surface_id: SurfaceId,
        _url: &str,
        _initiator: &str,
        _resource_type: i32,
    ) -> bool {
        // Content filtering (adblock-rust) plugs in here; the engine only
        // asks when it was initialized with filtering enabled.
        false
    }

    fn log(&self, level: i32, message: &str) {
        let level = match level {
            LOG_ERROR => "error",
            LOG_WARNING => "warning",
            _ => "info",
        };
        eprintln!("cef_host {level}: {message}");
    }
}

/// Frames inside a surface may load web content and in-page documents, never
/// local files or browser-internal pages.
fn subframe_url_allowed(url: &str) -> bool {
    let scheme = url
        .split_once(':')
        .map(|(scheme, _)| scheme.to_ascii_lowercase())
        .unwrap_or_default();
    matches!(scheme.as_str(), "https" | "http" | "about" | "data" | "blob")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use crate::browser_runtime::{
        NavigationDisposition, NavigationRequest, PresentationMode, PrivacyMode, SurfacePolicy,
    };
    use serde_json::json;
    use std::env;
    use std::fs::File;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(name: &str) -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = env::temp_dir().join(format!(
            "roscord-cef-host-{name}-{}-{timestamp}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn spec_with_presentation(key: &str, presentation: PresentationMode) -> SurfaceSpec {
        SurfaceSpec::new(
            ProfileKey::new(key).unwrap(),
            presentation,
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

    fn spec(key: &str) -> SurfaceSpec {
        spec_with_presentation(key, PresentationMode::Embedded)
    }

    fn host_args(extra: &[&str]) -> Vec<OsString> {
        let mut args = vec![
            OsString::from("cef_host"),
            OsString::from("--socket"),
            OsString::from("/tmp/roscord-cef.sock"),
            OsString::from("--parent-pid"),
            OsString::from("42"),
            OsString::from("--parent-nonce"),
            OsString::from("0123456789abcdef0123456789abcdef"),
            OsString::from("--cef-root"),
            OsString::from("/opt/roscord/cef"),
            OsString::from("--profile-root"),
            OsString::from("/tmp/roscord-profile"),
        ];
        args.extend(extra.iter().map(OsString::from));
        args
    }

    #[test]
    fn launch_arguments_accept_the_app_equals_form() {
        let config = HostConfig::parse(
            [
                "cef_host",
                "--socket=/tmp/roscord-cef.sock",
                "--parent-pid=42",
                "--parent-nonce=0123456789abcdef0123456789abcdef",
                "--cef-root=/opt/roscord/cef",
                "--profile-root=/tmp/roscord-profile",
                "--max-frame-bytes=4096",
                "--cef-software-rendering",
            ]
            .map(OsString::from),
        )
        .unwrap();
        assert_eq!(config.socket_path, PathBuf::from("/tmp/roscord-cef.sock"));
        assert_eq!(config.parent_pid, 42);
        assert_eq!(config.cef_root, PathBuf::from("/opt/roscord/cef"));
        assert_eq!(config.max_frame_bytes, 4096);
        assert!(config.software_rendering);
        assert_eq!(
            HostConfig::parse(host_args(&[])).unwrap().socket_path,
            PathBuf::from("/tmp/roscord-cef.sock")
        );
    }

    #[test]
    fn a_missing_profile_root_is_created_privately_with_its_parents() {
        let root = temp_root("profile-parents");
        let profile_root = root.join("share").join("roscord").join("cef").join("profiles");
        validate_profile_root(&profile_root).unwrap();
        for directory in [
            root.join("share"),
            root.join("share/roscord"),
            root.join("share/roscord/cef"),
            profile_root.clone(),
        ] {
            let mode = fs::metadata(&directory).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{}", directory.display());
        }
        // An existing ancestor others can write to is refused.
        let shared = root.join("shared");
        fs::create_dir(&shared).unwrap();
        fs::set_permissions(&shared, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(validate_profile_root(&shared.join("a").join("profiles")).is_err());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn children_find_the_runtime_from_the_argument_or_the_environment() {
        let root = child_cef_root(&[
            OsString::from("cef_host"),
            OsString::from("--type=renderer"),
            OsString::from("--cef-root=/opt/roscord/cef"),
        ])
        .unwrap();
        assert_eq!(root, PathBuf::from("/opt/roscord/cef"));
    }

    #[test]
    fn validation_and_fault_injection_flags_are_removed() {
        // The cutover removed `--cef-validation` and `--cef-fault`: every
        // spelling is rejected in all builds, and production routing is
        // unconditional.
        for flag in [
            "--cef-validation",
            "--cef-validation=true",
            "--cef-fault=host_crash",
            "--cef-fault=unknown",
            "--cef-fault",
        ] {
            let parsed = HostConfig::parse(host_args(&[flag]));
            assert!(
                matches!(parsed, Err(HostError::Usage(_))),
                "{flag} must be rejected, got {parsed:?}"
            );
        }
        let config = HostConfig::parse(host_args(&[])).unwrap();
        assert_eq!(
            config.max_frame_bytes,
            crate::browser_runtime::DEFAULT_MAX_FRAME_BYTES
        );
    }

    fn fake_cef_root(root: &Path) {
        for relative in REQUIRED_CEF_FILES {
            let path = root.join(relative);
            if *relative == "Release/locales" {
                fs::create_dir_all(path).unwrap();
            } else {
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                let file = File::create(path).unwrap();
                file.set_permissions(fs::Permissions::from_mode(0o600))
                    .unwrap();
            }
        }
        for directory in ["Release", "Release/locales"] {
            fs::set_permissions(root.join(directory), fs::Permissions::from_mode(0o700)).unwrap();
        }
    }

    #[test]
    fn host_core_completes_open_and_close_over_wire_messages() {
        let root = temp_root("lifecycle");
        let mut host = HostCore::new(root.clone());
        let opened = host
            .dispatch(WireMessage::Open {
                request_id: 7,
                spec: spec("account-a"),
            })
            .unwrap();
        assert!(matches!(
            opened[0],
            WireMessage::Opened {
                request_id: 7,
                surface_id: SurfaceId(1)
            }
        ));
        assert!(matches!(
            opened[1],
            WireMessage::Event {
                event: SurfaceEvent::Ready {
                    surface_id: SurfaceId(1),
                    sequence: 1,
                    ..
                }
            }
        ));
        assert_eq!(
            host.dispatch(WireMessage::Heartbeat { request_id: 12 })
                .unwrap(),
            vec![WireMessage::HeartbeatAck { request_id: 12 }]
        );

        let closed = host
            .dispatch(WireMessage::Close {
                surface_id: SurfaceId(1),
            })
            .unwrap();
        assert!(matches!(
            closed[0],
            WireMessage::Event {
                event: SurfaceEvent::Closed {
                    surface_id: SurfaceId(1),
                    ..
                }
            }
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn unix_transport_completes_open_close_and_shutdown() {
        let root = temp_root("transport");
        let codec = FramedCodec::new("nonce-transport-1234").unwrap();
        let server_codec = codec.clone();
        let (mut client, mut server) = UnixStream::pair().unwrap();
        let server_root = root.clone();
        let server_thread = std::thread::spawn(move || {
            let mut host = HostCore::new(server_root);
            serve_connection(&mut server, &server_codec, &mut host)
        });

        let open = WireMessage::Open {
            request_id: 11,
            spec: spec("transport-account"),
        };
        client.write_all(&codec.encode(&open).unwrap()).unwrap();
        assert!(matches!(
            read_message(&mut client, &codec).unwrap(),
            Some(WireMessage::Opened {
                request_id: 11,
                surface_id: SurfaceId(1)
            })
        ));
        assert!(matches!(
            read_message(&mut client, &codec).unwrap(),
            Some(WireMessage::Event {
                event: SurfaceEvent::Ready {
                    surface_id: SurfaceId(1),
                    ..
                }
            })
        ));

        let close = WireMessage::Close {
            surface_id: SurfaceId(1),
        };
        client.write_all(&codec.encode(&close).unwrap()).unwrap();
        assert!(matches!(
            read_message(&mut client, &codec).unwrap(),
            Some(WireMessage::Event {
                event: SurfaceEvent::Closed {
                    surface_id: SurfaceId(1),
                    ..
                }
            })
        ));
        drop(client);
        assert!(server_thread.join().unwrap().is_ok());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_parent_that_exits_with_unread_events_is_a_disconnect() {
        let codec = FramedCodec::new("nonce-transport-1234").unwrap();
        let (client, mut server) = UnixStream::pair().unwrap();
        // Closing a socket with unread data resets the connection.
        server.write_all(&[0_u8; 16]).unwrap();
        drop(client);
        assert!(matches!(read_message(&mut server, &codec), Ok(None)));
    }

    #[test]
    fn host_core_rejects_profile_and_surface_reuse() {
        let root = temp_root("ownership");
        let mut host = HostCore::new(root.clone());
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec("account-a"),
        })
        .unwrap();
        let command = SurfaceCommand::Focus {
            sequence: 1,
            profile_key: Some(ProfileKey::new("account-b").unwrap()),
            focused: true,
        };
        // Rejections are answered with a wire error so the connection
        // survives a bad command.
        let replies = host
            .dispatch(WireMessage::Command {
                request_id: 99,
                surface_id: SurfaceId(1),
                command,
            })
            .unwrap();
        assert!(matches!(
            replies.as_slice(),
            [WireMessage::Error {
                request_id: Some(99),
                code,
                ..
            }] if code == "runtime_failed"
        ));
        let replies = host
            .dispatch(WireMessage::Close {
                surface_id: SurfaceId(99),
            })
            .unwrap();
        assert!(matches!(
            replies.as_slice(),
            [WireMessage::Error {
                request_id: None,
                code,
                ..
            }] if code == "runtime_failed"
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn host_core_mediates_camera_and_display_requests() {
        use crate::browser_runtime::{FailureKind, PermissionDecision};

        let root = temp_root("media");
        let mut host = HostCore::new(root.clone());
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec("account-a"),
        })
        .unwrap();

        // Camera allow: acknowledged with no failure event.
        host.register_permission_request(
            SurfaceId(1),
            "media-camera-1".to_owned(),
            "https://widget.test".to_owned(),
            "https://widget.test".to_owned(),
            "camera",
        )
        .unwrap();
        let allowed = host
            .dispatch(WireMessage::Command {
                request_id: 10,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Permission {
                    sequence: 1,
                    profile_key: None,
                    request_id: "media-camera-1".to_owned(),
                    decision: PermissionDecision::AllowSession,
                },
            })
            .unwrap();
        assert_eq!(allowed, vec![WireMessage::Ack { request_id: 10 }]);

        // Camera deny: acknowledged plus a sanitized permission_denied event
        // that carries no origin.
        host.register_permission_request(
            SurfaceId(1),
            "media-camera-2".to_owned(),
            "https://widget.test".to_owned(),
            "https://widget.test".to_owned(),
            "microphone",
        )
        .unwrap();
        let denied = host
            .dispatch(WireMessage::Command {
                request_id: 11,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Permission {
                    sequence: 2,
                    profile_key: None,
                    request_id: "media-camera-2".to_owned(),
                    decision: PermissionDecision::Deny,
                },
            })
            .unwrap();
        assert!(matches!(
            denied.first(),
            Some(WireMessage::Ack { request_id: 11 })
        ));
        let Some(WireMessage::Event {
            event: SurfaceEvent::Failed { failure, .. },
        }) = denied.get(1)
        else {
            panic!("camera denial must emit a sanitized failure");
        };
        assert_eq!(failure.kind(), &FailureKind::PermissionDenied);
        assert!(!failure.message().contains("https://"));

        // Decisions for requests the host never issued grant nothing.
        let unknown = host
            .dispatch(WireMessage::Command {
                request_id: 12,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Permission {
                    sequence: 3,
                    profile_key: None,
                    request_id: "media-missing".to_owned(),
                    decision: PermissionDecision::AllowAlways,
                },
            })
            .unwrap();
        assert!(matches!(
            unknown.first(),
            Some(WireMessage::Error { request_id: Some(12), .. })
        ));
        let Some(WireMessage::Error { code, .. }) = unknown.first() else {
            unreachable!()
        };
        assert_eq!(code, "unknown_permission_request");

        // Display dismissal: the portal outcome denies the page with a
        // sanitized capture_denied event, and the consumed request cannot
        // be decided afterwards.
        host.register_permission_request(
            SurfaceId(1),
            "media-display-1".to_owned(),
            "https://widget.test".to_owned(),
            "https://widget.test".to_owned(),
            "display_video",
        )
        .unwrap();
        let portal = host
            .report_portal_outcome("media-display-1", "dismissed")
            .unwrap();
        let Some(WireMessage::Event {
            event: SurfaceEvent::Failed { failure, .. },
        }) = portal.first()
        else {
            panic!("portal dismissal must emit a sanitized failure");
        };
        assert_eq!(failure.kind(), &FailureKind::CaptureDenied);
        let late = host
            .dispatch(WireMessage::Command {
                request_id: 13,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Permission {
                    sequence: 4,
                    profile_key: None,
                    request_id: "media-display-1".to_owned(),
                    decision: PermissionDecision::AllowOnce,
                },
            })
            .unwrap();
        assert!(matches!(
            late.first(),
            Some(WireMessage::Error { request_id: Some(13), .. })
        ));

        // Closing the surface drops pending requests: late decisions fail
        // closed instead of granting a dead surface.
        host.register_permission_request(
            SurfaceId(1),
            "media-camera-3".to_owned(),
            "https://widget.test".to_owned(),
            "https://widget.test".to_owned(),
            "camera",
        )
        .unwrap();
        host.dispatch(WireMessage::Close {
            surface_id: SurfaceId(1),
        })
        .unwrap();
        let dead = host
            .dispatch(WireMessage::Command {
                request_id: 14,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Permission {
                    sequence: 5,
                    profile_key: None,
                    request_id: "media-camera-3".to_owned(),
                    decision: PermissionDecision::AllowOnce,
                },
            })
            .unwrap();
        let Some(WireMessage::Error { code, .. }) = dead.first() else {
            panic!("late decisions for closed surfaces must fail closed");
        };
        assert_eq!(code, "unknown_permission_request");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn host_core_acknowledges_the_global_transport_request_id() {
        let root = temp_root("command-request-id");
        let mut host = HostCore::new(root.clone());
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec("account-a"),
        })
        .unwrap();
        let responses = host
            .dispatch(WireMessage::Command {
                request_id: 77,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Focus {
                    sequence: 1,
                    profile_key: Some(ProfileKey::new("account-a").unwrap()),
                    focused: true,
                },
            })
            .unwrap();
        assert!(matches!(
            responses.first(),
            Some(WireMessage::Ack { request_id: 77 })
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn host_core_completes_generic_script_commands_without_echoing_app_messages() {
        let root = temp_root("script-command");
        let mut host = HostCore::new(root.clone());
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec("account-a"),
        })
        .unwrap();
        let envelope = ScriptEnvelope::new(
            ScriptSource::App,
            "https://surface.example",
            "test.channel",
            "script-1",
            json!({
                "operation": "dispatch_script_message",
                "storage_key": "app.toSurface:1",
                "payload": "_{\"kind\":\"message\"}\n",
            }),
        )
        .unwrap();
        let responses = host
            .dispatch(WireMessage::Command {
                request_id: 9,
                surface_id: SurfaceId(1),
                command: SurfaceCommand::Script {
                    sequence: 1,
                    profile_key: Some(ProfileKey::new("account-a").unwrap()),
                    envelope,
                },
            })
            .unwrap();
        assert!(matches!(
            responses.first(),
            Some(WireMessage::Ack { request_id: 9 })
        ));
        let WireMessage::Event {
            event: SurfaceEvent::ScriptMessage { envelope, .. },
        } = &responses[1]
        else {
            panic!("expected script completion event");
        };
        assert_eq!(envelope.source(), ScriptSource::Host);
        assert_eq!(envelope.value()["status"], json!("executed"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn persistent_profiles_are_bound_by_manifest_and_private_profiles_leave_no_directory() {
        let root = temp_root("profiles");
        let mut store = ProfileStore::new(root.clone());
        let account_a = ProfileKey::new("account-a").unwrap();
        let account_b = ProfileKey::new("account-b").unwrap();
        let first = store.open(&account_a, PrivacyMode::Persistent).unwrap();
        let second = store.open(&account_a, PrivacyMode::Persistent).unwrap();
        let other = store.open(&account_b, PrivacyMode::Persistent).unwrap();
        assert_eq!(first.context_id(), second.context_id());
        assert_ne!(first.context_id(), other.context_id());
        let private = store.open(&account_a, PrivacyMode::Private).unwrap();
        assert_ne!(first.context_id(), private.context_id());
        assert_eq!(fs::read_dir(&root).unwrap().count(), 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn host_core_clear_data_waits_for_quiescence_and_keeps_downloads() {
        let root = temp_root("clear-data");
        let mut host = HostCore::new(root.clone());
        let key = ProfileKey::new("account-a").unwrap();
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec("account-a"),
        })
        .unwrap();

        let profile_path = host
            .profile_store
            .persistent_path(&key)
            .unwrap()
            .to_owned();
        fs::create_dir(profile_path.join("downloads")).unwrap();
        File::create(profile_path.join("downloads").join("committed.bin")).unwrap();
        File::create(profile_path.join("old-cache.bin")).unwrap();

        assert!(matches!(host.clear_data(&key), Err(HostError::ProfileBusy)));
        host.dispatch(WireMessage::Close {
            surface_id: SurfaceId(1),
        })
        .unwrap();
        let result = host.clear_data(&key).unwrap();
        assert!(result.preserved_downloads());
        assert!(profile_path
            .join("downloads")
            .join("committed.bin")
            .exists());
        assert!(!profile_path.join("old-cache.bin").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn same_account_persistent_presentations_share_one_context() {
        let root = temp_root("presentations");
        let mut host = HostCore::new(root.clone());
        host.dispatch(WireMessage::Open {
            request_id: 1,
            spec: spec_with_presentation("account-a", PresentationMode::Embedded),
        })
        .unwrap();
        host.dispatch(WireMessage::Open {
            request_id: 2,
            spec: spec_with_presentation("account-a", PresentationMode::Standalone),
        })
        .unwrap();
        assert_eq!(
            host.surfaces
                .get(&SurfaceId(1))
                .unwrap()
                .context
                .context_id(),
            host.surfaces
                .get(&SurfaceId(2))
                .unwrap()
                .context
                .context_id()
        );
        host.dispatch(WireMessage::Close {
            surface_id: SurfaceId(1),
        })
        .unwrap();
        host.dispatch(WireMessage::Close {
            surface_id: SurfaceId(2),
        })
        .unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn validates_explicit_cef_payload_and_rejects_stale_endpoint() {
        let root = temp_root("payload");
        fake_cef_root(&root);
        assert_eq!(
            validate_cef_root(&root).unwrap(),
            fs::canonicalize(&root).unwrap()
        );

        let endpoint = root.join("host.sock");
        let first = UnixEndpoint::bind(&endpoint).unwrap();
        assert!(UnixEndpoint::bind(&endpoint).is_err());
        drop(first);
        assert!(!endpoint.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_elevated_and_insecure_launch_arguments() {
        assert!(reject_insecure_arguments(&[
            OsString::from("cef_host"),
            OsString::from("--no-sandbox"),
        ])
        .is_err());
        assert!(reject_insecure_arguments(&[
            OsString::from("cef_host"),
            OsString::from("--no-sandbox=1"),
        ])
        .is_err());
        assert!(validate_nonce("short").is_err());
        assert!(validate_absolute_path(Path::new("relative"), "--cef-root").is_err());
        if unsafe { libc::geteuid() } == 0 {
            assert!(reject_elevated_launch().is_err());
        } else {
            assert!(reject_elevated_launch().is_ok());
        }
    }

    #[test]
    fn authenticates_the_expected_unix_peer_credentials() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        let current_pid = std::process::id();
        assert!(peer_matches(&stream, current_pid).unwrap());
        assert!(!peer_matches(&stream, current_pid.saturating_add(1)).unwrap());
    }

    #[test]
    fn framed_transport_keeps_nonce_and_version_validation_at_host_boundary() {
        let codec = FramedCodec::new("nonce-123456789").unwrap();
        let frame = codec.encode(&WireMessage::Ack { request_id: 1 }).unwrap();
        assert_eq!(
            codec.decode(&frame).unwrap(),
            WireMessage::Ack { request_id: 1 }
        );
        let mut envelope: serde_json::Value = serde_json::from_slice(&frame[4..]).unwrap();
        envelope["version"] = json!(2);
        let body = serde_json::to_vec(&envelope).unwrap();
        let mut invalid = (body.len() as u32).to_be_bytes().to_vec();
        invalid.extend(body);
        assert!(codec.decode(&invalid).is_err());
    }
}
