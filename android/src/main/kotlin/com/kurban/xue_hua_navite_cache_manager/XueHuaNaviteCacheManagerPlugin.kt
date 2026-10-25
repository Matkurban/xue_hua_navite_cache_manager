package com.kurban.xue_hua_navite_cache_manager

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import java.util.regex.Pattern

/**
 * Native Android implementation of `xue_hua_navite_cache_manager`.
 *
 * Provides thread-safe network file downloading, conditional HTTP revalidation (ETag / Last-Modified),
 * MD5 and SHA-256 verification, atomic disk persistence under `context.cacheDir`, and
 * LRU / LFU / FIFO / TTL quota eviction.
 */
class XueHuaNaviteCacheManagerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var applicationContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val indexLock = Any()
    private val executor = Executors.newCachedThreadPool()

    // Configuration fields
    @Volatile
    private var maxDiskCacheBytes: Long = 500L * 1024L * 1024L

    @Volatile
    private var maxEntries: Int = 2000

    @Volatile
    private var defaultTtlSeconds: Long = 7L * 24L * 3600L

    @Volatile
    private var evictionPolicy: String = "lru"

    @Volatile
    private var cacheSubdirectory: String = "xue_hua_network_cache"

    @Volatile
    private var maxConcurrentDownloads: Int = 4

    @Volatile
    private var downloadPermits = Semaphore(4)

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

    // Cache index and telemetry counters
    private val entries = LinkedHashMap<String, CacheRecord>()
    private var hitCount: Long = 0L
    private var missCount: Long = 0L
    private var evictionCount: Long = 0L
    private var indexLoaded: Boolean = false

    // Active download cancellation flags
    private val activeDownloads = ConcurrentHashMap<String, AtomicBoolean>()

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
        var pinned: Boolean
    ) {
        fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean {
            return expiresAtMs in 1..<nowMs
        }

        fun toMap(): Map<String, Any?> {
            return mapOf(
                "key" to key,
                "url" to url,
                "filePath" to filePath,
                "sizeBytes" to sizeBytes,
                "createdAtMs" to createdAtMs,
                "lastAccessedAtMs" to lastAccessedAtMs,
                "expiresAtMs" to expiresAtMs,
                "hitCount" to hitCount,
                "tag" to tag,
                "mimeType" to mimeType,
                "eTag" to eTag,
                "lastModified" to lastModified,
                "checksum" to checksum,
                "checksumAlgorithm" to checksumAlgorithm,
                "pinned" to pinned
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
                    pinned = obj.optBoolean("pinned", false)
                )
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        methodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "xue_hua_navite_cache_manager"
        )
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            "xue_hua_navite_cache_manager/events"
        )
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitProgress(
        key: String,
        url: String,
        state: String,
        bytesReceived: Long,
        totalBytes: Long,
        filePath: String? = null,
        errorMessage: String? = null
    ) {
        val payload = mapOf<String, Any?>(
            "key" to key,
            "url" to url,
            "state" to state,
            "bytesReceived" to bytesReceived,
            "totalBytes" to totalBytes,
            "filePath" to filePath,
            "errorMessage" to errorMessage
        )
        mainHandler.post {
            eventSink?.success(payload)
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
                    val f = File(record.filePath)
                    if (record.key.isNotEmpty() && f.exists()) {
                        entries[record.key] = record
                    }
                }
            } catch (_: Exception) {
                // Recover cleanly if index file was corrupted.
            }
        }
    }

    private fun persistIndexLocked() {
        try {
            val root = JSONObject()
            root.put("hitCount", hitCount)
            root.put("missCount", missCount)
            root.put("evictionCount", evictionCount)
            val arr = JSONArray()
            for (record in entries.values) {
                arr.put(record.toJson())
            }
            root.put("entries", arr)
            val indexFile = getIndexFile()
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

    override fun onMethodCall(call: MethodCall, result: Result) {
        ensureIndexLoaded()
        when (call.method) {
            "configure" -> handleConfigure(call, result)
            "downloadFile" -> executor.execute { handleDownloadFile(call, result) }
            "prefetchAll" -> executor.execute { handlePrefetchAll(call, result) }
            "cancelDownload" -> handleCancelDownload(call, result)
            "getFileFromCache" -> handleGetFileFromCache(call, result)
            "readCacheBytes" -> executor.execute { handleReadCacheBytes(call, result) }
            "containsKey" -> handleContainsKey(call, result)
            "putBytes" -> executor.execute { handlePutBytes(call, result) }
            "putFile" -> executor.execute { handlePutFile(call, result) }
            "setPinned" -> handleSetPinned(call, result)
            "removeFile" -> handleRemoveFile(call, result)
            "removeByTag" -> handleRemoveByTag(call, result)
            "removeExpired" -> handleRemoveExpired(result)
            "trimToSize" -> handleTrimToSize(call, result)
            "clearAll" -> handleClearAll(call, result)
            "listEntries" -> handleListEntries(call, result)
            "getStats" -> handleGetStats(result)
            "getCapabilities" -> handleGetCapabilities(result)
            else -> result.notImplemented()
        }
    }

    private fun handleConfigure(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val prevSubdir = cacheSubdirectory
        maxDiskCacheBytes = (args["maxDiskCacheBytes"] as? Number)?.toLong() ?: maxDiskCacheBytes
        maxEntries = (args["maxEntries"] as? Number)?.toInt() ?: maxEntries
        defaultTtlSeconds = (args["defaultTtlSeconds"] as? Number)?.toLong() ?: defaultTtlSeconds
        evictionPolicy = (args["evictionPolicy"] as? String) ?: evictionPolicy
        cacheSubdirectory =
            (args["cacheSubdirectory"] as? String)?.takeIf { it.isNotBlank() } ?: cacheSubdirectory
        val newConcurrency =
            ((args["maxConcurrentDownloads"] as? Number)?.toInt() ?: maxConcurrentDownloads)
                .coerceAtLeast(1)
        if (newConcurrency != maxConcurrentDownloads) {
            maxConcurrentDownloads = newConcurrency
            downloadPermits = Semaphore(newConcurrency)
        }
        connectTimeoutMs = (args["connectTimeoutMs"] as? Number)?.toInt() ?: connectTimeoutMs
        readTimeoutMs = (args["readTimeoutMs"] as? Number)?.toInt() ?: readTimeoutMs
        respectHttpCacheHeaders =
            (args["respectHttpCacheHeaders"] as? Boolean) ?: respectHttpCacheHeaders
        autoTrimOnWrite = (args["autoTrimOnWrite"] as? Boolean) ?: autoTrimOnWrite

        val rawHeaders = args["defaultHeaders"] as? Map<*, *>
        if (rawHeaders != null) {
            val map = mutableMapOf<String, String>()
            for ((k, v) in rawHeaders) {
                if (k != null && v != null) {
                    map[k.toString()] = v.toString()
                }
            }
            defaultHeaders = map
        }

        if (prevSubdir != cacheSubdirectory) {
            synchronized(indexLock) {
                indexLoaded = false
            }
            ensureIndexLoaded()
        }

        if (autoTrimOnWrite) {
            synchronized(indexLock) {
                enforceQuotaLocked(maxDiskCacheBytes, null)
                persistIndexLocked()
            }
        }
        result.success(null)
    }

    private fun handleDownloadFile(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        try {
            val fetchResult = executeDownloadRequest(args)
            mainHandler.post { result.success(fetchResult) }
        } catch (e: CustomCacheException) {
            mainHandler.post { result.error(e.code, e.message, e.details) }
        } catch (e: Exception) {
            mainHandler.post {
                result.error(
                    "DOWNLOAD_FAILED",
                    e.message ?: "Download failed",
                    null
                )
            }
        }
    }

    private class CustomCacheException(
        val code: String,
        override val message: String,
        val details: Any? = null
    ) : Exception(message)

    private fun executeDownloadRequest(args: Map<*, *>): Map<String, Any?> {
        val startMs = System.currentTimeMillis()
        val url = (args["url"] as? String)?.trim() ?: throw CustomCacheException(
            "INVALID_URL",
            "URL is required"
        )
        val customKey = args["customKey"] as? String
        val tag = args["tag"] as? String
        val fileExtension = args["fileExtension"] as? String
        val ttlOverride = (args["ttlSeconds"] as? Number)?.toLong()
        val forceRefresh = (args["forceRefresh"] as? Boolean) ?: false
        val fallbackToCacheOnError = (args["fallbackToCacheOnError"] as? Boolean) ?: true
        val pinned = (args["pinned"] as? Boolean) ?: false
        val checksumAlgorithm = (args["checksumAlgorithm"] as? String) ?: "none"
        val expectedChecksum = (args["expectedChecksum"] as? String)?.trim()?.lowercase()

        val key = resolveKey(url, customKey)
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
                    persistIndexLocked()
                    emitProgress(
                        key,
                        url,
                        "cacheHit",
                        found.sizeBytes,
                        found.sizeBytes,
                        found.filePath
                    )
                    return mapOf(
                        "entry" to found.toMap(),
                        "source" to "cacheHit",
                        "httpStatusCode" to null,
                        "elapsedMs" to (System.currentTimeMillis() - startMs)
                    )
                }
            }
            missCount += 1L
        }

        val cancelFlag = AtomicBoolean(false)
        activeDownloads[key] = cancelFlag
        emitProgress(key, url, "started", 0L, -1L)

        val semaphore = downloadPermits
        semaphore.acquire()
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
            val reqHeaders = args["headers"] as? Map<*, *>
            if (reqHeaders != null) {
                for ((k, v) in reqHeaders) {
                    if (k != null && v != null) {
                        conn.setRequestProperty(k.toString(), v.toString())
                    }
                }
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
                synchronized(indexLock) {
                    existing.lastAccessedAtMs = now
                    existing.expiresAtMs = now + ttlSec * 1000L
                    existing.hitCount += 1L
                    existing.eTag = conn.getHeaderField("ETag") ?: existing.eTag
                    existing.lastModified =
                        conn.getHeaderField("Last-Modified") ?: existing.lastModified
                    if (tag != null) existing.tag = tag
                    if (pinned) existing.pinned = true
                    entries[key] = existing
                    persistIndexLocked()
                }
                emitProgress(
                    key,
                    url,
                    "cacheHit",
                    existing.sizeBytes,
                    existing.sizeBytes,
                    existing.filePath
                )
                return mapOf(
                    "entry" to existing.toMap(),
                    "source" to "revalidated",
                    "httpStatusCode" to 304,
                    "elapsedMs" to (System.currentTimeMillis() - startMs)
                )
            }

            if (statusCode !in 200..299) {
                throw CustomCacheException("HTTP_ERROR", "HTTP $statusCode for $url", statusCode)
            }

            val totalBytes = conn.contentLengthLong
            val contentType = conn.contentType?.substringBefore(';')?.trim()
            val resolvedExt = inferExtension(url, contentType, fileExtension)
            val cacheDir = getCacheRootDir()
            val workingTempFile = File(cacheDir, "$key.${System.nanoTime()}.tmp")
            tempFile = workingTempFile

            var bytesReceived = 0L
            conn.inputStream.use { input ->
                FileOutputStream(workingTempFile).use { output ->
                    val buffer = ByteArray(16 * 1024)
                    var read = input.read(buffer)
                    while (read != -1) {
                        if (cancelFlag.get()) {
                            throw CustomCacheException("CANCELED", "Download canceled for $key")
                        }
                        output.write(buffer, 0, read)
                        bytesReceived += read
                        emitProgress(key, url, "inProgress", bytesReceived, totalBytes)
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
                    throw CustomCacheException(
                        "CHECKSUM_MISMATCH",
                        "Checksum mismatch: expected $expectedChecksum, got $computedHash"
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
                pinned = pinned
            )

            synchronized(indexLock) {
                val old = entries[key]
                if (old != null && old.filePath != finalFile.absolutePath) {
                    File(old.filePath).delete()
                }
                entries[key] = record
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, key)
                }
                persistIndexLocked()
            }

            emitProgress(key, url, "completed", record.sizeBytes, record.sizeBytes, record.filePath)
            return mapOf(
                "entry" to record.toMap(),
                "source" to "networkDownload",
                "httpStatusCode" to statusCode,
                "elapsedMs" to (System.currentTimeMillis() - startMs)
            )
        } catch (e: Exception) {
            tempFile?.delete()
            val existing = existingRecord
            if (fallbackToCacheOnError && existing != null && File(existing.filePath).exists() &&
                (e !is CustomCacheException || e.code != "CANCELED")
            ) {
                return mapOf(
                    "entry" to existing.toMap(),
                    "source" to "staleCacheFallback",
                    "httpStatusCode" to null,
                    "elapsedMs" to (System.currentTimeMillis() - startMs)
                )
            }
            val state =
                if (e is CustomCacheException && e.code == "CANCELED") "canceled" else "failed"
            emitProgress(key, url, state, 0L, -1L, null, e.message)
            throw e
        } finally {
            semaphore.release()
            activeDownloads.remove(key)
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

    private fun handlePrefetchAll(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val reqList = args["requests"] as? List<*> ?: emptyList<Any>()
        val out = mutableListOf<Map<*, *>>()
        for (item in reqList) {
            val map = item as? Map<*, *> ?: continue
            try {
                val res = executeDownloadRequest(map)
                val entryMap = res["entry"] as? Map<*, *>
                if (entryMap != null) {
                    out.add(entryMap)
                }
            } catch (_: Exception) {
            }
        }
        mainHandler.post { result.success(out) }
    }

    private fun handleCancelDownload(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val key = resolveKey(keyOrUrl)
        val flag = activeDownloads[key] ?: activeDownloads[keyOrUrl]
        if (flag != null) {
            flag.set(true)
            result.success(true)
        } else {
            result.success(false)
        }
    }

    private fun handleGetFileFromCache(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val ignoreExpired = (args["ignoreExpired"] as? Boolean) ?: true
        val key = resolveKey(keyOrUrl)

        synchronized(indexLock) {
            val record = entries[key]
            if (record == null) {
                missCount += 1L
                result.success(null)
                return
            }
            val file = File(record.filePath)
            if (!file.exists()) {
                entries.remove(key)
                missCount += 1L
                persistIndexLocked()
                result.success(null)
                return
            }
            if (ignoreExpired && record.isExpired()) {
                missCount += 1L
                result.success(null)
                return
            }
            record.lastAccessedAtMs = System.currentTimeMillis()
            record.hitCount += 1L
            hitCount += 1L
            persistIndexLocked()
            result.success(record.toMap())
        }
    }

    private fun handleReadCacheBytes(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val ignoreExpired = (args["ignoreExpired"] as? Boolean) ?: true
        val key = resolveKey(keyOrUrl)

        var resolvedFilePath: String? = null
        synchronized(indexLock) {
            val record = entries[key]
            if (record != null && (!ignoreExpired || !record.isExpired())) {
                val file = File(record.filePath)
                if (file.exists()) {
                    record.lastAccessedAtMs = System.currentTimeMillis()
                    record.hitCount += 1L
                    hitCount += 1L
                    persistIndexLocked()
                    resolvedFilePath = record.filePath
                }
            } else {
                missCount += 1L
            }
        }

        val targetPath = resolvedFilePath
        if (targetPath == null) {
            mainHandler.post { result.success(null) }
            return
        }
        try {
            val bytes = File(targetPath).readBytes()
            mainHandler.post { result.success(bytes) }
        } catch (_: Exception) {
            mainHandler.post { result.success(null) }
        }
    }

    private fun handleContainsKey(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val ignoreExpired = (args["ignoreExpired"] as? Boolean) ?: true
        val key = resolveKey(keyOrUrl)

        synchronized(indexLock) {
            val record = entries[key]
            if (record == null || !File(record.filePath).exists()) {
                result.success(false)
                return
            }
            if (ignoreExpired && record.isExpired()) {
                result.success(false)
                return
            }
            result.success(true)
        }
    }

    private fun handlePutBytes(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val key = (args["key"] as? String)?.trim() ?: ""
        val bytes = args["bytes"] as? ByteArray
        if (key.isEmpty() || bytes == null) {
            mainHandler.post { result.error("INVALID_ARGS", "key and bytes are required", null) }
            return
        }
        val url = (args["url"] as? String) ?: "local://$key"
        val fileExtension = args["fileExtension"] as? String
        val mimeType = (args["mimeType"] as? String) ?: "application/octet-stream"
        val tag = args["tag"] as? String
        val ttlSeconds = (args["ttlSeconds"] as? Number)?.toLong() ?: defaultTtlSeconds
        val pinned = (args["pinned"] as? Boolean) ?: false

        try {
            val ext = inferExtension(url, mimeType, fileExtension)
            val destFile = File(getCacheRootDir(), "$key.$ext")
            destFile.writeBytes(bytes)
            val checksum = computeSha256String(bytes)
            val now = System.currentTimeMillis()

            val record = CacheRecord(
                key = key,
                url = url,
                filePath = destFile.absolutePath,
                sizeBytes = bytes.size.toLong(),
                createdAtMs = now,
                lastAccessedAtMs = now,
                expiresAtMs = now + ttlSeconds * 1000L,
                hitCount = 1L,
                tag = tag,
                mimeType = mimeType,
                eTag = null,
                lastModified = null,
                checksum = checksum,
                checksumAlgorithm = "sha256",
                pinned = pinned
            )
            synchronized(indexLock) {
                entries[key] = record
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, key)
                }
                persistIndexLocked()
            }
            mainHandler.post { result.success(record.toMap()) }
        } catch (e: Exception) {
            mainHandler.post { result.error("PUT_BYTES_FAILED", e.message, null) }
        }
    }

    private fun handlePutFile(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val key = (args["key"] as? String)?.trim() ?: ""
        val sourceFilePath = (args["sourceFilePath"] as? String)?.trim() ?: ""
        val sourceFile = File(sourceFilePath)
        if (key.isEmpty() || !sourceFile.exists()) {
            mainHandler.post {
                result.error(
                    "INVALID_SOURCE",
                    "Source file does not exist: $sourceFilePath",
                    null
                )
            }
            return
        }
        val url = (args["url"] as? String) ?: "file://$sourceFilePath"
        val fileExtension =
            args["fileExtension"] as? String ?: sourceFile.extension.takeIf { it.isNotEmpty() }
        val mimeType = (args["mimeType"] as? String) ?: "application/octet-stream"
        val tag = args["tag"] as? String
        val ttlSeconds = (args["ttlSeconds"] as? Number)?.toLong() ?: defaultTtlSeconds
        val pinned = (args["pinned"] as? Boolean) ?: false

        try {
            val ext = inferExtension(url, mimeType, fileExtension)
            val destFile = File(getCacheRootDir(), "$key.$ext")
            sourceFile.copyTo(destFile, overwrite = true)
            val checksum = computeFileHash(destFile, "sha256")
            val now = System.currentTimeMillis()

            val record = CacheRecord(
                key = key,
                url = url,
                filePath = destFile.absolutePath,
                sizeBytes = destFile.length(),
                createdAtMs = now,
                lastAccessedAtMs = now,
                expiresAtMs = now + ttlSeconds * 1000L,
                hitCount = 1L,
                tag = tag,
                mimeType = mimeType,
                eTag = null,
                lastModified = null,
                checksum = checksum,
                checksumAlgorithm = "sha256",
                pinned = pinned
            )
            synchronized(indexLock) {
                entries[key] = record
                if (autoTrimOnWrite) {
                    enforceQuotaLocked(maxDiskCacheBytes, key)
                }
                persistIndexLocked()
            }
            mainHandler.post { result.success(record.toMap()) }
        } catch (e: Exception) {
            mainHandler.post { result.error("PUT_FILE_FAILED", e.message, null) }
        }
    }

    private fun handleSetPinned(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val pinned = (args["pinned"] as? Boolean) ?: false
        val key = resolveKey(keyOrUrl)

        synchronized(indexLock) {
            val record = entries[key]
            if (record == null) {
                result.success(false)
                return
            }
            record.pinned = pinned
            persistIndexLocked()
            result.success(true)
        }
    }

    private fun handleRemoveFile(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val keyOrUrl = (args["keyOrUrl"] as? String) ?: ""
        val key = resolveKey(keyOrUrl)

        synchronized(indexLock) {
            val removed = entries.remove(key)
            if (removed == null) {
                result.success(false)
                return
            }
            File(removed.filePath).delete()
            persistIndexLocked()
            result.success(true)
        }
    }

    private fun handleRemoveByTag(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val tag = (args["tag"] as? String) ?: ""
        synchronized(indexLock) {
            val keys = entries.values.filter { it.tag == tag }.map { it.key }
            for (k in keys) {
                val removed = entries.remove(k)
                if (removed != null) {
                    File(removed.filePath).delete()
                }
            }
            if (keys.isNotEmpty()) {
                persistIndexLocked()
            }
            result.success(keys.size)
        }
    }

    private fun handleRemoveExpired(result: Result) {
        synchronized(indexLock) {
            val count = removeExpiredLocked()
            if (count > 0) {
                persistIndexLocked()
            }
            result.success(count)
        }
    }

    private fun removeExpiredLocked(): Int {
        val now = System.currentTimeMillis()
        val expiredKeys = entries.values.filter { !it.pinned && it.isExpired(now) }.map { it.key }
        for (k in expiredKeys) {
            val removed = entries.remove(k)
            if (removed != null) {
                File(removed.filePath).delete()
            }
        }
        evictionCount += expiredKeys.size
        return expiredKeys.size
    }

    private fun handleTrimToSize(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val targetMax = (args["maxBytes"] as? Number)?.toLong() ?: maxDiskCacheBytes
        synchronized(indexLock) {
            val evicted = enforceQuotaLocked(targetMax, null)
            if (evicted > 0) {
                persistIndexLocked()
            }
            result.success(evicted)
        }
    }

    private fun enforceQuotaLocked(targetMaxBytes: Long, protectedKey: String?): Int {
        var evicted = removeExpiredLocked()
        if (evictionPolicy == "ttlOnly") {
            return evicted
        }

        var totalBytes = entries.values.sumOf { it.sizeBytes }
        if (totalBytes <= targetMaxBytes && entries.size <= maxEntries) {
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

        for ((candidateKey) in candidates) {
            if (totalBytes <= targetMaxBytes && entries.size <= maxEntries) {
                break
            }
            val removed = entries.remove(candidateKey)
            if (removed != null) {
                File(removed.filePath).delete()
                totalBytes -= removed.sizeBytes
                evicted += 1
                evictionCount += 1L
            }
        }
        return evicted
    }

    private fun handleClearAll(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val includePinned = (args["includePinned"] as? Boolean) ?: true
        synchronized(indexLock) {
            val keys = entries.values.filter { includePinned || !it.pinned }.map { it.key }
            for (k in keys) {
                val removed = entries.remove(k)
                if (removed != null) {
                    File(removed.filePath).delete()
                }
            }
            persistIndexLocked()
            result.success(keys.size)
        }
    }

    private fun handleListEntries(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val tag = args["tag"] as? String
        val includeExpired = (args["includeExpired"] as? Boolean) ?: true
        val now = System.currentTimeMillis()

        synchronized(indexLock) {
            val filtered = entries.values.filter { record ->
                (tag == null || record.tag == tag) && (includeExpired || !record.isExpired(now))
            }.sortedByDescending { it.lastAccessedAtMs }
                .map { it.toMap() }
            result.success(filtered)
        }
    }

    private fun handleGetStats(result: Result) {
        val now = System.currentTimeMillis()
        synchronized(indexLock) {
            var totalBytes = 0L
            var expiredCount = 0
            var pinnedCount = 0
            val bytesByTag = mutableMapOf<String, Long>()

            for (record in entries.values) {
                totalBytes += record.sizeBytes
                if (record.isExpired(now)) expiredCount++
                if (record.pinned) pinnedCount++
                val tagKey = if (record.tag.isNullOrBlank()) "untagged" else record.tag!!
                bytesByTag[tagKey] = (bytesByTag[tagKey] ?: 0L) + record.sizeBytes
            }

            val stats = mapOf<String, Any?>(
                "totalEntries" to entries.size,
                "totalBytes" to totalBytes,
                "expiredEntries" to expiredCount,
                "pinnedEntries" to pinnedCount,
                "maxDiskCacheBytes" to maxDiskCacheBytes,
                "cacheDirectoryPath" to getCacheRootDir().absolutePath,
                "hitCount" to hitCount,
                "missCount" to missCount,
                "evictionCount" to evictionCount,
                "bytesByTag" to bytesByTag
            )
            result.success(stats)
        }
    }

    private fun handleGetCapabilities(result: Result) {
        val caps = mapOf<String, Any?>(
            "platformName" to "android",
            "supportsFileSystemPaths" to true,
            "supportsConditionalHttpRevalidation" to true,
            "supportsNativeCryptoHash" to true,
            "supportsLowDiskSpaceNotifications" to true,
            "storageMechanism" to "Context.getCacheDir() + HttpURLConnection + MessageDigest",
            "defaultCacheRootPath" to getCacheRootDir().absolutePath
        )
        result.success(caps)
    }
}
