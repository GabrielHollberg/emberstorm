package dev.soundstorm.app

import android.content.Context
import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Downloads kept by the app, in its own folder, which Android never clears
 * (the owner's rule, 2026-10-11: a download is deleted by nobody but the
 * person; the web view's storage can be). The page's half is app.js's
 * openDownloads and the contract in CLAUDE.md, "Downloads kept by the apps";
 * the iPhone's is KeptFiles.swift. Kept out of backups and device transfer
 * with everything else of the app's (data_extraction_rules.xml).
 *
 * Each server (its host and port: an install's home and away names are two)
 * has a folder under files/kept: every kept file by a hash of its address
 * (path and query), entries.json saying which is which, index.json the
 * page's list of downloads, origin.txt where it came from.
 *
 * The page reads a kept file at `<server>/__emberstorm-kept/<path>`, which
 * this app answers itself (`intercept`, from both web view clients), with
 * byte ranges - the same origin as the page, so nothing more is allowed than
 * the page already had. The native player reads its kept copy of a server
 * address directly (`fileFor`). Offline, the page's own files, kept too, are
 * answered at the server's own addresses (`offline`), so the app opens on
 * its downloads as it does from the service worker on a secure name.
 */
object KeptFiles {
    const val PREFIX = "/__emberstorm-kept"

    /** Called with each answer for the page: `window.__soundstormKeep`. */
    @Volatile var answer: ((site: String, json: String) -> Unit)? = null
    /** Called when the list or files change: the page's script is made again. */
    @Volatile var changed: ((site: String) -> Unit)? = null

    private lateinit var root: File
    private val lock = Any()
    private val meta = HashMap<String, JSONObject>()
    // One file at a time, as the page fetched them: a film's pieces are made
    // by the video server as they are asked for.
    private val fetcher = Executors.newSingleThreadExecutor()
    private val stopped = HashSet<String>()

    fun init(context: Context) {
        if (!::root.isInitialized) root = File(context.filesDir, "kept").apply { mkdirs() }
    }

    /** host:port of an address, its port always written. */
    fun site(url: String): String? {
        val u = runCatching { Uri.parse(url) }.getOrNull() ?: return null
        val scheme = u.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = u.host?.lowercase() ?: return null
        val port = if (u.port != -1) u.port else if (scheme == "http") 80 else 443
        return "$host:$port"
    }

    /** The key a file is kept under: its path and query, as the page's keptKey. */
    fun key(url: String): String {
        val u = Uri.parse(url)
        val path = u.encodedPath.takeUnless { it.isNullOrEmpty() } ?: "/"
        val q = u.encodedQuery
        return if (q.isNullOrEmpty()) path else "$path?$q"
    }

    private fun folder(site: String) = File(root, site.replace(':', '_').replace(Regex("[^a-z0-9._-]"), "_"))

    private fun entries(site: String): JSONObject = synchronized(lock) {
        meta.getOrPut(site) {
            runCatching { JSONObject(File(folder(site), "entries.json").readText()) }.getOrDefault(JSONObject())
        }
    }

    private fun saveEntries(site: String) = synchronized(lock) {
        val dir = folder(site).apply { mkdirs() }
        val tmp = File(dir, "entries.json.part")
        tmp.writeText(entries(site).toString())
        tmp.renameTo(File(dir, "entries.json"))
    }

    private fun fileName(key: String): String {
        val d = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
        return d.take(16).joinToString("") { "%02x".format(it) }
    }

    /** The page's script: what the app keeps for the server the page is on. */
    fun pageScript(origin: String): String {
        val site = site(origin) ?: return ""
        val index = runCatching { File(folder(site), "index.json").readText() }.getOrNull()
            ?.takeIf { runCatching { JSONObject(it) }.isSuccess } ?: "null"
        val urls = JSONArray(entries(site).keys().asSequence().toList().sorted())
        return """
(() => {
  const app = window.soundstormApp;
  if (!app || typeof SoundStormNative === 'undefined') return;
  app.keeps = 1;
  app.keptIndex = $index;
  app.keptURLs = $urls;
  app.keep = (cmd, data) => SoundStormNative.postMessage(JSON.stringify({ type: 'keep', cmd, data: data || {} }));
  app.keptURL = (address) => {
    const u = new URL(address, location.href);
    return location.origin + '$PREFIX' + u.pathname + u.search;
  };
})();
"""
    }

    /** The page's message, from `origin` (the page's own server). */
    fun handle(cmd: String, data: JSONObject, origin: String) {
        val site = site(origin) ?: return
        val urls = data.optJSONArray("urls") ?: JSONArray()
        val addresses = (0 until urls.length()).mapNotNull { i ->
            val u = runCatching { URL(URL("$origin/"), urls.optString(i)).toString() }.getOrNull() ?: return@mapNotNull null
            u.takeIf { site(it) == site }
        }
        when (cmd) {
            "add" -> fetch(data.optString("id"), site, origin, addresses, quiet = false, again = false)
            "shell" -> fetch("shell:$site", site, origin, addresses, quiet = true, again = true)
            "stop" -> synchronized(lock) { stopped.add(data.optString("id")) }
            "remove" -> {
                synchronized(lock) {
                    val m = entries(site)
                    for (a in addresses) {
                        val e = m.optJSONObject(key(a)) ?: continue
                        File(folder(site), e.optString("file")).delete()
                        m.remove(key(a))
                    }
                    saveEntries(site)
                }
                changed?.invoke(site)
            }
            "index" -> {
                val dir = folder(site).apply { mkdirs() }
                File(dir, "origin.txt").writeText(origin)
                val tmp = File(dir, "index.json.part")
                tmp.writeText((data.optJSONObject("index") ?: JSONObject()).toString())
                tmp.renameTo(File(dir, "index.json"))
                changed?.invoke(site)
            }
            "clear" -> {
                synchronized(lock) {
                    meta.remove(site)
                    folder(site).deleteRecursively()
                }
                changed?.invoke(site)
            }
        }
    }

    private fun fetch(id: String, site: String, origin: String, addresses: List<String>, quiet: Boolean, again: Boolean) {
        val wanted = addresses.distinctBy { key(it) }
        fetcher.execute {
            val kept = JSONArray()
            val failed = JSONArray()
            var bytes = 0L
            val total = wanted.size
            fun report(done: Boolean) {
                if (quiet) return
                val a = if (done) JSONObject().put("cmd", "done").put("id", id).put("kept", kept).put("failed", failed)
                else JSONObject().put("cmd", "progress").put("id", id).put("done", kept.length() + failed.length())
                    .put("total", total).put("bytes", bytes)
                answer?.invoke(site, a.toString())
            }
            for (url in wanted) {
                if (synchronized(lock) { stopped.contains(id) }) break
                val k = key(url)
                val have = entries(site).optJSONObject(k)
                if (!again && have != null && File(folder(site), have.optString("file")).exists()) {
                    kept.put(k)
                    report(false)
                    continue
                }
                val size = runCatching { download(site, url, k) }.getOrNull()
                if (size != null) {
                    kept.put(k)
                    bytes += size
                } else failed.put(k)
                report(false)
            }
            synchronized(lock) { stopped.remove(id) }
            if (!quiet || kept.length() > 0) changed?.invoke(site)
            report(true)
        }
    }

    /** One address into the folder: with the session's cookies, no redirect. */
    private fun download(site: String, url: String, key: String): Long? {
        WebCookies.install()
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = false
        conn.connectTimeout = 20_000
        conn.readTimeout = 60_000
        conn.setRequestProperty("User-Agent", "SoundStormApp/1")
        try {
            if (conn.responseCode != 200) return null
            val dir = folder(site).apply { mkdirs() }
            val name = fileName(key)
            val part = File(dir, "$name.part")
            var size = 0L
            conn.inputStream.use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        size += n
                    }
                }
            }
            val file = File(dir, name)
            if (!part.renameTo(file)) return null
            val entry = JSONObject().put("file", name).put("size", size)
                .put("type", conn.contentType ?: "application/octet-stream")
            conn.getHeaderField("Content-Security-Policy")?.let { entry.put("csp", it) }
            synchronized(lock) {
                entries(site).put(key, entry)
                saveEntries(site)
            }
            return size
        } finally {
            conn.disconnect()
        }
    }

    /** The kept copy of a server address, for the native player. */
    fun fileFor(url: String): File? {
        if (!::root.isInitialized) return null
        val site = site(url) ?: return null
        val e = entries(site).optJSONObject(key(url)) ?: return null
        return File(folder(site), e.optString("file")).takeIf { it.exists() }
    }

    /**
     * Where the page lives for a saved server (its secure or chosen name,
     * which the app follows without saving): set when that page keeps its
     * files, read when the saved address cannot be reached.
     */
    fun livesAt(context: Context, saved: String, at: String) {
        if (saved == at) return
        context.getSharedPreferences("kept", Context.MODE_PRIVATE).edit().putString("livesAt:$saved", at).apply()
    }

    fun livesAt(context: Context, saved: String): String? =
        context.getSharedPreferences("kept", Context.MODE_PRIVATE).getString("livesAt:$saved", null)

    /**
     * Which install an address is (`/healthz`'s id), remembered whenever a
     * page of it loads: an install answers at several names (its code's home
     * and away names, a chosen name's two), and its kept copy and downloads
     * are under whichever the page was on. Offline, any of them finds it.
     */
    fun rememberId(context: Context, origin: String, id: String) {
        val site = site(origin) ?: return
        context.getSharedPreferences("kept", Context.MODE_PRIVATE).edit()
            .putString("id:$site", id).putString("origin:$site", origin).apply()
    }

    /** The install an address is: as remembered, else its code (the name's first part). */
    fun idOf(context: Context, origin: String): String? {
        val site = site(origin) ?: return null
        context.getSharedPreferences("kept", Context.MODE_PRIVATE).getString("id:$site", null)?.let { return it }
        val host = Uri.parse(origin).host?.lowercase() ?: return null
        return if (ServerAddress.zoneOf(host) != null) host.substringBefore('.') else null
    }

    /** An address of this install whose page is kept, if any. */
    fun keptPageFor(context: Context, id: String): String? {
        val prefs = context.getSharedPreferences("kept", Context.MODE_PRIVATE)
        for ((k, v) in prefs.all) {
            if (!k.startsWith("id:") || v != id) continue
            val origin = prefs.getString("origin:" + k.removePrefix("id:"), null) ?: continue
            if (hasShell(origin)) return origin
        }
        return null
    }

    /** Whether the page's own files are kept for this server. */
    fun hasShell(origin: String): Boolean {
        val site = site(origin) ?: return false
        return entries(site).has("/") && entries(site).has("/static/app.js")
    }

    /**
     * A request the app answers from its folder: anything under PREFIX on
     * the page's own server, and - offline, the page opened from its kept
     * copy - the page's own files at their own addresses.
     */
    fun intercept(request: WebResourceRequest, server: String?, offline: Boolean): WebResourceResponse? {
        if (!::root.isInitialized || request.method != "GET") return null
        val url = request.url.toString()
        val site = site(url) ?: return null
        if (server == null || site(server) != site) return null
        val path = request.url.encodedPath ?: return null
        val key = when {
            path.startsWith("$PREFIX/") -> key(url).removePrefix(PREFIX)
            offline && !path.startsWith("/api/") -> key(url)
            else -> return null
        }
        val e = entries(site).optJSONObject(key) ?: return if (path.startsWith("$PREFIX/")) notFound() else null
        val file = File(folder(site), e.optString("file"))
        if (!file.exists()) return notFound()
        return serve(file, e, request.requestHeaders.entries.firstOrNull { it.key.equals("Range", true) }?.value)
    }

    private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found",
        mapOf("Cache-Control" to "no-store"), "not kept".byteInputStream())

    private fun serve(file: File, e: JSONObject, range: String?): WebResourceResponse {
        val full = e.optString("type", "application/octet-stream")
        val mime = full.substringBefore(';').trim()
        val charset = Regex("charset=([^;]+)", RegexOption.IGNORE_CASE).find(full)?.groupValues?.get(1)?.trim()
        val length = file.length()
        val headers = mutableMapOf("Accept-Ranges" to "bytes", "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff")
        e.optString("csp").takeIf { it.isNotEmpty() }?.let { headers["Content-Security-Policy"] = it }
        val m = range?.let { Regex("bytes=(\\d*)-(\\d*)").find(it) }
        if (m != null && length > 0) {
            val (a, b) = m.destructured
            var start = a.toLongOrNull()
            var end = b.toLongOrNull()
            if (start == null && end != null) { start = maxOf(0, length - end); end = length - 1 }
            start = start ?: 0
            end = minOf(end ?: (length - 1), length - 1)
            if (start in 0..end) {
                headers["Content-Range"] = "bytes $start-$end/$length"
                headers["Content-Length"] = (end - start + 1).toString()
                val input: InputStream = FileInputStream(file).apply { skip(start) }
                return WebResourceResponse(mime, charset, 206, "Partial Content", headers, Limited(input, end - start + 1))
            }
        }
        headers["Content-Length"] = length.toString()
        return WebResourceResponse(mime, charset, 200, "OK", headers, FileInputStream(file))
    }

    /** At most `left` bytes of a stream. */
    private class Limited(private val inner: InputStream, private var left: Long) : InputStream() {
        override fun read(): Int {
            if (left <= 0) return -1
            val c = inner.read()
            if (c >= 0) left--
            return c
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (left <= 0) return -1
            val n = inner.read(b, off, minOf(len.toLong(), left).toInt())
            if (n > 0) left -= n
            return n
        }

        override fun close() = inner.close()
    }
}
