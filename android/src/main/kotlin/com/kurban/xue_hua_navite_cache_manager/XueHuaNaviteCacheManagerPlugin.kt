package com.kurban.xue_hua_navite_cache_manager

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.regex.Pattern
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Native Android implementation of `xue_hua_navite_cache_manager` using Pigeon JNI.
 *
 * Provides thread-safe network file downloading, conditional HTTP revalidation (ETag / Last-Modified),
 * MD5 and SHA-256 verification, atomic disk persistence under `context.cacheDir`, O(1) running byte
 * tracking, debounced asynchronous index flushing for 10,000+ entries, and listener-safe progress events.
 * Network downloads run on a fixed pool capped by `maxConcurrentDownloads`. Identical in-flight keys
 * share one transfer and fan the result out to every waiter.
 */
class XueHuaNaviteCacheManagerPlugin :
    FlutterPlugin,
    CacheHostApi {

    private lateinit var applicationContext: Context
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null

    private val indexLock = Any()
    private val downloadExecutor = ThreadPoolExecutor(
        4,
        4,
        30L,
        TimeUnit.SECONDS,
        LinkedBlockingQueue<Runnable>(),
        ThreadFactory { r -> Thread(r, "xuehua-cache-dl").apply { isDaemon = true } }
    )
    private val persistScheduler = Executors.newSingleThreadScheduledExecutor()
    private var pendingPersistFuture: ScheduledFuture<*>? = null

    private var progressExecutor: ExecutorService = newProgressExecutor()
    private var progressScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + progressExecutor.asCoroutineDispatcher())

    @Volatile
    private var maxDiskCacheBytes: Long = 500L * 1024L * 1024L

    @Volatile
    private var maxEntries: Int = 20000

    @Volatile
    private var defaultTtlSeconds: Long = 7L * 24L * 3600L

    @Volatile
    private var evictionPolicy: String = "lru"

    @Volatile
    private var cacheSubdirectory: String = "xue_hua_network_cache"

    @Volatile
    private var maxConcurrentDownloads: Int = 4

    @Volatile
    private var connectTimeoutMs: Int = 15000

    @Volatile
    private var readTimeoutMs: Int = 30000

    @Volatile
    private var defaultHeaders: Map<String, String> = emptyMap()

    @Volatile
    private var respectHttpCacheHeaders: Boolean = true

    @Volatile
    private var autoTrimOnWrite: Boolean = true

    private val entries = LinkedHashMap<String, CacheRecord>(256, 0.75f, false)
    private var totalCachedBytes: Long = 0L
    private var hitCount: Long = 0L
    private var missCount: Long = 0L
    private var evictionCount: Long = 0L
    private var indexLoaded: Boolean = false

    private val activeDownloads = ConcurrentHashMap<String, AtomicBoolean>()

    private class InFlightDownload(
        val future: CompletableFuture<WireCacheFetchResult>,
        val cancelFlag: AtomicBoolean = AtomicBoolean(false),
    )

    /** One network transfer per cache key. Followers await the leader's future. */
    private val inFlightDownloads = ConcurrentHashMap<String, InFlightDownload>()

    private data class CacheRecord(
        val key: String,
        val url: String,
        val filePath: String,
        val sizeBytes: Long,
        val createdAtMs: Long,
        var lastAccessedAtMs: Long,
        var expiresAtMs: Long,
        var hitCount: Long,
        var tag: String?,
        var mimeType: String?,
        var eTag: String?,
        var lastModified: String?,
        var checksum: String?,
        var checksumAlgorithm: String,
        var pinned: Boolean,
    ) {
        fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean {
            return expiresAtMs > 0L && nowMs > expiresAtMs
        }

        fun toWire(): WireCacheEntry {
            return WireCacheEntry(
                key = key,
                url = url,
                filePath = filePath,
                sizeBytes = sizeBytes,
                createdAtMs = createdAtMs,
                lastAccessedAtMs = lastAccessedAtMs,
                expiresAtMs = expiresAtMs,
                hitCount = hitCount,
                tag = tag,
                mimeType = mimeType,
                eTag = eTag,
                lastModified = lastModified,
                checksum = checksum,
                checksumAlgorithm = toWireChecksumAlgorithm(checksumAlgorithm),
                pinned = pinned,
            )
        }

        fun toJson(): JSONObject {
            val obj = JSONObject()
            obj.put("key", key)
            obj.put("url", url)
            obj.put("filePath", filePath)
            obj.put("sizeBytes", sizeBytes)
            obj.put("createdAtMs", createdAtMs)
            obj.put("lastAccessedAtMs", lastAccessedAtMs)
            obj.put("expiresAtMs", expiresAtMs)
            obj.put("hitCount", hitCount)
            if (tag != null) obj.put("tag", tag)
            if (mimeType != null) obj.put("mimeType", mimeType)
            if (eTag != null) obj.put("eTag", eTag)
            if (lastModified != null) obj.put("lastModified", lastModified)
            if (checksum != null) obj.put("checksum", checksum)
            obj.put("checksumAlgorithm", checksumAlgorithm)
            obj.put("pinned", pinned)
            return obj
        }

        companion object {
            fun fromJson(obj: JSONObject): CacheRecord {
                return CacheRecord(
                    key = obj.optString("key", ""),
                    url = obj.optString("url", ""),
                    filePath = obj.optString("filePath", ""),
                    sizeBytes = obj.optLong("sizeBytes", 0L),
                    createdAtMs = obj.optLong("createdAtMs", 0L),
                    lastAccessedAtMs = obj.optLong("lastAccessedAtMs", 0L),
                    expiresAtMs = obj.optLong("expiresAtMs", 0L),
                    hitCount = obj.optLong("hitCount", 0L),
                    tag = if (obj.has("tag") && !obj.isNull("tag")) obj.getString("tag") else null,
                    mimeType = if (obj.has("mimeType") && !obj.isNull("mimeType")) obj.getString("mimeType") else null,
                    eTag = if (obj.has("eTag") && !obj.isNull("eTag")) obj.getString("eTag") else null,
                    lastModified = if (obj.has("lastModified") && !obj.isNull("lastModified")) {
                        obj.getString("lastModified")
                    } else {
                        null
                    },
                    checksum = if (obj.has("checksum") && !obj.isNull("checksum")) obj.getString("checksum") else null,
                    checksumAlgorithm = obj.optString("checksumAlgorithm", "none"),
                    pinned = obj.optBoolean("pinned", false),
                )
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        pluginBinding = flutterPluginBinding
        if (progressExecutor.isShutdown) {
            progressExecutor = newProgressExecutor()
            progressScope = CoroutineScope(SupervisorJob() + progressExecutor.asCoroutineDispatcher())
        }
        CacheHostApiRegistrar().register(this, flutterPluginBinding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CacheHostApiRegistrar().unregister(this, binding)
        pluginBinding = null
        progressScope.cancel()
        progressExecutor.shutdown()
        flushIndexNow()
        downloadExecutor.shutdownNow()
    }

    private fun emitProgress(
        key: String,
        url: String,
        state: WireCacheTransferState,
        bytesReceived: Long,
        totalBytes: Long,
        filePath: String? = null,
        errorMessage: String? = null,
    ) {
        val binding = pluginBinding ?: return
        val flutterApi = CacheProgressFlutterApiRegistrar().getInstance(binding) ?: return
        val event = WireCacheProgressEvent(
            key = key,
            url = url,
            state = state,
            bytesReceived = bytesReceived,
            totalBytes = totalBytes,
            filePath = filePath,
            errorMessage = errorMessage,
        )
        progressScope.launch {
            try {
                flutterApi.onProgress(event)
            } catch (_: Throwable) {
                // Ignore stale/detached Dart isolate callbacks per Pigeon FlutterApi guidance.
            }
        }
    }

    private fun getCacheRootDir(): File {
        val dir = File(applicationContext.cacheDir, cacheSubdirectory)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    private fun getIndexFile(): File {
        return File(getCacheRootDir(), "cache_index_v1.json")
    }

    private fun ensureIndexLoaded() {
        synchronized(indexLock) {
            if (indexLoaded) return
            indexLoaded = true
            entries.clear()
            totalCachedBytes = 0L
            val indexFile = getIndexFile()
            if (!indexFile.exists()) return
            try {
                val raw = indexFile.readText(Charsets.UTF_8)
                val root = JSONObject(raw)
                hitCount = root.optLong("hitCount", 0L)
                missCount = root.optLong("missCount", 0L)
                evictionCount = root.optLong("evictionCount", 0L)
                val arr = root.optJSONArray("entries") ?: JSONArray()
                for (i in 0 until arr.length()) {
                    val item = arr.optJSONObject(i) ?: continue
                    val record = CacheRecord.fromJson(item)
                    val resolvedFile = resolveExistingFile(record)
                    if (record.key.isNotEmpty() && resolvedFile != null) {
                        val updatedRecord = if (resolvedFile.absolutePath != record.filePath) {
                            record.copy(filePath = resolvedFile.absolutePath)
                        } else {
                            record
                        }
                        entries[updatedRecord.key] = updatedRecord
                        totalCachedBytes += updatedRecord.sizeBytes
                    }
                }
            } catch (_: Exception) {
                // Recover cleanly if index file was corrupted.
            }
            recoverOrphanedFilesOnDiskLocked()
        }
    }

    private fun resolveExistingFile(record: CacheRecord): File? {
        val direct = File(record.filePath)
        if (direct.exists()) return direct
        val fileName = direct.name
        if (fileName.isNotEmpty()) {
            val candidate = File(getCacheRootDir(), fileName)
            if (candidate.exists()) return candidate
        }
        return null
    }

    private fun recoverOrphanedFilesOnDiskLocked() {
        val dir = getCacheRootDir()
        val files = dir.listFiles() ?: return
        var recoveredAny = false
        for (file in files) {
            if (!file.isFile) continue
            val name = file.name
            if (name == "cache_index_v1.json" || name.endsWith(".tmp") || name.endsWith(".json")) {
                continue
            }
            val key = file.nameWithoutExtension
            if (key.isEmpty() || entries.containsKey(key)) continue
            val size = file.length()
            if (size <= 0L) continue
            val modifiedMs = file.lastModified().takeIf { it > 0L } ?: System.currentTimeMillis()
            val record = CacheRecord(
                key = key,
                url = "cached://$key",
                filePath = file.absolutePath,
                sizeBytes = size,
                createdAtMs = modifiedMs,
                lastAccessedAtMs = modifiedMs,
                expiresAtMs = modifiedMs + defaultTtlSeconds * 1000L,
                hitCount = 1L,
                tag = "recovered",
                mimeType = "application/octet-stream",
                eTag = null,
                lastModified = null,
                checksum = null,
                checksumAlgorithm = "none",
                pinned = false,
            )
            entries[key] = record
            totalCachedBytes += size
            recoveredAny = true
        }
        if (recoveredAny) {
            schedulePersistIndexLocked(immediate = true)
        }
    }

    /**
     * Schedules a debounced background flush of the in-memory index so 10,000+ rapid
     * cache operations coalesce into a single non-blocking disk write.
     */
    private fun schedulePersistIndexLocked(immediate: Boolean = false) {
        pendingPersistFuture?.cancel(false)
        val delayMs = if (immediate) 0L else 120L
        if (!persistScheduler.isShutdown) {
            pendingPersistFuture = persistScheduler.schedule(
                { flushIndexNow() },
                delayMs,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    private fun flushIndexNow() {
        if (!::applicationContext.isInitialized) return
        val snapshotEntries: List<CacheRecord>
        val snapshotHit: Long
        val snapshotMiss: Long
        val snapshotEviction: Long
        val indexFile: File
        synchronized(indexLock) {
            snapshotEntries = entries.values.map { it.copy() }
            snapshotHit = hitCount
            snapshotMiss = missCount
            snapshotEviction = evictionCount
            indexFile = getIndexFile()
        }
        try {
            val root = JSONObject()
            root.put("hitCount", snapshotHit)
            root.put("missCount", snapshotMiss)
            root.put("evictionCount", snapshotEviction)
            val arr = JSONArray()
            for (record in snapshotEntries) {
                arr.put(record.toJson())
            }
            root.put("entries", arr)
            val tmpFile = File(indexFile.parentFile, "cache_index_v1.json.tmp")
            tmpFile.writeText(root.toString(), Charsets.UTF_8)
            if (!tmpFile.renameTo(indexFile)) {
                indexFile.writeText(root.toString(), Charsets.UTF_8)
                tmpFile.delete()
            }
        } catch (_: Exception) {
        }
    }

    private fun resolveKey(keyOrUrl: String, customKey: String? = null): String {
        if (!customKey.isNullOrBlank()) {
            return customKey.trim()
        }
        synchronized(indexLock) {
            if (entries.containsKey(keyOrUrl)) {
                return keyOrUrl
            }
        }
        return computeSha256String(keyOrUrl.toByteArray(Charsets.UTF_8))
    }

    private fun computeSha256String(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(bytes)
        return hash.joinToString("") { "%02x".format(it) }
    }

    private fun computeFileHash(file: File, algorithm: String): String {
        val digestName = when (algorithm.lowercase()) {
            "md5" -> "MD5"
            else -> "SHA-256"
        }
        val digest = MessageDigest.getInstance(digestName)
        FileInputStream(file).use { fis ->
            val buffer = ByteArray(16 * 1024)
            var read = fis.read(buffer)
            while (read != -1) {
                digest.update(buffer, 0, read)
                read = fis.read(buffer)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun inferExtension(url: String, mimeType: String?, explicitExtension: String?): String {
        if (!explicitExtension.isNullOrBlank()) {
            return explicitExtension.trim().trimStart('.')
        }
        try {
            val path = URI.create(url).path ?: ""
            val lastSegment = path.substringAfterLast('/', "")
            val ext = lastSegment.substringAfterLast('.', "")
            if (ext.isNotEmpty() && ext.length <= 8 && ext.all { it.isLetterOrDigit() }) {
                return ext.lowercase()
            }
        } catch (_: Exception) {
        }
        return when (mimeType?.lowercase()?.substringBefore(';')?.trim()) {
            "image/png" -> "png"
            "image/jpeg", "image/jpg" -> "jpg"
            "image/webp" -> "webp"
            "image/gif" -> "gif"
            "image/svg+xml" -> "svg"
            "application/pdf" -> "pdf"
            "application/json" -> "json"
            "audio/mpeg", "audio/mp3" -> "mp3"
            "video/mp4" -> "mp4"
            "text/plain" -> "txt"
            else -> "bin"
        }
    }

    override suspend fun configure(config: WireCacheManagerConfig) = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val prevSubdir = cacheSubdirectory
        maxDiskCacheBytes = config.maxDiskCacheBytes
        maxEntries = config.maxEntries.toInt().coerceAtLeast(1)
        defaultTtlSeconds = config.defaultTtlSeconds
        evictionPolicy = fromWireEvictionPolicy(config.evictionPolicy)
        cacheSubdirectory =
            config.cacheSubdirectory.takeIf { it.isNotBlank() } ?: cacheSubdirectory
        val newConcurrency = config.maxConcurrentDownloads.toInt().coerceAtLeast(1)
        if (newConcurrency != maxConcurrentDownloads) {
            resizeDownloadPool(newConcurrency)
        }
        connectTimeoutMs = config.connectTimeoutMs.toInt().coerceAtLeast(0)
        readTimeoutMs = config.readTimeoutMs.toInt().coerceAtLeast(0)
        defaultHeaders = HashMap(config.defaultHeaders)
        respectHttpCacheHeaders = config.respectHttpCacheHeaders
        autoTrimOnWrite = config.autoTrimOnWrite

        if (prevSubdir != cacheSubdirectory) {
            flushIndexNow()
            synchronized(indexLock) {
                indexLoaded = false
            }
            ensureIndexLoaded()
        }

        if (autoTrimOnWrite) {
            synchronized(indexLock) {
                enforceQuotaLocked(maxDiskCacheBytes, null, checkOnlyFastPath = false)
                schedulePersistIndexLocked()
            }
        }
    }

    private fun resizeDownloadPool(newConcurrency: Int) {
        val size = newConcurrency.coerceAtLeast(1)
        maxConcurrentDownloads = size
        if (size > downloadExecutor.maximumPoolSize) {
            downloadExecutor.maximumPoolSize = size
            downloadExecutor.corePoolSize = size
        } else {
            downloadExecutor.corePoolSize = size
            downloadExecutor.maximumPoolSize = size
        }
    }

    private fun unwrapDownloadError(error: Throwable?): Throwable? {
        var current = error
        while (current is CompletionException && current.cause != null) {
            current = current.cause
        }
        return current
    }

    /**
     * Cache hits return immediately. Misses share one pooled download per key and complete
     * every waiter from that single transfer.
     */
    private fun downloadCoalesced(request: WireCacheRequest): CompletableFuture<WireCacheFetchResult> {
        val url = request.url.trim()
        if (url.isEmpty()) {
            val failed = CompletableFuture<WireCacheFetchResult>()
            failed.completeExceptionally(FlutterError("INVALID_URL", "URL is required", null))
            return failed
        }
        val key = resolveKey(url, request.customKey)
        if (!request.forceRefresh) {
            val cached = tryFreshCacheHit(request, key, url, System.currentTimeMillis())
            if (cached != null) {
                return CompletableFuture.completedFuture(cached)
            }
        }

        val created = InFlightDownload(CompletableFuture())
        val existing = inFlightDownloads.putIfAbsent(key, created)
        if (existing != null) {
            return existing.future
        }
        activeDownloads[key] = created.cancelFlag
        try {
            downloadExecutor.execute {
                var value: WireCacheFetchResult? = null
                var error: Throwable? = null
                try {
                    if (created.cancelFlag.get()) {
                        throw FlutterError("CANCELED", "Download canceled for $key", null)
                    }
                    value = executeDownloadRequest(request, created.cancelFlag)
                } catch (t: Throwable) {
                    error = t
                } finally {
                    inFlightDownloads.remove(key, created)
                    activeDownloads.remove(key, created.cancelFlag)
                }
                if (error != null) {
                    created.future.completeExceptionally(error)
                } else if (value != null) {
                    created.future.complete(value)
                } else {
                    created.future.completeExceptionally(
                        FlutterError("DOWNLOAD_FAILED", "Download failed", null),
                    )
                }
            }
        } catch (e: RejectedExecutionException) {
            inFlightDownloads.remove(key, created)
            activeDownloads.remove(key, created.cancelFlag)
            created.future.completeExceptionally(e)
        }
        return created.future
    }

    private fun tryFreshCacheHit(
        request: WireCacheRequest,
        key: String,
        url: String,
        startMs: Long,
    ): WireCacheFetchResult? {
        val tag = request.tag
        val pinned = request.pinned
        val hit = synchronized(indexLock) {
            val found = entries[key] ?: return@synchronized null
            if (!File(found.filePath).exists() || found.isExpired(startMs)) {
                return@synchronized null
            }
            found.lastAccessedAtMs = startMs
            found.hitCount += 1L
            if (tag != null) found.tag = tag
            if (pinned) found.pinned = true
            hitCount += 1L
            schedulePersistIndexLocked()
            WireCacheFetchResult(
                entry = found.toWire(),
                source = WireCacheResultSource.CACHE_HIT,
                httpStatusCode = null,
                elapsedMs = System.currentTimeMillis() - startMs,
            )
        } ?: return null

        emitProgress(
            key = key,
            url = url,
            state = WireCacheTransferState.CACHE_HIT,
            bytesReceived = hit.entry!!.sizeBytes,
            totalBytes = hit.entry!!.sizeBytes,
            filePath = hit.entry!!.filePath,
        )
        return hit
    }

    override suspend fun downloadFile(request: WireCacheRequest): WireCacheFetchResult =
        withContext(Dispatchers.IO) {
            ensureIndexLoaded()
            downloadCoalesced(request).awaitResult()
        }

    private suspend fun CompletableFuture<WireCacheFetchResult>.awaitResult(): WireCacheFetchResult =
        suspendCancellableCoroutine { continuation ->
            whenComplete { value, error ->
                if (!continuation.isActive) return@whenComplete
                if (error != null) {
                    val failure = unwrapDownloadError(error)
                    when (failure) {
                        is FlutterError -> continuation.resumeWithException(failure)
                        else -> continuation.resumeWithException(
                            FlutterError(
                                "DOWNLOAD_FAILED",
                                failure?.message ?: "Download failed",
                                null,
                            ),
                        )
                    }
                } else if (value != null) {
                    continuation.resume(value)
                } else {
                    continuation.resumeWithException(
                        FlutterError("DOWNLOAD_FAILED", "Download failed", null),
                    )
                }
            }
        }

    private fun executeDownloadRequest(
        request: WireCacheRequest,
        externalCancel: AtomicBoolean? = null,
    ): WireCacheFetchResult {
        val startMs = System.currentTimeMillis()
        val url = request.url.trim()
        if (url.isEmpty()) {
            throw FlutterError("INVALID_URL", "URL is required", null)
        }
        val tag = request.tag
        val ttlOverride = request.ttlSeconds
        val forceRefresh = request.forceRefresh
        val fallbackToCacheOnError = request.fallbackToCacheOnError
        val pinned = request.pinned
        val checksumAlgorithm = fromWireChecksumAlgorithm(request.checksumAlgorithm)
        val expectedChecksum = request.expectedChecksum?.trim()?.lowercase()

        val key = resolveKey(url, request.customKey)
        var existingRecord: CacheRecord? = null

        synchronized(indexLock) {
            val found = entries[key]
            if (found != null && File(found.filePath).exists()) {
                existingRecord = found
                if (!forceRefresh && !found.isExpired(startMs)) {
                    found.lastAccessedAtMs = startMs
                    found.hitCount += 1L
                    if (tag != null) found.tag = tag
                    if (pinned) found.pinned = true
                    hitCount += 1L
                    schedulePersistIndexLocked()
                    val wireEntry = found.toWire()
                    emitProgress(
                        key = key,
                        url = url,
                        state = WireCacheTransferState.CACHE_HIT,
                        bytesReceived = found.sizeBytes,
                        totalBytes = found.sizeBytes,
                        filePath = found.filePath,
                    )
                    return WireCacheFetchResult(
                        entry = wireEntry,
                        source = WireCacheResultSource.CACHE_HIT,
                        httpStatusCode = null,
                        elapsedMs = System.currentTimeMillis() - startMs,
                    )
                }
            }
            missCount += 1L
        }

        val cancelFlag = externalCancel ?: AtomicBoolean(false)
        val ownsCancel = externalCancel == null
        if (ownsCancel) {
            activeDownloads[key] = cancelFlag
        }
        emitProgress(key, url, WireCacheTransferState.STARTED, 0L, -1L)
        if (cancelFlag.get()) {
            if (ownsCancel) {
                activeDownloads.remove(key, cancelFlag)
            }
            throw FlutterError("CANCELED", "Download canceled for $key", null)
        }

        var tempFile: File? = null
        try {
            val conn = (URI.create(url).toURL().openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
                instanceFollowRedirects = true
            }

            for ((k, v) in defaultHeaders) {
                conn.setRequestProperty(k, v)
            }
            for ((k, v) in request.headers) {
                conn.setRequestProperty(k, v)
            }

            val existing = existingRecord
            if (respectHttpCacheHeaders && existing != null) {
                if (!existing.eTag.isNullOrBlank()) {
                    conn.setRequestProperty("If-None-Match", existing.eTag)
                }
                if (!existing.lastModified.isNullOrBlank()) {
                    conn.setRequestProperty("If-Modified-Since", existing.lastModified)
                }
            }

            conn.connect()
            val statusCode = conn.responseCode

            if (statusCode == HttpURLConnection.HTTP_NOT_MODIFIED && existing != null) {
                val now = System.currentTimeMillis()
                val ttlSec = ttlOverride ?: parseMaxAgeSeconds(conn.getHeaderField("Cache-Control"))
                    ?: defaultTtlSeconds
                val wireEntry = synchronized(indexLock) {
                    existing.lastAccessedAtMs = now
                    existing.expiresAtMs = now + ttlSec * 1000L
                    existing.hitCount += 1L
                    existing.eTag = conn.getHeaderField("ETag") ?: existing.eTag
                    existing.lastModified =
                        conn.getHeaderField("Last-Modified") ?: existing.lastModified
                    if (tag != null) existing.tag = tag
                    if (pinned) existing.pinned = true
                    entries[key] = existing
                    schedulePersistIndexLocked()
                    existing.toWire()
                }
                emitProgress(
                    key = key,
                    url = url,
                    state = WireCacheTransferState.CACHE_HIT,
                    bytesReceived = wireEntry.sizeBytes,
                    totalBytes = wireEntry.sizeBytes,
                    filePath = wireEntry.filePath,
                )
                return WireCacheFetchResult(
                    entry = wireEntry,
                    source = WireCacheResultSource.REVALIDATED,
                    httpStatusCode = 304L,
                    elapsedMs = System.currentTimeMillis() - startMs,
                )
            }

            if (statusCode !in 200..299) {
                throw FlutterError("HTTP_ERROR", "HTTP $statusCode for $url", statusCode.toLong())
            }

            val totalBytes = conn.contentLengthLong
            val contentType = conn.contentType?.substringBefore(';')?.trim()
            val resolvedExt = inferExtension(url, contentType, request.fileExtension)
            val cacheDir = getCacheRootDir()
            val workingTempFile = File(cacheDir, "$key.${System.nanoTime()}.tmp")
            tempFile = workingTempFile

            var bytesReceived = 0L
            var lastProgressEmitMs = 0L
            conn.inputStream.use { input ->
                FileOutputStream(workingTempFile).use { output ->
                    val buffer = ByteArray(16 * 1024)
                    var read = input.read(buffer)
                    while (read != -1) {
                        if (cancelFlag.get()) {
                            throw FlutterError("CANCELED", "Download canceled for $key", null)
                        }
                        output.write(buffer, 0, read)
                        bytesReceived += read
                        val nowMs = System.currentTimeMillis()
                        if (nowMs - lastProgressEmitMs >= 50L || bytesReceived == totalBytes) {
                            lastProgressEmitMs = nowMs
                            emitProgress(
                                key,
                                url,
                                WireCacheTransferState.IN_PROGRESS,
                                bytesReceived,
                                totalBytes,
                            )
                        }
                        read = input.read(buffer)
                    }
                    output.flush()
                }
            }

            var computedHash: String? = null
            if (checksumAlgorithm != "none") {
                computedHash = computeFileHash(workingTempFile, checksumAlgorithm)
                if (!expectedChecksum.isNullOrEmpty() && computedHash.lowercase() != expectedChecksum) {
                    workingTempFile.delete()
                    throw FlutterError(
                        "CHECKSUM_MISMATCH",
                        "Checksum mismatch: expected $expectedChecksum, got $computedHash",
                        null,
                    )
                }
            }

            val finalFile = File(cacheDir, "$key.$resolvedExt")
            if (finalFile.exists()) {
                finalFile.delete()
            }
            if (!workingTempFile.renameTo(finalFile)) {
                workingTempFile.copyTo(finalFile, overwrite = true)
                workingTempFile.delete()
            }

            val now = System.currentTimeMillis()
            val ttlSec = ttlOverride
                ?: (if (respectHttpCacheHeaders) parseMaxAgeSeconds(conn.getHeaderField("Cache-Control")) else null)
                ?: defaultTtlSeconds

            val record = CacheRecord(
                key = key,
                url = url,
                filePath = finalFile.absolutePath,
                sizeBytes = finalFile.length(),
                createdAtMs = now,
                lastAccessedAtMs = now,
                expiresAtMs = now + ttlSec * 1000L,
                hitCount = 1L,
                tag = tag,
                mimeType = contentType ?: "application/octet-stream",
                eTag = conn.getHeaderField("ETag"),
                lastModified = conn.getHeaderField("Last-Modified"),
                checksum = computedHash,
                checksumAlgorithm = checksumAlgorithm,
                pinned = pinned,
            )

            val wireEntry = synchronized(indexLock) {
                val old = entries[key]
                if (old != null) {
                    totalCachedBytes -= old.sizeBytes
                    if (old.filePath != finalFile.absolutePath) {
                        File(old.filePath).delete()
                    }
                }
                entries[key] = record
                totalCachedBytes += record.sizeBytes
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, key, checkOnlyFastPath = true)
                }
                schedulePersistIndexLocked(immediate = true)
                record.toWire()
            }

            emitProgress(
                key = key,
                url = url,
                state = WireCacheTransferState.COMPLETED,
                bytesReceived = wireEntry.sizeBytes,
                totalBytes = wireEntry.sizeBytes,
                filePath = wireEntry.filePath,
            )
            return WireCacheFetchResult(
                entry = wireEntry,
                source = WireCacheResultSource.NETWORK_DOWNLOAD,
                httpStatusCode = statusCode.toLong(),
                elapsedMs = System.currentTimeMillis() - startMs,
            )
        } catch (t: Throwable) {
            tempFile?.delete()
            val existing = existingRecord
            val isCanceled = t is FlutterError && t.code == "CANCELED"
            if (fallbackToCacheOnError && existing != null && File(existing.filePath).exists() && !isCanceled) {
                return WireCacheFetchResult(
                    entry = existing.toWire(),
                    source = WireCacheResultSource.STALE_CACHE_FALLBACK,
                    httpStatusCode = null,
                    elapsedMs = System.currentTimeMillis() - startMs,
                )
            }
            val state = if (isCanceled) WireCacheTransferState.CANCELED else WireCacheTransferState.FAILED
            emitProgress(key, url, state, 0L, -1L, null, t.message)
            if (t is FlutterError) throw t
            throw FlutterError("DOWNLOAD_FAILED", t.message ?: "Download failed", null)
        } finally {
            if (ownsCancel) {
                activeDownloads.remove(key, cancelFlag)
            }
        }
    }

    private fun parseMaxAgeSeconds(cacheControl: String?): Long? {
        if (cacheControl.isNullOrBlank()) return null
        val matcher = Pattern.compile("max-age=(\\d+)").matcher(cacheControl)
        return if (matcher.find()) {
            matcher.group(1)?.toLongOrNull()
        } else {
            null
        }
    }

    override suspend fun prefetchAll(requests: List<WireCacheRequest>): List<WireCacheEntry> =
        withContext(Dispatchers.IO) {
            ensureIndexLoaded()
            if (requests.isEmpty()) {
                return@withContext emptyList()
            }
            val futures = requests.map { downloadCoalesced(it) }
            val out = mutableListOf<WireCacheEntry>()
            for (future in futures) {
                try {
                    out.add(future.awaitResult().entry!!)
                } catch (_: Throwable) {
                }
            }
            out
        }

    override fun cancelDownload(keyOrUrl: String): Boolean {
        // Lock-free lookup against active downloads so cancellation never stalls behind disk I/O.
        val directFlag = activeDownloads[keyOrUrl]
        if (directFlag != null) {
            directFlag.set(true)
            return true
        }
        val shaKey = computeSha256String(keyOrUrl.toByteArray(Charsets.UTF_8))
        val shaFlag = activeDownloads[shaKey]
        if (shaFlag != null) {
            shaFlag.set(true)
            return true
        }
        return false
    }

    override suspend fun getFileFromCache(
        keyOrUrl: String,
        ignoreExpired: Boolean,
    ): WireCacheEntry? = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val key = resolveKey(keyOrUrl)

        val resultEntry = synchronized(indexLock) {
            val record = entries[key]
            if (record == null) {
                missCount += 1L
                return@synchronized null
            }
            val file = File(record.filePath)
            if (!file.exists()) {
                entries.remove(key)
                totalCachedBytes = (totalCachedBytes - record.sizeBytes).coerceAtLeast(0L)
                missCount += 1L
                schedulePersistIndexLocked()
                return@synchronized null
            }
            if (ignoreExpired && record.isExpired()) {
                missCount += 1L
                return@synchronized null
            }
            record.lastAccessedAtMs = System.currentTimeMillis()
            record.hitCount += 1L
            hitCount += 1L
            schedulePersistIndexLocked()
            record.toWire()
        } ?: return@withContext null

        emitProgress(
            key = key,
            url = resultEntry.url,
            state = WireCacheTransferState.CACHE_HIT,
            bytesReceived = resultEntry.sizeBytes,
            totalBytes = resultEntry.sizeBytes,
            filePath = resultEntry.filePath,
        )
        resultEntry
    }

    override suspend fun readCacheBytes(
        keyOrUrl: String,
        ignoreExpired: Boolean,
    ): ByteArray? = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val key = resolveKey(keyOrUrl)

        val targetPath = synchronized(indexLock) {
            val record = entries[key]
            if (record != null && (!ignoreExpired || !record.isExpired())) {
                val file = File(record.filePath)
                if (file.exists()) {
                    record.lastAccessedAtMs = System.currentTimeMillis()
                    record.hitCount += 1L
                    hitCount += 1L
                    schedulePersistIndexLocked()
                    record.filePath
                } else {
                    missCount += 1L
                    null
                }
            } else {
                missCount += 1L
                null
            }
        } ?: return@withContext null

        try {
            File(targetPath).readBytes()
        } catch (_: Exception) {
            null
        }
    }

    override suspend fun containsKey(keyOrUrl: String, ignoreExpired: Boolean): Boolean =
        withContext(Dispatchers.IO) {
            ensureIndexLoaded()
            val key = resolveKey(keyOrUrl)

            synchronized(indexLock) {
                val record = entries[key] ?: return@synchronized false
                if (!File(record.filePath).exists()) {
                    return@synchronized false
                }
                if (ignoreExpired && record.isExpired()) {
                    return@synchronized false
                }
                true
            }
        }

    override suspend fun putBytes(
        key: String,
        bytes: ByteArray,
        url: String?,
        fileExtension: String?,
        mimeType: String?,
        tag: String?,
        ttlSeconds: Long?,
        pinned: Boolean,
    ): WireCacheEntry = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val cleanKey = key.trim()
        if (cleanKey.isEmpty()) {
            throw FlutterError("INVALID_ARGS", "key and bytes are required", null)
        }
        val effectiveUrl = url ?: "local://$cleanKey"
        val effectiveMime = mimeType ?: "application/octet-stream"
        val effectiveTtl = ttlSeconds ?: defaultTtlSeconds

        try {
            val ext = inferExtension(effectiveUrl, effectiveMime, fileExtension)
            val destFile = File(getCacheRootDir(), "$cleanKey.$ext")
            destFile.writeBytes(bytes)
            val checksum = computeSha256String(bytes)
            val now = System.currentTimeMillis()

            val record = CacheRecord(
                key = cleanKey,
                url = effectiveUrl,
                filePath = destFile.absolutePath,
                sizeBytes = bytes.size.toLong(),
                createdAtMs = now,
                lastAccessedAtMs = now,
                expiresAtMs = now + effectiveTtl * 1000L,
                hitCount = 1L,
                tag = tag,
                mimeType = effectiveMime,
                eTag = null,
                lastModified = null,
                checksum = checksum,
                checksumAlgorithm = "sha256",
                pinned = pinned,
            )
            synchronized(indexLock) {
                val previous = entries[cleanKey]
                if (previous != null) {
                    totalCachedBytes -= previous.sizeBytes
                }
                entries[cleanKey] = record
                totalCachedBytes += record.sizeBytes
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, cleanKey, checkOnlyFastPath = true)
                }
                schedulePersistIndexLocked()
                record.toWire()
            }
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("PUT_BYTES_FAILED", e.message, null)
        }
    }

    override suspend fun putFile(
        key: String,
        sourceFilePath: String,
        url: String?,
        fileExtension: String?,
        mimeType: String?,
        tag: String?,
        ttlSeconds: Long?,
        pinned: Boolean,
    ): WireCacheEntry = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val cleanKey = key.trim()
        val cleanSource = sourceFilePath.trim()
        val sourceFile = File(cleanSource)
        if (cleanKey.isEmpty() || !sourceFile.exists()) {
            throw FlutterError("INVALID_SOURCE", "Source file does not exist: $cleanSource", null)
        }
        val effectiveUrl = url ?: "file://$cleanSource"
        val effectiveExt = fileExtension ?: sourceFile.extension.takeIf { it.isNotEmpty() }
        val effectiveMime = mimeType ?: "application/octet-stream"
        val effectiveTtl = ttlSeconds ?: defaultTtlSeconds

        try {
            val ext = inferExtension(effectiveUrl, effectiveMime, effectiveExt)
            val destFile = File(getCacheRootDir(), "$cleanKey.$ext")
            sourceFile.copyTo(destFile, overwrite = true)
            val checksum = computeFileHash(destFile, "sha256")
            val now = System.currentTimeMillis()

            val record = CacheRecord(
                key = cleanKey,
                url = effectiveUrl,
                filePath = destFile.absolutePath,
                sizeBytes = destFile.length(),
                createdAtMs = now,
                lastAccessedAtMs = now,
                expiresAtMs = now + effectiveTtl * 1000L,
                hitCount = 1L,
                tag = tag,
                mimeType = effectiveMime,
                eTag = null,
                lastModified = null,
                checksum = checksum,
                checksumAlgorithm = "sha256",
                pinned = pinned,
            )
            synchronized(indexLock) {
                val previous = entries[cleanKey]
                if (previous != null) {
                    totalCachedBytes -= previous.sizeBytes
                }
                entries[cleanKey] = record
                totalCachedBytes += record.sizeBytes
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, cleanKey, checkOnlyFastPath = true)
                }
                schedulePersistIndexLocked()
                record.toWire()
            }
        } catch (e: FlutterError) {
            throw e
        } catch (e: Exception) {
            throw FlutterError("PUT_FILE_FAILED", e.message, null)
        }
    }

    override suspend fun setPinned(keyOrUrl: String, pinned: Boolean): Boolean =
        withContext(Dispatchers.IO) {
            ensureIndexLoaded()
            val key = resolveKey(keyOrUrl)

            synchronized(indexLock) {
                val record = entries[key] ?: return@synchronized false
                record.pinned = pinned
                schedulePersistIndexLocked()
                true
            }
        }

    override suspend fun removeFile(keyOrUrl: String): Boolean = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val key = resolveKey(keyOrUrl)

        val removed = synchronized(indexLock) {
            val existing = entries.remove(key) ?: return@synchronized null
            totalCachedBytes = (totalCachedBytes - existing.sizeBytes).coerceAtLeast(0L)
            schedulePersistIndexLocked()
            existing
        } ?: return@withContext false

        File(removed.filePath).delete()
        true
    }

    override suspend fun removeByTag(tag: String): Long = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val paths = mutableListOf<String>()
        val count = synchronized(indexLock) {
            val keys = entries.values.filter { it.tag == tag }.map { it.key }
            for (k in keys) {
                val removed = entries.remove(k)
                if (removed != null) {
                    totalCachedBytes = (totalCachedBytes - removed.sizeBytes).coerceAtLeast(0L)
                    paths.add(removed.filePath)
                }
            }
            if (keys.isNotEmpty()) {
                schedulePersistIndexLocked()
            }
            keys.size.toLong()
        }
        for (path in paths) {
            File(path).delete()
        }
        count
    }

    override suspend fun removeExpired(): Long = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val paths = mutableListOf<String>()
        val removedCount = synchronized(indexLock) {
            val removed = removeExpiredLocked(paths)
            if (removed > 0) {
                schedulePersistIndexLocked()
            }
            removed.toLong()
        }
        for (path in paths) {
            File(path).delete()
        }
        removedCount
    }

    private fun removeExpiredLocked(deletedPathsOut: MutableList<String>? = null): Int {
        val now = System.currentTimeMillis()
        val expiredKeys = entries.values.filter { !it.pinned && it.isExpired(now) }.map { it.key }
        for (k in expiredKeys) {
            val removed = entries.remove(k)
            if (removed != null) {
                totalCachedBytes = (totalCachedBytes - removed.sizeBytes).coerceAtLeast(0L)
                if (deletedPathsOut != null) {
                    deletedPathsOut.add(removed.filePath)
                } else {
                    File(removed.filePath).delete()
                }
            }
        }
        evictionCount += expiredKeys.size
        return expiredKeys.size
    }

    override suspend fun trimToSize(maxBytes: Long): Long = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val paths = mutableListOf<String>()
        val evicted = synchronized(indexLock) {
            val count = enforceQuotaLocked(maxBytes, null, checkOnlyFastPath = false, paths)
            if (count > 0) {
                schedulePersistIndexLocked()
            }
            count.toLong()
        }
        for (path in paths) {
            File(path).delete()
        }
        evicted
    }

    private fun enforceQuotaLocked(
        targetMaxBytes: Long,
        protectedKey: String?,
        checkOnlyFastPath: Boolean,
        deletedPathsOut: MutableList<String>? = null,
    ): Int {
        if (checkOnlyFastPath && totalCachedBytes <= targetMaxBytes && entries.size <= maxEntries) {
            return 0
        }

        var evicted = removeExpiredLocked(deletedPathsOut)
        if (evictionPolicy == "ttlOnly") {
            return evicted
        }

        if (totalCachedBytes <= targetMaxBytes && entries.size <= maxEntries) {
            return evicted
        }

        val candidates = entries.values
            .filter { !it.pinned && it.key != protectedKey }
            .sortedWith { a, b ->
                when (evictionPolicy) {
                    "lfu" -> {
                        val cmp = a.hitCount.compareTo(b.hitCount)
                        if (cmp != 0) cmp else a.lastAccessedAtMs.compareTo(b.lastAccessedAtMs)
                    }
                    "fifo" -> a.createdAtMs.compareTo(b.createdAtMs)
                    else -> a.lastAccessedAtMs.compareTo(b.lastAccessedAtMs)
                }
            }

        for (candidate in candidates) {
            if (totalCachedBytes <= targetMaxBytes && entries.size <= maxEntries) {
                break
            }
            val removed = entries.remove(candidate.key)
            if (removed != null) {
                if (deletedPathsOut != null) {
                    deletedPathsOut.add(removed.filePath)
                } else {
                    File(removed.filePath).delete()
                }
                totalCachedBytes = (totalCachedBytes - removed.sizeBytes).coerceAtLeast(0L)
                evicted += 1
                evictionCount += 1L
            }
        }
        return evicted
    }

    override suspend fun clearAll(includePinned: Boolean): Long = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        try {
            // Drop index entries under the lock, then delete files outside it so
            // concurrent listEntries/getStats are not blocked on disk I/O.
            val paths = mutableListOf<String>()
            val removedCount = synchronized(indexLock) {
                val keys = entries.values.filter { includePinned || !it.pinned }.map { it.key }
                for (k in keys) {
                    val removed = entries.remove(k)
                    if (removed != null) {
                        totalCachedBytes = (totalCachedBytes - removed.sizeBytes).coerceAtLeast(0L)
                        paths.add(removed.filePath)
                    }
                }
                schedulePersistIndexLocked(immediate = true)
                keys.size.toLong()
            }
            for (path in paths) {
                File(path).delete()
            }
            removedCount
        } catch (e: Exception) {
            throw FlutterError("CLEAR_ALL_FAILED", e.message, null)
        }
    }

    override suspend fun listEntries(tag: String?, includeExpired: Boolean): List<WireCacheEntry> =
        withContext(Dispatchers.IO) {
            ensureIndexLoaded()
            val now = System.currentTimeMillis()
            synchronized(indexLock) {
                entries.values
                    .filter { record ->
                        (tag == null || record.tag == tag) && (includeExpired || !record.isExpired(now))
                    }
                    .sortedByDescending { it.lastAccessedAtMs }
                    .map { it.toWire() }
            }
        }

    override suspend fun getStats(): WireCacheStats = withContext(Dispatchers.IO) {
        ensureIndexLoaded()
        val now = System.currentTimeMillis()
        synchronized(indexLock) {
            var totalBytes = 0L
            var expiredCount = 0L
            var pinnedCount = 0L
            val bytesByTag = mutableMapOf<String, Long>()

            for (record in entries.values) {
                totalBytes += record.sizeBytes
                if (record.isExpired(now)) expiredCount++
                if (record.pinned) pinnedCount++
                val tagKey = if (record.tag.isNullOrBlank()) "untagged" else record.tag!!
                bytesByTag[tagKey] = (bytesByTag[tagKey] ?: 0L) + record.sizeBytes
            }
            totalCachedBytes = totalBytes

            WireCacheStats(
                totalEntries = entries.size.toLong(),
                totalBytes = totalBytes,
                expiredEntries = expiredCount,
                pinnedEntries = pinnedCount,
                maxDiskCacheBytes = maxDiskCacheBytes,
                cacheDirectoryPath = getCacheRootDir().absolutePath,
                hitCount = hitCount,
                missCount = missCount,
                evictionCount = evictionCount,
                bytesByTag = bytesByTag,
            )
        }
    }

    override fun getCapabilities(): WireCachePlatformCapabilities {
        val defaultRoot = if (::applicationContext.isInitialized) {
            File(applicationContext.cacheDir, cacheSubdirectory).absolutePath
        } else {
            ""
        }
        return WireCachePlatformCapabilities(
            platformName = "android",
            supportsFileSystemPaths = true,
            supportsConditionalHttpRevalidation = true,
            supportsNativeCryptoHash = true,
            supportsLowDiskSpaceNotifications = true,
            storageMechanism = "Context.getCacheDir() + HttpURLConnection + Debounced Index",
            defaultCacheRootPath = defaultRoot,
        )
    }

    companion object {
        private fun newProgressExecutor(): ExecutorService {
            return Executors.newSingleThreadExecutor { r ->
                Thread(r, "xuehua-cache-progress").apply { isDaemon = true }
            }
        }

        private fun toWireChecksumAlgorithm(value: String): WireCacheChecksumAlgorithm {
            return when (value.lowercase()) {
                "md5" -> WireCacheChecksumAlgorithm.MD5
                "sha256" -> WireCacheChecksumAlgorithm.SHA256
                else -> WireCacheChecksumAlgorithm.NONE
            }
        }

        private fun fromWireChecksumAlgorithm(value: WireCacheChecksumAlgorithm): String {
            return when (value) {
                WireCacheChecksumAlgorithm.MD5 -> "md5"
                WireCacheChecksumAlgorithm.SHA256 -> "sha256"
                WireCacheChecksumAlgorithm.NONE -> "none"
            }
        }

        private fun fromWireEvictionPolicy(value: WireCacheEvictionPolicy): String {
            return when (value) {
                WireCacheEvictionPolicy.LRU -> "lru"
                WireCacheEvictionPolicy.LFU -> "lfu"
                WireCacheEvictionPolicy.FIFO -> "fifo"
                WireCacheEvictionPolicy.TTL_ONLY -> "ttlOnly"
            }
        }
    }
}
