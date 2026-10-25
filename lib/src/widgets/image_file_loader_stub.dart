import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Platform-incompatible stub for loading image bytes from a local filesystem path.
Future<ui.Codec> loadFileImageCodec(
  String filePath,
  ImageDecoderCallback decode, {
  int? maxWidth,
  int? maxHeight,
}) {
  throw UnsupportedError(
    'Direct file system image loading is not supported on Web.',
  );
}

/// Decodes raw [bytes] into a [ui.Codec] with optional target dimensions.
Future<ui.Codec> decodeImageBytes(
  Uint8List bytes,
  ImageDecoderCallback decode, {
  int? maxWidth,
  int? maxHeight,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  return decode(
    buffer,
    getTargetSize: (maxWidth != null || maxHeight != null)
        ? (int intrinsicWidth, int intrinsicHeight) {
            if (maxWidth != null && maxHeight != null) {
              return ui.TargetImageSize(width: maxWidth, height: maxHeight);
            }
            if (maxWidth != null) {
              final ratio = maxWidth / intrinsicWidth;
              return ui.TargetImageSize(
                width: maxWidth,
                height: (intrinsicHeight * ratio).round().clamp(1, 65536),
              );
            }
            final ratio = maxHeight! / intrinsicHeight;
            return ui.TargetImageSize(
              width: (intrinsicWidth * ratio).round().clamp(1, 65536),
              height: maxHeight,
            );
          }
        : null,
  );
}
