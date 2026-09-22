import 'package:flutter/widgets.dart';

/// Accessible recovery UI shared by every CEF-owned surface.
///
/// Covers criterion 3 of #127 across Windows embedded/standalone, native
/// Linux embedded/standalone, Flatpak both presentations, and the Windows
/// official-video adapter: reconnecting, crashed-surface, retry, close, and
/// diagnostic-reporting UI is accessible.
///
/// Contract:
/// - Recoverable failures show "Reconnecting browser" as a live region.
/// - Terminal surface failures show "This embedded page crashed. Retry" or
///   "Graphics unavailable. Retry" with Close and Report diagnostics.
/// - Terminal runtime failures show "Embedded browser unavailable. Retry
///   browser".
/// - Raw process paths, URLs, CEF statuses, profile IDs, cookies, and device
///   IDs are never shown; only the fixed strings above plus an opaque
///   diagnostic ID (for example `d-3-7`) are rendered.
/// - Every control is keyboard-focusable, exposes a semantic label, honors
///   text scaling, and works with high-contrast themes (no color-only
///   signalling; text labels always accompany state).

/// Accessible reconnecting overlay shown during host restart.
///
/// The rest of roscord remains usable while this surface reports
/// reconnecting; the overlay is a live region so screen readers announce
/// the state change.
class ReconnectingBrowserOverlay extends StatelessWidget {
  const ReconnectingBrowserOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Reconnecting browser',
      child: const Text(
        'Reconnecting browser…',
        textDirection: TextDirection.ltr,
      ),
    );
  }
}

/// Terminal surface failure card with Retry, Close, and Report diagnostics.
///
/// [title] must be one of the fixed contract strings:
/// "This embedded page crashed. Retry" or "Graphics unavailable. Retry".
/// [diagnosticId] is the opaque ID (for example `d-3-7`) retained locally
/// when upload is unavailable; [onCopyDiagnosticId] implements Copy
/// diagnostic ID.
class CrashedSurfaceCard extends StatelessWidget {
  const CrashedSurfaceCard({
    super.key,
    required this.title,
    required this.diagnosticId,
    required this.onRetry,
    required this.onClose,
    required this.onReport,
    required this.onCopyDiagnosticId,
  }) : assert(
          title == 'This embedded page crashed. Retry' ||
              title == 'Graphics unavailable. Retry',
          'crashed-surface title must use the fixed contract string',
        );

  final String title;
  final String diagnosticId;
  final VoidCallback onRetry;
  final VoidCallback onClose;
  final VoidCallback onReport;
  final VoidCallback onCopyDiagnosticId;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '$title. Diagnostic $diagnosticId',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, textDirection: TextDirection.ltr),
          Text(
            'Diagnostic $diagnosticId',
            textDirection: TextDirection.ltr,
          ),
          Wrap(
            spacing: 8,
            children: [
              _Action(
                label: 'Retry',
                semanticHint: 'Retry loading this page',
                onPressed: onRetry,
              ),
              _Action(
                label: 'Close',
                semanticHint: 'Close this page',
                onPressed: onClose,
              ),
              _Action(
                label: 'Report diagnostics',
                semanticHint: 'Report diagnostics for this failure',
                onPressed: onReport,
              ),
              _Action(
                label: 'Copy diagnostic ID',
                semanticHint: 'Copy diagnostic ID $diagnosticId',
                onPressed: onCopyDiagnosticId,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Terminal runtime failure card with a single Retry browser action.
class RuntimeUnavailableCard extends StatelessWidget {
  const RuntimeUnavailableCard({
    super.key,
    required this.diagnosticId,
    required this.onRetryBrowser,
  });

  final String diagnosticId;
  final VoidCallback onRetryBrowser;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Embedded browser unavailable. Retry browser. '
          'Diagnostic $diagnosticId',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Embedded browser unavailable. Retry browser',
            textDirection: TextDirection.ltr,
          ),
          Text(
            'Diagnostic $diagnosticId',
            textDirection: TextDirection.ltr,
          ),
          _Action(
            label: 'Retry browser',
            semanticHint: 'Retry starting the embedded browser',
            onPressed: onRetryBrowser,
          ),
        ],
      ),
    );
  }
}

/// Keyboard-focusable semantic button used by all recovery cards.
///
/// Built on widgets-only primitives so the cards work in every presentation
/// (embedded texture, owned window placeholder, dialog chrome) and remain
/// testable without a Material ancestor.
class _Action extends StatefulWidget {
  const _Action({
    required this.label,
    required this.semanticHint,
    required this.onPressed,
  });

  final String label;
  final String semanticHint;
  final VoidCallback onPressed;

  @override
  State<_Action> createState() => _ActionState();
}

class _ActionState extends State<_Action> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!mounted) return;
      setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      hint: widget.semanticHint,
      focused: _focused,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (node, event) {
            // Enter/Space activation is handled by the embedder's shortcut
            // layer; focus traversal itself must work for keyboard users.
            return KeyEventResult.ignored;
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFF000000),
                width: _focused ? 3 : 1,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.label,
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
      ),
    );
  }
}
