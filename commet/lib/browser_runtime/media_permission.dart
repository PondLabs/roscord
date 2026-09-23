import 'browser_runtime.dart';

/// Mediated camera, microphone, and screen-capture permissions.
///
/// This library mirrors the Rust `browser_media` decision table for fixtures
/// and adapter tests.  Media and capture access is deny-by-default and fails
/// closed through OS/portal mediation:
///
/// - Camera/microphone decisions support deny, once/session, and explicitly
///   scoped persistent grants keyed by account profile, requesting origin,
///   top-level origin, and capability.
/// - A stored grant is honored only while the surface's current policy still
///   declares both origins, the capability stays enabled, and the OS-level
///   mediation check still passes.
/// - Display capture never receives a persistent grant; every display-capture
///   request needs fresh source consent.
/// - Portal denial, dismissal, timeout, disconnect, and unsupported
///   capability all deny the page plus a sanitized failure event.

/// Canonical wire names for mediated media capabilities.
abstract final class MediaCapabilityName {
  static const String camera = 'camera';
  static const String microphone = 'microphone';
  static const String cameraMicrophone = 'camera+microphone';
  static const String displayVideo = 'display_video';
  static const String displayAudio = 'display_audio';
  static const String displayVideoAudio = 'display_video+display_audio';
}

enum MediaCapability {
  camera,
  microphone,
  cameraAndMicrophone,
  displayVideo,
  displayAudio,
  displayVideoAndAudio,
  unknown;

  /// Classify a wire capability string.  Matching is exact and
  /// case-sensitive so a near-miss capability cannot inherit a grant.
  static MediaCapability classify(String capability) {
    return switch (capability) {
      MediaCapabilityName.camera => MediaCapability.camera,
      MediaCapabilityName.microphone => MediaCapability.microphone,
      MediaCapabilityName.cameraMicrophone =>
        MediaCapability.cameraAndMicrophone,
      MediaCapabilityName.displayVideo => MediaCapability.displayVideo,
      MediaCapabilityName.displayAudio => MediaCapability.displayAudio,
      MediaCapabilityName.displayVideoAudio =>
        MediaCapability.displayVideoAndAudio,
      _ => MediaCapability.unknown,
    };
  }

  String get wireName => switch (this) {
        MediaCapability.camera => MediaCapabilityName.camera,
        MediaCapability.microphone => MediaCapabilityName.microphone,
        MediaCapability.cameraAndMicrophone =>
          MediaCapabilityName.cameraMicrophone,
        MediaCapability.displayVideo => MediaCapabilityName.displayVideo,
        MediaCapability.displayAudio => MediaCapabilityName.displayAudio,
        MediaCapability.displayVideoAndAudio =>
          MediaCapabilityName.displayVideoAudio,
        MediaCapability.unknown => 'unknown_media',
      };

  /// Display (screen/window) capture always needs fresh source consent, so
  /// it is never satisfied by a stored grant of any kind.
  bool get isDisplay => switch (this) {
        MediaCapability.displayVideo ||
        MediaCapability.displayAudio ||
        MediaCapability.displayVideoAndAudio =>
          true,
        _ => false,
      };

  /// Only classified camera/microphone capabilities can hold a persistent
  /// grant.  Display capture and unknown capabilities cannot.
  bool get supportsPersistentGrant => switch (this) {
        MediaCapability.camera ||
        MediaCapability.microphone ||
        MediaCapability.cameraAndMicrophone =>
          true,
        _ => false,
      };
}

/// The scope of one stored media grant: account, requesting origin,
/// top-level origin, and capability.  A grant never crosses any of these
/// boundaries.
class MediaGrantScope {
  final String profileKey;
  final String requestingOrigin;
  final String topLevelOrigin;
  final MediaCapability capability;

  MediaGrantScope({
    required ProfileKey profileKey,
    required String requestingOrigin,
    required String topLevelOrigin,
    required this.capability,
  })  : profileKey = profileKey.value,
        requestingOrigin = _validateScopeOrigin(requestingOrigin),
        topLevelOrigin = _validateScopeOrigin(topLevelOrigin) {
    if (capability == MediaCapability.unknown) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'media capability is not grantable',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MediaGrantScope &&
      other.profileKey == profileKey &&
      other.requestingOrigin == requestingOrigin &&
      other.topLevelOrigin == topLevelOrigin &&
      other.capability == capability;

  @override
  int get hashCode =>
      Object.hash(profileKey, requestingOrigin, topLevelOrigin, capability);
}

String _validateScopeOrigin(String origin) {
  if (origin.isEmpty ||
      origin.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
      origin.contains(RegExp(r'\s')) ||
      !origin.contains('://')) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'media grant origin is invalid',
    );
  }
  return origin;
}

enum _StoredGrant { session, persistent }

/// In-memory media grant store owned by the host process.
///
/// Session grants evaporate on [clearSession] (host restart and recovery).
/// Persistent grants survive surface close but are dropped by [clearProfile]
/// (clear-data).  Private surfaces never receive persistent storage: an
/// `allowAlways` decision there is kept as a session grant only.
class MediaGrantStore {
  final Map<MediaGrantScope, _StoredGrant> _grants = {};

  /// Record an app decision for [scope].
  ///
  /// Returns true when a grant was stored for later requests and false when
  /// the decision applies to the pending request only (`deny`, `allowOnce`,
  /// display-capture `allowAlways`, or an explicit deny that also revokes
  /// any stored grant for the scope).
  bool remember(
    MediaGrantScope scope,
    PermissionDecision decision, {
    required bool privateContext,
  }) {
    switch (decision) {
      case PermissionDecision.deny:
        _grants.remove(scope);
        return false;
      case PermissionDecision.allowOnce:
        return false;
      case PermissionDecision.allowSession:
        _grants[scope] = _StoredGrant.session;
        return true;
      case PermissionDecision.allowAlways:
        if (!scope.capability.supportsPersistentGrant) {
          // Display capture always needs fresh consent.
          return false;
        }
        _grants[scope] =
            privateContext ? _StoredGrant.session : _StoredGrant.persistent;
        return true;
    }
  }

  /// Returns true when a stored grant covers [scope] for one more use.
  ///
  /// Every use re-checks the surface's current policy ([policyOrigins] must
  /// still declare both the requesting and the top-level origin and
  /// [capabilityAllowed] must still hold) and the OS-level mediation result
  /// ([osMediated]).  Display capture always returns false.
  bool takeGrant(
    MediaGrantScope scope, {
    required List<String> policyOrigins,
    required bool capabilityAllowed,
    required bool osMediated,
    required bool privateContext,
  }) {
    if (scope.capability.isDisplay || !capabilityAllowed || !osMediated) {
      return false;
    }
    final stored = _grants[scope];
    if (stored == null) return false;
    if (privateContext && stored == _StoredGrant.persistent) return false;
    return policyOrigins.contains(scope.requestingOrigin) &&
        policyOrigins.contains(scope.topLevelOrigin);
  }

  /// Drop every session grant.  Called on host restart and recovery.
  void clearSession() {
    _grants.removeWhere((_, stored) => stored == _StoredGrant.session);
  }

  /// Drop every grant (session and persistent) for one account.  Called as
  /// part of clear-data after all of the account's surfaces are quiescent.
  void clearProfile(ProfileKey profileKey) {
    _grants.removeWhere((scope, _) => scope.profileKey == profileKey.value);
  }

  int get length => _grants.length;
}

/// Outcome of the OS-level capture mediation for one request.
///
/// On Windows this is the result of the qualified OS media path behind
/// `OnRequestMediaAccessPermission`.  On Linux and Flatpak it is the result
/// of the qualified XDG ScreenCast/PipeWire portal dialog.  Only [granted]
/// continues the page request; every other outcome denies the page and
/// additionally emits a sanitized `capture_denied` failure.
enum CapturePortalOutcome {
  granted,
  denied,
  dismissed,
  timedOut,
  disconnected,
  unsupported;

  static CapturePortalOutcome? parse(String name) {
    return switch (name) {
      'granted' => CapturePortalOutcome.granted,
      'denied' => CapturePortalOutcome.denied,
      'dismissed' => CapturePortalOutcome.dismissed,
      'timeout' => CapturePortalOutcome.timedOut,
      'disconnect' => CapturePortalOutcome.disconnected,
      'unsupported' => CapturePortalOutcome.unsupported,
      _ => null,
    };
  }

  String get wireName => switch (this) {
        CapturePortalOutcome.granted => 'granted',
        CapturePortalOutcome.denied => 'denied',
        CapturePortalOutcome.dismissed => 'dismissed',
        CapturePortalOutcome.timedOut => 'timeout',
        CapturePortalOutcome.disconnected => 'disconnect',
        CapturePortalOutcome.unsupported => 'unsupported',
      };

  /// Every outcome except an explicit grant denies the page request.
  bool get deniesPage => this != CapturePortalOutcome.granted;

  /// Fixed sanitized message for the `capture_denied` failure event.  The
  /// message never carries origins, paths, tokens, or page contents.
  String get sanitizedMessage => switch (this) {
        CapturePortalOutcome.granted => 'system capture granted the request',
        CapturePortalOutcome.denied =>
          'system capture dialog denied the request',
        CapturePortalOutcome.dismissed => 'system capture dialog was dismissed',
        CapturePortalOutcome.timedOut => 'system capture dialog timed out',
        CapturePortalOutcome.disconnected =>
          'system capture service disconnected during the request',
        CapturePortalOutcome.unsupported =>
          'system capture is not supported for this capability',
      };
}

/// Fixed sanitized message for the `permission_denied` failure event.  The
/// message never carries origins, paths, tokens, or page contents.
String sanitizedPermissionDeniedMessage(MediaCapability capability) {
  if (capability.isDisplay) {
    return 'display capture was denied; each request needs fresh consent';
  }
  if (capability == MediaCapability.unknown) {
    return 'media access was denied by policy';
  }
  return 'camera or microphone access was denied by policy';
}

/// One page-originated media request awaiting mediation.
class PendingPermissionRequest {
  final SurfaceId surfaceId;

  /// Null for unclassifiable capabilities.  Such requests can only be
  /// denied; they never read or write the grant store.
  final MediaGrantScope? scope;
  final CapturePortalOutcome? portal;

  const PendingPermissionRequest({
    required this.surfaceId,
    required this.scope,
    this.portal,
  });

  PendingPermissionRequest withPortal(CapturePortalOutcome outcome) {
    return PendingPermissionRequest(
      surfaceId: surfaceId,
      scope: scope,
      portal: outcome,
    );
  }
}

/// Current-policy view the host assembles from the requesting surface for
/// one grant decision or lookup.
class MediaPolicyView {
  /// Exact declared origins (allowed plus loopback) of the current policy.
  final List<String> origins;

  /// Whether the capability is still enabled by current policy.
  final bool capabilityAllowed;

  /// Private surfaces never read or write persistent grants.
  final bool privateContext;

  /// The OS-level mediation check for this use.
  final bool osMediated;

  const MediaPolicyView({
    required this.origins,
    required this.capabilityAllowed,
    required this.privateContext,
    required this.osMediated,
  });
}

/// Outcome of resolving one app decision for a pending request.
class PermissionResolution {
  final SurfaceId surfaceId;

  /// Whether the page request may proceed exactly once.
  final bool grantedOnce;

  /// Whether a grant was stored for later requests in the scope.
  final bool stored;

  /// Sanitized failure to report when the page is denied.
  final SurfaceFailure? failure;

  const PermissionResolution({
    required this.surfaceId,
    required this.grantedOnce,
    required this.stored,
    required this.failure,
  });
}

/// Host-side media permission state machine.
///
/// The registry is deny-by-default: a request the registry never saw, a
/// request for an unknown capability, and any use whose current-policy or
/// OS check fails all resolve to page denial.  Pending requests are dropped
/// when their surface closes, so a late app decision can never grant a dead
/// surface.
class HostPermissionRegistry {
  final Map<String, PendingPermissionRequest> _pending = {};
  final MediaGrantStore _grants = MediaGrantStore();

  /// When true (Linux/Flatpak), display-capture decisions additionally
  /// require a prior XDG portal grant recorded via [reportPortalOutcome].
  /// When false (Windows), the qualified OS media path mediates
  /// synchronously inside the permission callback.
  final bool portalMediationRequired;

  HostPermissionRegistry({required this.portalMediationRequired});

  /// Record a page-originated request and return the classified capability.
  /// Duplicate request ids are rejected so a replayed event can never
  /// double-register a request.
  MediaCapability register({
    required SurfaceId surfaceId,
    required ProfileKey profileKey,
    required String requestId,
    required String requestingOrigin,
    required String topLevelOrigin,
    required String capabilityName,
  }) {
    if (requestId.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'permission request id must not be empty',
      );
    }
    if (_pending.containsKey(requestId)) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'permission request id is already pending',
      );
    }
    final capability = MediaCapability.classify(capabilityName);
    MediaGrantScope? scope;
    try {
      scope = MediaGrantScope(
        profileKey: profileKey,
        requestingOrigin: requestingOrigin,
        topLevelOrigin: topLevelOrigin,
        capability: capability,
      );
    } on BrowserRuntimeException {
      scope = null;
    }
    _pending[requestId] = PendingPermissionRequest(
      surfaceId: surfaceId,
      scope: scope,
    );
    return capability;
  }

  /// Fast path for the CEF callback: returns true when a stored grant
  /// covers this exact scope under the surface's current policy and OS
  /// mediation, without asking the app again.  Display capture always
  /// returns false.  Only a registered request can be auto-covered.
  bool storedGrantCovers({
    required SurfaceId surfaceId,
    required ProfileKey profileKey,
    required String requestingOrigin,
    required String topLevelOrigin,
    required String capabilityName,
    required MediaPolicyView policy,
  }) {
    final capability = MediaCapability.classify(capabilityName);
    if (capability == MediaCapability.unknown || capability.isDisplay) {
      return false;
    }
    late final MediaGrantScope scope;
    try {
      scope = MediaGrantScope(
        profileKey: profileKey,
        requestingOrigin: requestingOrigin,
        topLevelOrigin: topLevelOrigin,
        capability: capability,
      );
    } on BrowserRuntimeException {
      return false;
    }
    final registered = _pending.values.any(
      (pending) => pending.surfaceId == surfaceId && pending.scope == scope,
    );
    if (!registered) return false;
    return _grants.takeGrant(
      scope,
      policyOrigins: policy.origins,
      capabilityAllowed: policy.capabilityAllowed,
      osMediated: policy.osMediated,
      privateContext: policy.privateContext,
    );
  }

  /// Record the OS portal outcome for a pending display request.  A
  /// non-grant outcome denies the page and returns the sanitized
  /// `capture_denied` failure; the caller must additionally cancel the page
  /// callback.  The pending request is consumed in every non-grant case.
  (SurfaceId, SurfaceFailure?) reportPortalOutcome(
    String requestId,
    CapturePortalOutcome outcome,
  ) {
    final pending = _pending[requestId];
    if (pending == null) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'unknown permission request',
      );
    }
    if (outcome == CapturePortalOutcome.granted) {
      _pending[requestId] = pending.withPortal(outcome);
      return (pending.surfaceId, null);
    }
    _pending.remove(requestId);
    return (
      pending.surfaceId,
      SurfaceFailure(
        FailureKind.captureDenied,
        outcome.sanitizedMessage,
      ),
    );
  }

  /// Resolve one app decision for a pending request.  Unknown request ids
  /// are rejected; unknown capabilities, failed policy/OS checks, and a
  /// missing portal grant (where portal mediation is required) all deny the
  /// page with a sanitized failure.
  PermissionResolution resolve(
    String requestId,
    PermissionDecision decision,
    MediaPolicyView policy,
  ) {
    final pending = _pending.remove(requestId);
    if (pending == null) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'unknown permission request',
      );
    }
    SurfaceFailure deny(MediaCapability capability) => SurfaceFailure(
          FailureKind.permissionDenied,
          sanitizedPermissionDeniedMessage(capability),
        );
    final scope = pending.scope;
    if (scope == null) {
      return PermissionResolution(
        surfaceId: pending.surfaceId,
        grantedOnce: false,
        stored: false,
        failure: deny(MediaCapability.unknown),
      );
    }
    final capability = scope.capability;
    if (decision == PermissionDecision.deny) {
      _grants.remember(
        scope,
        PermissionDecision.deny,
        privateContext: policy.privateContext,
      );
      return PermissionResolution(
        surfaceId: pending.surfaceId,
        grantedOnce: false,
        stored: false,
        failure: deny(capability),
      );
    }
    if (capability.isDisplay &&
        portalMediationRequired &&
        pending.portal != CapturePortalOutcome.granted) {
      return PermissionResolution(
        surfaceId: pending.surfaceId,
        grantedOnce: false,
        stored: false,
        failure: SurfaceFailure(
          FailureKind.captureDenied,
          CapturePortalOutcome.disconnected.sanitizedMessage,
        ),
      );
    }
    if (!policy.capabilityAllowed ||
        !policy.osMediated ||
        !policy.origins.contains(scope.requestingOrigin) ||
        !policy.origins.contains(scope.topLevelOrigin)) {
      return PermissionResolution(
        surfaceId: pending.surfaceId,
        grantedOnce: false,
        stored: false,
        failure: deny(capability),
      );
    }
    // Display allowAlways degrades to once: the pending request may
    // proceed, but nothing is stored for the next request.
    final effective =
        capability.isDisplay && decision == PermissionDecision.allowAlways
            ? PermissionDecision.allowOnce
            : decision;
    final stored = _grants.remember(
      scope,
      effective,
      privateContext: policy.privateContext,
    );
    return PermissionResolution(
      surfaceId: pending.surfaceId,
      grantedOnce: true,
      stored: stored,
      failure: null,
    );
  }

  /// Drop all pending requests for one surface.  Called when the surface
  /// closes so a late decision can never grant a dead surface.
  void removeSurface(SurfaceId surfaceId) {
    _pending.removeWhere((_, pending) => pending.surfaceId == surfaceId);
  }

  /// Drop session grants (host restart and recovery).
  void clearSession() => _grants.clearSession();

  /// Drop every grant for one account (clear-data).
  void clearProfile(ProfileKey profileKey) => _grants.clearProfile(profileKey);

  /// Inspect one pending request without consuming it.
  PendingPermissionRequest? pending(String requestId) => _pending[requestId];

  int get pendingCount => _pending.length;
}
