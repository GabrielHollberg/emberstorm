package dev.soundstorm.app

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/**
 * The one EmberStorm server this app talks to. Every install is someone's
 * own, so the address is asked for on first launch rather than built in -
 * as the iPhone app does (ios/EmberStorm/ServerAddress.swift).
 */
object ServerAddress {
    /** Where install names live: emberstorm.app, and soundstorm.dev from before the rename (2026-10-07). */
    val ZONES = listOf("emberstorm.app", "soundstorm.dev")

    /** The zone [host] is an install's name under, else null. */
    fun zoneOf(host: String?): String? = host?.lowercase()?.let { h -> ZONES.firstOrNull { h.endsWith(".$it") } }

    /** Whether [host] is an install's home name, <id>.home.<zone>. */
    fun isHomeName(host: String?): Boolean = host?.lowercase()?.let { h -> ZONES.any { h.endsWith(".home.$it") } } == true

    /** Whether [host] is an install's away name, <id>.net.<zone>. */
    fun isAwayName(host: String?): Boolean = host?.lowercase()?.let { h -> ZONES.any { h.endsWith(".net.$it") } } == true

    /** Whether [host] is an install's home or away name. */
    fun isInstallName(host: String?): Boolean = isHomeName(host) || isAwayName(host)

    /** The install's code in a home name ("abc123" of abc123.home.emberstorm.app), else null. */
    fun homeCode(host: String?): String? {
        val h = host?.lowercase() ?: return null
        val z = ZONES.firstOrNull { h.endsWith(".home.$it") } ?: return null
        return h.removeSuffix(".home.$z")
    }

    /** A home name's away twin (abc123.home.Z to abc123.net.Z), else null. */
    fun awayHost(host: String?): String? {
        val h = host?.lowercase() ?: return null
        val z = ZONES.firstOrNull { h.endsWith(".home.$it") } ?: return null
        return h.removeSuffix(".home.$z") + ".net.$z"
    }

    /**
     * The install id the server at [base] answers with (/healthz's "id"), or
     * null. Run off the main thread.
     */
    /**
     * At most [max] bytes of a reply, as text: a server - or anything
     * answering where one was looked for - decides how much it sends, and a
     * reply read whole could be any size (the twelfth security pass).
     */
    fun capped(stream: java.io.InputStream?, max: Int = 1 shl 20): String {
        if (stream == null) return ""
        return stream.use { s ->
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(16 * 1024)
            while (out.size() < max) {
                val n = s.read(buf, 0, minOf(buf.size, max - out.size()))
                if (n < 0) break
                out.write(buf, 0, n)
            }
            out.toString("UTF-8")
        }
    }

    fun installIdAt(base: Uri): String? {
        val conn = java.net.URL(base.buildUpon().path("/healthz").clearQuery().fragment(null).build().toString())
            .openConnection() as java.net.HttpURLConnection
        conn.setRequestProperty(WebCookies.NO_COOKIES, "1")
        conn.connectTimeout = 5000
        conn.readTimeout = 5000
        return try {
            if (conn.responseCode != 200) return null
            val body = capped(conn.inputStream, 64 * 1024)
            org.json.JSONObject(body).optString("id").takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            null
        } finally {
            conn.disconnect()
        }
    }

    private const val PREFS = "soundstorm"
    private const val KEY = "serverURL"

    fun saved(context: Context): Uri? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let(::parse)

    fun save(context: Context, server: Uri?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, server?.toString()).apply()
    }

    // Several saved servers, as the iPhone and Apple TV apps keep them
    // (ios/Shared/ServerAddress.swift): the latest used first. Sign-ins stay
    // with each, since cookies belong to an address, so switching signs
    // nobody out.
    private const val LIST_KEY = "servers"

    data class Server(val url: Uri, val name: String)

    fun all(context: Context): List<Server> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(LIST_KEY, null)
        if (raw == null) {
            // From before the list: the one address in use seeds it.
            return saved(context)?.let { listOf(Server(it, defaultName(it))) } ?: emptyList()
        }
        val array = runCatching { org.json.JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<Server>()
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            val url = parse(o.optString("url")) ?: continue
            if (out.any { origin(it.url) == origin(url) }) continue
            out += Server(url, o.optString("name").ifBlank { defaultName(url) })
        }
        return out
    }

    private fun store(context: Context, list: List<Server>) {
        val array = org.json.JSONArray()
        list.take(20).forEach { array.put(JSONObject().put("url", it.url.toString()).put("name", it.name)) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(LIST_KEY, array.toString()).apply()
    }

    /** The server now in use: to the top of the list, added if new. */
    fun remember(context: Context, url: Uri) {
        val list = all(context)
        val name = list.firstOrNull { origin(it.url) == origin(url) }?.name ?: defaultName(url)
        store(context, listOf(Server(url, name)) + list.filter { origin(it.url) != origin(url) })
        save(context, url)
    }

    fun forget(context: Context, url: Uri) {
        store(context, all(context).filter { origin(it.url) != origin(url) })
        if (saved(context)?.let { origin(it) == origin(url) } == true) save(context, null)
    }

    fun rename(context: Context, url: Uri, name: String) {
        store(context, all(context).map {
            if (origin(it.url) == origin(url)) it.copy(name = name.trim().ifBlank { defaultName(url) }) else it
        })
    }

    /** "EmberStorm abc123" for an install's own name, else the host. */
    fun defaultName(url: Uri): String {
        val host = url.host ?: return url.toString()
        if (isInstallName(host)) return "EmberStorm " + host.substringBefore('.')
        return host
    }

    /**
     * Turns what somebody typed into the server's root URL. Anything without a
     * scheme is https: the default install has a real certificate on its
     * emberstorm.app name. A path is dropped - the app lives at the root.
     */
    fun parse(typed: String): Uri? {
        var text = typed.trim()
        if (text.isEmpty()) return null
        if (!text.contains("://")) text = "https://$text"
        val uri = Uri.parse(text)
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "https" && scheme != "http") return null
        // Lowercase, as an origin is compared: a typed capital left the
        // page's messages unrecognised.
        val host = uri.host?.lowercase()
        if (host.isNullOrEmpty()) return null
        val authority = if (uri.port != -1) "$host:${uri.port}" else host
        return Uri.Builder().scheme(scheme).encodedAuthority(authority).path("/").build()
    }

    /** "scheme://host[:port]", the form an origin rule and an origin check use. */
    fun origin(server: Uri): String =
        "${server.scheme}://${server.host}" + if (server.port != -1) ":${server.port}" else ""

    /** The origin of the page showing now (set by MainActivity), which may
     *  be the install's secure name rather than the address typed. */
    @Volatile var current: String? = null

    /**
     * Whether an address the page hands the app is the server's own: the
     * native player, its covers and the notification fetch nothing else. A
     * page is somebody else's text as far as the app is concerned - the
     * review found any address, any scheme, was loaded with the session.
     */
    fun isServer(context: Context, url: String?): Boolean {
        if (url.isNullOrEmpty()) return false
        val u = runCatching { Uri.parse(url) }.getOrNull() ?: return false
        val scheme = u.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return false
        val o = origin(u).lowercase()
        if (current?.lowercase() == o) return true
        return saved(context)?.let { origin(it).lowercase() == o } == true
    }

    class CheckFailed(message: String) : Exception(message)

    /**
     * Asks the server's /healthz, which every EmberStorm answers with
     * {"status":"ok","sources":n}, so a typo that lands on some other web
     * server is caught here rather than as a strange page later. Blocking:
     * call it off the main thread.
     */
    fun check(server: Uri) {
        val host = server.host ?: server.toString()
        val conn = try {
            (URL(origin(server) + "/healthz").openConnection() as HttpURLConnection).apply {
                setRequestProperty(WebCookies.NO_COOKIES, "1")
                connectTimeout = 10_000
                readTimeout = 10_000
                useCaches = false
            }
        } catch (e: Exception) {
            throw CheckFailed("That doesn't look like a web address.")
        }
        try {
            val code = conn.responseCode
            val body = capped(if (code in 200..299) conn.inputStream else conn.errorStream, 64 * 1024)
            val ok = code == 200 && runCatching {
                val json = JSONObject(body)
                json.optString("status") == "ok" && json.has("sources")
            }.getOrDefault(false)
            if (!ok) throw CheckFailed("Something answered at that address, but it isn't EmberStorm.")
        } catch (e: CheckFailed) {
            throw e
        } catch (e: SSLException) {
            throw CheckFailed("$host has a certificate this phone doesn't trust. " +
                "Use the emberstorm.app address EmberStorm gave you.")
        } catch (e: UnknownHostException) {
            throw CheckFailed("Couldn't find $host. Check the address.")
        } catch (e: SocketTimeoutException) {
            throw CheckFailed("Couldn't reach $host. Is EmberStorm running, and is this phone on a network that can reach it?")
        } catch (e: ConnectException) {
            throw CheckFailed("Couldn't reach $host. Is EmberStorm running, and is this phone on a network that can reach it?")
        } catch (e: Exception) {
            throw CheckFailed(e.message ?: "Couldn't reach $host.")
        } finally {
            conn.disconnect()
        }
    }

    /**
     * The addresses worth trying for what was typed, best first - as the
     * iPhone and Apple TV apps try them (ServerAddress.candidates). Just the
     * install's code ("abc123", or "abc123.emberstorm.app") is its home and
     * away names, with and without :8099; a emberstorm.app name typed without
     * its port is tried on EmberStorm's own port first (the away name is
     * "<id>.net.emberstorm.app:8099", and typed without the port it found
     * nothing). A phone prefers the away name, which works anywhere (the page
     * moves itself to the home name when it can); a TV, which stays put, the
     * home name. Null when it is not an address at all.
     */
    fun candidates(typed: String, preferAway: Boolean): List<Uri>? {
        val text = typed.trim().lowercase()
        val bare = ZONES.fold(text) { t, z -> t.removeSuffix(".$z") }
        if (!text.contains("://") && Regex("^[a-z0-9][a-z0-9-]{2,62}$").matches(bare) &&
            bare != "localhost" && !bare.all { it.isDigit() }) {
            val levels = if (preferAway) listOf("net", "home") else listOf("home", "net")
            return levels.flatMap { level ->
                listOf("https://$bare.$level.${ZONES[0]}:8099", "https://$bare.$level.${ZONES[0]}").mapNotNull(::parse)
            }
        }
        val url = parse(typed) ?: return null
        if (url.port != -1 || url.scheme != "https" || zoneOf(url.host) == null) return listOf(url)
        val withPort = parse("https://${url.host}:8099") ?: return listOf(url)
        return listOf(withPort, url)
    }

    /**
     * The best of the candidates that answers like EmberStorm. All are asked
     * at once, so a home name that cannot be reached from here costs no wait
     * beyond the slowest. Blocking: call it off the main thread.
     */
    fun find(typed: String, preferAway: Boolean): Uri {
        val list = candidates(typed, preferAway) ?: throw CheckFailed("That doesn't look like a web address.")
        if (list.size == 1) {
            check(list[0])
            return list[0]
        }
        val pool = java.util.concurrent.Executors.newFixedThreadPool(list.size)
        try {
            val results = list.map { url -> pool.submit<String?> { try { check(url); null } catch (e: CheckFailed) { e.message } } }
            // The best that answered, once nothing better can.
            for ((i, f) in results.withIndex()) {
                if (runCatching { f.get() }.getOrDefault("") == null) return list[i]
            }
            if (list.size > 2 && !typed.contains('.')) {
                throw CheckFailed("Couldn't reach a server with the code ${typed.trim()}, at home or away. Check the code - it is in EmberStorm's Settings, Use on your phone or TV - and, away from home, that remote access is on.")
            }
            throw CheckFailed(runCatching { results.last().get() }.getOrNull() ?: "Something answered at that address, but it isn't EmberStorm.")
        } finally {
            pool.shutdownNow()
        }
    }
}
