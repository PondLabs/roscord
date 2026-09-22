//! Bounded BrowserRuntime lifecycle and recovery policy.
//!
//! This module is deliberately independent of CEF and of either desktop
//! transport.  The Windows and Linux adapters feed host/child observations
//! into this controller and expose the resulting [`RuntimeEvent`] values to
//! callers.  Keeping the policy here makes the backoff, command and shutdown
//! rules deterministic in unit tests.

use std::collections::{BTreeMap, VecDeque};

use serde::{Deserialize, Serialize};

use crate::browser_runtime::{
    BrowserRuntime, RuntimeError, SurfaceCommand, SurfaceId, SurfaceSpec,
};

pub const HEARTBEAT_INTERVAL_MS: u64 = 2_000;
pub const HEARTBEAT_TIMEOUT_MS: u64 = 10_000;
pub const HOST_TERMINATION_GRACE_MS: u64 = 5_000;
pub const RESTART_WINDOW_MS: u64 = 60_000;
pub const HEALTHY_RESET_MS: u64 = 60_000;
pub const MAX_AUTOMATIC_HOST_RESTARTS: usize = 3;
pub const MAX_RENDERER_RECOVERIES: usize = 2;
pub const MAX_GPU_FAILURES: usize = 2;

const AUTOMATIC_RESTART_DELAYS_MS: [u64; MAX_AUTOMATIC_HOST_RESTARTS] = [250, 1_000, 4_000];

/// The externally observable state of the one desktop host instance.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeState {
    Stopped,
    Starting,
    Ready,
    Degraded,
    Restarting,
    Failed,
    Stopping,
}

/// The recovery boundary for a failure.  A child failure must not be
/// misreported as a host failure because that would restart every surface.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureScope {
    Lifecycle,
    Host,
    Renderer,
    Gpu,
    Utility,
    Profile,
}

/// Stable, CEF-independent failure classifications.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureClass {
    CleanStop,
    ShutdownTimeout,
    HostStartFailure,
    HostCrash,
    HostUnresponsive,
    HostProtocolViolation,
    RendererCrash,
    RendererOom,
    RendererKilled,
    RendererAbnormalExit,
    RendererLaunchFailed,
    RendererIntegrityFailure,
    RendererUnresponsive,
    GpuCrash,
    GpuLaunchFailed,
    GpuDisabled,
    UtilityCrash,
    NetworkServiceFailure,
    UtilityLaunchFailed,
    ProfileLocked,
    ProfileCorrupt,
    ProfileUnavailable,
    GraphicsUnavailable,
}

impl FailureClass {
    pub fn scope(self) -> FailureScope {
        match self {
            Self::CleanStop | Self::ShutdownTimeout => FailureScope::Lifecycle,
            Self::HostStartFailure
            | Self::HostCrash
            | Self::HostUnresponsive
            | Self::HostProtocolViolation => FailureScope::Host,
            Self::RendererCrash
            | Self::RendererOom
            | Self::RendererKilled
            | Self::RendererAbnormalExit
            | Self::RendererLaunchFailed
            | Self::RendererIntegrityFailure
            | Self::RendererUnresponsive
            | Self::GraphicsUnavailable => FailureScope::Renderer,
            Self::GpuCrash | Self::GpuLaunchFailed | Self::GpuDisabled => FailureScope::Gpu,
            Self::UtilityCrash | Self::NetworkServiceFailure | Self::UtilityLaunchFailed => {
                FailureScope::Utility
            }
            Self::ProfileLocked | Self::ProfileCorrupt | Self::ProfileUnavailable => {
                FailureScope::Profile
            }
        }
    }

    /// Deterministic start/integrity failures never enter an automatic retry
    /// loop.  The user can still request one explicit retry.
    pub fn deterministic(self) -> bool {
        matches!(
            self,
            Self::HostStartFailure
                | Self::HostProtocolViolation
                | Self::ProfileLocked
                | Self::ProfileCorrupt
        )
    }

    pub fn is_clean_stop(self) -> bool {
        self == Self::CleanStop
    }
}

/// A redacted failure record shared by logs, diagnostics and lifecycle
/// events.  Callers should pass already-sanitized text; this type also removes
/// controls and caps the length at the protocol boundary.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuntimeFailure {
    pub failure_id: String,
    pub scope: FailureScope,
    pub class: FailureClass,
    pub recoverable: bool,
    pub raw_status: Option<String>,
    pub message: String,
}

impl RuntimeFailure {
    fn new(
        failure_id: String,
        class: FailureClass,
        raw_status: Option<String>,
        message: impl Into<String>,
    ) -> Self {
        let message = sanitize_text(&message.into(), 512);
        Self {
            failure_id,
            scope: class.scope(),
            class,
            recoverable: !class.deterministic() && !class.is_clean_stop(),
            raw_status: raw_status.map(|status| sanitize_text(&status, 128)),
            message,
        }
    }
}

fn sanitize_text(value: &str, max_length: usize) -> String {
    let mut sanitized = String::new();
    for token in value.split_whitespace() {
        if !sanitized.is_empty() {
            sanitized.push(' ');
        }
        let lower = token.to_ascii_lowercase();
        let replacement = if lower.starts_with("http://") || lower.starts_with("https://") {
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
        };
        sanitized.push_str(replacement);
    }
    sanitized.chars().take(max_length).collect()
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandOutcome {
    Failed,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandOutcomeReason {
    RuntimeLost,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type", content = "payload")]
pub enum RuntimeEventKind {
    StateChanged {
        state: RuntimeState,
    },
    HeartbeatSent {
        request_id: u64,
    },
    HeartbeatAck {
        request_id: u64,
    },
    Failure {
        failure: RuntimeFailure,
    },
    RestartScheduled {
        attempt: u8,
        delay_ms: u64,
    },
    CommandOutcome {
        command_id: u64,
        outcome: CommandOutcome,
        reason: CommandOutcomeReason,
    },
    SurfaceRecovering,
    SurfaceRestored,
    SurfaceFailed {
        failure: RuntimeFailure,
    },
    ShutdownComplete {
        clean: bool,
    },
}

/// A lossless lifecycle record.  `event_seq` is global to the desktop
/// runtime; `runtime_epoch` changes for every host process and makes stale
/// events from an older host unambiguous.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RuntimeEvent {
    pub event_seq: u64,
    pub runtime_epoch: u64,
    pub failure_id: Option<String>,
    pub surface_id: Option<SurfaceId>,
    pub kind: RuntimeEventKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandToken {
    pub command_id: u64,
    pub surface_id: SurfaceId,
    pub side_effecting: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleError {
    InvalidTransition {
        state: RuntimeState,
        action: &'static str,
    },
    UnknownSurface(SurfaceId),
    UnknownCommand(u64),
}

#[derive(Clone, Debug)]
struct SurfaceRecord {
    spec: SurfaceSpec,
    presentation: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
struct CommandRecord {
    token: CommandToken,
    acknowledged: bool,
}

/// Deterministic policy engine for one BrowserRuntime instance.
#[derive(Clone, Debug)]
pub struct RuntimeLifecycle {
    state: RuntimeState,
    runtime_epoch: u64,
    next_event_seq: u64,
    next_failure_seq: u64,
    next_heartbeat_id: u64,
    next_command_id: u64,
    last_heartbeat_sent_ms: Option<u64>,
    last_heartbeat_ack_ms: Option<u64>,
    pending_heartbeat: Option<u64>,
    restart_due_ms: Option<u64>,
    restart_attempts: VecDeque<u64>,
    renderer_failures: BTreeMap<SurfaceId, VecDeque<u64>>,
    gpu_failures: VecDeque<u64>,
    gpu_disabled: bool,
    healthy_since_ms: Option<u64>,
    stopping_intentionally: bool,
    surfaces: BTreeMap<SurfaceId, SurfaceRecord>,
    commands: BTreeMap<u64, CommandRecord>,
}

impl Default for RuntimeLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeLifecycle {
    pub fn new() -> Self {
        Self {
            state: RuntimeState::Stopped,
            runtime_epoch: 0,
            next_event_seq: 1,
            next_failure_seq: 1,
            next_heartbeat_id: 1,
            next_command_id: 1,
            last_heartbeat_sent_ms: None,
            last_heartbeat_ack_ms: None,
            pending_heartbeat: None,
            restart_due_ms: None,
            restart_attempts: VecDeque::new(),
            renderer_failures: BTreeMap::new(),
            gpu_failures: VecDeque::new(),
            gpu_disabled: false,
            healthy_since_ms: None,
            stopping_intentionally: false,
            surfaces: BTreeMap::new(),
            commands: BTreeMap::new(),
        }
    }

    pub fn state(&self) -> RuntimeState {
        self.state
    }

    pub fn runtime_epoch(&self) -> u64 {
        self.runtime_epoch
    }

    /// Whether this runtime epoch has been pinned to software rendering after
    /// repeated GPU failures.
    pub fn gpu_disabled(&self) -> bool {
        self.gpu_disabled
    }

    pub fn restart_due_ms(&self) -> Option<u64> {
        self.restart_due_ms
    }

    pub fn automatic_restart_attempts(&self, now_ms: u64) -> usize {
        self.restart_attempts
            .iter()
            .filter(|attempt| now_ms.saturating_sub(**attempt) < RESTART_WINDOW_MS)
            .count()
    }

    pub fn register_surface(
        &mut self,
        surface_id: SurfaceId,
        spec: SurfaceSpec,
    ) -> Result<(), LifecycleError> {
        self.surfaces
            .entry(surface_id)
            .or_insert_with(|| SurfaceRecord {
                spec,
                presentation: BTreeMap::new(),
            });
        Ok(())
    }

    pub fn surface_spec(&self, surface_id: SurfaceId) -> Option<&SurfaceSpec> {
        self.surfaces.get(&surface_id).map(|surface| &surface.spec)
    }

    pub fn remove_surface(&mut self, surface_id: SurfaceId) -> Result<(), LifecycleError> {
        self.surfaces
            .remove(&surface_id)
            .map(|_| ())
            .ok_or(LifecycleError::UnknownSurface(surface_id))
    }

    pub fn surface_ids(&self) -> impl Iterator<Item = SurfaceId> + '_ {
        self.surfaces.keys().copied()
    }

    pub fn set_presentation_value(
        &mut self,
        surface_id: SurfaceId,
        key: impl Into<String>,
        value: impl Into<String>,
    ) -> Result<(), LifecycleError> {
        let surface = self
            .surfaces
            .get_mut(&surface_id)
            .ok_or(LifecycleError::UnknownSurface(surface_id))?;
        surface.presentation.insert(key.into(), value.into());
        Ok(())
    }

    pub fn presentation_value(&self, surface_id: SurfaceId, key: &str) -> Option<&str> {
        self.surfaces
            .get(&surface_id)
            .and_then(|surface| surface.presentation.get(key))
            .map(String::as_str)
    }

    pub fn start(&mut self, now_ms: u64) -> Result<Vec<RuntimeEvent>, LifecycleError> {
        if !matches!(
            self.state,
            RuntimeState::Stopped | RuntimeState::Restarting | RuntimeState::Failed
        ) {
            return Err(LifecycleError::InvalidTransition {
                state: self.state,
                action: "start",
            });
        }
        self.stopping_intentionally = false;
        self.runtime_epoch = self.runtime_epoch.saturating_add(1);
        self.pending_heartbeat = None;
        self.last_heartbeat_sent_ms = None;
        self.last_heartbeat_ack_ms = Some(now_ms);
        self.healthy_since_ms = None;
        self.gpu_failures.clear();
        self.gpu_disabled = false;
        for attempts in self.renderer_failures.values_mut() {
            attempts.clear();
        }
        self.restart_due_ms = None;
        let mut events = vec![self.state_event(RuntimeState::Starting)];
        if !self.surfaces.is_empty() {
            for surface_id in self.surface_ids().collect::<Vec<_>>() {
                events.push(self.surface_event(surface_id, RuntimeEventKind::SurfaceRecovering));
            }
        }
        self.state = RuntimeState::Starting;
        Ok(events)
    }

    pub fn host_ready(&mut self, now_ms: u64) -> Result<Vec<RuntimeEvent>, LifecycleError> {
        if !matches!(self.state, RuntimeState::Starting | RuntimeState::Degraded) {
            return Err(LifecycleError::InvalidTransition {
                state: self.state,
                action: "host_ready",
            });
        }
        self.last_heartbeat_ack_ms = Some(now_ms);
        self.healthy_since_ms = Some(now_ms);
        self.pending_heartbeat = None;
        let mut events = vec![self.state_event(RuntimeState::Ready)];
        for surface_id in self.surface_ids().collect::<Vec<_>>() {
            events.push(self.surface_event(surface_id, RuntimeEventKind::SurfaceRestored));
        }
        self.state = RuntimeState::Ready;
        Ok(events)
    }

    pub fn heartbeat_due(&mut self, now_ms: u64) -> Option<RuntimeEvent> {
        if !matches!(self.state, RuntimeState::Ready | RuntimeState::Degraded) {
            return None;
        }
        if self
            .last_heartbeat_sent_ms
            .is_some_and(|sent| now_ms.saturating_sub(sent) < HEARTBEAT_INTERVAL_MS)
            || self.pending_heartbeat.is_some()
        {
            return None;
        }
        let request_id = self.next_heartbeat_id;
        self.next_heartbeat_id = self.next_heartbeat_id.saturating_add(1);
        self.last_heartbeat_sent_ms = Some(now_ms);
        self.pending_heartbeat = Some(request_id);
        Some(self.event(RuntimeEventKind::HeartbeatSent { request_id }, None, None))
    }

    pub fn heartbeat_ack(
        &mut self,
        request_id: u64,
        now_ms: u64,
    ) -> Result<RuntimeEvent, LifecycleError> {
        if self.pending_heartbeat != Some(request_id) {
            return Err(LifecycleError::InvalidTransition {
                state: self.state,
                action: "heartbeat_ack",
            });
        }
        self.pending_heartbeat = None;
        self.last_heartbeat_ack_ms = Some(now_ms);
        if self.healthy_since_ms.is_none() {
            self.healthy_since_ms = Some(now_ms);
        }
        Ok(self.event(RuntimeEventKind::HeartbeatAck { request_id }, None, None))
    }

    /// Advance time and return any heartbeat/recovery events that became due.
    pub fn tick(&mut self, now_ms: u64) -> Vec<RuntimeEvent> {
        let mut events = Vec::new();
        if self
            .healthy_since_ms
            .is_some_and(|healthy| now_ms.saturating_sub(healthy) >= HEALTHY_RESET_MS)
        {
            self.restart_attempts.clear();
            self.healthy_since_ms = Some(now_ms);
        }
        if let Some(last_ack) = self.last_heartbeat_ack_ms {
            if matches!(self.state, RuntimeState::Ready | RuntimeState::Degraded)
                && now_ms.saturating_sub(last_ack) >= HEARTBEAT_TIMEOUT_MS
            {
                events.extend(self.report_failure(
                    FailureClass::HostUnresponsive,
                    None,
                    "host heartbeat timed out",
                    now_ms,
                ));
                events.extend(self.resolve_in_flight_commands(FailureClass::HostUnresponsive));
            }
        }
        if let Some(heartbeat) = self.heartbeat_due(now_ms) {
            events.push(heartbeat);
        }
        events
    }

    pub fn report_failure(
        &mut self,
        class: FailureClass,
        raw_status: Option<String>,
        message: impl Into<String>,
        now_ms: u64,
    ) -> Vec<RuntimeEvent> {
        self.report_failure_at_surface(class, raw_status, message, now_ms, None)
    }

    pub fn report_surface_failure(
        &mut self,
        surface_id: SurfaceId,
        class: FailureClass,
        raw_status: Option<String>,
        message: impl Into<String>,
        now_ms: u64,
    ) -> Result<Vec<RuntimeEvent>, LifecycleError> {
        if !self.surfaces.contains_key(&surface_id) {
            return Err(LifecycleError::UnknownSurface(surface_id));
        }
        Ok(self.report_failure_at_surface(class, raw_status, message, now_ms, Some(surface_id)))
    }

    fn report_failure_at_surface(
        &mut self,
        class: FailureClass,
        raw_status: Option<String>,
        message: impl Into<String>,
        now_ms: u64,
        target_surface_id: Option<SurfaceId>,
    ) -> Vec<RuntimeEvent> {
        let classification = if self.stopping_intentionally && class.scope() == FailureScope::Host {
            FailureClass::CleanStop
        } else {
            class
        };
        let failure_id = format!("f-{}-{}", self.runtime_epoch, self.next_failure_seq);
        self.next_failure_seq = self.next_failure_seq.saturating_add(1);
        let failure = RuntimeFailure::new(failure_id.clone(), classification, raw_status, message);
        let mut events = vec![self.event(
            RuntimeEventKind::Failure {
                failure: failure.clone(),
            },
            Some(failure_id.clone()),
            None,
        )];

        if classification.is_clean_stop() || self.stopping_intentionally {
            return events;
        }
        match classification.scope() {
            FailureScope::Host => {
                if classification.deterministic() {
                    events.push(self.event(
                        RuntimeEventKind::StateChanged {
                            state: RuntimeState::Failed,
                        },
                        Some(failure_id.clone()),
                        None,
                    ));
                    self.state = RuntimeState::Failed;
                } else {
                    events.extend(self.schedule_host_restart(failure_id, now_ms));
                }
            }
            FailureScope::Renderer => {
                if let Some(surface_id) =
                    target_surface_id.or_else(|| self.first_surface_for_renderer_failure())
                {
                    let attempts = self.renderer_failures.entry(surface_id).or_default();
                    prune(attempts, now_ms);
                    attempts.push_back(now_ms);
                    if attempts.len() <= MAX_RENDERER_RECOVERIES {
                        events.push(self.event(
                            RuntimeEventKind::SurfaceRecovering,
                            Some(failure_id.clone()),
                            Some(surface_id),
                        ));
                    } else {
                        events.push(self.event(
                            RuntimeEventKind::SurfaceFailed {
                                failure: failure.clone(),
                            },
                            Some(failure_id),
                            Some(surface_id),
                        ));
                    }
                }
            }
            FailureScope::Gpu => {
                prune(&mut self.gpu_failures, now_ms);
                self.gpu_failures.push_back(now_ms);
                let state = RuntimeState::Degraded;
                if self.state != state {
                    events.push(self.event(
                        RuntimeEventKind::StateChanged { state },
                        Some(failure_id.clone()),
                        None,
                    ));
                    self.state = state;
                }
                if self.gpu_failures.len() >= MAX_GPU_FAILURES && !self.gpu_disabled {
                    self.gpu_disabled = true;
                    let disabled_failure_id =
                        format!("f-{}-{}", self.runtime_epoch, self.next_failure_seq);
                    self.next_failure_seq = self.next_failure_seq.saturating_add(1);
                    let disabled_failure = RuntimeFailure::new(
                        disabled_failure_id.clone(),
                        FailureClass::GpuDisabled,
                        Some(format!("{:?}", classification)),
                        "software rendering pinned after repeated GPU failures",
                    );
                    events.push(self.event(
                        RuntimeEventKind::Failure {
                            failure: disabled_failure,
                        },
                        Some(disabled_failure_id),
                        None,
                    ));
                }
            }
            FailureScope::Profile => {
                let surface_id =
                    target_surface_id.or_else(|| self.first_surface_for_profile_failure());
                if let Some(surface_id) = surface_id {
                    events.push(self.event(
                        RuntimeEventKind::SurfaceFailed {
                            failure: failure.clone(),
                        },
                        Some(failure_id),
                        Some(surface_id),
                    ));
                } else if classification.deterministic() {
                    events.push(self.event(
                        RuntimeEventKind::StateChanged {
                            state: RuntimeState::Failed,
                        },
                        Some(failure_id),
                        None,
                    ));
                    self.state = RuntimeState::Failed;
                }
            }
            FailureScope::Utility | FailureScope::Lifecycle => {}
        }
        events
    }

    pub fn host_lost(&mut self, now_ms: u64, message: impl Into<String>) -> Vec<RuntimeEvent> {
        self.host_lost_with_status(now_ms, None, message)
    }

    pub fn host_lost_with_status(
        &mut self,
        now_ms: u64,
        raw_status: Option<String>,
        message: impl Into<String>,
    ) -> Vec<RuntimeEvent> {
        if self.stopping_intentionally
            || matches!(self.state, RuntimeState::Stopping | RuntimeState::Stopped)
        {
            return self.report_failure(FailureClass::CleanStop, raw_status, message, now_ms);
        }
        let mut events = self.report_failure(FailureClass::HostCrash, raw_status, message, now_ms);
        events.extend(self.resolve_in_flight_commands(FailureClass::HostCrash));
        events
    }

    pub fn host_protocol_violation(
        &mut self,
        now_ms: u64,
        message: impl Into<String>,
    ) -> Vec<RuntimeEvent> {
        let mut events =
            self.report_failure(FailureClass::HostProtocolViolation, None, message, now_ms);
        events.extend(self.resolve_in_flight_commands(FailureClass::HostProtocolViolation));
        events
    }

    pub fn retry(&mut self, now_ms: u64) -> Result<Vec<RuntimeEvent>, LifecycleError> {
        if self.state != RuntimeState::Failed {
            return Err(LifecycleError::InvalidTransition {
                state: self.state,
                action: "retry",
            });
        }
        self.restart_attempts.clear();
        self.start(now_ms)
    }

    pub fn restart_ready(&self, now_ms: u64) -> bool {
        self.state == RuntimeState::Restarting
            && self.restart_due_ms.is_some_and(|due| now_ms >= due)
    }

    pub fn begin_command(
        &mut self,
        surface_id: SurfaceId,
        side_effecting: bool,
    ) -> Result<CommandToken, LifecycleError> {
        if !matches!(self.state, RuntimeState::Ready | RuntimeState::Degraded) {
            return Err(LifecycleError::InvalidTransition {
                state: self.state,
                action: "command",
            });
        }
        if !self.surfaces.contains_key(&surface_id) {
            return Err(LifecycleError::UnknownSurface(surface_id));
        }
        let token = CommandToken {
            command_id: self.next_command_id,
            surface_id,
            side_effecting,
        };
        self.next_command_id = self.next_command_id.saturating_add(1);
        self.commands.insert(
            token.command_id,
            CommandRecord {
                token: token.clone(),
                acknowledged: false,
            },
        );
        Ok(token)
    }

    pub fn acknowledge_command(&mut self, command_id: u64) -> Result<(), LifecycleError> {
        self.commands
            .get_mut(&command_id)
            .map(|command| command.acknowledged = true)
            .ok_or(LifecycleError::UnknownCommand(command_id))
    }

    pub fn complete_command(&mut self, command_id: u64) -> Result<(), LifecycleError> {
        self.commands
            .remove(&command_id)
            .map(|_| ())
            .ok_or(LifecycleError::UnknownCommand(command_id))
    }

    /// No command is safe to replay across a process crash.  Presentation
    /// values are held separately through [`set_presentation_value`].
    pub fn should_replay_command(&self, _command_id: u64) -> bool {
        false
    }

    pub fn begin_shutdown(&mut self) -> Vec<RuntimeEvent> {
        self.stopping_intentionally = true;
        if self.state == RuntimeState::Stopping || self.state == RuntimeState::Stopped {
            return Vec::new();
        }
        let event = self.state_event(RuntimeState::Stopping);
        self.state = RuntimeState::Stopping;
        vec![event]
    }

    pub fn finish_shutdown(&mut self, clean: bool) -> Vec<RuntimeEvent> {
        self.pending_heartbeat = None;
        self.restart_due_ms = None;
        self.commands.clear();
        self.state = RuntimeState::Stopped;
        vec![self.event(RuntimeEventKind::ShutdownComplete { clean }, None, None)]
    }

    fn resolve_in_flight_commands(&mut self, _reason: FailureClass) -> Vec<RuntimeEvent> {
        let pending = std::mem::take(&mut self.commands);
        pending
            .into_values()
            .map(|command| {
                let outcome = if command.acknowledged {
                    CommandOutcome::Unknown
                } else {
                    CommandOutcome::Failed
                };
                self.event(
                    RuntimeEventKind::CommandOutcome {
                        command_id: command.token.command_id,
                        outcome,
                        reason: CommandOutcomeReason::RuntimeLost,
                    },
                    None,
                    Some(command.token.surface_id),
                )
            })
            .collect()
    }

    fn schedule_host_restart(&mut self, failure_id: String, now_ms: u64) -> Vec<RuntimeEvent> {
        prune(&mut self.restart_attempts, now_ms);
        let attempt = self.restart_attempts.len();
        if attempt >= MAX_AUTOMATIC_HOST_RESTARTS {
            let state = self.event(
                RuntimeEventKind::StateChanged {
                    state: RuntimeState::Failed,
                },
                Some(failure_id),
                None,
            );
            self.state = RuntimeState::Failed;
            return vec![state];
        }
        let delay = AUTOMATIC_RESTART_DELAYS_MS[attempt];
        self.restart_attempts.push_back(now_ms);
        self.restart_due_ms = Some(
            now_ms
                .saturating_add(HOST_TERMINATION_GRACE_MS)
                .saturating_add(delay),
        );
        let mut events = Vec::new();
        if self.state != RuntimeState::Restarting {
            events.push(self.event(
                RuntimeEventKind::StateChanged {
                    state: RuntimeState::Restarting,
                },
                Some(failure_id.clone()),
                None,
            ));
            self.state = RuntimeState::Restarting;
            for surface_id in self.surface_ids().collect::<Vec<_>>() {
                events.push(self.event(
                    RuntimeEventKind::SurfaceRecovering,
                    Some(failure_id.clone()),
                    Some(surface_id),
                ));
            }
        }
        events.push(self.event(
            RuntimeEventKind::RestartScheduled {
                attempt: (attempt + 1) as u8,
                delay_ms: delay,
            },
            Some(failure_id),
            None,
        ));
        events
    }

    fn first_surface_for_renderer_failure(&self) -> Option<SurfaceId> {
        self.surfaces.keys().next().copied()
    }

    fn first_surface_for_profile_failure(&self) -> Option<SurfaceId> {
        self.surfaces.keys().next().copied()
    }

    fn state_event(&mut self, state: RuntimeState) -> RuntimeEvent {
        self.event(RuntimeEventKind::StateChanged { state }, None, None)
    }

    fn surface_event(&mut self, surface_id: SurfaceId, kind: RuntimeEventKind) -> RuntimeEvent {
        self.event(kind, None, Some(surface_id))
    }

    fn event(
        &mut self,
        kind: RuntimeEventKind,
        failure_id: Option<String>,
        surface_id: Option<SurfaceId>,
    ) -> RuntimeEvent {
        let event = RuntimeEvent {
            event_seq: self.next_event_seq,
            runtime_epoch: self.runtime_epoch,
            failure_id,
            surface_id,
            kind,
        };
        self.next_event_seq = self.next_event_seq.saturating_add(1);
        event
    }
}

/// Adapter used by the native clients to apply the lifecycle policy around a
/// concrete four-operation transport.  It intentionally does not replay an
/// operation after a disconnect; callers observe the command outcome events
/// and decide whether to issue a new command after a restored surface.
pub struct LifecycleBrowserRuntime<R: BrowserRuntime> {
    inner: R,
    lifecycle: RuntimeLifecycle,
    pending_events: VecDeque<RuntimeEvent>,
}

impl<R: BrowserRuntime> LifecycleBrowserRuntime<R> {
    pub fn new(mut inner: R, now_ms: u64) -> Result<Self, LifecycleError> {
        let mut lifecycle = RuntimeLifecycle::new();
        let mut pending_events = lifecycle.start(now_ms)?;
        pending_events.extend(lifecycle.host_ready(now_ms)?);
        // Keep the concrete transport alive in the wrapper.  It is already
        // authenticated by the time this constructor is called.
        let _ = &mut inner;
        Ok(Self {
            inner,
            lifecycle,
            pending_events: pending_events.into(),
        })
    }

    pub fn lifecycle(&self) -> &RuntimeLifecycle {
        &self.lifecycle
    }

    pub fn lifecycle_mut(&mut self) -> &mut RuntimeLifecycle {
        &mut self.lifecycle
    }

    pub fn lifecycle_events(&mut self) -> Vec<RuntimeEvent> {
        self.pending_events.drain(..).collect()
    }

    pub fn tick(&mut self, now_ms: u64) -> Vec<RuntimeEvent> {
        let events = self.lifecycle.tick(now_ms);
        self.pending_events.extend(events.iter().cloned());
        events
    }

    pub fn host_lost(&mut self, now_ms: u64, message: impl Into<String>) {
        self.pending_events
            .extend(self.lifecycle.host_lost(now_ms, message));
    }

    pub fn into_inner(self) -> R {
        self.inner
    }

    fn unavailable() -> RuntimeError {
        RuntimeError::Protocol(crate::browser_runtime::ProtocolError::InvalidMessage(
            "browser runtime is temporarily unavailable".to_owned(),
        ))
    }
}

impl<R: BrowserRuntime> BrowserRuntime for LifecycleBrowserRuntime<R> {
    fn open(&mut self, spec: SurfaceSpec) -> Result<SurfaceId, RuntimeError> {
        if !matches!(
            self.lifecycle.state(),
            RuntimeState::Ready | RuntimeState::Degraded
        ) {
            return Err(Self::unavailable());
        }
        let surface_id = self.inner.open(spec.clone())?;
        self.lifecycle
            .register_surface(surface_id, spec)
            .map_err(|_| Self::unavailable())?;
        Ok(surface_id)
    }

    fn command(
        &mut self,
        surface_id: SurfaceId,
        command: SurfaceCommand,
    ) -> Result<(), RuntimeError> {
        if !matches!(
            self.lifecycle.state(),
            RuntimeState::Ready | RuntimeState::Degraded
        ) {
            return Err(Self::unavailable());
        }
        let side_effecting = !matches!(
            command,
            SurfaceCommand::Resize { .. } | SurfaceCommand::Focus { .. }
        );
        let token = self
            .lifecycle
            .begin_command(surface_id, side_effecting)
            .map_err(|_| Self::unavailable())?;
        match self.inner.command(surface_id, command) {
            Ok(()) => {
                let _ = self.lifecycle.acknowledge_command(token.command_id);
                let _ = self.lifecycle.complete_command(token.command_id);
                Ok(())
            }
            Err(error) => {
                let _ = self.lifecycle.complete_command(token.command_id);
                Err(error)
            }
        }
    }

    fn events(&mut self) -> Vec<crate::browser_runtime::SurfaceEvent> {
        self.inner.events()
    }

    fn close(&mut self, surface_id: SurfaceId) -> Result<(), RuntimeError> {
        let result = self.inner.close(surface_id);
        if result.is_ok() {
            let _ = self.lifecycle.remove_surface(surface_id);
        }
        result
    }
}

fn prune(values: &mut VecDeque<u64>, now_ms: u64) {
    while values
        .front()
        .is_some_and(|timestamp| now_ms.saturating_sub(*timestamp) >= RESTART_WINDOW_MS)
    {
        values.pop_front();
    }
}

/// The cutover deleted validation-only fault injection: there is no
/// `--cef-validation` switch, no `--cef-fault` point, and no `FaultPoint`
/// type. Recovery is driven only by real host, renderer, GPU, utility, and
/// profile observations through [`RuntimeLifecycle`]; production binaries
/// cannot select a fault path.

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_runtime::{
        NavigationDisposition, NavigationRequest, PresentationMode, PrivacyMode, ProfileKey,
        SurfacePolicy,
    };

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
    fn heartbeat_timeout_uses_bounded_backoff_and_distinct_epoch() {
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        lifecycle.register_surface(SurfaceId(1), spec()).unwrap();
        let events = lifecycle.tick(2_000);
        assert!(matches!(
            events.first().map(|event| &event.kind),
            Some(RuntimeEventKind::HeartbeatSent { .. })
        ));
        let timeout = lifecycle.tick(10_000);
        assert!(timeout.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::Failure { failure }
                    if failure.class == FailureClass::HostUnresponsive
            )
        }));
        assert_eq!(lifecycle.state(), RuntimeState::Restarting);
        assert_eq!(lifecycle.restart_due_ms(), Some(15_250));
        let old_epoch = lifecycle.runtime_epoch();
        assert!(lifecycle.start(15_250).is_ok());
        assert_eq!(lifecycle.runtime_epoch(), old_epoch + 1);
    }

    #[test]
    fn command_outcomes_are_failed_or_unknown_and_never_replayed() {
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        lifecycle.register_surface(SurfaceId(1), spec()).unwrap();
        let unacknowledged = lifecycle.begin_command(SurfaceId(1), true).unwrap();
        let acknowledged = lifecycle.begin_command(SurfaceId(1), true).unwrap();
        lifecycle
            .acknowledge_command(acknowledged.command_id)
            .unwrap();
        let outcomes = lifecycle.host_lost(1, "host exited");
        assert!(outcomes.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::CommandOutcome {
                    command_id,
                    outcome: CommandOutcome::Failed,
                    reason: CommandOutcomeReason::RuntimeLost,
                    ..
                } if *command_id == unacknowledged.command_id
            )
        }));
        assert!(outcomes.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::CommandOutcome {
                    command_id,
                    outcome: CommandOutcome::Unknown,
                    reason: CommandOutcomeReason::RuntimeLost,
                    ..
                } if *command_id == acknowledged.command_id
            )
        }));
        assert!(!lifecycle.should_replay_command(acknowledged.command_id));
    }

    #[test]
    fn renderer_and_gpu_failures_are_scoped_without_host_restart() {
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        lifecycle.register_surface(SurfaceId(1), spec()).unwrap();
        let events = lifecycle.report_failure(
            FailureClass::RendererCrash,
            Some("TS_PROCESS_CRASHED".to_owned()),
            "renderer exited",
            1,
        );
        assert!(events.iter().any(|event| {
            matches!(event.kind, RuntimeEventKind::SurfaceRecovering)
                && event.surface_id == Some(SurfaceId(1))
        }));
        assert_eq!(lifecycle.state(), RuntimeState::Ready);
        let events = lifecycle.report_failure(FailureClass::GpuCrash, None, "gpu exited", 2);
        assert!(events.iter().any(|event| matches!(
            event.kind,
            RuntimeEventKind::StateChanged {
                state: RuntimeState::Degraded
            }
        )));
        let events = lifecycle.report_failure(FailureClass::GpuCrash, None, "gpu exited again", 3);
        assert!(lifecycle.gpu_disabled());
        assert!(events.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::Failure { failure }
                    if failure.class == FailureClass::GpuDisabled
            )
        }));
    }

    #[test]
    fn clean_shutdown_does_not_schedule_recovery() {
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        lifecycle.begin_shutdown();
        let events = lifecycle.report_failure(FailureClass::HostCrash, None, "eof", 1);
        assert!(events.iter().any(|event| {
            matches!(
                &event.kind,
                RuntimeEventKind::Failure { failure }
                    if failure.class == FailureClass::CleanStop
            )
        }));
        assert!(!events.iter().any(|event| {
            matches!(
                event.kind,
                RuntimeEventKind::StateChanged {
                    state: RuntimeState::Restarting
                }
            )
        }));
        assert_eq!(lifecycle.state(), RuntimeState::Stopping);
        lifecycle.finish_shutdown(true);
        assert_eq!(lifecycle.state(), RuntimeState::Stopped);
    }

    #[test]
    fn failure_messages_redact_urls_paths_and_secrets() {
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        let events = lifecycle.report_failure(
            FailureClass::HostCrash,
            Some("exit /private/profile".to_owned()),
            "https://widget.test/page C:\\private\\profile token=abc",
            1,
        );
        let RuntimeEventKind::Failure { failure } = &events[0].kind else {
            panic!("expected failure event");
        };
        assert!(!failure.message.contains("https://"));
        assert!(!failure.message.contains("private"));
        assert!(!failure.message.contains("abc"));
        assert!(!failure.raw_status.as_deref().unwrap().contains("private"));
    }

    #[test]
    fn validation_and_fault_injection_controls_are_gone() {
        // The cutover removed the validation switch and fault injection:
        // recovery is driven only by real host observations, so there is no
        // fault-point vocabulary left to parse. This test pins the deletion
        // by asserting the lifecycle still classifies a real host crash
        // without any injection hook.
        let mut lifecycle = RuntimeLifecycle::new();
        lifecycle.start(0).unwrap();
        lifecycle.host_ready(0).unwrap();
        let events = lifecycle.report_failure(
            FailureClass::HostCrash,
            None,
            "real host exit".to_owned(),
            1,
        );
        assert!(matches!(events[0].kind, RuntimeEventKind::Failure { .. }));
    }
}
