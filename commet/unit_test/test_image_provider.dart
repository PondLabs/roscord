import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// An [ImageProvider] around a pre-created [ui.Image], so widget tests lay
/// images out at a known size without touching the network or test assets.
///
/// Create the image with `tester.runAsync(() => createTestImage(...))`.
class FixedImageProvider extends ImageProvider<FixedImageProvider> {
  const FixedImageProvider(this.image);

  final ui.Image image;

  @override
  Future<FixedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<FixedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      FixedImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      SynchronousFuture<ImageInfo>(ImageInfo(image: key.image)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FixedImageProvider && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
}
