import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A Flutter texture showing frames that roscord's CEF host writes to a
/// shared-memory frame ring.
///
/// The host reports each frame as (ring name, slot, sequence, size) in a
/// `frame_ready` event; [present] passes that reference on, and the raster
/// thread copies the slot into the texture. A frame the host has already
/// overwritten is skipped, so the texture never shows a torn frame.
class BrowserSurfaceTexture {
  BrowserSurfaceTexture._(this.textureId);

  static const MethodChannel _channel = MethodChannel('browser_surface');

  /// The id to give a [Texture] widget.
  final int textureId;

  bool _disposed = false;

  /// Whether this platform has a native implementation.
  static bool get isSupported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  /// Registers a native texture, or returns null where there is no native
  /// implementation (other platforms, or tests without the plugin).
  static Future<BrowserSurfaceTexture?> create() async {
    if (!isSupported) return null;
    try {
      final id = await _channel.invokeMethod<int>('create');
      return id == null ? null : BrowserSurfaceTexture._(id);
    } on MissingPluginException {
      return null;
    }
  }

  /// Shows frame [sequence] from [slot] of the ring [buffer] next time the
  /// texture is drawn.
  Future<void> present({
    required String buffer,
    required int slot,
    required int sequence,
    required int width,
    required int height,
  }) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('present', {
      'textureId': textureId,
      'buffer': buffer,
      'slot': slot,
      'sequence': sequence,
      'width': width,
      'height': height,
    });
  }

  /// Unregisters the texture and unmaps its ring.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod<void>('dispose', {'textureId': textureId});
  }
}
