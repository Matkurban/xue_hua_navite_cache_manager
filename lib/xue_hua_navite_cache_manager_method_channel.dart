import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/cache_models.dart';
import 'xue_hua_navite_cache_manager_platform_interface.dart';

/// An implementation of [XueHuaNaviteCacheManagerPlatform] that uses method and event channels.
class MethodChannelXueHuaNaviteCacheManager
    extends XueHuaNaviteCacheManagerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    'xue_hua_navite_cache_manager',
  );

  /// The event channel used to receive real-time download progress events.
  @visibleForTesting
  final EventChannel eventChannel = const EventChannel(
    'xue_hua_navite_cache_manager/events',
  );

  Stream<CacheProgressEvent>? _progressStream;

  @override
  Stream<CacheProgressEvent> get progressStream {
    _progressStream ??= eventChannel.receiveBroadcastStream().map((
      dynamic event,
    ) {
      if (event is Map) {
        return CacheProgressEvent.fromMap(event.cast<Object?, Object?>());
      }
      return const CacheProgressEvent(
        key: '',
        url: '',
        state: CacheTransferState.inProgress,
        bytesReceived: 0,
        totalBytes: -1,
      );
    });
    return _progressStream!;
  }

  @override
  Future<void> configure(CacheManagerConfig config) async {
    await methodChannel.invokeMethod<void>('configure', config.toMap());
  }

  @override
  Future<CacheFetchResult> downloadFile(CacheRequest request) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'downloadFile',
      request.toMap(),
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: 'Native downloadFile returned null.',
      );
    }
    return CacheFetchResult.fromMap(result);
  }

  @override
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) async {
    final result = await methodChannel.invokeListMethod<Object?>(
      'prefetchAll',
      <String, Object?>{'requests': requests.map((r) => r.toMap()).toList()},
    );
    if (result == null) {
      return const <CacheEntry>[];
    }
    return result
        .whereType<Map<Object?, Object?>>()
        .map(CacheEntry.fromMap)
        .toList();
  }

  @override
  Future<bool> cancelDownload(String keyOrUrl) async {
    final canceled = await methodChannel.invokeMethod<bool>(
      'cancelDownload',
      <String, Object?>{'keyOrUrl': keyOrUrl},
    );
    return canceled ?? false;
  }

  @override
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getFileFromCache',
      <String, Object?>{'keyOrUrl': keyOrUrl, 'ignoreExpired': ignoreExpired},
    );
    if (result == null || result.isEmpty) {
      return null;
    }
    return CacheEntry.fromMap(result);
  }

  @override
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final bytes = await methodChannel.invokeMethod<Uint8List>(
      'readCacheBytes',
      <String, Object?>{'keyOrUrl': keyOrUrl, 'ignoreExpired': ignoreExpired},
    );
    return bytes;
  }

  @override
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) async {
    final exists = await methodChannel.invokeMethod<bool>(
      'containsKey',
      <String, Object?>{'keyOrUrl': keyOrUrl, 'ignoreExpired': ignoreExpired},
    );
    return exists ?? false;
  }

  @override
  Future<CacheEntry> putBytes({
    required String key,
    required Uint8List bytes,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'putBytes',
      <String, Object?>{
        'key': key,
        'bytes': bytes,
        'url': url,
        'fileExtension': fileExtension,
        'mimeType': mimeType,
        'tag': tag,
        'ttlSeconds': ttlSeconds,
        'pinned': pinned,
      },
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: 'Native putBytes returned null.',
      );
    }
    return CacheEntry.fromMap(result);
  }

  @override
  Future<CacheEntry> putFile({
    required String key,
    required String sourceFilePath,
    String? url,
    String? fileExtension,
    String? mimeType,
    String? tag,
    int? ttlSeconds,
    bool pinned = false,
  }) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'putFile',
      <String, Object?>{
        'key': key,
        'sourceFilePath': sourceFilePath,
        'url': url,
        'fileExtension': fileExtension,
        'mimeType': mimeType,
        'tag': tag,
        'ttlSeconds': ttlSeconds,
        'pinned': pinned,
      },
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: 'Native putFile returned null.',
      );
    }
    return CacheEntry.fromMap(result);
  }

  @override
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) async {
    final updated = await methodChannel.invokeMethod<bool>(
      'setPinned',
      <String, Object?>{'keyOrUrl': keyOrUrl, 'pinned': pinned},
    );
    return updated ?? false;
  }

  @override
  Future<bool> removeFile(String keyOrUrl) async {
    final removed = await methodChannel.invokeMethod<bool>(
      'removeFile',
      <String, Object?>{'keyOrUrl': keyOrUrl},
    );
    return removed ?? false;
  }

  @override
  Future<int> removeByTag(String tag) async {
    final count = await methodChannel.invokeMethod<int>(
      'removeByTag',
      <String, Object?>{'tag': tag},
    );
    return count ?? 0;
  }

  @override
  Future<int> removeExpired() async {
    final count = await methodChannel.invokeMethod<int>('removeExpired');
    return count ?? 0;
  }

  @override
  Future<int> trimToSize(int maxBytes) async {
    final count = await methodChannel.invokeMethod<int>(
      'trimToSize',
      <String, Object?>{'maxBytes': maxBytes},
    );
    return count ?? 0;
  }

  @override
  Future<int> clearAll({bool includePinned = true}) async {
    final count = await methodChannel.invokeMethod<int>(
      'clearAll',
      <String, Object?>{'includePinned': includePinned},
    );
    return count ?? 0;
  }

  @override
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) async {
    final result = await methodChannel.invokeListMethod<Object?>(
      'listEntries',
      <String, Object?>{'tag': tag, 'includeExpired': includeExpired},
    );
    if (result == null) {
      return const <CacheEntry>[];
    }
    return result
        .whereType<Map<Object?, Object?>>()
        .map(CacheEntry.fromMap)
        .toList();
  }

  @override
  Future<CacheStats> getStats() async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getStats',
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: 'Native getStats returned null.',
      );
    }
    return CacheStats.fromMap(result);
  }

  @override
  Future<CachePlatformCapabilities> getCapabilities() async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'getCapabilities',
    );
    if (result == null) {
      throw PlatformException(
        code: 'NULL_RESULT',
        message: 'Native getCapabilities returned null.',
      );
    }
    return CachePlatformCapabilities.fromMap(result);
  }
}
