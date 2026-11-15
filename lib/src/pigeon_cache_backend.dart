import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;

import 'cache_backend.dart';
import 'cache_models.dart';
import 'pigeon/cache_messages.g.dart';

/// Pigeon-backed implementation of [CacheBackend].
///
/// Uses generated FFI (iOS/macOS) and JNI (Android) native interop when running
/// on Apple or Android platforms, and generated Pigeon BinaryMessenger channels
/// on Windows and Linux.
class PigeonCacheBackend implements CacheBackend {
  /// Creates a [PigeonCacheBackend].
  ///
  /// The optional [hostApi] parameter is intended for unit testing with custom
  /// messengers or fake hosts without initializing native interop.
  PigeonCacheBackend({
    @visibleForTesting CacheHostApi? hostApi,
    @visibleForTesting bool registerFlutterApi = true,
  }) : _overrideHostApi = hostApi,
       _shouldRegisterFlutterApi = registerFlutterApi;

  final CacheHostApi? _overrideHostApi;
  final bool _shouldRegisterFlutterApi;

  bool _progressApiRegistered = false;

  late final CacheHostApi _api = _overrideHostApi ?? _createHostApi();

  late final StreamController<CacheProgressEvent> _progressController =
      StreamController<CacheProgressEvent>.broadcast(
        onListen: _ensureProgressApiRegistered,
      );

  static bool get _usesNativeInterop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static bool _isMissingNativeInteropHost(Object error) {
    final String typeName = error.runtimeType.toString();
    return error is UnsupportedError ||
        typeName.contains('FailedToLoadClass') ||
        typeName.contains('FailedToLoadProtocol');
  }

  static CacheHostApi _createHostApi() {
    if (_usesNativeInterop) {
      try {
        return CacheHostApi.createWithNativeInteropApi();
      } catch (error) {
        // Under host-less `flutter test` (without native plugin dylibs loaded),
        // FFI/JNI native interop lookup throws FailedToLoadClassException,
        // FailedToLoadProtocolException, or UnsupportedError. Fall back cleanly
        // to channel-based CacheHostApi so widget tests run without binaries.
        if (_isMissingNativeInteropHost(error)) {
          return CacheHostApi();
        }
        rethrow;
      }
    }
    return CacheHostApi();
  }

  void _ensureProgressApiRegistered() {
    if (!_shouldRegisterFlutterApi || _progressApiRegistered) {
      return;
    }
    // Resolve `_api` before (or alongside) FlutterApi registration so Pigeon's
    // native interop layer learns the calling isolate's engine affinity first.
    final CacheHostApi _ = _api;
    try {
      CacheProgressFlutterApi.setUp(
        _ProgressFlutterApiHandler(_progressController),
      );
      _progressApiRegistered = true;
    } catch (error) {
      if (_isMissingNativeInteropHost(error)) {
        // Under host-less `flutter test`, FFI class/protocol lookup fails; mark
        // registered so repeated calls don't re-throw while keeping stream open.
        _progressApiRegistered = true;
        return;
      }
      rethrow;
    }
  }

  @override
  Stream<CacheProgressEvent> get progressStream {
    _ensureProgressApiRegistered();
    return _progressController.stream;
  }

  @override
  Future<void> configure(CacheManagerConfig config) {
    _ensureProgressApiRegistered();
    return _api.configure(_toWireConfig(config));
  }

  @override
  Future<CacheFetchResult> downloadFile(CacheRequest request) async {
    _ensureProgressApiRegistered();
    final WireCacheFetchResult result = await _api.downloadFile(
      _toWireRequest(request),
    );
    return _fromWireFetchResult(result);
  }

  @override
  Future<List<CacheEntry>> prefetchAll(List<CacheRequest> requests) async {
    _ensureProgressApiRegistered();
    final List<WireCacheEntry> entries = await _api.prefetchAll(
      requests.map(_toWireRequest).toList(growable: false),
    );
    return entries.map(_fromWireEntry).toList(growable: false);
  }

  @override
  Future<bool> cancelDownload(String keyOrUrl) {
    _ensureProgressApiRegistered();
    return _api.cancelDownload(keyOrUrl);
  }

  @override
  Future<CacheEntry?> getFileFromCache(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) async {
    final WireCacheEntry? entry = await _api.getFileFromCache(
      keyOrUrl,
      ignoreExpired,
    );
    return entry == null ? null : _fromWireEntry(entry);
  }

  @override
  Future<Uint8List?> readCacheBytes(
    String keyOrUrl, {
    bool ignoreExpired = true,
  }) {
    return _api.readCacheBytes(keyOrUrl, ignoreExpired);
  }

  @override
  Future<bool> containsKey(String keyOrUrl, {bool ignoreExpired = true}) {
    return _api.containsKey(keyOrUrl, ignoreExpired);
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
    final WireCacheEntry entry = await _api.putBytes(
      key,
      bytes,
      url,
      fileExtension,
      mimeType,
      tag,
      ttlSeconds,
      pinned,
    );
    return _fromWireEntry(entry);
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
    final WireCacheEntry entry = await _api.putFile(
      key,
      sourceFilePath,
      url,
      fileExtension,
      mimeType,
      tag,
      ttlSeconds,
      pinned,
    );
    return _fromWireEntry(entry);
  }

  @override
  Future<bool> setPinned(String keyOrUrl, {required bool pinned}) {
    return _api.setPinned(keyOrUrl, pinned);
  }

  @override
  Future<bool> removeFile(String keyOrUrl) {
    return _api.removeFile(keyOrUrl);
  }

  @override
  Future<int> removeByTag(String tag) {
    return _api.removeByTag(tag);
  }

  @override
  Future<int> removeExpired() {
    return _api.removeExpired();
  }

  @override
  Future<int> trimToSize(int maxBytes) {
    return _api.trimToSize(maxBytes);
  }

  @override
  Future<int> clearAll({bool includePinned = true}) {
    return _api.clearAll(includePinned);
  }

  @override
  Future<List<CacheEntry>> listEntries({
    String? tag,
    bool includeExpired = true,
  }) async {
    final List<WireCacheEntry> entries = await _api.listEntries(
      tag,
      includeExpired,
    );
    return entries.map(_fromWireEntry).toList(growable: false);
  }

  @override
  Future<CacheStats> getStats() async {
    return _fromWireStats(await _api.getStats());
  }

  @override
  Future<CachePlatformCapabilities> getCapabilities() async {
    return _fromWireCapabilities(await _api.getCapabilities());
  }

  static WireCacheManagerConfig _toWireConfig(CacheManagerConfig config) {
    return WireCacheManagerConfig(
      maxDiskCacheBytes: config.maxDiskCacheBytes,
      maxEntries: config.maxEntries,
      defaultTtlSeconds: config.defaultTtlSeconds,
      evictionPolicy: _toWireEvictionPolicy(config.evictionPolicy),
      cacheSubdirectory: config.cacheSubdirectory,
      maxConcurrentDownloads: config.maxConcurrentDownloads,
      connectTimeoutMs: config.connectTimeoutMs,
      readTimeoutMs: config.readTimeoutMs,
      defaultHeaders: Map<String, String>.from(config.defaultHeaders),
      respectHttpCacheHeaders: config.respectHttpCacheHeaders,
      autoTrimOnWrite: config.autoTrimOnWrite,
    );
  }

  static WireCacheRequest _toWireRequest(CacheRequest request) {
    return WireCacheRequest(
      url: request.url,
      customKey: request.customKey,
      tag: request.tag,
      fileExtension: request.fileExtension,
      headers: Map<String, String>.from(request.headers),
      ttlSeconds: request.ttlSeconds,
      forceRefresh: request.forceRefresh,
      fallbackToCacheOnError: request.fallbackToCacheOnError,
      pinned: request.pinned,
      checksumAlgorithm: _toWireChecksumAlgorithm(request.checksumAlgorithm),
      expectedChecksum: request.expectedChecksum,
    );
  }

  static WireCacheEvictionPolicy _toWireEvictionPolicy(
    CacheEvictionPolicy policy,
  ) {
    return switch (policy) {
      CacheEvictionPolicy.lru => WireCacheEvictionPolicy.lru,
      CacheEvictionPolicy.lfu => WireCacheEvictionPolicy.lfu,
      CacheEvictionPolicy.fifo => WireCacheEvictionPolicy.fifo,
      CacheEvictionPolicy.ttlOnly => WireCacheEvictionPolicy.ttlOnly,
    };
  }

  static WireCacheChecksumAlgorithm _toWireChecksumAlgorithm(
    CacheChecksumAlgorithm algorithm,
  ) {
    return switch (algorithm) {
      CacheChecksumAlgorithm.none => WireCacheChecksumAlgorithm.none,
      CacheChecksumAlgorithm.md5 => WireCacheChecksumAlgorithm.md5,
      CacheChecksumAlgorithm.sha256 => WireCacheChecksumAlgorithm.sha256,
    };
  }

  static CacheChecksumAlgorithm _fromWireChecksumAlgorithm(
    WireCacheChecksumAlgorithm algorithm,
  ) {
    return switch (algorithm) {
      WireCacheChecksumAlgorithm.none => CacheChecksumAlgorithm.none,
      WireCacheChecksumAlgorithm.md5 => CacheChecksumAlgorithm.md5,
      WireCacheChecksumAlgorithm.sha256 => CacheChecksumAlgorithm.sha256,
    };
  }

  static CacheResultSource _fromWireResultSource(WireCacheResultSource source) {
    return switch (source) {
      WireCacheResultSource.cacheHit => CacheResultSource.cacheHit,
      WireCacheResultSource.revalidated => CacheResultSource.revalidated,
      WireCacheResultSource.networkDownload =>
        CacheResultSource.networkDownload,
      WireCacheResultSource.staleCacheFallback =>
        CacheResultSource.staleCacheFallback,
    };
  }

  static CacheTransferState _fromWireTransferState(
    WireCacheTransferState state,
  ) {
    return switch (state) {
      WireCacheTransferState.started => CacheTransferState.started,
      WireCacheTransferState.inProgress => CacheTransferState.inProgress,
      WireCacheTransferState.cacheHit => CacheTransferState.cacheHit,
      WireCacheTransferState.completed => CacheTransferState.completed,
      WireCacheTransferState.canceled => CacheTransferState.canceled,
      WireCacheTransferState.failed => CacheTransferState.failed,
    };
  }

  static CacheEntry _fromWireEntry(WireCacheEntry entry) {
    return CacheEntry(
      key: entry.key,
      url: entry.url,
      filePath: entry.filePath,
      sizeBytes: entry.sizeBytes,
      createdAtMs: entry.createdAtMs,
      lastAccessedAtMs: entry.lastAccessedAtMs,
      expiresAtMs: entry.expiresAtMs,
      hitCount: entry.hitCount,
      tag: entry.tag,
      mimeType: entry.mimeType,
      eTag: entry.eTag,
      lastModified: entry.lastModified,
      checksum: entry.checksum,
      checksumAlgorithm: _fromWireChecksumAlgorithm(entry.checksumAlgorithm),
      pinned: entry.pinned,
    );
  }

  static CacheFetchResult _fromWireFetchResult(WireCacheFetchResult result) {
    final WireCacheEntry? entry = result.entry;
    if (entry == null) {
      throw StateError('WireCacheFetchResult.entry was unexpectedly null');
    }
    return CacheFetchResult(
      entry: _fromWireEntry(entry),
      source: _fromWireResultSource(result.source),
      httpStatusCode: result.httpStatusCode,
      elapsedMs: result.elapsedMs,
    );
  }

  static CacheStats _fromWireStats(WireCacheStats stats) {
    return CacheStats(
      totalEntries: stats.totalEntries,
      totalBytes: stats.totalBytes,
      expiredEntries: stats.expiredEntries,
      pinnedEntries: stats.pinnedEntries,
      maxDiskCacheBytes: stats.maxDiskCacheBytes,
      cacheDirectoryPath: stats.cacheDirectoryPath,
      hitCount: stats.hitCount,
      missCount: stats.missCount,
      evictionCount: stats.evictionCount,
      bytesByTag: Map<String, int>.from(stats.bytesByTag),
    );
  }

  static CachePlatformCapabilities _fromWireCapabilities(
    WireCachePlatformCapabilities capabilities,
  ) {
    return CachePlatformCapabilities(
      platformName: capabilities.platformName,
      supportsFileSystemPaths: capabilities.supportsFileSystemPaths,
      supportsConditionalHttpRevalidation:
          capabilities.supportsConditionalHttpRevalidation,
      supportsNativeCryptoHash: capabilities.supportsNativeCryptoHash,
      supportsLowDiskSpaceNotifications:
          capabilities.supportsLowDiskSpaceNotifications,
      storageMechanism: capabilities.storageMechanism,
      defaultCacheRootPath: capabilities.defaultCacheRootPath,
    );
  }

  /// Converts a Pigeon wire progress payload to a public [CacheProgressEvent].
  static CacheProgressEvent fromWireProgressEvent(WireCacheProgressEvent event) {
    return CacheProgressEvent(
      key: event.key,
      url: event.url,
      state: _fromWireTransferState(event.state),
      bytesReceived: event.bytesReceived,
      totalBytes: event.totalBytes,
      filePath: event.filePath,
      errorMessage: event.errorMessage,
    );
  }
}

final class _ProgressFlutterApiHandler implements CacheProgressFlutterApi {
  _ProgressFlutterApiHandler(this._controller);

  final StreamController<CacheProgressEvent> _controller;

  @override
  Future<void> onProgress(WireCacheProgressEvent event) async {
    if (!_controller.isClosed) {
      _controller.add(PigeonCacheBackend.fromWireProgressEvent(event));
    }
  }
}
