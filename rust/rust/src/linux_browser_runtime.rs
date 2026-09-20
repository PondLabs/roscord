//! Linux BrowserRuntime client for the authenticated `cef_host` transport.
//!
//! The client owns host startup and the one Unix stream for a desktop
//! instance.  It only moves [`WireMessage`] values across the process
//! boundary; CEF objects and buffers remain in the host.

use std::collections::{BTreeMap, VecDeque};
use std::env;
use std::fs::{self, symlink_metadata};
use std::io::{self, ErrorKind, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use uuid::Uuid;

use crate::browser_runtime::{
    BrowserRuntime, FramedCodec, ProfileKey, ProtocolError, RuntimeError, SurfaceCommand,
    SurfaceEvent, SurfaceId, SurfaceSpec, WireMessage, DEFAULT_MAX_FRAME_BYTES,
};

const HOST_START_TIMEOUT: Duration = Duration::from_secs(5);
const HOST_POLL_INTERVAL: Duration = Duration::from_millis(10);

/// Explicit inputs needed to start the bundled Linux host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LinuxBrowserRuntimeConfig {
    pub host_binary: PathBuf,
    pub cef_root: PathBuf,
    pub profile_root: PathBuf,
    /// Optional owner-controlled parent for a private per-runtime socket dir.
    /// When omitted, XDG_RUNTIME_DIR or the system temporary directory is
    /// used only as the parent; the actual socket directory is mode 0700.
    pub socket_root: Option<PathBuf>,
    pub max_frame_bytes: usize,
}

impl LinuxBrowserRuntimeConfig {
    pub fn new(
        host_binary: impl Into<PathBuf>,
        cef_root: impl Into<PathBuf>,
        profile_root: impl Into<PathBuf>,
    ) -> Self {
        Self {
            host_binary: host_binary.into(),
            cef_root: cef_root.into(),
            profile_root: profile_root.into(),
            socket_root: None,
            max_frame_bytes: DEFAULT_MAX_FRAME_BYTES,
        }
    }
}

struct ClientSurface {
    profile_key: ProfileKey,
    last_command_sequence: u64,
}

/// One lazily-started Linux host connection implementing the public seam.
pub struct LinuxBrowserRuntime {
    child: Child,
    stream: UnixStream,
    codec: FramedCodec,
    read_buffer: Vec<u8>,
    pending_events: VecDeque<SurfaceEvent>,
    surfaces: BTreeMap<SurfaceId, ClientSurface>,
    next_request_id: u64,
    socket_root: PathBuf,
    stopped: bool,
}

impl LinuxBrowserRuntime {
    /// Start one authenticated host process and connect to its owner-only
    /// endpoint.  CEF and sandbox validation remains in `cef_host` so the
    /// parent cannot accidentally weaken the host's launch boundary.
    pub fn start(config: LinuxBrowserRuntimeConfig) -> Result<Self, RuntimeError> {
        validate_start_path(&config.host_binary, "host binary", true)?;
        validate_start_path(&config.cef_root, "CEF root", false)?;
        validate_absolute(&config.profile_root, "profile root")?;
        if config.max_frame_bytes == 0 || config.max_frame_bytes > u32::MAX as usize {
            return Err(runtime_error(
                "max frame size is outside the protocol limit",
            ));
        }

        let nonce = Uuid::new_v4().simple().to_string();
        let codec = FramedCodec::with_limit(nonce.clone(), config.max_frame_bytes)
            .map_err(RuntimeError::Protocol)?;
        let socket_root = create_socket_root(config.socket_root.as_deref(), &nonce)?;
        let socket_path = socket_root.join("host.sock");
        let parent_pid = std::process::id();
        let mut child = match Command::new(&config.host_binary)
            .arg("--socket")
            .arg(&socket_path)
            .arg("--parent-pid")
            .arg(parent_pid.to_string())
            .arg("--parent-nonce")
            .arg(&nonce)
            .arg("--cef-root")
            .arg(&config.cef_root)
            .arg("--profile-root")
            .arg(&config.profile_root)
            .arg("--max-frame-bytes")
            .arg(config.max_frame_bytes.to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                remove_socket_root(&socket_root);
                return Err(io_error("cannot start cef_host", error));
            }
        };

        let stream = match connect_to_host(&mut child, &socket_path) {
            Ok(stream) => stream,
            Err(error) => {
                terminate_child(&mut child);
                remove_socket_root(&socket_root);
                return Err(error);
            }
        };
        if let Err(error) = stream.set_nonblocking(true) {
            terminate_child(&mut child);
            remove_socket_root(&socket_root);
            return Err(io_error("cannot configure cef_host transport", error));
        }

        Ok(Self {
            child,
            stream,
            codec,
            read_buffer: Vec::new(),
            pending_events: VecDeque::new(),
            surfaces: BTreeMap::new(),
            next_request_id: 1,
            socket_root,
            stopped: false,
        })
    }

    /// Close the authenticated stream and reap the host.  Dropping the
    /// client also performs this clean shutdown, but callers can make the
    /// lifecycle boundary explicit.
    pub fn shutdown(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
        terminate_child(&mut self.child);
        remove_socket_root(&self.socket_root);
        self.surfaces.clear();
    }

    fn next_request_id(&mut self) -> Result<u64, RuntimeError> {
        let request_id = self.next_request_id;
        self.next_request_id = self
            .next_request_id
            .checked_add(1)
            .ok_or_else(|| runtime_error("request id exhausted"))?;
        Ok(request_id)
    }

    fn send(&mut self, message: &WireMessage) -> Result<(), RuntimeError> {
        if self.stopped {
            return Err(runtime_error("cef_host is stopped"));
        }
        let frame = self.codec.encode(message).map_err(RuntimeError::Protocol)?;
        self.stream
            .set_nonblocking(false)
            .map_err(|error| io_error("cannot prepare host write", error))?;
        let result = self
            .stream
            .write_all(&frame)
            .map_err(|error| io_error("cannot write to cef_host", error));
        let restore = self
            .stream
            .set_nonblocking(true)
            .map_err(|error| io_error("cannot restore host transport", error));
        result.and(restore)
    }

    fn read_blocking(&mut self) -> Result<WireMessage, RuntimeError> {
        self.stream
            .set_nonblocking(false)
            .map_err(|error| io_error("cannot prepare host read", error))?;
        let result = loop {
            match self.codec.decode_next(&mut self.read_buffer) {
                Ok(Some(message)) => break Ok(message),
                Ok(None) => {}
                Err(error) => break Err(RuntimeError::Protocol(error)),
            }
            let mut chunk = [0_u8; 8192];
            match self.stream.read(&mut chunk) {
                Ok(0) => break Err(runtime_error("cef_host disconnected")),
                Ok(read) => self.read_buffer.extend_from_slice(&chunk[..read]),
                Err(error) => break Err(io_error("cannot read from cef_host", error)),
            }
        };
        let restore = self
            .stream
            .set_nonblocking(true)
            .map_err(|error| io_error("cannot restore host transport", error));
        result.and(restore)
    }

    fn drain_available(&mut self) -> Result<(), RuntimeError> {
        loop {
            let mut chunk = [0_u8; 8192];
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    self.stopped = true;
                    return Err(runtime_error("cef_host disconnected"));
                }
                Ok(read) => self.read_buffer.extend_from_slice(&chunk[..read]),
                Err(error) if error.kind() == ErrorKind::WouldBlock => break,
                Err(error) => return Err(io_error("cannot read from cef_host", error)),
            }
            while let Some(message) = self
                .codec
                .decode_next(&mut self.read_buffer)
                .map_err(RuntimeError::Protocol)?
            {
                self.accept_event(message)?;
            }
        }
        while let Some(message) = self
            .codec
            .decode_next(&mut self.read_buffer)
            .map_err(RuntimeError::Protocol)?
        {
            self.accept_event(message)?;
        }
        Ok(())
    }

    fn accept_event(&mut self, message: WireMessage) -> Result<(), RuntimeError> {
        match message {
            WireMessage::Event { event } => self.pending_events.push_back(event),
            WireMessage::Error { message, .. } => return Err(runtime_error(message)),
            WireMessage::Opened { .. } | WireMessage::Ack { .. } => {
                return Err(runtime_error("unexpected host response"))
            }
            WireMessage::Open { .. } | WireMessage::Command { .. } | WireMessage::Close { .. } => {
                return Err(runtime_error("host sent a request to the parent"))
            }
        }
        Ok(())
    }

    fn finish_open(
        &mut self,
        request_id: u64,
        spec: &SurfaceSpec,
    ) -> Result<SurfaceId, RuntimeError> {
        let mut surface_id = None;
        let mut ready = false;
        while surface_id.is_none() || !ready {
            match self.read_blocking()? {
                WireMessage::Opened {
                    request_id: received,
                    surface_id: received_surface,
                } if received == request_id => surface_id = Some(received_surface),
                WireMessage::Opened { .. } => {
                    return Err(runtime_error("host returned an unexpected open response"))
                }
                WireMessage::Event { event } => {
                    if let SurfaceEvent::Ready {
                        surface_id: ready_id,
                        ..
                    } = &event
                    {
                        if let Some(opened_id) = surface_id {
                            if opened_id != *ready_id {
                                return Err(runtime_error(
                                    "host ready event does not match opened surface",
                                ));
                            }
                        }
                        ready = true;
                    }
                    self.pending_events.push_back(event);
                }
                WireMessage::Error { message, .. } => return Err(runtime_error(message)),
                _ => return Err(runtime_error("host returned an invalid open response")),
            }
        }
        let surface_id = surface_id.expect("open response was received");
        self.surfaces.insert(
            surface_id,
            ClientSurface {
                profile_key: spec.profile_key().clone(),
                last_command_sequence: 0,
            },
        );
        Ok(surface_id)
    }
}

impl BrowserRuntime for LinuxBrowserRuntime {
    fn open(&mut self, spec: SurfaceSpec) -> Result<SurfaceId, RuntimeError> {
        spec.validate()?;
        let request_id = self.next_request_id()?;
        self.send(&WireMessage::Open {
            request_id,
            spec: spec.clone(),
        })?;
        self.finish_open(request_id, &spec)
    }

    fn command(
        &mut self,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<(), RuntimeError> {
        command.validate()?;
        {
            let surface = self
                .surfaces
                .get_mut(&surface_id)
                .ok_or(RuntimeError::StaleSurface(surface_id))?;
            if let Some(profile_key) = command.profile_key() {
                if profile_key != &surface.profile_key {
                    return Err(RuntimeError::ProfileMismatch);
                }
            }
            if command.sequence() <= surface.last_command_sequence {
                return Err(RuntimeError::SequenceViolation {
                    expected_after: surface.last_command_sequence,
                    received: command.sequence(),
                });
            }
            surface.last_command_sequence = command.sequence();
        }
        self.send(&WireMessage::Command {
            surface_id,
            command,
        })?;
        self.drain_available()
    }

    fn events(&mut self) -> Vec<SurfaceEvent> {
        if !self.stopped {
            let _ = self.drain_available();
        }
        self.pending_events.drain(..).collect()
    }

    fn close(&mut self, surface_id: SurfaceId) -> Result<(), RuntimeError> {
        if !self.surfaces.contains_key(&surface_id) {
            return Err(RuntimeError::StaleSurface(surface_id));
        }
        self.send(&WireMessage::Close { surface_id })?;
        loop {
            match self.read_blocking()? {
                WireMessage::Event { event } if event.surface_id() == surface_id => {
                    let closed = matches!(event, SurfaceEvent::Closed { .. });
                    self.pending_events.push_back(event);
                    if closed {
                        self.surfaces.remove(&surface_id);
                        return Ok(());
                    }
                }
                WireMessage::Event { event } => self.pending_events.push_back(event),
                WireMessage::Error { message, .. } => return Err(runtime_error(message)),
                _ => return Err(runtime_error("host returned an invalid close response")),
            }
        }
    }
}

impl Drop for LinuxBrowserRuntime {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn validate_absolute(path: &Path, description: &str) -> Result<(), RuntimeError> {
    if !path.is_absolute() {
        return Err(runtime_error(format!("{description} must be absolute")));
    }
    Ok(())
}

fn validate_start_path(
    path: &Path,
    description: &str,
    require_file: bool,
) -> Result<(), RuntimeError> {
    validate_absolute(path, description)?;
    let metadata = symlink_metadata(path)
        .map_err(|error| io_error(format!("cannot inspect {description}"), error))?;
    if metadata.file_type().is_symlink()
        || (require_file && !metadata.is_file())
        || (!require_file && !metadata.is_dir())
    {
        return Err(runtime_error(format!("{description} is not a real path")));
    }
    if require_file && metadata.mode() & 0o022 != 0 {
        return Err(runtime_error(format!(
            "{description} is writable by other users"
        )));
    }
    Ok(())
}

fn create_socket_root(base: Option<&Path>, nonce: &str) -> Result<PathBuf, RuntimeError> {
    let base = base
        .map(Path::to_owned)
        .or_else(|| env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from))
        .unwrap_or_else(env::temp_dir);
    validate_absolute(&base, "socket root")?;
    let base_metadata =
        symlink_metadata(&base).map_err(|error| io_error("cannot inspect socket root", error))?;
    if base_metadata.file_type().is_symlink() || !base_metadata.is_dir() {
        return Err(runtime_error("socket root is not a real directory"));
    }
    let root = base.join(format!("roscord-cef-{}-{nonce}", std::process::id()));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&root)
        .map_err(|error| io_error("cannot create private socket root", error))?;
    Ok(root)
}

fn connect_to_host(child: &mut Child, socket_path: &Path) -> Result<UnixStream, RuntimeError> {
    let deadline = Instant::now() + HOST_START_TIMEOUT;
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| io_error("cannot inspect cef_host", error))?
        {
            return Err(runtime_error(format!(
                "cef_host exited before opening its endpoint ({status})"
            )));
        }
        match UnixStream::connect(socket_path) {
            Ok(stream) => return Ok(stream),
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::NotFound | ErrorKind::ConnectionRefused
                ) && Instant::now() < deadline =>
            {
                thread::sleep(HOST_POLL_INTERVAL);
            }
            Err(error) => return Err(io_error("cannot connect to cef_host", error)),
        }
    }
}

fn terminate_child(child: &mut Child) {
    if child.try_wait().ok().flatten().is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
}

fn remove_socket_root(path: &Path) {
    let _ = fs::remove_dir_all(path);
}

fn runtime_error(message: impl Into<String>) -> RuntimeError {
    RuntimeError::Protocol(ProtocolError::InvalidMessage(message.into()))
}

fn io_error(context: impl Into<String>, error: io::Error) -> RuntimeError {
    runtime_error(format!("{}: {error}", context.into()))
}
