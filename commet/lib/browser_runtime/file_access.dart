import 'browser_runtime.dart';

/// Default one-shot prompt budget for file-access requests (downloads,
/// clipboard, uploads).  The host cancels the request when the app has not
/// produced a decision by the deadline.
const int fileAccessRequestTimeoutMs = 30000;

/// Maximum accepted download filename length in bytes (UTF-8).
const int maxDownloadFileNameBytes = 255;

/// Mediated download filename policy.
///
/// The page's suggested name is untrusted: it may contain traversal,
/// separators, drive prefixes, reserved device names, or control characters.
/// [sanitizeSuggestedName] returns a safe leaf name or throws
/// [BrowserRuntimeException] with [BrowserRuntimeErrorCode.invalidCommand].
String sanitizeSuggestedDownloadName(String suggested) {
  if (suggested.isEmpty) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename is empty',
    );
  }
  // Reject NUL/control characters, separators, and drive prefixes outright;
  // the caller must not guess which byte the page "meant".
  if (suggested.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
      suggested.contains('/') ||
      suggested.contains(r'\') ||
      suggested.contains('\u0000')) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename contains a forbidden character',
    );
  }
  if (suggested.length > 2 && suggested[1] == ':') {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename must not contain a drive prefix',
    );
  }
  var leaf = suggested;
  // Strip surrounding whitespace; Windows also forbids trailing dots/spaces.
  leaf = leaf.trim();
  while (leaf.endsWith('.') || leaf.endsWith(' ')) {
    leaf = leaf.substring(0, leaf.length - 1);
  }
  if (leaf.isEmpty || leaf == '.' || leaf == '..') {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename is a dot segment',
    );
  }
  if (leaf.startsWith('.') && leaf.length == 1) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename is a dot segment',
    );
  }
  final stem = leaf.split('.').first.toUpperCase();
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(stem)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename is a reserved device name',
    );
  }
  final bytes = leaf.length;
  if (bytes > maxDownloadFileNameBytes) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'download filename is too long',
    );
  }
  return leaf;
}

/// Returns a destination leaf that does not silently overwrite an existing
/// sibling.  `existingLeafs` is the lower-cased set of names already present
/// in the safe destination directory.  The first free `name (n).ext` form
/// wins; the search is bounded so a hostile directory cannot force an
/// unbounded loop.
String resolveNonOverwritingLeaf(String leaf, Set<String> existingLeafs) {
  final lower = existingLeafs.map((name) => name.toLowerCase()).toSet();
  if (!lower.contains(leaf.toLowerCase())) return leaf;
  final dot = leaf.lastIndexOf('.');
  final stem = dot <= 0 ? leaf : leaf.substring(0, dot);
  final extension = dot <= 0 ? '' : leaf.substring(dot);
  for (var counter = 1; counter <= 9999; counter++) {
    final candidate = '$stem ($counter)$extension';
    if (candidate.length > maxDownloadFileNameBytes) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'download filename has no free non-overwriting form',
      );
    }
    if (!lower.contains(candidate.toLowerCase())) return candidate;
  }
  throw const BrowserRuntimeException(
    BrowserRuntimeErrorCode.invalidCommand,
    'download filename has no free non-overwriting form',
  );
}

/// Clipboard read policy: a page read requires a user gesture *and* an
/// explicit one-shot app prompt.  The prompt is consumed by a single read;
/// pages never receive a native clipboard handle, only the mediated snapshot.
ClipboardDecision decideClipboardRead({
  required bool userGesture,
  required bool promptAccepted,
}) {
  if (!userGesture) return ClipboardDecision.deny;
  return promptAccepted ? ClipboardDecision.allow : ClipboardDecision.deny;
}

/// Clipboard write policy: a page write requires a user gesture *and* an
/// admitted origin.  There is no standing grant: each write is checked
/// against the surface's declared origins.
ClipboardDecision decideClipboardWrite({
  required bool userGesture,
  required String origin,
  required List<String> admittedOrigins,
}) {
  if (!userGesture) return ClipboardDecision.deny;
  if (origin.isEmpty) return ClipboardDecision.deny;
  return admittedOrigins.contains(origin)
      ? ClipboardDecision.allow
      : ClipboardDecision.deny;
}

/// Upload chooser policy: an upload proceeds only after the app shows exactly
/// one OS/portal chooser for that request.  The host stages the user's
/// explicit selection as read-only copies; the page never learns a real path,
/// never enumerates a directory, and never keeps a persistent grant.
UploadDecision decideUpload({
  required bool chooserShown,
  required bool userConfirmed,
}) {
  if (!chooserShown) return const DenyUpload();
  return userConfirmed ? const AcceptUpload() : const CancelUpload();
}

enum FileAccessKind { download, clipboardRead, clipboardWrite, upload }

enum FileAccessCancelReason {
  navigation,
  close,
  hostLoss,
  timeout,
  denied,
  unavailableUi,
}

class PendingFileAccessRequest {
  final SurfaceId surfaceId;
  final String requestId;
  final FileAccessKind kind;
  final int createdMs;
  final int timeoutMs;

  const PendingFileAccessRequest({
    required this.surfaceId,
    required this.requestId,
    required this.kind,
    required this.createdMs,
    this.timeoutMs = fileAccessRequestTimeoutMs,
  });

  bool get isClipboard =>
      kind == FileAccessKind.clipboardRead ||
      kind == FileAccessKind.clipboardWrite;

  bool expiredAt(int nowMs) => nowMs - createdMs >= timeoutMs;
}

/// Deterministic registry for pending download/clipboard/upload requests.
///
/// The registry owns no UI and performs no I/O: the adapter registers a
/// host request, then cancels it when the surface navigates, closes, the
/// host is lost, the one-shot prompt times out, the app denies it, or no UI
/// can be shown.  Cancellation is idempotent and terminal: a cancelled
/// request id never resolves afterwards.
class PendingFileAccessRegistry {
  final Map<String, PendingFileAccessRequest> _pending = {};

  int get length => _pending.length;

  bool contains(String requestId) => _pending.containsKey(requestId);

  void register(PendingFileAccessRequest request) {
    if (request.requestId.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'request id must not be empty',
      );
    }
    if (_pending.containsKey(request.requestId)) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'request id is already pending',
      );
    }
    _pending[request.requestId] = request;
  }

  /// Removes a request after the app produced a terminal decision.
  /// Returns false when the request was already cancelled.
  bool resolve(String requestId) => _pending.remove(requestId) != null;

  List<PendingFileAccessRequest> cancelForNavigation(SurfaceId surfaceId) =>
      _removeWhere(
        (request) => request.surfaceId == surfaceId,
        FileAccessCancelReason.navigation,
      );

  List<PendingFileAccessRequest> cancelForClose(SurfaceId surfaceId) =>
      _removeWhere(
        (request) => request.surfaceId == surfaceId,
        FileAccessCancelReason.close,
      );

  List<PendingFileAccessRequest> cancelForHostLoss() => _removeWhere(
        (_) => true,
        FileAccessCancelReason.hostLoss,
      );

  List<PendingFileAccessRequest> cancelForUnavailableUi(
    SurfaceId surfaceId,
  ) =>
      _removeWhere(
        (request) => request.surfaceId == surfaceId,
        FileAccessCancelReason.unavailableUi,
      );

  List<PendingFileAccessRequest> cancelDenied(String requestId) => _removeWhere(
        (request) => request.requestId == requestId,
        FileAccessCancelReason.denied,
      );

  List<PendingFileAccessRequest> expire(int nowMs) {
    final expired = _pending.values
        .where((request) => request.expiredAt(nowMs))
        .map((request) => request.requestId)
        .toList();
    return _removeWhere(
      (request) => expired.contains(request.requestId),
      FileAccessCancelReason.timeout,
    );
  }

  List<PendingFileAccessRequest> _removeWhere(
    bool Function(PendingFileAccessRequest) matches,
    FileAccessCancelReason reason,
  ) {
    // `reason` is part of the public cancellation contract: callers map it
    // to terminal download/clipboard/upload decisions.  It is intentionally
    // not inspected inside the registry itself.
    final removed = <PendingFileAccessRequest>[];
    for (final id in _pending.keys.toList()) {
      final request = _pending[id]!;
      if (matches(request)) {
        _pending.remove(id);
        removed.add(request);
      }
    }
    return removed;
  }
}
