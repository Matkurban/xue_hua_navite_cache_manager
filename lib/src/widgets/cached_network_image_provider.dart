import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../xue_hua_navite_cache_manager.dart';
import 'image_file_loader_stub.dart'
    if (dart.library.io) 'image_file_loader_io.dart';

/// An [ImageProvider] that fetches, caches, and decodes network images using
/// [XueHuaNaviteCacheManager].
///
/// Integrates directly with Flutter's [ImageCache] (`PaintingBinding.instance.imageCache`)
/// for instant 0ms synchronous memory hits, uses zero-copy `ui.ImmutableBuffer.fromFilePath`
/// decoding on native platforms to avoid copying large byte arrays across `MethodChannel`,
/// and supports target-size downsampling ([maxWidth], [maxHeight]) to eliminate UI jank.
@immutable
class CachedNetworkImageProvider
    extends ImageProvider<CachedNetworkImageProvider> {
  /// Creates a [CachedNetworkImageProvider] for the given [url].
  const CachedNetworkImageProvider(
    this.url, {
    this.scale = 1.0,
    this.cacheKey,
    this.tag,
    this.headers = const <String, String>{},
    this.ttlSeconds,
    this.forceRefresh = false,
    this.fallbackToCacheOnError = true,
    this.pinned = false,
    this.checksumAlgorithm = CacheChecksumAlgorithm.none,
    this.expectedChecksum,
    this.maxWidth,
    this.maxHeight,
    this.cacheManager,
    this.errorListener,
  });

  /// Remote HTTP or HTTPS URL of the image.
  final String url;

  /// Scale factor applied to the decoded image.
  final double scale;

  /// Optional custom cache key override.
  final String? cacheKey;

  /// Optional logical category tag (e.g. `'avatars'`, `'banners'`) for batch eviction.
  final String? tag;

  /// Optional HTTP request headers merged on top of `CacheManagerConfig.defaultHeaders`.
  final Map<String, String> headers;

  /// Optional TTL override in seconds.
  final int? ttlSeconds;

  /// When `true`, forces a conditional refresh or full network re-download.
  final bool forceRefresh;

  /// When `true` (default), falls back to an expired cached file if the network fails.
  final bool fallbackToCacheOnError;

  /// When `true`, marks the cached image as pinned so quota eviction skips it.
  final bool pinned;

  /// Optional checksum algorithm to verify the downloaded image file.
  final CacheChecksumAlgorithm checksumAlgorithm;

  /// Expected hex digest when [checksumAlgorithm] is enabled.
  final String? expectedChecksum;

  /// Optional maximum decode width in pixels (downsamples in native C++ codec to save GPU/RAM).
  final int? maxWidth;

  /// Optional maximum decode height in pixels (downsamples in native C++ codec to save GPU/RAM).
  final int? maxHeight;

  /// Optional custom [XueHuaNaviteCacheManager] instance; defaults to [XueHuaNaviteCacheManager.instance].
  final XueHuaNaviteCacheManager? cacheManager;

  /// Optional callback invoked if image loading or decoding fails.
  final void Function(Object error)? errorListener;

  @override
  Future<CachedNetworkImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<CachedNetworkImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final StreamController<ImageChunkEvent> chunkEvents =
        StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkImageProvider>('Image key', key),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    CachedNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    final manager = key.cacheManager ?? XueHuaNaviteCacheManager.instance;
    StreamSubscription<CacheProgressEvent>? progressSub;

    try {
      // Subscribe to progress events (both cacheHit and network inProgress)
      progressSub = manager.watchProgress(key.cacheKey ?? key.url).listen((
        event,
      ) {
        if (!chunkEvents.isClosed &&
            (event.state == CacheTransferState.inProgress ||
                event.state == CacheTransferState.completed ||
                event.state == CacheTransferState.cacheHit) &&
            event.bytesReceived >= 0) {
          chunkEvents.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: event.bytesReceived,
              expectedTotalBytes: event.totalBytes > 0
                  ? event.totalBytes
                  : null,
            ),
          );
        }
      });

      // Fast-path: check if a valid non-expired file already exists in local cache
      if (!key.forceRefresh) {
        final lookupKey = key.cacheKey ?? key.url;
        final cached = await manager.getFileFromCache(lookupKey);
        if (cached != null) {
          if (!chunkEvents.isClosed && cached.sizeBytes > 0) {
            chunkEvents.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: cached.sizeBytes,
                expectedTotalBytes: cached.sizeBytes,
              ),
            );
          }
          if (!kIsWeb && cached.filePath.isNotEmpty) {
            try {
              return await loadFileImageCodec(
                cached.filePath,
                decode,
                maxWidth: key.maxWidth,
                maxHeight: key.maxHeight,
              );
            } catch (_) {
              // Fall through to readCacheBytes or re-download if local file was removed externally
            }
          }
          final cachedBytes = await manager.readCacheBytes(cached.key);
          if (cachedBytes != null && cachedBytes.isNotEmpty) {
            return await decodeImageBytes(
              cachedBytes,
              decode,
              maxWidth: key.maxWidth,
              maxHeight: key.maxHeight,
            );
          }
        }
      }

      final result = await manager.downloadFile(
        CacheRequest(
          url: key.url,
          customKey: key.cacheKey,
          tag: key.tag,
          headers: key.headers,
          ttlSeconds: key.ttlSeconds,
          forceRefresh: key.forceRefresh,
          fallbackToCacheOnError: key.fallbackToCacheOnError,
          pinned: key.pinned,
          checksumAlgorithm: key.checksumAlgorithm,
          expectedChecksum: key.expectedChecksum,
        ),
      );

      if (!kIsWeb && result.filePath.isNotEmpty) {
        try {
          return await loadFileImageCodec(
            result.filePath,
            decode,
            maxWidth: key.maxWidth,
            maxHeight: key.maxHeight,
          );
        } catch (_) {
          // Fallback to reading bytes if path is virtual in unit test mocks
        }
      }

      final bytes = await manager.readCacheBytes(result.entry.key);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Failed to load cached image bytes for ${key.url}');
      }

      return await decodeImageBytes(
        bytes,
        decode,
        maxWidth: key.maxWidth,
        maxHeight: key.maxHeight,
      );
    } catch (error) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      key.errorListener?.call(error);
      rethrow;
    } finally {
      await progressSub?.cancel();
      await chunkEvents.close();
    }
  }

  /// Evicts this image provider from Flutter's in-memory [ImageCache] and optionally
  /// removes the underlying file from [XueHuaNaviteCacheManager].
  Future<bool> evictFromCache({bool removeDiskCache = false}) async {
    final memoryEvicted = await super.evict();
    if (removeDiskCache) {
      final manager = cacheManager ?? XueHuaNaviteCacheManager.instance;
      await manager.removeFile(cacheKey ?? url);
    }
    return memoryEvicted;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CachedNetworkImageProvider &&
        other.url == url &&
        other.scale == scale &&
        other.cacheKey == cacheKey &&
        other.maxWidth == maxWidth &&
        other.maxHeight == maxHeight;
  }

  @override
  int get hashCode => Object.hash(url, scale, cacheKey, maxWidth, maxHeight);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'CachedNetworkImageProvider')}("$url", scale: $scale, cacheKey: $cacheKey, maxWidth: $maxWidth, maxHeight: $maxHeight)';
}
