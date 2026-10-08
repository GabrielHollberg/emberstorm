package dev.soundstorm.app

import android.net.Uri
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Finding a EmberStorm server on the network the phone or TV is on, so
 * nobody setting one up has to type an address - as the iPhone and Apple TV
 * apps find one (ios/Shared/ServerDiscovery.swift).
 *
 * Not by mDNS: EmberStorm runs in Docker, which on Windows and macOS keeps a
 * container's announcements off the home network. Every address on the
 * device's own network is asked whether EmberStorm answers on its port
 * (/healthz says so) - a few hundred quick questions at once, a few seconds.
 * One that answers is asked its secure home name (/api/session's
 * secureName), which is kept instead of the bare address when it answers too.
 */
object ServerDiscovery {
    /**
     * A server found: its best address, the name it goes by ("Gabriel's
     * EmberStorm", none until it has an owner), and whether it has an owner
     * yet - a new box has none, and is set up rather than signed in to.
     */
    data class Found(val url: Uri, val name: String? = null, val setUp: Boolean = true) {
        /** What to call it on screen: its name, else the code of a home name. */
        val label: String get() = name ?: ServerAddress.homeCode(url.host) ?: url.host ?: url.toString()
    }

    /** EmberStorm's own port; a server moved to another is typed in. */
    private const val PORT = 8099

    /** The servers on this device's network, the best address of each. Blocking. */
    fun search(): List<Found> {
        val hosts = neighbours()
        if (hosts.isEmpty()) return emptyList()
        val pool = Executors.newFixedThreadPool(128)
        try {
            val answering = pool.invokeAll(hosts.map { host ->
                Callable { "http://$host:$PORT".let { base -> health(base, 1200)?.let { base to it } } }
            }, 30, TimeUnit.SECONDS).mapNotNull { runCatching { it.get() }.getOrNull() }.sortedBy { it.first }
            return answering.map { (plain, health) ->
                Found(Uri.parse(secureName(plain) ?: "$plain/"),
                    health.optString("name").trim().takeIf { it.isNotEmpty() }?.take(60),
                    health.optBoolean("setUp", true))
            }.distinctBy { it.url.toString() }.sortedBy { it.label }
        } finally {
            pool.shutdownNow()
        }
    }

    private fun get(url: String, timeout: Int): String? = runCatching {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = timeout
        conn.readTimeout = timeout
        conn.instanceFollowRedirects = false
        conn.useCaches = false
        try {
            if (conn.responseCode != 200) null else conn.inputStream.bufferedReader().use { it.readText().take(64 * 1024) }
        } finally {
            conn.disconnect()
        }
    }.getOrNull()

    /** What /healthz says, when [base] is an EmberStorm answering; else null. */
    private fun health(base: String, timeout: Int = 2000): JSONObject? {
        val body = get("$base/healthz", timeout) ?: return null
        return runCatching { JSONObject(body).takeIf { it.optString("status") == "ok" && it.has("sources") } }.getOrNull()
    }

    private fun isEmberStorm(base: String, timeout: Int = 2000): Boolean = health(base, timeout) != null

    /** The install's secure home name, if it has one and it answers from here. */
    private fun secureName(plain: String): String? {
        val body = get("$plain/api/session", 3000) ?: return null
        val name = runCatching { JSONObject(body).optString("secureName") }.getOrNull()?.lowercase() ?: return null
        // One of the install's own names, under the zone it lives in now or
        // the one from before the rename.
        if (!Regex("^[a-z0-9][a-z0-9.-]*$").matches(name) || ServerAddress.zoneOf(name) == null) return null
        val secure = "https://$name:$PORT"
        return if (isEmberStorm(secure)) "$secure/" else null
    }

    /**
     * Every address on the device's own network (its IPv4 /24), and on
     * 192.168.0.x and 192.168.1.x - the networks routers most often make, for
     * a router inside a router (the owner's projector is on 192.168.68.x
     * inside 192.168.0.x, where the server is). Private networks only.
     */
    private fun neighbours(): List<String> {
        val mine = mutableSetOf<Int>()
        runCatching {
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.isUp || nif.isLoopback) continue
                // Wi-Fi and wired only: mobile data has private addresses
                // too, and a carrier's network is no place to look.
                if (!nif.name.startsWith("wlan") && !nif.name.startsWith("eth")) continue
                for (a in nif.inetAddresses) {
                    if (a !is Inet4Address) continue
                    val b = a.address.map { it.toInt() and 255 }
                    val private = b[0] == 10 || (b[0] == 172 && b[1] in 16..31) || (b[0] == 192 && b[1] == 168)
                    if (private) mine += (b[0] shl 24) or (b[1] shl 16) or (b[2] shl 8)
                }
            }
        }
        if (mine.isEmpty()) return emptyList()
        mine += (192 shl 24) or (168 shl 16)
        mine += (192 shl 24) or (168 shl 16) or (1 shl 8)
        return mine.flatMap { base ->
            (1..254).map { n ->
                val v = base or n
                "${v ushr 24}.${(v shr 16) and 255}.${(v shr 8) and 255}.${v and 255}"
            }
        }.distinct()
    }
}
