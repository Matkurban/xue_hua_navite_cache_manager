import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Loads an image file directly from [filePath] into an [ui.ImmutableBuffer]
/// on the Engine IO thread without copying large byte arrays across MethodChannel.
Future<ui.Codec> loadFileImageCodec(
  String filePath,
  ui.ImageDecoderCallback decode, {
  int? maxWidth,
  int? maxHeight,
}) async {
  final file = File(filePath);
  if (!await file.exists()) {
    throw StateError('Cached image file does not exist: $filePath');
  }
  final length = await file.length();
  if (length <= 0) {
    throw StateError('Cached image file is empty: $filePath');
  }

  final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromFilePath(
    filePath,
  );
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

/// Decodes raw [bytes] into a [ui.Codec] with optional target dimensions.
Future<ui.Codec> decodeImageBytes(
  Uint8List bytes,
  ui.ImageDecoderCallback decode, {
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
