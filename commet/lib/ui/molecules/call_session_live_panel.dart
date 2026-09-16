import 'dart:async';

import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/client/components/voip/voip_stream.dart';
import 'package:flutter/material.dart';
import 'package:tiamat/tiamat.dart' as tiamat;

/// The "you are live" section of the sidebar voice panel.
///
/// Shows a LIVE pill, a small 16:9 preview of the local screen share or
/// camera, and buttons to stop them. When both are on the preview shows one
/// at a time and the user can switch. Renders nothing while neither is on.
class CallSessionLivePanel extends StatefulWidget {
  const CallSessionLivePanel({required this.session, this.onOpen, super.key});

  final VoipSession session;

  /// Called when the preview is tapped. The voice panel uses this to open
  /// the voice channel.
  final void Function()? onOpen;

  static const previewKey = ValueKey("callSessionLivePanel_preview");
  static const stopScreenshareKey =
      ValueKey("callSessionLivePanel_stopScreenshare");
  static const stopCameraKey = ValueKey("callSessionLivePanel_stopCamera");
  static const showScreenKey = ValueKey("callSessionLivePanel_showScreen");
  static const showCameraKey = ValueKey("callSessionLivePanel_showCamera");

  @override
  State<CallSessionLivePanel> createState() => _CallSessionLivePanelState();
}

class _CallSessionLivePanelState extends State<CallSessionLivePanel> {
  StreamSubscription? _sub;
  final GlobalKey _rendererKey = GlobalKey();

  /// Which source the preview shows when both are live.
  VoipStreamType _selected = VoipStreamType.screenshare;

  @override
  void initState() {
    _sub = widget.session.onStateChanged.listen((_) {
      if (mounted) setState(() {});
    });
    super.initState();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  VoipStream? _outgoing(VoipStreamType type) {
    for (final s in widget.session.streams) {
      if (s.direction == VoipStreamDirection.outgoing && s.type == type) {
        return s;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sharingScreen = widget.session.isSharingScreen;
    final cameraOn = widget.session.isCameraEnabled;
    if (!sharingScreen && !cameraOn) {
      return const SizedBox.shrink();
    }

    // Fall back to whatever is still live if the selected source stopped.
    final showCamera =
        cameraOn && (_selected == VoipStreamType.video || !sharingScreen);
    final previewType =
        showCamera ? VoipStreamType.video : VoipStreamType.screenshare;
    final preview = _outgoing(previewType);
    final colors = ColorScheme.of(context);

    final label = switch ((sharingScreen, cameraOn)) {
      (true, true) => "Screen + Camera",
      (true, false) => "Screen",
      _ => "Camera",
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Row(
            spacing: 6,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: colors.error,
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: tiamat.Text.tiny("LIVE", color: colors.onError),
              ),
              Expanded(
                child: tiamat.Text.labelLow(label,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              if (sharingScreen && cameraOn) ...[
                _sourceChip(
                  key: CallSessionLivePanel.showScreenKey,
                  icon: Icons.screen_share_outlined,
                  selected: !showCamera,
                  onTap: () =>
                      setState(() => _selected = VoipStreamType.screenshare),
                ),
                _sourceChip(
                  key: CallSessionLivePanel.showCameraKey,
                  icon: Icons.videocam_outlined,
                  selected: showCamera,
                  onTap: () => setState(() => _selected = VoipStreamType.video),
                ),
              ],
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Expanded(
                child: Material(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: CallSessionLivePanel.previewKey,
                    onTap: widget.onOpen,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: preview?.buildVideoRenderer(
                              BoxFit.cover, _rendererKey) ??
                          const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              Column(
                spacing: 4,
                children: [
                  if (sharingScreen)
                    _stopButton(
                      key: CallSessionLivePanel.stopScreenshareKey,
                      icon: Icons.stop_screen_share_outlined,
                      onPressed: widget.session.stopScreenshare,
                    ),
                  if (cameraOn)
                    _stopButton(
                      key: CallSessionLivePanel.stopCameraKey,
                      icon: Icons.videocam_off_outlined,
                      onPressed: widget.session.stopCamera,
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stopButton(
      {required Key key,
      required IconData icon,
      required Future<void> Function() onPressed}) {
    return SizedBox(
      width: 32,
      height: 32,
      child: tiamat.IconButton(
        key: key,
        icon: icon,
        iconColor: ColorScheme.of(context).error,
        onPressed: onPressed,
      ),
    );
  }

  Widget _sourceChip(
      {required Key key,
      required IconData icon,
      required bool selected,
      required void Function() onTap}) {
    final colors = ColorScheme.of(context);
    return Material(
      key: key,
      color: selected ? colors.primary.withAlpha(60) : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon,
              size: 14,
              color: selected ? colors.primary : colors.onSurfaceVariant),
        ),
      ),
    );
  }
}
