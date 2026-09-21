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
use crate::browser_runtime_lifecycle::{
    FailureClass, FaultPoint, RuntimeEvent, RuntimeEventKind, RuntimeLifecycle, RuntimeState,
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
    spec: SurfaceSpec,
    profile_key: ProfileKey,
    last_command_sequence: u64,
}

struct HostTransport {
    child: Child,
    stream: UnixStream,
    codec: FramedCodec,
    socket_root: PathBuf,
}

struct PendingCommand {
    command_id: u64,
    surface_id: SurfaceId,
    waits_for_event: bool,
}

/// One lazily-started Linux host connection implementing the public seam.
pub struct LinuxBrowserRuntime {
    child: Child,
    stream: UnixStream,
    codec: FramedCodec,
    read_buffer: Vec<u8>,
    pending_events: VecDeque<SurfaceEvent>,
    surfaces: BTreeMap<SurfaceId, ClientSurface>,
    wire_surface_ids: BTreeMap<SurfaceId, SurfaceId>,
    next_request_id: u64,
    config: LinuxBrowserRuntimeConfig,
    socket_root: PathBuf,
    stopped: bool,
    connected: bool,
    started_at: Instant,
    lifecycle: RuntimeLifecycle,
    lifecycle_events: VecDeque<RuntimeEvent>,
    pending_commands: BTreeMap<u64, VecDeque<PendingCommand>>,
    acknowledged_commands: BTreeMap<SurfaceId, VecDeque<u64>>,
    held_presentation: BTreeMap<(SurfaceId, u8), SurfaceCommand>,
    validation_build: bool,
    fault_point: Option<FaultPoint>,
}

impl LinuxBrowserRuntime {
    /// Start one authenticated host process and connect to its owner-only
    /// endpoint.  CEF and sandbox validation remains in `cef_host` so the
    /// parent cannot accidentally weaken the host's launch boundary.
    pub fn start(config: LinuxBrowserRuntimeConfig) -> Result<Self, RuntimeError> {
        Self::start_with_validation_fault(config, None)
    }

    /// Validation-only launch hook used by deterministic lifecycle tests.
    /// Release builds reject the option before spawning the host.
    pub fn start_with_validation_fault(
        config: LinuxBrowserRuntimeConfig,
        fault_point: Option<FaultPoint>,
    ) -> Result<Self, RuntimeError> {
        if fault_point.is_some() && !cfg!(debug_assertions) {
            return Err(runtime_error(
                "CEF fault injection is unavailable in production builds",
            ));
        }
        Self::start_with_options(config, fault_point.is_some(), fault_point)
    }

    fn start_with_options(
        config: LinuxBrowserRuntimeConfig,
        validation_build: bool,
        fault_point: Option<FaultPoint>,
    ) -> Result<Self, RuntimeError> {
        validate_start_path(&config.host_binary, "host binary", true)?;
        validate_start_path(&config.cef_root, "CEF root", false)?;
        validate_absolute(&config.profile_root, "profile root")?;
        if config.max_frame_bytes == 0 || config.max_frame_bytes > u32::MAX as usize {
            return Err(runtime_error(
                "max frame size is outside the protocol limit",
            ));
        }

        let transport = spawn_host(&config, validation_build, fault_point)?;

        let mut lifecycle = RuntimeLifecycle::new();
        let mut lifecycle_events = lifecycle
            .start(0)
            .map_err(|error| runtime_error(format!("cannot start lifecycle: {error:?}")))?;
        lifecycle_events.extend(
            lifecycle
                .host_ready(0)
                .map_err(|error| runtime_error(format!("cannot ready lifecycle: {error:?}")))?,
        );
        Ok(Self {
            child: transport.child,
            stream: transport.stream,
            codec: transport.codec,
            read_buffer: Vec::new(),
            pending_events: VecDeque::new(),
            surfaces: BTreeMap::new(),
            wire_surface_ids: BTreeMap::new(),
            next_request_id: 1,
            config,
            socket_root: transport.socket_root,
            stopped: false,
            connected: true,
            started_at: Instant::now(),
            lifecycle,
            lifecycle_events: lifecycle_events.into(),
            pending_commands: BTreeMap::new(),
            acknowledged_commands: BTreeMap::new(),
            held_presentation: BTreeMap::new(),
            validation_build,
            fault_point,
        })
    }

    /// Close the authenticated stream and reap the host.  Dropping the
    /// client also performs this clean shutdown, but callers can make the
    /// lifecycle boundary explicit.
    pub fn shutdown(&mut self) {
        if self.stopped {
            let _ = self.stream.shutdown(std::net::Shutdown::Both);
            terminate_child(&mut self.child);
            remove_socket_root(&self.socket_root);
            return;
        }
        self.lifecycle_events
            .extend(self.lifecycle.begin_shutdown());
        self.stopped = true;
        self.connected = false;
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
        let clean = terminate_child(&mut self.child);
        remove_socket_root(&self.socket_root);
        self.surfaces.clear();
        self.pending_commands.clear();
        self.acknowledged_commands.clear();
        self.held_presentation.clear();
        if !clean {
            self.lifecycle_events.extend(self.lifecycle.report_failure(
                FailureClass::ShutdownTimeout,
                None,
                "cef_host did not exit within the shutdown deadline",
                self.now_ms(),
            ));
        }
        self.lifecycle_events
            .extend(self.lifecycle.finish_shutdown(clean));
    }

    pub fn lifecycle(&self) -> &RuntimeLifecycle {
        &self.lifecycle
    }

    pub fn lifecycle_events(&mut self) -> Vec<RuntimeEvent> {
        self.lifecycle_events.drain(..).collect()
    }

    /// Report a renderer, GPU, utility, or profile observation from the CEF
    /// child without widening the four-operation BrowserRuntime trait.
    pub fn report_surface_failure(
        &mut self,
        surface_id: SurfaceId,
        class: FailureClass,
        raw_status: Option<String>,
        message: impl Into<String>,
    ) -> Result<(), RuntimeError> {
        let events = self
            .lifecycle
            .report_surface_failure(surface_id, class, raw_status, message, self.now_ms())
            .map_err(|error| runtime_error(format!("cannot report surface failure: {error:?}")))?;
        self.lifecycle_events.extend(events);
        Ok(())
    }

    fn now_ms(&self) -> u64 {
        self.started_at
            .elapsed()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64
    }

    fn service_heartbeat(&mut self) -> Result<(), RuntimeError> {
        let now = self.now_ms();
        let events = self.lifecycle.tick(now);
        let timed_out = events.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::Failure { failure }
                    if failure.class == FailureClass::HostUnresponsive
            )
        });
        for event in &events {
            if let RuntimeEventKind::HeartbeatSent { request_id } = event.kind {
                self.send(&WireMessage::Heartbeat { request_id })?;
            }
        }
        self.lifecycle_events.extend(events);
        if timed_out {
            // A heartbeat timeout means the old process is no longer trusted.
            // Reap it before the bounded restart timer can launch a replacement;
            // this also releases profile locks held by the hung process.
            self.disconnect_transport();
        }
        Ok(())
    }

    fn reconnect_if_due(&mut self) {
        if self.stopped || !self.lifecycle.restart_ready(self.now_ms()) {
            return;
        }
        if let Err(error) = self.reconnect() {
            let now = self.now_ms();
            self.lifecycle_events.extend(self.lifecycle.report_failure(
                FailureClass::HostStartFailure,
                None,
                format!("automatic browser restart failed: {error}"),
                now,
            ));
        }
    }

    fn reconnect(&mut self) -> Result<(), RuntimeError> {
        self.connect_transport()?;
        self.lifecycle_events.extend(
            self.lifecycle
                .start(0)
                .map_err(|error| runtime_error(format!("cannot restart lifecycle: {error:?}")))?,
        );
        self.restore_and_ready()
    }

    /// Start one explicit retry after an automatic recovery budget is
    /// exhausted. It creates a fresh epoch and never replays side effects.
    pub fn retry_browser(&mut self) -> Result<(), RuntimeError> {
        if self.stopped {
            return Err(runtime_error("browser runtime is stopped"));
        }
        self.lifecycle_events.extend(
            self.lifecycle
                .retry(self.now_ms())
                .map_err(|error| runtime_error(format!("cannot retry lifecycle: {error:?}")))?,
        );
        if let Err(error) = self
            .connect_transport()
            .and_then(|_| self.restore_and_ready())
        {
            self.lifecycle_events.extend(self.lifecycle.report_failure(
                FailureClass::HostStartFailure,
                None,
                format!("manual browser retry failed: {error}"),
                self.now_ms(),
            ));
            return Err(error);
        }
        Ok(())
    }

    fn connect_transport(&mut self) -> Result<(), RuntimeError> {
        let transport = spawn_host(&self.config, self.validation_build, self.fault_point)?;
        self.child = transport.child;
        self.stream = transport.stream;
        self.codec = transport.codec;
        self.socket_root = transport.socket_root;
        self.connected = true;
        self.read_buffer.clear();
        self.started_at = Instant::now();
        Ok(())
    }

    fn restore_and_ready(&mut self) -> Result<(), RuntimeError> {
        if let Err(error) = self.restore_surfaces() {
            self.disconnect_transport();
            return Err(error);
        }
        self.lifecycle_events.extend(
            self.lifecycle
                .host_ready(0)
                .map_err(|error| runtime_error(format!("cannot ready lifecycle: {error:?}")))?,
        );
        self.flush_held_presentation()?;
        Ok(())
    }

    fn restore_surfaces(&mut self) -> Result<(), RuntimeError> {
        let surfaces = self
            .surfaces
            .iter()
            .map(|(surface_id, surface)| (*surface_id, surface.spec.clone()))
            .collect::<Vec<_>>();
        for (logical_surface_id, spec) in surfaces {
            let request_id = self.next_request_id()?;
            self.send(&WireMessage::Open {
                request_id,
                spec: spec.clone(),
            })?;
            self.finish_open(request_id, &spec, Some(logical_surface_id))?;
        }
        Ok(())
    }

    fn disconnect_transport(&mut self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
        terminate_child_now(&mut self.child);
        remove_socket_root(&self.socket_root);
        self.read_buffer.clear();
        self.wire_surface_ids.clear();
        self.pending_commands.clear();
        self.acknowledged_commands.clear();
        self.connected = false;
    }

    fn flush_held_presentation(&mut self) -> Result<(), RuntimeError> {
        let mut held = std::mem::take(&mut self.held_presentation)
            .into_iter()
            .collect::<Vec<_>>();
        held.sort_by_key(|(_, command)| command.sequence());
        for ((logical_surface_id, _), command) in held {
            let wire_surface_id = self
                .wire_surface_ids
                .get(&logical_surface_id)
                .copied()
                .ok_or(RuntimeError::StaleSurface(logical_surface_id))?;
            let token = self
                .lifecycle
                .begin_command(logical_surface_id, false)
                .map_err(|error| {
                    runtime_error(format!("cannot track presentation command: {error:?}"))
                })?;
            let request_id = self.next_request_id()?;
            self.pending_commands
                .entry(request_id)
                .or_default()
                .push_back(PendingCommand {
                    command_id: token.command_id,
                    surface_id: logical_surface_id,
                    waits_for_event: true,
                });
            if let Err(error) = self.send(&WireMessage::Command {
                request_id,
                surface_id: wire_surface_id,
                command,
            }) {
                self.pending_commands.remove(&request_id);
                let _ = self.lifecycle.complete_command(token.command_id);
                return Err(error);
            }
        }
        Ok(())
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
        let restoring_surface = matches!(self.lifecycle.state(), RuntimeState::Starting)
            && matches!(message, WireMessage::Open { .. });
        if self.stopped
            || !self.connected
            || (!matches!(
                self.lifecycle.state(),
                RuntimeState::Ready | RuntimeState::Degraded
            ) && !restoring_surface)
        {
            return Err(runtime_error("browser runtime is temporarily unavailable"));
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
        if let Err(error) = restore {
            return Err(error);
        }
        result
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
                Ok(0) => break Err(self.mark_host_lost("cef_host disconnected")),
                Ok(read) => self.read_buffer.extend_from_slice(&chunk[..read]),
                Err(error) => break Err(io_error("cannot read from cef_host", error)),
            }
        };
        let restore = self
            .stream
            .set_nonblocking(true)
            .map_err(|error| io_error("cannot restore host transport", error));
        if let Err(error) = restore {
            return Err(error);
        }
        result
    }

    fn drain_available(&mut self) -> Result<(), RuntimeError> {
        loop {
            let mut chunk = [0_u8; 8192];
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(self.mark_host_lost("cef_host disconnected"));
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

    fn mark_host_lost(&mut self, message: impl Into<String>) -> RuntimeError {
        if self.stopped || !self.connected {
            return runtime_error("cef_host disconnected");
        }
        let raw_status = self
            .child
            .try_wait()
            .ok()
            .flatten()
            .map(|status| status.to_string());
        self.disconnect_transport();
        self.lifecycle_events
            .extend(self.lifecycle.host_lost_with_status(
                self.now_ms(),
                raw_status,
                message.into(),
            ));
        self.pending_commands.clear();
        self.acknowledged_commands.clear();
        runtime_error("cef_host disconnected")
    }

    fn mark_protocol_violation(&mut self, message: impl Into<String>) -> RuntimeError {
        if self.stopped || !self.connected {
            return runtime_error("cef_host protocol violation");
        }
        self.disconnect_transport();
        self.lifecycle_events.extend(
            self.lifecycle
                .host_protocol_violation(self.now_ms(), message.into()),
        );
        self.pending_commands.clear();
        self.acknowledged_commands.clear();
        runtime_error("cef_host protocol violation")
    }

    fn accept_event(&mut self, message: WireMessage) -> Result<(), RuntimeError> {
        match message {
            WireMessage::Event { event } => {
                let event = self.remap_event(event);
                if matches!(
                    event,
                    SurfaceEvent::Navigation { .. }
                        | SurfaceEvent::WindowChanged { .. }
                        | SurfaceEvent::ScriptMessage { .. }
                ) {
                    let surface_id = event.surface_id();
                    if let Some(command_ids) = self.acknowledged_commands.get_mut(&surface_id) {
                        if let Some(command_id) = command_ids.pop_front() {
                            let _ = self.lifecycle.complete_command(command_id);
                        }
                        if command_ids.is_empty() {
                            self.acknowledged_commands.remove(&surface_id);
                        }
                    }
                }
                self.pending_events.push_back(event);
            }
            WireMessage::Ack { request_id } => {
                let pending = self
                    .pending_commands
                    .get_mut(&request_id)
                    .and_then(VecDeque::pop_front);
                let Some(pending) = pending else {
                    return Err(self
                        .mark_protocol_violation("host acknowledged an unknown command request"));
                };
                let _ = self.lifecycle.acknowledge_command(pending.command_id);
                if pending.waits_for_event {
                    self.acknowledged_commands
                        .entry(pending.surface_id)
                        .or_default()
                        .push_back(pending.command_id);
                } else {
                    let _ = self.lifecycle.complete_command(pending.command_id);
                }
                if self
                    .pending_commands
                    .get(&request_id)
                    .is_some_and(|pending| pending.is_empty())
                {
                    self.pending_commands.remove(&request_id);
                }
            }
            WireMessage::HeartbeatAck { request_id } => {
                let event = self
                    .lifecycle
                    .heartbeat_ack(request_id, self.now_ms())
                    .map_err(|error| {
                        runtime_error(format!("invalid heartbeat acknowledgement: {error:?}"))
                    })?;
                self.lifecycle_events.push_back(event);
            }
            WireMessage::Error {
                request_id: Some(request_id),
                code,
                message,
            } => {
                if let Some(command_ids) = self.pending_commands.remove(&request_id) {
                    let surface_id = command_ids.front().map(|pending| pending.surface_id);
                    for pending in command_ids {
                        let _ = self.lifecycle.complete_command(pending.command_id);
                    }
                    if let Some(class) = failure_class_for_code(&code) {
                        let events = match surface_id {
                            Some(surface_id) => self.lifecycle.report_surface_failure(
                                surface_id,
                                class,
                                None,
                                message.clone(),
                                self.now_ms(),
                            ),
                            None => Ok(self.lifecycle.report_failure(
                                class,
                                None,
                                message.clone(),
                                self.now_ms(),
                            )),
                        }
                        .map_err(|error| {
                            runtime_error(format!("cannot record command failure: {error:?}"))
                        })?;
                        self.lifecycle_events.extend(events);
                    }
                    return Err(runtime_error(format!("{code}: {message}")));
                }
                return Err(runtime_error(
                    "host returned an error for an unknown request",
                ));
            }
            WireMessage::Error {
                request_id: None,
                message,
                ..
            } => return Err(runtime_error(message)),
            WireMessage::Opened { .. } => return Err(runtime_error("unexpected host response")),
            WireMessage::Open { .. }
            | WireMessage::Command { .. }
            | WireMessage::Close { .. }
            | WireMessage::Heartbeat { .. } => {
                return Err(runtime_error("host sent a request to the parent"))
            }
        }
        Ok(())
    }

    fn remap_event(&self, event: SurfaceEvent) -> SurfaceEvent {
        let wire_surface_id = event.surface_id();
        let logical_surface_id = self
            .wire_surface_ids
            .iter()
            .find_map(|(logical, wire)| (*wire == wire_surface_id).then_some(*logical));
        match logical_surface_id {
            Some(logical) => remap_surface_event(event, logical, wire_surface_id),
            None => event,
        }
    }

    fn finish_open(
        &mut self,
        request_id: u64,
        spec: &SurfaceSpec,
        logical_surface_id: Option<SurfaceId>,
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
                    let event = match (logical_surface_id, surface_id) {
                        (Some(logical), Some(wire)) => remap_surface_event(event, logical, wire),
                        _ => event,
                    };
                    self.pending_events.push_back(event);
                }
                WireMessage::Error { code, message, .. } => {
                    if let Some(class) = failure_class_for_code(&code) {
                        self.lifecycle_events.extend(self.lifecycle.report_failure(
                            class,
                            None,
                            message.clone(),
                            self.now_ms(),
                        ));
                    }
                    return Err(runtime_error(format!("{code}: {message}")));
                }
                WireMessage::HeartbeatAck { .. } | WireMessage::Ack { .. } => {
                    return Err(runtime_error("host returned an invalid open response"))
                }
                _ => return Err(runtime_error("host returned an invalid open response")),
            }
        }
        let surface_id = surface_id.expect("open response was received");
        let logical_surface_id = logical_surface_id.unwrap_or(surface_id);
        let last_command_sequence = self
            .surfaces
            .get(&logical_surface_id)
            .map(|surface| surface.last_command_sequence)
            .unwrap_or(0);
        self.surfaces.insert(
            logical_surface_id,
            ClientSurface {
                spec: spec.clone(),
                profile_key: spec.profile_key().clone(),
                last_command_sequence,
            },
        );
        self.wire_surface_ids.insert(logical_surface_id, surface_id);
        self.lifecycle
            .register_surface(logical_surface_id, spec.clone())
            .map_err(|error| runtime_error(format!("cannot register surface: {error:?}")))?;
        Ok(logical_surface_id)
    }
}

impl BrowserRuntime for LinuxBrowserRuntime {
    fn open(&mut self, spec: SurfaceSpec) -> Result<SurfaceId, RuntimeError> {
        if !matches!(
            self.lifecycle.state(),
            RuntimeState::Ready | RuntimeState::Degraded
        ) {
            return Err(runtime_error("browser runtime is temporarily unavailable"));
        }
        spec.validate()?;
        let request_id = self.next_request_id()?;
        self.send(&WireMessage::Open {
            request_id,
            spec: spec.clone(),
        })?;
        self.finish_open(request_id, &spec, None)
    }

    fn command(
        &mut self,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<(), RuntimeError> {
        command.validate()?;
        let presentation = matches!(
            &command,
            SurfaceCommand::Resize { .. } | SurfaceCommand::Focus { .. }
        );
        if self.lifecycle.state() == RuntimeState::Restarting && presentation {
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
            let kind = if matches!(&command, SurfaceCommand::Resize { .. }) {
                0
            } else {
                1
            };
            self.held_presentation.insert((surface_id, kind), command);
            return Ok(());
        }
        if !matches!(
            self.lifecycle.state(),
            RuntimeState::Ready | RuntimeState::Degraded
        ) {
            return Err(runtime_error("browser runtime is temporarily unavailable"));
        }
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
        let side_effecting = !presentation;
        let command_token = self
            .lifecycle
            .begin_command(surface_id, side_effecting)
            .map_err(|error| runtime_error(format!("cannot track command: {error:?}")))?;
        let request_id = self.next_request_id()?;
        self.pending_commands
            .entry(request_id)
            .or_default()
            .push_back(PendingCommand {
                command_id: command_token.command_id,
                surface_id,
                waits_for_event: matches!(
                    &command,
                    SurfaceCommand::Navigate { .. }
                        | SurfaceCommand::Resize { .. }
                        | SurfaceCommand::Focus { .. }
                        | SurfaceCommand::Script { .. }
                ),
            });
        let wire_surface_id = self
            .wire_surface_ids
            .get(&surface_id)
            .copied()
            .unwrap_or(surface_id);
        self.send(&WireMessage::Command {
            request_id,
            surface_id: wire_surface_id,
            command,
        })
        .map_err(|error| {
            let empty = if let Some(pending) = self.pending_commands.get_mut(&request_id) {
                pending.retain(|pending| pending.command_id != command_token.command_id);
                pending.is_empty()
            } else {
                false
            };
            if empty {
                self.pending_commands.remove(&request_id);
            }
            let _ = self.lifecycle.complete_command(command_token.command_id);
            error
        })?;
        self.drain_available()
    }

    fn events(&mut self) -> Vec<SurfaceEvent> {
        if !self.stopped {
            if let Err(error) = self.service_heartbeat() {
                let _ = self.mark_host_lost(error.to_string());
            }
            if !self.stopped && self.connected {
                if let Err(error) = self.drain_available() {
                    if matches!(&error, RuntimeError::Protocol(_)) {
                        let _ = self.mark_protocol_violation(error.to_string());
                    } else {
                        let _ = self.mark_host_lost(error.to_string());
                    }
                }
            }
            self.reconnect_if_due();
        }
        self.pending_events.drain(..).collect()
    }

    fn close(&mut self, surface_id: SurfaceId) -> Result<(), RuntimeError> {
        if !self.surfaces.contains_key(&surface_id) {
            return Err(RuntimeError::StaleSurface(surface_id));
        }
        if self.lifecycle.state() == RuntimeState::Restarting {
            self.surfaces.remove(&surface_id);
            self.wire_surface_ids.remove(&surface_id);
            self.held_presentation.remove(&(surface_id, 0));
            self.held_presentation.remove(&(surface_id, 1));
            if let Some(command_ids) = self.acknowledged_commands.remove(&surface_id) {
                for command_id in command_ids {
                    let _ = self.lifecycle.complete_command(command_id);
                }
            }
            let _ = self.lifecycle.remove_surface(surface_id);
            return Ok(());
        }
        let wire_surface_id = self
            .wire_surface_ids
            .get(&surface_id)
            .copied()
            .unwrap_or(surface_id);
        self.send(&WireMessage::Close {
            surface_id: wire_surface_id,
        })?;
        loop {
            match self.read_blocking()? {
                WireMessage::Event { event } if event.surface_id() == wire_surface_id => {
                    let closed = matches!(event, SurfaceEvent::Closed { .. });
                    self.pending_events.push_back(remap_surface_event(
                        event,
                        surface_id,
                        wire_surface_id,
                    ));
                    if closed {
                        self.surfaces.remove(&surface_id);
                        self.wire_surface_ids.remove(&surface_id);
                        self.held_presentation.remove(&(surface_id, 0));
                        self.held_presentation.remove(&(surface_id, 1));
                        if let Some(command_ids) = self.acknowledged_commands.remove(&surface_id) {
                            for command_id in command_ids {
                                let _ = self.lifecycle.complete_command(command_id);
                            }
                        }
                        let _ = self.lifecycle.remove_surface(surface_id);
                        return Ok(());
                    }
                }
                WireMessage::Event { event } => {
                    self.pending_events.push_back(self.remap_event(event))
                }
                WireMessage::Error { message, .. } => return Err(runtime_error(message)),
                WireMessage::HeartbeatAck { .. } | WireMessage::Ack { .. } => {
                    return Err(runtime_error("host returned an invalid close response"))
                }
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

fn spawn_host(
    config: &LinuxBrowserRuntimeConfig,
    validation_build: bool,
    fault_point: Option<FaultPoint>,
) -> Result<HostTransport, RuntimeError> {
    let nonce = Uuid::new_v4().simple().to_string();
    let codec = FramedCodec::with_limit(nonce.clone(), config.max_frame_bytes)
        .map_err(RuntimeError::Protocol)?;
    let socket_root = create_socket_root(config.socket_root.as_deref(), &nonce)?;
    let socket_path = socket_root.join("host.sock");
    let parent_pid = std::process::id();
    let mut command = Command::new(&config.host_binary);
    command
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
        .arg(config.max_frame_bytes.to_string());
    if validation_build {
        command.arg("--cef-validation");
    }
    if let Some(fault_point) = fault_point {
        command.arg(format!("--cef-fault={}", fault_name(fault_point)));
    }
    let mut child = match command
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
    Ok(HostTransport {
        child,
        stream,
        codec,
        socket_root,
    })
}

fn fault_name(fault_point: FaultPoint) -> &'static str {
    match fault_point {
        FaultPoint::HostCrash => "host_crash",
        FaultPoint::HostUnresponsive => "host_unresponsive",
        FaultPoint::RendererCrash => "renderer_crash",
        FaultPoint::RendererOom => "renderer_oom",
        FaultPoint::RendererHang => "renderer_hang",
        FaultPoint::GpuCrash => "gpu_crash",
        FaultPoint::UtilityCrash => "utility_crash",
        FaultPoint::BadBundle => "bad_bundle",
        FaultPoint::BadProtocol => "bad_protocol",
        FaultPoint::SandboxFailure => "sandbox_failure",
        FaultPoint::ProfileLock => "profile_lock",
    }
}

fn failure_class_for_code(code: &str) -> Option<FailureClass> {
    Some(match code {
        "renderer_crash" => FailureClass::RendererCrash,
        "renderer_oom" => FailureClass::RendererOom,
        "renderer_killed" => FailureClass::RendererKilled,
        "renderer_abnormal_exit" => FailureClass::RendererAbnormalExit,
        "renderer_launch_failed" => FailureClass::RendererLaunchFailed,
        "renderer_integrity_failure" => FailureClass::RendererIntegrityFailure,
        "renderer_unresponsive" => FailureClass::RendererUnresponsive,
        "gpu_crash" => FailureClass::GpuCrash,
        "gpu_launch_failed" => FailureClass::GpuLaunchFailed,
        "utility_crash" => FailureClass::UtilityCrash,
        "network_service_failure" => FailureClass::NetworkServiceFailure,
        "utility_launch_failed" => FailureClass::UtilityLaunchFailed,
        "profile_locked" => FailureClass::ProfileLocked,
        "profile_corrupt" => FailureClass::ProfileCorrupt,
        "profile_unavailable" => FailureClass::ProfileUnavailable,
        _ => return None,
    })
}

fn remap_surface_event(
    event: SurfaceEvent,
    logical_surface_id: SurfaceId,
    wire_surface_id: SurfaceId,
) -> SurfaceEvent {
    if logical_surface_id == wire_surface_id {
        return event;
    }
    match event {
        SurfaceEvent::Ready {
            sequence,
            initial_navigation,
            ..
        } => SurfaceEvent::Ready {
            surface_id: logical_surface_id,
            sequence,
            initial_navigation,
        },
        SurfaceEvent::Closed {
            sequence, reason, ..
        } => SurfaceEvent::Closed {
            surface_id: logical_surface_id,
            sequence,
            reason,
        },
        SurfaceEvent::Failed {
            sequence, failure, ..
        } => SurfaceEvent::Failed {
            surface_id: logical_surface_id,
            sequence,
            failure,
        },
        SurfaceEvent::FrameReady {
            sequence, frame, ..
        } => SurfaceEvent::FrameReady {
            surface_id: logical_surface_id,
            sequence,
            frame,
        },
        SurfaceEvent::Navigation {
            sequence,
            navigation,
            ..
        } => SurfaceEvent::Navigation {
            surface_id: logical_surface_id,
            sequence,
            navigation,
        },
        SurfaceEvent::ScriptMessage {
            sequence, envelope, ..
        } => SurfaceEvent::ScriptMessage {
            surface_id: logical_surface_id,
            sequence,
            envelope,
        },
        SurfaceEvent::PermissionRequest {
            sequence,
            request_id,
            origin,
            top_level_origin,
            capability,
            user_gesture,
            ..
        } => SurfaceEvent::PermissionRequest {
            surface_id: logical_surface_id,
            sequence,
            request_id,
            origin,
            top_level_origin,
            capability,
            user_gesture,
        },
        SurfaceEvent::PopupRequest {
            sequence,
            request_id,
            url,
            user_gesture,
            ..
        } => SurfaceEvent::PopupRequest {
            surface_id: logical_surface_id,
            sequence,
            request_id,
            url,
            user_gesture,
        },
        SurfaceEvent::DownloadRequest {
            sequence,
            request_id,
            url,
            ..
        } => SurfaceEvent::DownloadRequest {
            surface_id: logical_surface_id,
            sequence,
            request_id,
            url,
        },
        SurfaceEvent::ClipboardRequest {
            sequence,
            request_id,
            write,
            user_gesture,
            ..
        } => SurfaceEvent::ClipboardRequest {
            surface_id: logical_surface_id,
            sequence,
            request_id,
            write,
            user_gesture,
        },
        SurfaceEvent::WindowChanged {
            sequence, change, ..
        } => SurfaceEvent::WindowChanged {
            surface_id: logical_surface_id,
            sequence,
            change,
        },
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

fn terminate_child(child: &mut Child) -> bool {
    if child.try_wait().ok().flatten().is_some() {
        return true;
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => thread::sleep(HOST_POLL_INTERVAL),
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    false
}

fn terminate_child_now(child: &mut Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn remove_socket_root(path: &Path) {
    let _ = fs::remove_dir_all(path);
}

fn runtime_error(message: impl Into<String>) -> RuntimeError {
    RuntimeError::Protocol(ProtocolError::InvalidMessage(sanitize_runtime_message(
        &message.into(),
    )))
}

fn io_error(context: impl Into<String>, error: io::Error) -> RuntimeError {
    runtime_error(format!("{}: {error}", context.into()))
}

fn sanitize_runtime_message(value: &str) -> String {
    value
        .split_whitespace()
        .map(|token| {
            let lower = token.to_ascii_lowercase();
            if lower.starts_with("http://") || lower.starts_with("https://") {
                "<redacted-url>"
            } else if ["token=", "secret=", "password=", "cookie=", "profile_key="]
                .iter()
                .any(|prefix| lower.starts_with(prefix))
            {
                "<redacted-secret>"
            } else if token.contains('/')
                || token.contains('\\')
                || (token.len() > 2 && token.as_bytes()[1] == b':')
            {
                "<redacted-path>"
            } else {
                token
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(512)
        .collect()
}
