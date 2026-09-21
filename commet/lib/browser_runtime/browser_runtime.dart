import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

const int browserRuntimeProtocolVersion = 1;
const int defaultBrowserRuntimeMaxFrameBytes = 1024 * 1024;

typedef JsonValue = Object?;

enum BrowserRuntimeErrorCode {
  invalidSpec,
  invalidCommand,
  unknownSurface,
  staleSurface,
  sequenceViolation,
  profileMismatch,
  profileBusy,
  profileCorrupt,
  profileUnavailable,
  migrationFailed,
  certificateDenied,
  clientCertificateDenied,
  policyViolation,
  protocol,
}

class BrowserRuntimeException implements Exception {
  final BrowserRuntimeErrorCode code;
  final String message;
  final int? expectedAfter;
  final int? received;

  const BrowserRuntimeException(
    this.code,
    this.message, {
    this.expectedAfter,
    this.received,
  });

  @override
  String toString() => 'BrowserRuntimeException($code): $message';
}

class ProtocolException implements Exception {
  final String code;
  final String message;
  final int? size;
  final int? max;

  const ProtocolException(this.code, this.message, {this.size, this.max});

  @override
  String toString() => 'ProtocolException($code): $message';
}

class ProfileKey {
  /// The stable local account-record identity (the Matrix client's
  /// `MatrixClient.identifier`). Callers must not substitute a Matrix user
  /// id, homeserver URL, display name, or a URL-derived path.
  final String value;

  ProfileKey(String value) : value = _validateProfileKey(value);

  static String _validateProfileKey(String value) {
    if (value.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'profile key is empty',
      );
    }
    if (utf8.encode(value).length > 256) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'profile key is too long',
      );
    }
    if (value.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
        value.contains('/') ||
        value.contains(r'\')) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'profile key contains a forbidden character',
      );
    }
    return value;
  }

  @override
  bool operator ==(Object other) => other is ProfileKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

enum PresentationMode { embedded, standalone }

enum PrivacyMode { persistent, privateContext }

enum NavigationDisposition { current, newSurface, external }

class NavigationRequest {
  final String url;
  final NavigationDisposition disposition;
  final bool userInitiated;

  NavigationRequest({
    required String url,
    this.disposition = NavigationDisposition.current,
    this.userInitiated = false,
  }) : url = _validateUrl(url);

  Map<String, Object?> toJson() => {
        'url': url,
        'disposition': _navigationDispositionToWire(disposition),
        'user_initiated': userInitiated,
      };

  factory NavigationRequest.fromJson(Map<String, dynamic> json) {
    return NavigationRequest(
      url: _requiredString(json, 'url'),
      disposition: _navigationDispositionFromWire(
        _requiredString(json, 'disposition'),
      ),
      userInitiated: _requiredBool(json, 'user_initiated'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NavigationRequest &&
      other.url == url &&
      other.disposition == disposition &&
      other.userInitiated == userInitiated;

  @override
  int get hashCode => Object.hash(url, disposition, userInitiated);
}

class SurfacePolicy {
  final List<String> allowedOrigins;
  final List<String> allowedLoopbackOrigins;
  final bool allowExternalNavigation;
  final Map<String, bool> capabilities;

  SurfacePolicy({
    Iterable<String> allowedOrigins = const [],
    Iterable<String> allowedLoopbackOrigins = const [],
    this.allowExternalNavigation = false,
    Map<String, bool> capabilities = const {},
  })  : allowedOrigins = List.unmodifiable(allowedOrigins),
        allowedLoopbackOrigins = List.unmodifiable(allowedLoopbackOrigins),
        capabilities = Map.unmodifiable(capabilities) {
    for (final origin in this.allowedOrigins) {
      _validateDeclaredOrigin(origin, loopback: false);
    }
    for (final origin in this.allowedLoopbackOrigins) {
      _validateDeclaredOrigin(origin, loopback: true);
    }
    if (this.capabilities.keys.any(
          (capability) =>
              capability.isEmpty || capability.runes.any((rune) => rune < 0x20),
        )) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'policy contains an invalid capability',
      );
    }
  }

  const SurfacePolicy._empty()
      : allowedOrigins = const [],
        allowedLoopbackOrigins = const [],
        allowExternalNavigation = false,
        capabilities = const {};

  Map<String, Object?> toJson() => {
        'allowed_origins': allowedOrigins,
        'allowed_loopback_origins': allowedLoopbackOrigins,
        'allow_external_navigation': allowExternalNavigation,
        'capabilities': capabilities,
      };

  factory SurfacePolicy.fromJson(Map<String, dynamic> json) {
    final origins = (json['allowed_origins'] as List<dynamic>? ?? const []).map(
      (value) => value as String,
    );
    final loopbackOrigins =
        (json['allowed_loopback_origins'] as List<dynamic>? ?? const []).map(
      (value) => value as String,
    );
    final capabilities = Map<String, bool>.from(
      (json['capabilities'] as Map<dynamic, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key as String, value as bool),
      ),
    );
    return SurfacePolicy(
      allowedOrigins: origins,
      allowedLoopbackOrigins: loopbackOrigins,
      allowExternalNavigation:
          json['allow_external_navigation'] as bool? ?? false,
      capabilities: capabilities,
    );
  }

  bool allowsUrl(String url) {
    final origin = _urlOrigin(url);
    if (_isControlledFixture(url)) return true;
    return origin != null &&
        [...allowedOrigins, ...allowedLoopbackOrigins].contains(origin);
  }

  NavigationPolicyDecision navigationDecision(NavigationRequest navigation) {
    if (navigation.disposition == NavigationDisposition.external) {
      return navigation.userInitiated && allowExternalNavigation
          ? NavigationPolicyDecision.external
          : NavigationPolicyDecision.blocked;
    }
    if (allowsUrl(navigation.url)) return NavigationPolicyDecision.inProcess;
    return navigation.userInitiated && allowExternalNavigation
        ? NavigationPolicyDecision.external
        : NavigationPolicyDecision.blocked;
  }
}

enum NavigationPolicyDecision { inProcess, external, blocked }

class SurfaceSpec {
  final ProfileKey profileKey;
  final PresentationMode presentation;
  final PrivacyMode privacy;
  final NavigationRequest initialNavigation;
  final SurfacePolicy policy;

  SurfaceSpec({
    required this.profileKey,
    required this.presentation,
    required this.privacy,
    required this.initialNavigation,
    this.policy = const SurfacePolicy._empty(),
  }) {
    if (policy.navigationDecision(initialNavigation) !=
        NavigationPolicyDecision.inProcess) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'initial navigation is outside the declared policy',
      );
    }
  }

  Map<String, Object?> toJson() => {
        'profile_key': profileKey.value,
        'presentation': presentation.name,
        'privacy': _privacyToWire(privacy),
        'initial_navigation': initialNavigation.toJson(),
        'policy': policy.toJson(),
      };

  factory SurfaceSpec.fromJson(Map<String, dynamic> json) {
    return SurfaceSpec(
      profileKey: ProfileKey(_requiredString(json, 'profile_key')),
      presentation: _enumValue(
        PresentationMode.values,
        _requiredString(json, 'presentation'),
      ),
      privacy: _privacyFromWire(_requiredString(json, 'privacy')),
      initialNavigation: NavigationRequest.fromJson(
        _requiredMap(json, 'initial_navigation'),
      ),
      policy: SurfacePolicy.fromJson(_requiredMap(json, 'policy')),
    );
  }
}

enum ScriptSource { page, app, host }

class BrowserRuntimeBlob {
  final Uint8List bytes;

  BrowserRuntimeBlob(Uint8List bytes)
      : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
}

class ScriptEnvelope {
  final ScriptSource source;
  final String origin;
  final String channel;
  final String requestId;
  final JsonValue value;

  ScriptEnvelope({
    required this.source,
    required this.origin,
    required this.channel,
    required this.requestId,
    required JsonValue value,
  }) : value = _validateAndCopyJson(value) {
    if (origin.isEmpty || channel.isEmpty || requestId.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'script envelope metadata must not be empty',
      );
    }
  }

  Map<String, Object?> toJson() => {
        'source': source.name,
        'origin': origin,
        'channel': channel,
        'request_id': requestId,
        'value': _encodeJsonValue(value),
      };

  factory ScriptEnvelope.fromJson(Map<String, dynamic> json) {
    return ScriptEnvelope(
      source: _enumValue(ScriptSource.values, _requiredString(json, 'source')),
      origin: _requiredString(json, 'origin'),
      channel: _requiredString(json, 'channel'),
      requestId: _requiredString(json, 'request_id'),
      value: _decodeJsonValue(_requiredValue(json, 'value')),
    );
  }
}

enum PointerKind { down, up, move, enter, leave, wheel }

enum ImePhase { start, update, commit, cancel }

sealed class InputEvent {
  const InputEvent();

  factory InputEvent.pointer({
    required PointerKind kind,
    required double x,
    required double y,
    int buttons = 0,
    double deltaX = 0,
    double deltaY = 0,
  }) =>
      PointerInput(
        kind: kind,
        x: x,
        y: y,
        buttons: buttons,
        deltaX: deltaX,
        deltaY: deltaY,
      );

  factory InputEvent.keyboard({
    required String key,
    required String code,
    int modifiers = 0,
    required bool pressed,
  }) =>
      KeyboardInput(
        key: key,
        code: code,
        modifiers: modifiers,
        pressed: pressed,
      );

  factory InputEvent.ime({
    required ImePhase phase,
    required String text,
    int selectionStart = 0,
    int selectionEnd = 0,
  }) =>
      ImeInput(
        phase: phase,
        text: text,
        selectionStart: selectionStart,
        selectionEnd: selectionEnd,
      );

  Map<String, Object?> toJson();

  factory InputEvent.fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    final payload = _requiredMap(json, 'payload');
    return switch (type) {
      'pointer' => PointerInput(
          kind:
              _enumValue(PointerKind.values, _requiredString(payload, 'kind')),
          x: _requiredDouble(payload, 'x'),
          y: _requiredDouble(payload, 'y'),
          buttons: _optionalInt(payload, 'buttons') ?? 0,
          deltaX: _optionalDouble(payload, 'delta_x') ?? 0,
          deltaY: _optionalDouble(payload, 'delta_y') ?? 0,
        ),
      'keyboard' => KeyboardInput(
          key: _requiredString(payload, 'key'),
          code: _requiredString(payload, 'code'),
          modifiers: _optionalInt(payload, 'modifiers') ?? 0,
          pressed: _requiredBool(payload, 'pressed'),
        ),
      'ime' => ImeInput(
          phase: _enumValue(ImePhase.values, _requiredString(payload, 'phase')),
          text: _requiredString(payload, 'text'),
          selectionStart: _optionalInt(payload, 'selection_start') ?? 0,
          selectionEnd: _optionalInt(payload, 'selection_end') ?? 0,
        ),
      _ => throw ProtocolException(
          'unknown_input_type',
          'unknown input event type $type',
        ),
    };
  }
}

class PointerInput extends InputEvent {
  final PointerKind kind;
  final double x;
  final double y;
  final int buttons;
  final double deltaX;
  final double deltaY;

  PointerInput({
    required this.kind,
    required this.x,
    required this.y,
    this.buttons = 0,
    this.deltaX = 0,
    this.deltaY = 0,
  }) {
    if (![x, y, deltaX, deltaY].every((value) => value.isFinite)) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'pointer coordinates must be finite',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'pointer',
        'payload': {
          'kind': kind.name,
          'x': x,
          'y': y,
          'buttons': buttons,
          'delta_x': deltaX,
          'delta_y': deltaY,
        },
      };
}

class KeyboardInput extends InputEvent {
  final String key;
  final String code;
  final int modifiers;
  final bool pressed;

  KeyboardInput({
    required this.key,
    required this.code,
    this.modifiers = 0,
    required this.pressed,
  }) {
    if (key.isEmpty || code.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'keyboard key and code must not be empty',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'keyboard',
        'payload': {
          'key': key,
          'code': code,
          'modifiers': modifiers,
          'pressed': pressed,
        },
      };
}

class ImeInput extends InputEvent {
  final ImePhase phase;
  final String text;
  final int selectionStart;
  final int selectionEnd;

  ImeInput({
    required this.phase,
    required this.text,
    this.selectionStart = 0,
    this.selectionEnd = 0,
  }) {
    if (selectionStart > selectionEnd) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'IME selection is inverted',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'ime',
        'payload': {
          'phase': phase.name,
          'text': text,
          'selection_start': selectionStart,
          'selection_end': selectionEnd,
        },
      };
}

enum PermissionDecision { deny, allowOnce, allowSession, allowAlways }

enum PopupAction { deny, openOwned, openExternal, close }

sealed class DownloadDecision {
  const DownloadDecision();

  Map<String, Object?> toJson();
}

class DenyDownload extends DownloadDecision {
  const DenyDownload();

  @override
  Map<String, Object?> toJson() => {'kind': 'deny'};
}

class CancelDownload extends DownloadDecision {
  const CancelDownload();

  @override
  Map<String, Object?> toJson() => {'kind': 'cancel'};
}

class AcceptDownload extends DownloadDecision {
  final String destination;

  const AcceptDownload(this.destination);

  @override
  Map<String, Object?> toJson() => {
        'kind': 'accept',
        'value': {'destination': destination},
      };
}

DownloadDecision _downloadDecisionFromJson(Map<String, dynamic> json) {
  return switch (_requiredString(json, 'kind')) {
    'deny' => const DenyDownload(),
    'cancel' => const CancelDownload(),
    'accept' => AcceptDownload(
        _requiredString(_requiredMap(json, 'value'), 'destination'),
      ),
    final value => throw ProtocolException(
        'unknown_download_decision',
        'unknown download decision $value',
      ),
  };
}

enum ClipboardDecision { deny, allow, cancel }

/// Upload handoff decision.  `AcceptUpload` means "show the OS/portal
/// chooser"; the host stages the user's explicit selection as read-only
/// copies and never reveals the real filesystem paths to the page.  There
/// is intentionally no destination or path field: uploads never grant the
/// page a persistent path or directory enumeration.
sealed class UploadDecision {
  const UploadDecision();

  Map<String, Object?> toJson();
}

class DenyUpload extends UploadDecision {
  const DenyUpload();

  @override
  Map<String, Object?> toJson() => {'kind': 'deny'};
}

class CancelUpload extends UploadDecision {
  const CancelUpload();

  @override
  Map<String, Object?> toJson() => {'kind': 'cancel'};
}

class AcceptUpload extends UploadDecision {
  const AcceptUpload();

  @override
  Map<String, Object?> toJson() => {'kind': 'accept'};
}

UploadDecision _uploadDecisionFromJson(Map<String, dynamic> json) {
  return switch (_requiredString(json, 'kind')) {
    'deny' => const DenyUpload(),
    'cancel' => const CancelUpload(),
    'accept' => const AcceptUpload(),
    final value => throw ProtocolException(
        'unknown_upload_decision',
        'unknown upload decision $value',
      ),
  };
}

sealed class SurfaceCommand {
  final int sequence;
  final ProfileKey? profileKey;

  const SurfaceCommand(this.sequence, this.profileKey);

  factory SurfaceCommand.navigate({
    required int sequence,
    ProfileKey? profileKey,
    required NavigationRequest navigation,
  }) = NavigateCommand;

  factory SurfaceCommand.input({
    required int sequence,
    ProfileKey? profileKey,
    required InputEvent input,
  }) = InputCommand;

  factory SurfaceCommand.resize({
    required int sequence,
    ProfileKey? profileKey,
    required int width,
    required int height,
    required double deviceScaleFactor,
  }) = ResizeCommand;

  factory SurfaceCommand.focus({
    required int sequence,
    ProfileKey? profileKey,
    required bool focused,
  }) = FocusCommand;

  factory SurfaceCommand.script({
    required int sequence,
    ProfileKey? profileKey,
    required ScriptEnvelope envelope,
  }) = ScriptCommand;

  factory SurfaceCommand.permission({
    required int sequence,
    ProfileKey? profileKey,
    required String requestId,
    required PermissionDecision decision,
  }) = PermissionCommand;

  factory SurfaceCommand.popup({
    required int sequence,
    ProfileKey? profileKey,
    required String requestId,
    required PopupAction action,
  }) = PopupCommand;

  factory SurfaceCommand.download({
    required int sequence,
    ProfileKey? profileKey,
    required String requestId,
    required DownloadDecision decision,
  }) = DownloadCommand;

  factory SurfaceCommand.clipboard({
    required int sequence,
    ProfileKey? profileKey,
    required String requestId,
    required ClipboardDecision decision,
  }) = ClipboardCommand;

  factory SurfaceCommand.upload({
    required int sequence,
    ProfileKey? profileKey,
    required String requestId,
    required UploadDecision decision,
  }) = UploadCommand;

  factory SurfaceCommand.releaseFrame({
    required int sequence,
    ProfileKey? profileKey,
    required int frameSequence,
  }) = ReleaseFrameCommand;

  Map<String, Object?> toJson();

  factory SurfaceCommand.fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    final payload = _requiredMap(json, 'payload');
    final sequence = _requiredInt(payload, 'sequence');
    final profile = payload['profile_key'] == null
        ? null
        : ProfileKey(payload['profile_key'] as String);
    return switch (type) {
      'navigate' => NavigateCommand(
          sequence: sequence,
          profileKey: profile,
          navigation: NavigationRequest.fromJson(
            _requiredMap(payload, 'navigation'),
          ),
        ),
      'input' => InputCommand(
          sequence: sequence,
          profileKey: profile,
          input: InputEvent.fromJson(_requiredMap(payload, 'input')),
        ),
      'resize' => ResizeCommand(
          sequence: sequence,
          profileKey: profile,
          width: _requiredInt(payload, 'width'),
          height: _requiredInt(payload, 'height'),
          deviceScaleFactor: _requiredDouble(payload, 'device_scale_factor'),
        ),
      'focus' => FocusCommand(
          sequence: sequence,
          profileKey: profile,
          focused: _requiredBool(payload, 'focused'),
        ),
      'script' => ScriptCommand(
          sequence: sequence,
          profileKey: profile,
          envelope: ScriptEnvelope.fromJson(_requiredMap(payload, 'envelope')),
        ),
      'permission' => PermissionCommand(
          sequence: sequence,
          profileKey: profile,
          requestId: _requiredString(payload, 'request_id'),
          decision: _permissionDecisionFromWire(
            _requiredString(payload, 'decision'),
          ),
        ),
      'popup' => PopupCommand(
          sequence: sequence,
          profileKey: profile,
          requestId: _requiredString(payload, 'request_id'),
          action: _popupActionFromWire(_requiredString(payload, 'action')),
        ),
      'download' => DownloadCommand(
          sequence: sequence,
          profileKey: profile,
          requestId: _requiredString(payload, 'request_id'),
          decision:
              _downloadDecisionFromJson(_requiredMap(payload, 'decision')),
        ),
      'clipboard' => ClipboardCommand(
          sequence: sequence,
          profileKey: profile,
          requestId: _requiredString(payload, 'request_id'),
          decision: _enumValue(
            ClipboardDecision.values,
            _requiredString(payload, 'decision'),
          ),
        ),
      'upload' => UploadCommand(
          sequence: sequence,
          profileKey: profile,
          requestId: _requiredString(payload, 'request_id'),
          decision:
              _uploadDecisionFromJson(_requiredMap(payload, 'decision')),
        ),
      'release_frame' => ReleaseFrameCommand(
          sequence: sequence,
          profileKey: profile,
          frameSequence: (payload['frame_sequence'] as num).toInt(),
        ),
      _ => throw ProtocolException(
          'unknown_command_type',
          'unknown surface command type $type',
        ),
    };
  }

  void validate() {
    if (sequence <= 0) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'command sequence must be greater than zero',
      );
    }
  }
}

abstract class _CommandBase extends SurfaceCommand {
  const _CommandBase(super.sequence, super.profileKey);

  Map<String, Object?> payload(Map<String, Object?> fields) => {
        'sequence': sequence,
        'profile_key': profileKey?.value,
        ...fields,
      };
}

class NavigateCommand extends _CommandBase {
  final NavigationRequest navigation;

  NavigateCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.navigation,
  }) : super(sequence, profileKey);

  @override
  Map<String, Object?> toJson() => {
        'type': 'navigate',
        'payload': payload({'navigation': navigation.toJson()}),
      };
}

class InputCommand extends _CommandBase {
  final InputEvent input;

  InputCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.input,
  }) : super(sequence, profileKey);

  @override
  Map<String, Object?> toJson() => {
        'type': 'input',
        'payload': payload({'input': input.toJson()}),
      };
}

class ResizeCommand extends _CommandBase {
  final int width;
  final int height;
  final double deviceScaleFactor;

  ResizeCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
  }) : super(sequence, profileKey) {
    if (width <= 0 ||
        height <= 0 ||
        !deviceScaleFactor.isFinite ||
        deviceScaleFactor <= 0) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'resize dimensions and scale must be positive',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'resize',
        'payload': payload({
          'width': width,
          'height': height,
          'device_scale_factor': deviceScaleFactor,
        }),
      };
}

class FocusCommand extends _CommandBase {
  final bool focused;

  FocusCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.focused,
  }) : super(sequence, profileKey);

  @override
  Map<String, Object?> toJson() => {
        'type': 'focus',
        'payload': payload({'focused': focused}),
      };
}

class ScriptCommand extends _CommandBase {
  final ScriptEnvelope envelope;

  ScriptCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.envelope,
  }) : super(sequence, profileKey);

  @override
  Map<String, Object?> toJson() => {
        'type': 'script',
        'payload': payload({'envelope': envelope.toJson()}),
      };
}

class PermissionCommand extends _CommandBase {
  final String requestId;
  final PermissionDecision decision;

  PermissionCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.requestId,
    required this.decision,
  }) : super(sequence, profileKey) {
    _requireRequestId(requestId);
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'permission',
        'payload': payload({
          'request_id': requestId,
          'decision': _permissionDecisionToWire(decision),
        }),
      };
}

class PopupCommand extends _CommandBase {
  final String requestId;
  final PopupAction action;

  PopupCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.requestId,
    required this.action,
  }) : super(sequence, profileKey) {
    _requireRequestId(requestId);
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'popup',
        'payload': payload({
          'request_id': requestId,
          'action': _popupActionToWire(action),
        }),
      };
}

class DownloadCommand extends _CommandBase {
  final String requestId;
  final DownloadDecision decision;

  DownloadCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.requestId,
    required this.decision,
  }) : super(sequence, profileKey) {
    _requireRequestId(requestId);
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'download',
        'payload': payload({
          'request_id': requestId,
          'decision': decision.toJson(),
        }),
      };
}

class ClipboardCommand extends _CommandBase {
  final String requestId;
  final ClipboardDecision decision;

  ClipboardCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.requestId,
    required this.decision,
  }) : super(sequence, profileKey) {
    _requireRequestId(requestId);
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'clipboard',
        'payload':
            payload({'request_id': requestId, 'decision': decision.name}),
      };
}

class UploadCommand extends _CommandBase {
  final String requestId;
  final UploadDecision decision;

  UploadCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.requestId,
    required this.decision,
  }) : super(sequence, profileKey) {
    _requireRequestId(requestId);
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'upload',
        'payload': payload({
          'request_id': requestId,
          'decision': decision.toJson(),
        }),
      };
}

class ReleaseFrameCommand extends _CommandBase {
  final int frameSequence;

  ReleaseFrameCommand({
    required int sequence,
    ProfileKey? profileKey,
    required this.frameSequence,
  }) : super(sequence, profileKey) {
    if (frameSequence <= 0) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'frame sequence must be greater than zero',
      );
    }
  }

  @override
  Map<String, Object?> toJson() => {
        'type': 'release_frame',
        'payload': payload({'frame_sequence': frameSequence}),
      };
}

class SurfaceId {
  final int value;

  const SurfaceId(this.value) : assert(value > 0);

  @override
  bool operator ==(Object other) => other is SurfaceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toString();
}

enum PixelFormat { bgraPremultiplied, rgbaPremultiplied }

class FrameReference {
  final int slot;
  final int width;
  final int height;
  final int stride;
  final PixelFormat format;
  final int sequence;

  FrameReference({
    required this.slot,
    required this.width,
    required this.height,
    required this.stride,
    required this.format,
    required this.sequence,
  }) {
    if (width <= 0 || height <= 0 || sequence <= 0 || stride < width * 4) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'frame dimensions, stride, and sequence are invalid',
      );
    }
  }

  Map<String, Object?> toJson() => {
        'slot': slot,
        'width': width,
        'height': height,
        'stride': stride,
        'format': _pixelFormatToWire(format),
        'sequence': sequence,
      };

  factory FrameReference.fromJson(Map<String, dynamic> json) => FrameReference(
        slot: _requiredInt(json, 'slot'),
        width: _requiredInt(json, 'width'),
        height: _requiredInt(json, 'height'),
        stride: _requiredInt(json, 'stride'),
        format: _pixelFormatFromWire(_requiredString(json, 'format')),
        sequence: _requiredInt(json, 'sequence'),
      );
}

enum NavigationOutcome { allowed, external, blocked, cancelled }

class NormalizedNavigation {
  final String url;
  final NavigationDisposition disposition;
  final NavigationOutcome outcome;

  const NormalizedNavigation({
    required this.url,
    required this.disposition,
    required this.outcome,
  });

  Map<String, Object?> toJson() => {
        'url': url,
        'disposition': _navigationDispositionToWire(disposition),
        'outcome': outcome.name,
      };

  factory NormalizedNavigation.fromJson(Map<String, dynamic> json) =>
      NormalizedNavigation(
        url: _requiredString(json, 'url'),
        disposition: _navigationDispositionFromWire(
          _requiredString(json, 'disposition'),
        ),
        outcome: _enumValue(
          NavigationOutcome.values,
          _requiredString(json, 'outcome'),
        ),
      );
}

enum CloseReason { user, host, replaced }

enum FailureKind {
  runtimeLost,
  profileMismatch,
  protocolViolation,
  navigationBlocked,
  certificateDenied,
  clientCertificateDenied,
  policyViolation,
  permissionDenied,
  captureDenied,
  malformedMessage,
  oversizedMessage,
  unknownMessage,
}

class SurfaceFailure {
  final FailureKind kind;
  final String message;

  const SurfaceFailure(this.kind, this.message);

  Map<String, Object?> toJson() => {
        'kind': _failureKindToWire(kind),
        'message': message,
      };

  factory SurfaceFailure.fromJson(Map<String, dynamic> json) => SurfaceFailure(
        _failureKindFromWire(_requiredString(json, 'kind')),
        _requiredString(json, 'message'),
      );
}

sealed class WindowChange {
  const WindowChange();

  Map<String, Object?> toJson();
}

class ResizedWindow extends WindowChange {
  final int width;
  final int height;
  final double deviceScaleFactor;

  const ResizedWindow(this.width, this.height, this.deviceScaleFactor);

  @override
  Map<String, Object?> toJson() => {
        'kind': 'resized',
        'value': {
          'width': width,
          'height': height,
          'device_scale_factor': deviceScaleFactor,
        },
      };
}

class FocusedWindow extends WindowChange {
  final bool focused;

  const FocusedWindow(this.focused);

  @override
  Map<String, Object?> toJson() => {
        'kind': 'focused',
        'value': {'focused': focused},
      };
}

WindowChange _windowChangeFromJson(Map<String, dynamic> json) {
  final value = _requiredMap(json, 'value');
  return switch (_requiredString(json, 'kind')) {
    'resized' => ResizedWindow(
        _requiredInt(value, 'width'),
        _requiredInt(value, 'height'),
        _requiredDouble(value, 'device_scale_factor'),
      ),
    'focused' => FocusedWindow(_requiredBool(value, 'focused')),
    final kind => throw ProtocolException(
        'unknown_window_change',
        'unknown window change $kind',
      ),
  };
}

sealed class SurfaceEvent {
  final SurfaceId surfaceId;
  final int sequence;

  const SurfaceEvent(this.surfaceId, this.sequence);

  Map<String, Object?> toJson();

  factory SurfaceEvent.fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    final payload = _requiredMap(json, 'payload');
    final id = _surfaceIdFromJson(payload, 'surface_id');
    final sequence = _requiredInt(payload, 'sequence');
    return switch (type) {
      'ready' => ReadyEvent(
          id,
          sequence,
          NavigationRequest.fromJson(
              _requiredMap(payload, 'initial_navigation')),
        ),
      'closed' => ClosedEvent(
          id,
          sequence,
          _enumValue(CloseReason.values, _requiredString(payload, 'reason')),
        ),
      'failed' => FailedEvent(
          id,
          sequence,
          SurfaceFailure.fromJson(_requiredMap(payload, 'failure')),
        ),
      'frame_ready' => FrameReadyEvent(
          id,
          sequence,
          FrameReference.fromJson(_requiredMap(payload, 'frame')),
        ),
      'navigation' => NavigationEvent(
          id,
          sequence,
          NormalizedNavigation.fromJson(_requiredMap(payload, 'navigation')),
        ),
      'script_message' => ScriptMessageEvent(
          id,
          sequence,
          ScriptEnvelope.fromJson(_requiredMap(payload, 'envelope')),
        ),
      'permission_request' => PermissionRequestEvent(
          id,
          sequence,
          requestId: _requiredString(payload, 'request_id'),
          origin: _requiredString(payload, 'origin'),
          topLevelOrigin: _requiredString(payload, 'top_level_origin'),
          capability: _requiredString(payload, 'capability'),
          userGesture: _requiredBool(payload, 'user_gesture'),
        ),
      'popup_request' => PopupRequestEvent(
          id,
          sequence,
          requestId: _requiredString(payload, 'request_id'),
          url: _requiredString(payload, 'url'),
          userGesture: _requiredBool(payload, 'user_gesture'),
        ),
      'download_request' => DownloadRequestEvent(
          id,
          sequence,
          requestId: _requiredString(payload, 'request_id'),
          url: _requiredString(payload, 'url'),
        ),
      'clipboard_request' => ClipboardRequestEvent(
          id,
          sequence,
          requestId: _requiredString(payload, 'request_id'),
          write: _requiredBool(payload, 'write'),
          userGesture: _requiredBool(payload, 'user_gesture'),
        ),
      'upload_request' => UploadRequestEvent(
          id,
          sequence,
          requestId: _requiredString(payload, 'request_id'),
          multiple: _requiredBool(payload, 'multiple'),
          accept: _stringList(payload, 'accept'),
        ),
      'window_changed' => WindowChangedEvent(
          id,
          sequence,
          _windowChangeFromJson(_requiredMap(payload, 'change')),
        ),
      _ => throw ProtocolException(
          'unknown_event_type',
          'unknown surface event type $type',
        ),
    };
  }
}

Map<String, Object?> _eventPayload(
  SurfaceId id,
  int sequence,
  Map<String, Object?> fields,
) =>
    {'surface_id': id.value, 'sequence': sequence, ...fields};

class ReadyEvent extends SurfaceEvent {
  final NavigationRequest initialNavigation;

  const ReadyEvent(super.surfaceId, super.sequence, this.initialNavigation);

  @override
  Map<String, Object?> toJson() => {
        'type': 'ready',
        'payload': _eventPayload(surfaceId, sequence, {
          'initial_navigation': initialNavigation.toJson(),
        }),
      };
}

class ClosedEvent extends SurfaceEvent {
  final CloseReason reason;

  const ClosedEvent(super.surfaceId, super.sequence, this.reason);

  @override
  Map<String, Object?> toJson() => {
        'type': 'closed',
        'payload': _eventPayload(surfaceId, sequence, {'reason': reason.name}),
      };
}

class FailedEvent extends SurfaceEvent {
  final SurfaceFailure failure;

  const FailedEvent(super.surfaceId, super.sequence, this.failure);

  @override
  Map<String, Object?> toJson() => {
        'type': 'failed',
        'payload': _eventPayload(surfaceId, sequence, {
          'failure': failure.toJson(),
        }),
      };
}

class FrameReadyEvent extends SurfaceEvent {
  final FrameReference frame;

  const FrameReadyEvent(super.surfaceId, super.sequence, this.frame);

  @override
  Map<String, Object?> toJson() => {
        'type': 'frame_ready',
        'payload':
            _eventPayload(surfaceId, sequence, {'frame': frame.toJson()}),
      };
}

class NavigationEvent extends SurfaceEvent {
  final NormalizedNavigation navigation;

  const NavigationEvent(super.surfaceId, super.sequence, this.navigation);

  @override
  Map<String, Object?> toJson() => {
        'type': 'navigation',
        'payload': _eventPayload(surfaceId, sequence, {
          'navigation': navigation.toJson(),
        }),
      };
}

class ScriptMessageEvent extends SurfaceEvent {
  final ScriptEnvelope envelope;

  const ScriptMessageEvent(super.surfaceId, super.sequence, this.envelope);

  @override
  Map<String, Object?> toJson() => {
        'type': 'script_message',
        'payload': _eventPayload(surfaceId, sequence, {
          'envelope': envelope.toJson(),
        }),
      };
}

class PermissionRequestEvent extends SurfaceEvent {
  final String requestId;
  final String origin;
  final String topLevelOrigin;
  final String capability;
  final bool userGesture;

  const PermissionRequestEvent(
    super.surfaceId,
    super.sequence, {
    required this.requestId,
    required this.origin,
    required this.topLevelOrigin,
    required this.capability,
    required this.userGesture,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'permission_request',
        'payload': _eventPayload(surfaceId, sequence, {
          'request_id': requestId,
          'origin': origin,
          'top_level_origin': topLevelOrigin,
          'capability': capability,
          'user_gesture': userGesture,
        }),
      };
}

class PopupRequestEvent extends SurfaceEvent {
  final String requestId;
  final String url;
  final bool userGesture;

  const PopupRequestEvent(
    super.surfaceId,
    super.sequence, {
    required this.requestId,
    required this.url,
    required this.userGesture,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'popup_request',
        'payload': _eventPayload(surfaceId, sequence, {
          'request_id': requestId,
          'url': url,
          'user_gesture': userGesture,
        }),
      };
}

class DownloadRequestEvent extends SurfaceEvent {
  final String requestId;
  final String url;

  const DownloadRequestEvent(
    super.surfaceId,
    super.sequence, {
    required this.requestId,
    required this.url,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'download_request',
        'payload': _eventPayload(surfaceId, sequence, {
          'request_id': requestId,
          'url': url,
        }),
      };
}

class ClipboardRequestEvent extends SurfaceEvent {
  final String requestId;
  final bool write;
  final bool userGesture;

  const ClipboardRequestEvent(
    super.surfaceId,
    super.sequence, {
    required this.requestId,
    required this.write,
    required this.userGesture,
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'clipboard_request',
        'payload': _eventPayload(surfaceId, sequence, {
          'request_id': requestId,
          'write': write,
          'user_gesture': userGesture,
        }),
      };
}

/// Page-initiated file-upload request.  `accept` carries only the page's
/// advisory filter list; the host never enumerates the filesystem to satisfy
/// it.  The app decision (`UploadCommand`) chooses deny/cancel/accept, where
/// accept shows exactly one OS/portal chooser.  The chooser result is staged
/// as read-only copies; the page receives staged bytes/handles, never a real
/// path or a persistent grant.
class UploadRequestEvent extends SurfaceEvent {
  final String requestId;
  final bool multiple;
  final List<String> accept;

  const UploadRequestEvent(
    super.surfaceId,
    super.sequence, {
    required this.requestId,
    required this.multiple,
    this.accept = const [],
  });

  @override
  Map<String, Object?> toJson() => {
        'type': 'upload_request',
        'payload': _eventPayload(surfaceId, sequence, {
          'request_id': requestId,
          'multiple': multiple,
          'accept': accept,
        }),
      };
}

class WindowChangedEvent extends SurfaceEvent {
  final WindowChange change;

  const WindowChangedEvent(super.surfaceId, super.sequence, this.change);

  @override
  Map<String, Object?> toJson() => {
        'type': 'window_changed',
        'payload':
            _eventPayload(surfaceId, sequence, {'change': change.toJson()}),
      };
}

/// The four-operation seam.  Implementations may be backed by the native
/// host, a test transport, or the deterministic fake below.
abstract interface class BrowserRuntime {
  Future<SurfaceId> open(SurfaceSpec spec);

  Future<void> command(SurfaceId surfaceId, SurfaceCommand command);

  Stream<SurfaceEvent> events();

  Future<void> close(SurfaceId surfaceId);
}

class _FakeSurface {
  final SurfaceSpec spec;
  int lastCommandSequence = 0;
  int nextEventSequence = 2;

  _FakeSurface(this.spec);
}

/// Deterministic host substitute for adapter and protocol fixtures.
class FakeBrowserRuntime implements BrowserRuntime {
  int _nextSurfaceId = 1;
  final Map<SurfaceId, _FakeSurface> _surfaces = {};
  final List<SurfaceEvent> _pendingEvents = [];
  late final StreamController<SurfaceEvent> _controller =
      StreamController<SurfaceEvent>()..onListen = _flushPending;
  bool _flushScheduled = false;

  @override
  Stream<SurfaceEvent> events() => _controller.stream;

  @override
  Future<SurfaceId> open(SurfaceSpec spec) async {
    final id = SurfaceId(_nextSurfaceId++);
    _surfaces[id] = _FakeSurface(spec);
    _enqueue(ReadyEvent(id, 1, spec.initialNavigation));
    return id;
  }

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) async {
    command.validate();
    final surface = _surfaces[surfaceId];
    if (surface == null) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
    if (command.profileKey != null &&
        command.profileKey != surface.spec.profileKey) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.profileMismatch,
        'surface profile key does not match',
      );
    }
    if (command.sequence <= surface.lastCommandSequence) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.sequenceViolation,
        'sequence must be greater than ${surface.lastCommandSequence}',
        expectedAfter: surface.lastCommandSequence,
        received: command.sequence,
      );
    }
    surface.lastCommandSequence = command.sequence;
    switch (command) {
      case NavigateCommand(:final navigation):
        final eventSequence = surface.nextEventSequence++;
        final decision = surface.spec.policy.navigationDecision(navigation);
        final outcome = switch (decision) {
          NavigationPolicyDecision.inProcess => NavigationOutcome.allowed,
          NavigationPolicyDecision.external => NavigationOutcome.external,
          NavigationPolicyDecision.blocked =>
            navigation.disposition == NavigationDisposition.external
                ? NavigationOutcome.cancelled
                : NavigationOutcome.blocked,
        };
        _enqueue(
          NavigationEvent(
            surfaceId,
            eventSequence,
            NormalizedNavigation(
              url: navigation.url,
              disposition: navigation.disposition,
              outcome: outcome,
            ),
          ),
        );
      case ScriptCommand(:final envelope):
        final eventSequence = surface.nextEventSequence++;
        _enqueue(ScriptMessageEvent(surfaceId, eventSequence, envelope));
      case ResizeCommand(:final width, :final height, :final deviceScaleFactor):
        final eventSequence = surface.nextEventSequence++;
        _enqueue(
          WindowChangedEvent(
            surfaceId,
            eventSequence,
            ResizedWindow(width, height, deviceScaleFactor),
          ),
        );
      case FocusCommand(:final focused):
        final eventSequence = surface.nextEventSequence++;
        _enqueue(
          WindowChangedEvent(surfaceId, eventSequence, FocusedWindow(focused)),
        );
      case InputCommand() ||
            PermissionCommand() ||
            PopupCommand() ||
            DownloadCommand() ||
            ClipboardCommand() ||
            UploadCommand() ||
            ReleaseFrameCommand():
        // These are accepted by the fake; the real host produces the
        // corresponding request events from CEF callbacks.
        return;
      default:
        return;
    }
  }

  @override
  Future<void> close(SurfaceId surfaceId) async {
    final surface = _surfaces.remove(surfaceId);
    if (surface == null) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
    _enqueue(
      ClosedEvent(surfaceId, surface.nextEventSequence, CloseReason.user),
    );
  }

  /// Test-only frame producer; frames are references to client-owned storage,
  /// never borrowed CEF buffers.
  void publishFrame(SurfaceId surfaceId, FrameReference frame) {
    final surface = _surfaces[surfaceId];
    if (surface == null) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
    _enqueue(FrameReadyEvent(surfaceId, surface.nextEventSequence++, frame));
  }

  void _enqueue(SurfaceEvent event) {
    if (event is FrameReadyEvent) {
      _pendingEvents.removeWhere(
        (pending) =>
            pending is FrameReadyEvent && pending.surfaceId == event.surfaceId,
      );
    }
    _pendingEvents.add(event);
    _flushPending();
  }

  void _flushPending() {
    if (!_controller.hasListener || _flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      if (!_controller.hasListener) return;
      final events = List<SurfaceEvent>.from(_pendingEvents);
      _pendingEvents.clear();
      for (final event in events) {
        _controller.add(event);
      }
      if (_pendingEvents.isNotEmpty) _flushPending();
    });
  }
}

sealed class WireMessage {
  const WireMessage();

  Map<String, Object?> toJson();

  factory WireMessage.fromJson(Map<String, dynamic> json) {
    final type = _requiredString(json, 'type');
    final payload = _requiredMap(json, 'payload');
    return switch (type) {
      'open' => OpenWireMessage(
          _requiredInt(payload, 'request_id'),
          SurfaceSpec.fromJson(_requiredMap(payload, 'spec')),
        ),
      'command' => CommandWireMessage(
          _requiredInt(payload, 'request_id'),
          _surfaceIdFromJson(payload, 'surface_id'),
          SurfaceCommand.fromJson(_requiredMap(payload, 'command')),
        ),
      'close' => CloseWireMessage(
          _surfaceIdFromJson(payload, 'surface_id'),
        ),
      'event' => EventWireMessage(
          SurfaceEvent.fromJson(_requiredMap(payload, 'event')),
        ),
      'opened' => OpenedWireMessage(
          _requiredInt(payload, 'request_id'),
          _surfaceIdFromJson(payload, 'surface_id'),
        ),
      'ack' => AckWireMessage(_requiredInt(payload, 'request_id')),
      'heartbeat' => HeartbeatWireMessage(_requiredInt(payload, 'request_id')),
      'heartbeat_ack' => HeartbeatAckWireMessage(
          _requiredInt(payload, 'request_id'),
        ),
      'error' => ErrorWireMessage(
          _optionalInt(payload, 'request_id'),
          _requiredString(payload, 'code'),
          _requiredString(payload, 'message'),
        ),
      _ => throw ProtocolException(
          'unknown_message_type',
          'unknown protocol message type $type',
        ),
    };
  }
}

class OpenWireMessage extends WireMessage {
  final int requestId;
  final SurfaceSpec spec;

  const OpenWireMessage(this.requestId, this.spec);

  @override
  Map<String, Object?> toJson() => {
        'type': 'open',
        'payload': {'request_id': requestId, 'spec': spec.toJson()},
      };
}

class CommandWireMessage extends WireMessage {
  final int requestId;
  final SurfaceId surfaceId;
  final SurfaceCommand command;

  const CommandWireMessage(this.requestId, this.surfaceId, this.command);

  @override
  Map<String, Object?> toJson() => {
        'type': 'command',
        'payload': {
          'request_id': requestId,
          'surface_id': surfaceId.value,
          'command': command.toJson(),
        },
      };
}

class CloseWireMessage extends WireMessage {
  final SurfaceId surfaceId;

  const CloseWireMessage(this.surfaceId);

  @override
  Map<String, Object?> toJson() => {
        'type': 'close',
        'payload': {'surface_id': surfaceId.value},
      };
}

class EventWireMessage extends WireMessage {
  final SurfaceEvent event;

  const EventWireMessage(this.event);

  @override
  Map<String, Object?> toJson() => {
        'type': 'event',
        'payload': {'event': event.toJson()},
      };
}

class OpenedWireMessage extends WireMessage {
  final int requestId;
  final SurfaceId surfaceId;

  const OpenedWireMessage(this.requestId, this.surfaceId);

  @override
  Map<String, Object?> toJson() => {
        'type': 'opened',
        'payload': {'request_id': requestId, 'surface_id': surfaceId.value},
      };
}

class AckWireMessage extends WireMessage {
  final int requestId;

  const AckWireMessage(this.requestId);

  @override
  Map<String, Object?> toJson() => {
        'type': 'ack',
        'payload': {'request_id': requestId},
      };
}

/// Transport liveness probe.  Heartbeats never carry surface or profile
/// state, so an idle browser can prove that the host and authenticated pipe
/// are still alive without replaying a caller command.
class HeartbeatWireMessage extends WireMessage {
  final int requestId;

  const HeartbeatWireMessage(this.requestId);

  @override
  Map<String, Object?> toJson() => {
        'type': 'heartbeat',
        'payload': {'request_id': requestId},
      };
}

class HeartbeatAckWireMessage extends WireMessage {
  final int requestId;

  const HeartbeatAckWireMessage(this.requestId);

  @override
  Map<String, Object?> toJson() => {
        'type': 'heartbeat_ack',
        'payload': {'request_id': requestId},
      };
}

class ErrorWireMessage extends WireMessage {
  final int? requestId;
  final String code;
  final String message;

  const ErrorWireMessage(this.requestId, this.code, this.message);

  @override
  Map<String, Object?> toJson() => {
        'type': 'error',
        'payload': {'request_id': requestId, 'code': code, 'message': message},
      };
}

class FramedDecodeResult {
  final WireMessage message;
  final int consumedBytes;

  const FramedDecodeResult(this.message, this.consumedBytes);
}

class FramedCodec {
  final int version;
  final String nonce;
  final int maxFrameBytes;

  FramedCodec(
    this.nonce, {
    this.version = browserRuntimeProtocolVersion,
    this.maxFrameBytes = defaultBrowserRuntimeMaxFrameBytes,
  }) {
    if (nonce.isEmpty || maxFrameBytes <= 0 || maxFrameBytes > 0xffffffff) {
      throw const ProtocolException(
        'invalid_codec',
        'nonce and max frame size must be valid',
      );
    }
  }

  Uint8List encode(WireMessage message) {
    final body = utf8.encode(
      jsonEncode({
        'version': version,
        'nonce': nonce,
        'message': message.toJson(),
      }),
    );
    if (body.isEmpty) {
      throw const ProtocolException('empty_frame', 'protocol frame is empty');
    }
    if (body.length > maxFrameBytes) {
      throw ProtocolException(
        'frame_too_large',
        'protocol frame exceeds configured limit',
        size: body.length,
        max: maxFrameBytes,
      );
    }
    final output = Uint8List(body.length + 4);
    ByteData.sublistView(output).setUint32(0, body.length, Endian.big);
    output.setRange(4, output.length, body);
    return output;
  }

  WireMessage decode(Uint8List frame) {
    if (frame.length < 4) {
      throw ProtocolException(
        'truncated_frame',
        'protocol frame is shorter than its length prefix',
      );
    }
    final declared = ByteData.sublistView(frame).getUint32(0, Endian.big);
    if (declared == 0) {
      throw const ProtocolException('empty_frame', 'protocol frame is empty');
    }
    if (declared > maxFrameBytes) {
      throw ProtocolException(
        'frame_too_large',
        'protocol frame exceeds configured limit',
        size: declared,
        max: maxFrameBytes,
      );
    }
    if (frame.length != declared + 4) {
      throw ProtocolException(
        'truncated_frame',
        'protocol frame length does not match payload',
      );
    }
    final Object? decoded;
    try {
      decoded =
          jsonDecode(utf8.decode(frame.sublist(4), allowMalformed: false));
    } on FormatException catch (error) {
      throw ProtocolException('malformed_json', error.message);
    }
    if (decoded is! Map) {
      throw const ProtocolException(
        'malformed_json',
        'protocol envelope must be an object',
      );
    }
    final decodedMap = Map<String, dynamic>.from(decoded);
    final receivedVersion = decodedMap['version'];
    if (receivedVersion != version) {
      throw ProtocolException(
        'unsupported_version',
        'protocol version $receivedVersion is not supported',
      );
    }
    if (decodedMap['nonce'] != nonce) {
      throw const ProtocolException(
        'nonce_mismatch',
        'protocol nonce does not match',
      );
    }
    final message = decodedMap['message'];
    if (message is! Map) {
      throw const ProtocolException(
        'invalid_message',
        'message object is missing',
      );
    }
    return WireMessage.fromJson(Map<String, dynamic>.from(message));
  }

  FramedDecodeResult? decodeNext(Uint8List buffer) {
    if (buffer.length < 4) return null;
    final declared = ByteData.sublistView(buffer).getUint32(0, Endian.big);
    if (declared == 0) {
      throw const ProtocolException('empty_frame', 'protocol frame is empty');
    }
    if (declared > maxFrameBytes) {
      throw ProtocolException(
        'frame_too_large',
        'protocol frame exceeds configured limit',
        size: declared,
        max: maxFrameBytes,
      );
    }
    final total = declared + 4;
    if (buffer.length < total) return null;
    return FramedDecodeResult(
      decode(Uint8List.sublistView(buffer, 0, total)),
      total,
    );
  }
}

String _validateUrl(String url) {
  if (url.isEmpty ||
      url.runes.any((rune) => rune < 0x20) ||
      url.contains(RegExp(r'\s'))) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidSpec,
      'navigation URL is invalid',
    );
  }
  final parsed = Uri.tryParse(url);
  final scheme = parsed?.scheme.toLowerCase();
  if (parsed == null ||
      !const {'http', 'https', 'commet'}.contains(scheme) ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      !_hasValidAuthority(url)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidSpec,
      'navigation scheme is not declared by the runtime',
    );
  }
  return url;
}

String _privacyToWire(PrivacyMode privacy) => switch (privacy) {
      PrivacyMode.persistent => 'persistent',
      PrivacyMode.privateContext => 'private',
    };

PrivacyMode _privacyFromWire(String value) => switch (value) {
      'persistent' => PrivacyMode.persistent,
      'private' => PrivacyMode.privateContext,
      _ =>
        throw ProtocolException('invalid_enum', 'unknown privacy mode $value'),
    };

String _navigationDispositionToWire(NavigationDisposition disposition) =>
    switch (disposition) {
      NavigationDisposition.current => 'current',
      NavigationDisposition.newSurface => 'new_surface',
      NavigationDisposition.external => 'external',
    };

NavigationDisposition _navigationDispositionFromWire(String value) =>
    switch (value) {
      'current' => NavigationDisposition.current,
      'new_surface' => NavigationDisposition.newSurface,
      'external' => NavigationDisposition.external,
      _ => throw ProtocolException(
          'invalid_enum',
          'unknown navigation disposition $value',
        ),
    };

String _permissionDecisionToWire(PermissionDecision decision) =>
    switch (decision) {
      PermissionDecision.deny => 'deny',
      PermissionDecision.allowOnce => 'allow_once',
      PermissionDecision.allowSession => 'allow_session',
      PermissionDecision.allowAlways => 'allow_always',
    };

PermissionDecision _permissionDecisionFromWire(String value) => switch (value) {
      'deny' => PermissionDecision.deny,
      'allow_once' => PermissionDecision.allowOnce,
      'allow_session' => PermissionDecision.allowSession,
      'allow_always' => PermissionDecision.allowAlways,
      _ => throw ProtocolException(
          'invalid_enum',
          'unknown permission decision $value',
        ),
    };

String _popupActionToWire(PopupAction action) => switch (action) {
      PopupAction.deny => 'deny',
      PopupAction.openOwned => 'open_owned',
      PopupAction.openExternal => 'open_external',
      PopupAction.close => 'close',
    };

PopupAction _popupActionFromWire(String value) => switch (value) {
      'deny' => PopupAction.deny,
      'open_owned' => PopupAction.openOwned,
      'open_external' => PopupAction.openExternal,
      'close' => PopupAction.close,
      _ =>
        throw ProtocolException('invalid_enum', 'unknown popup action $value'),
    };

String _pixelFormatToWire(PixelFormat format) => switch (format) {
      PixelFormat.bgraPremultiplied => 'bgra_premultiplied',
      PixelFormat.rgbaPremultiplied => 'rgba_premultiplied',
    };

PixelFormat _pixelFormatFromWire(String value) => switch (value) {
      'bgra_premultiplied' => PixelFormat.bgraPremultiplied,
      'rgba_premultiplied' => PixelFormat.rgbaPremultiplied,
      _ =>
        throw ProtocolException('invalid_enum', 'unknown pixel format $value'),
    };

String _failureKindToWire(FailureKind kind) => switch (kind) {
      FailureKind.runtimeLost => 'runtime_lost',
      FailureKind.profileMismatch => 'profile_mismatch',
      FailureKind.protocolViolation => 'protocol_violation',
      FailureKind.navigationBlocked => 'navigation_blocked',
      FailureKind.certificateDenied => 'certificate_denied',
      FailureKind.clientCertificateDenied => 'client_certificate_denied',
      FailureKind.policyViolation => 'policy_violation',
      FailureKind.permissionDenied => 'permission_denied',
      FailureKind.captureDenied => 'capture_denied',
      FailureKind.malformedMessage => 'malformed_message',
      FailureKind.oversizedMessage => 'oversized_message',
      FailureKind.unknownMessage => 'unknown_message',
    };

FailureKind _failureKindFromWire(String value) => switch (value) {
      'runtime_lost' => FailureKind.runtimeLost,
      'profile_mismatch' => FailureKind.profileMismatch,
      'protocol_violation' => FailureKind.protocolViolation,
      'navigation_blocked' => FailureKind.navigationBlocked,
      'certificate_denied' => FailureKind.certificateDenied,
      'client_certificate_denied' => FailureKind.clientCertificateDenied,
      'policy_violation' => FailureKind.policyViolation,
      'permission_denied' => FailureKind.permissionDenied,
      'capture_denied' => FailureKind.captureDenied,
      'malformed_message' => FailureKind.malformedMessage,
      'oversized_message' => FailureKind.oversizedMessage,
      'unknown_message' => FailureKind.unknownMessage,
      _ =>
        throw ProtocolException('invalid_enum', 'unknown failure kind $value'),
    };

String? _urlOrigin(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      !_hasValidAuthority(url)) {
    return null;
  }
  final scheme = parsed.scheme.toLowerCase();
  if (!const {'http', 'https', 'commet'}.contains(scheme)) return null;
  final host = parsed.host.toLowerCase();
  final normalizedHost = host.contains(':') ? '[$host]' : host;
  final port = parsed.hasPort ? ':${parsed.port}' : '';
  return '$scheme://$normalizedHost$port';
}

bool _hasValidAuthority(String url) {
  final separator = url.indexOf('://');
  if (separator <= 0) return false;
  final rest = url.substring(separator + 3);
  final authorityEnd = RegExp(r'[/\?#]').firstMatch(rest)?.start ?? rest.length;
  final authority = rest.substring(0, authorityEnd);
  if (authority.isEmpty || authority.contains('@')) return false;
  if (authority.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
      authority.contains(RegExp(r'\s'))) {
    return false;
  }
  if (authority.startsWith('[')) {
    final close = authority.indexOf(']');
    if (close <= 1) return false;
    final suffix = authority.substring(close + 1);
    if (suffix.isEmpty) return true;
    if (!suffix.startsWith(':')) return false;
    final port = suffix.substring(1);
    return port.isNotEmpty && port.runes.every(_isAsciiDigit);
  }
  final firstColon = authority.indexOf(':');
  if (firstColon < 0) return true;
  if (firstColon != authority.lastIndexOf(':')) return false;
  final host = authority.substring(0, firstColon);
  final port = authority.substring(firstColon + 1);
  return host.isNotEmpty &&
      port.isNotEmpty &&
      port.runes.every(_isAsciiDigit);
}

bool _isAsciiDigit(int rune) => rune >= 0x30 && rune <= 0x39;

bool _isControlledFixture(String url) =>
    url == 'commet://fixture' || url.startsWith('commet://fixture/');

void _validateDeclaredOrigin(String origin, {required bool loopback}) {
  final normalized = _urlOrigin(origin);
  final parsed = Uri.tryParse(origin);
  final scheme = parsed?.scheme.toLowerCase();
  final validScheme = loopback
      ? scheme == 'http'
      : scheme == 'https' || scheme == 'commet';
  final validLoopback = !loopback ||
      parsed != null &&
          parsed.hasPort &&
          const {'localhost', '127.0.0.1', '::1'}
              .contains(parsed.host.toLowerCase());
  if (normalized == null ||
      parsed!.userInfo.isNotEmpty ||
      parsed.path != '' ||
      parsed.query != '' ||
      parsed.fragment != '' ||
      !validScheme ||
      !validLoopback) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidSpec,
      'policy contains an invalid origin',
    );
  }
}

JsonValue _validateAndCopyJson(JsonValue value) {
  if (value is Uint8List) {
    return Uint8List.fromList(value).asUnmodifiableView();
  }
  if (value is BrowserRuntimeBlob) return BrowserRuntimeBlob(value.bytes);
  if (value is List) {
    return List.unmodifiable(value.map(_validateAndCopyJson));
  }
  if (value is Map) {
    final copy = <String, JsonValue>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const BrowserRuntimeException(
          BrowserRuntimeErrorCode.invalidCommand,
          'JSON object keys must be strings',
        );
      }
      copy[entry.key as String] = _validateAndCopyJson(entry.value);
    }
    final type = copy['__type'];
    if (type != null && type != 'ArrayBuffer' && type != 'Blob') {
      // Unknown __type values are ordinary JSON objects; only the two known
      // binary markers receive special treatment.
    }
    if (type == 'ArrayBuffer' || type == 'Blob') {
      final data = copy['data'];
      if (data is! String) {
        throw const BrowserRuntimeException(
          BrowserRuntimeErrorCode.invalidCommand,
          'binary value must contain base64 data',
        );
      }
      try {
        base64Decode(data);
      } on FormatException {
        throw const BrowserRuntimeException(
          BrowserRuntimeErrorCode.invalidCommand,
          'binary value contains invalid base64',
        );
      }
    }
    return Map.unmodifiable(copy);
  }
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  throw const BrowserRuntimeException(
    BrowserRuntimeErrorCode.invalidCommand,
    'value is not JSON-compatible',
  );
}

JsonValue _encodeJsonValue(JsonValue value) {
  if (value is Uint8List) {
    return {'__type': 'ArrayBuffer', 'data': base64Encode(value)};
  }
  if (value is BrowserRuntimeBlob) {
    return {'__type': 'Blob', 'data': base64Encode(value.bytes)};
  }
  if (value is List) return value.map(_encodeJsonValue).toList(growable: false);
  if (value is Map) {
    return value.map((key, item) => MapEntry(key, _encodeJsonValue(item)));
  }
  return value;
}

JsonValue _decodeJsonValue(JsonValue value) {
  if (value is List) return value.map(_decodeJsonValue).toList(growable: false);
  if (value is Map) {
    final type = value['__type'];
    final data = value['data'];
    if ((type == 'ArrayBuffer' || type == 'Blob') && data is String) {
      final bytes = base64Decode(data);
      return type == 'Blob'
          ? BrowserRuntimeBlob(bytes)
          : Uint8List.fromList(bytes).asUnmodifiableView();
    }
    final copy = <String, JsonValue>{};
    for (final entry in value.entries) {
      if (entry.key is String) {
        copy[entry.key as String] = _decodeJsonValue(entry.value);
      }
    }
    return Map.unmodifiable(copy);
  }
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw ProtocolException('invalid_message', 'field $key must be a string');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite || value % 1 != 0 || value < 0) {
    throw ProtocolException(
      'invalid_message',
      'field $key must be a non-negative integer',
    );
  }
  return value.toInt();
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _requiredInt(json, key);
}

double _requiredDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw ProtocolException('invalid_message', 'field $key must be a number');
  }
  return value.toDouble();
}

double? _optionalDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return _requiredDouble(json, key);
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw ProtocolException('invalid_message', 'field $key must be a boolean');
  }
  return value;
}

JsonValue _requiredValue(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) {
    throw ProtocolException('invalid_message', 'field $key is missing');
  }
  return json[key];
}

SurfaceId _surfaceIdFromJson(Map<String, dynamic> json, String key) {
  final value = _requiredInt(json, key);
  if (value <= 0) {
    throw ProtocolException('invalid_message', 'field $key must be positive');
  }
  return SurfaceId(value);
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw ProtocolException('invalid_message', 'field $key must be an object');
  }
  return Map<String, dynamic>.from(value);
}

List<String> _stringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) {
    throw ProtocolException('invalid_message', 'field $key must be a list');
  }
  return List<String>.unmodifiable(
    value.map((entry) {
      if (entry is! String) {
        throw ProtocolException(
            'invalid_message', 'field $key must contain strings');
      }
      return entry;
    }),
  );
}

T _enumValue<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw ProtocolException('invalid_enum', 'unknown enum value $name');
}

void _requireRequestId(String value) {
  if (value.isEmpty) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'request id must not be empty',
    );
  }
}
