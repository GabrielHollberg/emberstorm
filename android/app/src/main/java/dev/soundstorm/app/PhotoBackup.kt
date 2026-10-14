package dev.soundstorm.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Backing up this phone's photos and videos to the person's own folder on
 * their server (pictures/Personal/<name>/<year>/<month>/), the owner's design:
 * the server's half is httpapi/personalphotos.go.
 *
 * **To any number of servers, one account on each, and each server's backup
 * belongs to the phone's own person there** (the owner's design, 2026-10-12,
 * as the iPhone's ios/ PhotoBackup.swift). The first person to sign in to a
 * server on this phone is asked, by the app, "Is this your phone?" - which
 * only makes backup possible for them later. Yes, and that server's backup is
 * theirs: its switch and options appear in their Settings, off until they turn
 * it on. No, and the next person to sign in there is asked; anyone may still
 * claim an unclaimed phone from Settings (an accidental No). Once claimed,
 * nobody else on that server on this phone is asked or sees a switch - only
 * whose it is - and the owner alone lets it go ("This isn't my phone"). Who
 * is signed in is asked of the server (`/api/session`, with the web view's
 * cookie), never taken from the page: a second person signing in, or a page's
 * message, cannot change another's backup. Each server's backup has its own
 * switch, options, progress, confirmed list and marker (`Dest`), and sends
 * only while its own person is the one signed in there.
 *
 * It runs as WorkManager jobs, so Android decides when - on Wi-Fi only and
 * while charging if asked - and it carries on with the app closed: a job when
 * a new photo appears (a content trigger), one every few hours as a safety
 * net, and each job chains another while there is more to send, since one
 * job may run only minutes. Newest first, so today's photos are safe before
 * last year's.
 *
 * The phone keeps no list of what it sent (0.37, the owner's asking): each run
 * asks the server which it already has - by name, when taken and size - and
 * sends the rest, so the server is the one record. A photo deleted there is
 * one it says it has, so it is not sent back; one that went missing there is
 * sent again by itself.
 */
object PhotoBackup {
    private const val PREFS = "photo-backup"
    private const val SENT = "backup-sent.txt" // from before 0.53; removed when seen
    private const val CONFIRMED_OLD = "backup-confirmed.txt" // from before 0.67: one server
    private const val PERIODIC = "photo-backup-periodic"
    private const val NOW = "photo-backup-now"
    private const val NEW_PHOTOS = "photo-backup-new"

    /** Each job sends for at most this long, then hands over to the next. */
    const val BUDGET_MS = 8 * 60 * 1000L

    /** However quiet things are, every photo is checked with the server this often. */
    const val FULL_EVERY_MS = 24 * 60 * 60 * 1000L

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Any()

    // ------------------------------------------------------- each server's backup

    /** Who is signed in on a server, as the server says. */
    data class Person(val id: String, val name: String, val pictures: Boolean, val serverName: String)

    /** One server's backup on this phone: whose phone it is there, and how its backup is set and going. */
    class Dest(
        val key: String,
        var name: String,
        var server: String?,
        val account: String,
        var person: String,
        var enabled: Boolean = false,
        var wifiOnly: Boolean = true,
        var videos: Boolean = true,
        var charging: Boolean = false,
        var done: Int = 0,
        var total: Int = 0,
        var problem: String = "",
        var marker: String? = null,
        var lastFull: Long = 0,
        var fullPending: Boolean = true,
    ) {
        fun json(): JSONObject = JSONObject()
            .put("key", key).put("name", name).put("server", server ?: JSONObject.NULL)
            .put("account", account).put("person", person)
            .put("enabled", enabled).put("wifiOnly", wifiOnly).put("videos", videos).put("charging", charging)
            .put("done", done).put("total", total).put("problem", problem)
            .put("marker", marker ?: JSONObject.NULL).put("lastFull", lastFull).put("fullPending", fullPending)

        companion object {
            fun from(o: JSONObject) = Dest(
                o.optString("key"), o.optString("name"),
                o.optString("server").takeIf { it.isNotBlank() && !o.isNull("server") },
                o.optString("account"), o.optString("person"),
                o.optBoolean("enabled"), o.optBoolean("wifiOnly", true), o.optBoolean("videos", true),
                o.optBoolean("charging"), o.optInt("done"), o.optInt("total"), o.optString("problem"),
                o.optString("marker").takeIf { it.isNotBlank() && !o.isNull("marker") },
                o.optLong("lastFull"), o.optBoolean("fullPending", true))
        }
    }

    fun destinations(c: Context): List<Dest> = synchronized(lock) {
        migrate(c)
        val raw = prefs(c).getString("destinations", null) ?: return emptyList()
        val a = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        (0 until a.length()).mapNotNull { a.optJSONObject(it)?.let(Dest::from) }
    }

    private fun store(c: Context, list: List<Dest>) {
        val a = JSONArray()
        list.forEach { a.put(it.json()) }
        prefs(c).edit().putString("destinations", a.toString()).apply()
    }

    fun dest(c: Context, key: String): Dest? = destinations(c).firstOrNull { it.key == key }

    fun update(c: Context, key: String, change: (Dest) -> Unit) = synchronized(lock) {
        val all = destinations(c)
        val d = all.firstOrNull { it.key == key } ?: return@synchronized
        change(d)
        store(c, all)
    }

    /** Who answered No to "Is this your phone?", by server. */
    private fun declined(c: Context): JSONObject =
        runCatching { JSONObject(prefs(c).getString("declined", "{}") ?: "{}") }.getOrDefault(JSONObject())

    /**
     * A phone's one backup from before (0.66 and earlier) becomes its
     * server's, the account it was turned on for its owner.
     */
    private fun migrate(c: Context) {
        val p = prefs(c)
        if (!p.contains("enabled") && !p.contains("server")) return
        val server = p.getString("server", null)
        val account = p.getString("account", "") ?: ""
        val e = p.edit()
        if (server != null && account.isNotEmpty() && !p.contains("destinations")) {
            val key = serverKey(Uri.parse(server))
            val d = Dest(key, Uri.parse(server).host ?: key, server, account, "",
                p.getBoolean("enabled", false), p.getBoolean("wifiOnly", true), p.getBoolean("videos", true),
                p.getBoolean("charging", false), p.getInt("done", 0), p.getInt("total", 0), "",
                p.getString("marker", null), p.getLong("lastFull", 0), p.getBoolean("fullPending", true))
            e.putString("destinations", JSONArray().put(d.json()).toString())
            File(c.filesDir, CONFIRMED_OLD).takeIf { it.exists() }?.renameTo(confirmedFile(c, key))
        }
        for (k in listOf("enabled", "server", "account", "wifiOnly", "videos", "charging", "done", "total",
            "problem", "marker", "lastFull", "fullPending", "confirmedScope")) e.remove(k)
        e.apply()
        File(c.filesDir, CONFIRMED_OLD).delete()
    }

    /** A server: the install's label (the start of its emberstorm.app name), else host and port. */
    fun serverKey(u: Uri): String {
        val host = u.host?.lowercase() ?: ""
        if (ServerAddress.isInstallName(host)) return host.substringBefore('.')
        val port = if (u.port != -1) u.port else if (u.scheme == "http") 80 else 443
        return "$host:$port"
    }

    private fun keyOf(origin: String) = serverKey(Uri.parse(origin))

    /** Any server's backup is on. */
    fun enabled(c: Context) = destinations(c).any { it.enabled }

    // -------------------------------------------------------------- who is signed in

    private val people = HashMap<String, Pair<Person?, Long>>()

    /**
     * Who is signed in on the server at this origin, asked of the server with
     * the web view's cookie; null when nobody is. A network failure throws.
     * Somebody signed in is kept a quarter minute (the page asks every few
     * seconds while Settings is open); nobody is not kept, so a sign-in shows
     * at once.
     */
    fun whoIs(origin: String): Person? {
        synchronized(people) {
            people[origin]?.let { (p, at) -> if (p != null && System.currentTimeMillis() - at < 15_000) return p }
        }
        val conn = open(Uri.parse(origin), "/api/session", "GET")
        conn.readTimeout = 15_000
        var person: Person? = null
        if (conn.responseCode == 200) {
            val a = JSONObject(ServerAddress.capped(conn.inputStream, 256 * 1024))
            val user = a.optJSONObject("user")
            val id = user?.optString("id").orEmpty()
            if (a.optBoolean("signedIn") && id.isNotEmpty()) {
                val libs = user?.optJSONArray("libraries")
                val pictures = libs != null && (0 until libs.length()).any { libs.optString(it) == "picture" }
                person = Person(id, user?.optString("name").orEmpty(), pictures, a.optString("serverName"))
            }
        }
        synchronized(people) { people[origin] = person to System.currentTimeMillis() }
        return person
    }

    /** A new page (signed in or out, switched person): asked afresh. */
    fun forgetWho() = synchronized(people) { people.clear() }

    // ---------------------------------------------------------------- for the page

    /** Whether "Is this your phone?" is to be asked now: a server nobody has
     *  claimed this phone on, a person with Pictures who has not answered. */
    fun shouldAsk(c: Context, origin: String, who: Person): Boolean {
        val key = keyOf(origin)
        if (!who.pictures || dest(c, key) != null) return false
        val no = declined(c).optJSONArray(key) ?: return true
        return (0 until no.length()).none { no.optString(it) == who.id }
    }

    /** Their answer: Yes claims the phone on this server; No is kept, so they
     *  are not asked again (Settings still offers the claim). */
    fun answered(c: Context, yes: Boolean, origin: String, who: Person) {
        if (yes) return claim(c, origin, who)
        synchronized(lock) {
            val all = declined(c)
            val key = keyOf(origin)
            all.put(key, (all.optJSONArray(key) ?: JSONArray()).put(who.id))
            prefs(c).edit().putString("declined", all.toString()).apply()
        }
    }

    /** "Yes, it's mine" or Settings' "This is my phone": only while nobody has. */
    fun claim(c: Context, origin: String, who: Person) = synchronized(lock) {
        val key = keyOf(origin)
        val all = destinations(c)
        if (all.any { it.key == key } || !who.pictures) return@synchronized
        val name = who.serverName.ifBlank { Uri.parse(origin).host ?: key }
        store(c, all + Dest(key, name, origin.takeIf { it.startsWith("https://") }, who.id, who.name))
    }

    /** "This isn't my phone": the owner lets it go; everyone may be asked again. */
    fun release(c: Context, origin: String, who: Person) {
        val key = keyOf(origin)
        synchronized(lock) {
            val all = destinations(c)
            if (all.firstOrNull { it.key == key }?.account != who.id) return
            store(c, all.filter { it.key != key })
            val no = declined(c)
            no.remove(key)
            prefs(c).edit().putString("declined", no.toString()).apply()
        }
        confirmedFile(c, key).delete()
        schedule(c)
    }

    /** What the page asked for: on or off, and its options. Only the phone's
     *  own person on this server changes its backup: another account's "off"
     *  (signing in after them, signing out) is not theirs to give. */
    fun configure(c: Context, origin: String, who: Person, options: JSONObject) {
        val key = keyOf(origin)
        if (dest(c, key)?.account != who.id) return
        update(c, key) { d ->
            if (options.has("enabled")) d.enabled = options.optBoolean("enabled")
            if (options.has("wifiOnly")) d.wifiOnly = options.optBoolean("wifiOnly")
            if (options.has("videos")) d.videos = options.optBoolean("videos")
            if (options.has("charging")) d.charging = options.optBoolean("charging")
            d.problem = ""
            d.person = who.name
            if (who.serverName.isNotBlank()) d.name = who.serverName
            // Its secure address, from the page (the address typed is often
            // plain http; photos go only over https).
            if (origin.startsWith("https://")) d.server = origin
        }
        schedule(c, now = true)
    }

    /** This server's backup, as the person signed in there may see it. */
    fun status(c: Context, origin: String, who: Person?): JSONObject {
        val key = keyOf(origin)
        val all = destinations(c)
        val d = all.firstOrNull { it.key == key }
        val mine = d?.takeIf { who != null && it.account == who.id }
        val p = prefs(c)
        val out = JSONObject()
            .put("phone", if (mine != null) "mine" else if (d != null) "theirs" else "unclaimed")
            .put("permission", hasPermission(c))
            .put("enabled", mine?.enabled ?: false)
            .put("decided", mine != null)
            .put("wifiOnly", mine?.wifiOnly ?: true)
            .put("videos", mine?.videos ?: true)
            .put("charging", mine?.charging ?: false)
            .put("done", mine?.done ?: 0)
            .put("total", mine?.total ?: 0)
            .put("running", mine != null && p.getBoolean("running", false) && p.getString("runningKey", null) == key)
            .put("problem", mine?.problem ?: "")
        if (d != null && mine == null) out.put("phoneOwner", d.person)
        if (mine != null) {
            if (p.getString("sendingDest", null) == key) {
                out.put("sendingSize", p.getLong("sendingSize", 0))
                    .put("sendingSent", p.getLong("sendingSent", 0))
                    .put("sendingVideo", p.getBoolean("sendingVideo", false))
            }
            out.put("elsewhere", JSONArray(all.filter { it.key != key && it.enabled }.map { it.name }))
        }
        return out
    }

    /** The addresses to try for a server's backup, best first: its secure
     *  address and its away twin (a home name is unreachable away from home).
     *  Only the server its owner said yes to, never another one in the list
     *  (the thirteenth security pass). */
    fun servers(c: Context, d: Dest): List<Uri> {
        val s = d.server ?: return emptyList()
        val u = Uri.parse(s)
        val out = mutableListOf(u)
        ServerAddress.awayHost(u.host ?: "")?.let { away ->
            out += u.buildUpon().encodedAuthority(ServerAddress.awayAuthority(c, u, away)).build()
        }
        return out
    }

    /** The permissions to ask for: photos and videos, and their places. */
    fun permissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 33 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.ACCESS_MEDIA_LOCATION)
        Build.VERSION.SDK_INT >= 29 -> arrayOf(
            Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.ACCESS_MEDIA_LOCATION)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun hasPermission(c: Context): Boolean {
        fun has(p: String) = ContextCompat.checkSelfPermission(c, p) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= 34 -> has(Manifest.permission.READ_MEDIA_IMAGES) ||
                has(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            Build.VERSION.SDK_INT >= 33 -> has(Manifest.permission.READ_MEDIA_IMAGES)
            else -> has(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    // --------------------------------------------------------------- when it runs

    /** The jobs wait for the least any server's backup asks (Wi-Fi only if all
     *  do, charging only if all do); each server's own rule is kept in the job. */
    private fun constraints(c: Context, triggers: Boolean = false): Constraints {
        val on = destinations(c).filter { it.enabled }
        val b = Constraints.Builder()
            .setRequiredNetworkType(if (on.isNotEmpty() && on.all { it.wifiOnly }) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresCharging(on.isNotEmpty() && on.all { it.charging })
        if (triggers) {
            b.addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
                .setTriggerContentUpdateDelay(30, TimeUnit.SECONDS)
        }
        return b.build()
    }

    /** Whether this server's own rule lets it send now. */
    fun mayRun(c: Context, d: Dest): Boolean {
        if (d.wifiOnly) {
            val cm = c.getSystemService(ConnectivityManager::class.java)
            val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
            if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) return false
        }
        if (d.charging) {
            val battery = c.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            if (status != BatteryManager.BATTERY_STATUS_CHARGING && status != BatteryManager.BATTERY_STATUS_FULL) return false
        }
        return true
    }

    /** Sets up the jobs, or cancels them when no backup is on. */
    fun schedule(c: Context, now: Boolean = false) {
        val wm = WorkManager.getInstance(c)
        if (!enabled(c) || !hasPermission(c)) {
            wm.cancelUniqueWork(PERIODIC)
            wm.cancelUniqueWork(NOW)
            wm.cancelUniqueWork(NEW_PHOTOS)
            return
        }
        val cons = constraints(c)
        wm.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<BackupWorker>(6, TimeUnit.HOURS).setConstraints(cons).build())
        if (now) {
            wm.enqueueUniqueWork(NOW, ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<BackupWorker>().setConstraints(cons).build())
        }
        // Kept as it is on an ordinary opening (appended, it grew a job on
        // every launch - a review); replaced when the options changed.
        watchForNewPhotos(c, if (now) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP)
    }

    /** A job that runs when a photo or video is added to the phone. */
    fun watchForNewPhotos(c: Context, policy: ExistingWorkPolicy = ExistingWorkPolicy.APPEND_OR_REPLACE) {
        // Replaced, not kept: it is set up again from inside the job it
        // replaces, and KEEP found that running job and did nothing, so the
        // trigger fired once and no more (a review).
        WorkManager.getInstance(c).enqueueUniqueWork(NEW_PHOTOS, policy,
            OneTimeWorkRequestBuilder<BackupWorker>().setConstraints(constraints(c, triggers = true)).build())
    }

    /** More to send than one job had time for: the next one, straight after. */
    fun continueLater(c: Context) {
        WorkManager.getInstance(c).enqueueUniqueWork(NOW, ExistingWorkPolicy.APPEND_OR_REPLACE,
            OneTimeWorkRequestBuilder<BackupWorker>().setConstraints(constraints(c)).build())
    }

    // ------------------------------------------------------------- the camera roll

    /** stamp is the photo's size and last change in Android's list: free to
     *  read, and different once a photo is edited. */
    data class Item(val key: String, val uri: Uri, val name: String, val taken: Long, val video: Boolean, val stamp: String)

    /** Every photo and video, newest first. */
    fun cameraRoll(c: Context): List<Item> {
        val out = ArrayList<Item>()
        val sources = listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI to false, MediaStore.Video.Media.EXTERNAL_CONTENT_URI to true)
        for ((collection, video) in sources) {
            val projection = arrayOf(
                MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_ADDED,
                MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED)
            c.contentResolver.query(collection, projection, null, null, null)?.use { cur ->
                val id = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val name = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val taken = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                val added = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                val bytes = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val modified = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                while (cur.moveToNext()) {
                    val n = cur.getString(name) ?: continue
                    val t = cur.getLong(taken).takeIf { it > 0 } ?: (cur.getLong(added) * 1000)
                    val rowId = cur.getLong(id)
                    out.add(Item((if (video) "v" else "i") + rowId, ContentUris.withAppendedId(collection, rowId), n, t, video,
                        "${cur.getLong(bytes)}:${cur.getLong(modified)}"))
                }
            }
        }
        out.sortByDescending { it.taken }
        return out
    }

    /**
     * The file as it is, location included where allowed: without the
     * original, Android hands over a copy with the place taken out, which
     * would leave Places empty and differ in size from the original.
     */
    fun original(c: Context, uri: Uri): Uri =
        if (Build.VERSION.SDK_INT >= 29 && ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED)
            MediaStore.setRequireOriginal(uri) else uri

    /** How long the file is, as it will be sent. */
    fun length(c: Context, uri: Uri): Long =
        runCatching { c.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull() ?: -1L

    // ------------------------------------------- checking only what is new
    //
    // A run used to ask the server about every photo on the phone, every time
    // (the owner's asking, 2026-10-09: professional, and no more work than
    // needed). Now the phone keeps the photos each server has confirmed, with
    // their stamp, and that server's marker of the person's photo folder from
    // the end of the last run. While the marker is unchanged, only photos not
    // confirmed (new, or edited since) are checked. When it has changed - a
    // photo deleted or lost there, files moved by hand - or a day has passed,
    // or the server has no marker (an older one), every photo is checked, as
    // before; a full check cut short is finished by the next run, never
    // skipped. The server stays the record: the list only says what need not
    // be asked about while nothing there has changed.

    private fun confirmedFile(c: Context, key: String) =
        File(c.filesDir, "backup-confirmed-" + key.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".txt")

    fun confirmed(c: Context, key: String): MutableMap<String, String> {
        File(c.filesDir, SENT).delete()
        val f = confirmedFile(c, key)
        val out = HashMap<String, String>()
        if (f.exists()) f.forEachLine { line ->
            val tab = line.indexOf('\t')
            if (tab > 0) out[line.substring(0, tab)] = line.substring(tab + 1)
        }
        return out
    }

    fun confirm(c: Context, key: String, items: Collection<Item>) {
        if (items.isEmpty()) return
        confirmedFile(c, key).appendText(items.joinToString("") { "${it.key}\t${it.stamp}\n" })
    }

    /** Whether this run checks every photo: see above. */
    fun fullDue(d: Dest, marker: String?): Boolean =
        marker == null || d.fullPending || d.marker != marker || System.currentTimeMillis() - d.lastFull > FULL_EVERY_MS

    /** A full check got through every photo: the list is what is on the phone now. */
    fun finishFull(c: Context, key: String, roll: List<Item>, known: Map<String, String>) {
        val keep = roll.mapNotNull { item -> known[item.key]?.let { stamp -> "${item.key}\t$stamp\n" } }
        confirmedFile(c, key).writeText(keep.joinToString(""))
        update(c, key) { it.fullPending = false; it.lastFull = System.currentTimeMillis() }
    }

    /** The server's marker of this person's photo folder, or null (an older server). */
    fun marker(server: Uri, account: String): String? = runCatching {
        val conn = open(server, "/api/photos/backup/marker" + accountQuery(account, "?"), "GET")
        if (conn.responseCode != 200) return@runCatching null
        JSONObject(ServerAddress.capped(conn.inputStream, 64 * 1024)).optString("marker").ifBlank { null }
    }.getOrNull()

    fun record(c: Context, key: String, done: Int? = null, total: Int? = null, problem: String? = null) =
        update(c, key) { d ->
            done?.let { d.done = it }
            total?.let { d.total = it }
            problem?.let { d.problem = it }
        }

    /** A run going, and on which server. */
    fun running(c: Context, key: String?) {
        val e = prefs(c).edit()
        if (key == null) e.putBoolean("running", false).putLong("lastRun", System.currentTimeMillis())
        else e.putBoolean("running", true).putString("runningKey", key)
        e.apply()
    }

    // ------------------------------------------------------------- the notification

    private const val CHANNEL = "photo-backup"
    const val NOTIFICATION_ID = 7302

    /** While sending, the job shows a quiet notification: that is what lets
     *  Android run it past ten minutes, which one long video can take. */
    fun foregroundInfo(c: Context, done: Int, total: Int, sent: Long = 0, size: Long = 0): ForegroundInfo {
        val nm = c.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Photo backup", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) })
        }
        val text = if (size > 0) "$done of $total - ${sent / 1_000_000} of ${size / 1_000_000} MB of this one"
            else "$done of $total backed up"
        val n = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_soundstorm)
            .setContentTitle("Backing up photos")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setProgress(if (size > 0) 1000 else total, if (size > 0) (sent * 1000 / size).toInt() else done, false)
            .build()
        return if (Build.VERSION.SDK_INT >= 29) ForegroundInfo(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else ForegroundInfo(NOTIFICATION_ID, n)
    }

    // ------------------------------------------------------------------ the server

    class Refused(val code: Int, message: String) : Exception(message)

    private fun open(server: Uri, path: String, method: String): HttpURLConnection {
        val conn = URL(server.toString().trimEnd('/') + path).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 15_000
        conn.readTimeout = 120_000
        conn.instanceFollowRedirects = false
        WebCookies.install()
        return conn
    }

    /** Whose backup it is: sent with every photo, so the server can refuse
     *  one meant for another account. */
    private fun accountQuery(account: String, sep: String): String =
        if (account.isEmpty()) "" else sep + "account=" + URLEncoder.encode(account, "UTF-8")

    /** Which of these the server already has. */
    fun check(server: Uri, account: String, items: List<Pair<Item, Long>>): BooleanArray {
        val conn = open(server, "/api/photos/backup/check" + accountQuery(account, "?"), "POST")
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        val list = JSONArray()
        for ((it, size) in items) list.put(JSONObject().put("name", it.name).put("taken", it.taken).put("size", size))
        conn.outputStream.use { it.write(JSONObject().put("items", list).toString().toByteArray()) }
        val code = conn.responseCode
        if (code !in 200..299) throw Refused(code, errorOf(conn))
        val have = JSONObject(ServerAddress.capped(conn.inputStream)).getJSONArray("have")
        return BooleanArray(items.size) { have.optBoolean(it) }
    }

    /** Sends one photo or video, the whole file as the body. */
    fun send(c: Context, server: Uri, d: Dest, item: Item, uri: Uri, size: Long, onProgress: (Long) -> Unit = {}) {
        val q = "?name=" + URLEncoder.encode(item.name, "UTF-8") + "&taken=" + item.taken + accountQuery(d.account, "&")
        val conn = open(server, "/api/photos/backup$q", "PUT")
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", if (item.video) "video/*" else "image/*")
        if (size > 0) conn.setFixedLengthStreamingMode(size) else conn.setChunkedStreamingMode(256 * 1024)
        // How far through this file, for Settings: a long video otherwise
        // looks like nothing happening until all of it is there.
        val p = prefs(c)
        p.edit().putString("sendingDest", d.key).putLong("sendingSize", size).putLong("sendingSent", 0)
            .putBoolean("sendingVideo", item.video).apply()
        try {
            c.contentResolver.openInputStream(uri)?.use { input ->
                conn.outputStream.use { out ->
                    val buf = ByteArray(256 * 1024)
                    var sent = 0L
                    var shown = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        sent += n
                        val now = System.currentTimeMillis()
                        if (now - shown > 1000) {
                            shown = now
                            p.edit().putLong("sendingSent", sent).apply()
                            onProgress(sent)
                        }
                    }
                }
            } ?: throw Refused(0, "could not read the file")
        } finally {
            p.edit().putLong("sendingSize", 0).putLong("sendingSent", 0).apply()
        }
        val code = conn.responseCode
        if (code !in 200..299 && code != 409) throw Refused(code, errorOf(conn))
        conn.inputStream.close()
    }

    private fun errorOf(conn: HttpURLConnection): String =
        runCatching { JSONObject(ServerAddress.capped(conn.errorStream, 64 * 1024)).optString("error") }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: "the server answered ${conn.responseCode}"
}

/** One backup job: as much of the camera roll as fits in its time, server by server. */
class BackupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    companion object {
        // One backup at a time, whichever job started it (a new photo, the
        // six-hourly one, the switch turned on): two at once sent the same
        // video twice side by side.
        private val busy = AtomicBoolean(false)
    }

    override fun doWork(): Result {
        // The job that waits for new photos is used up by running; set it up
        // again for the next one, before anything else - a new-photo job that
        // found another backup running returned at once and left nothing
        // watching (a review, 2026-10-09). From the new-photo job itself
        // APPEND_OR_REPLACE, which replaces it as it ends; from any other job
        // only if missing (KEEP) - appended from those, a new link was added
        // to its chain every run and they piled up.
        // Only on a job's first run: a new-photo job run again (a server
        // error asks for a retry) added another link to the chain each time,
        // and it never shrank (a review).
        val fromNewPhoto = triggeredContentUris.isNotEmpty() || triggeredContentAuthorities.isNotEmpty()
        if (runAttemptCount == 0) {
            PhotoBackup.watchForNewPhotos(applicationContext, if (fromNewPhoto) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP)
        }
        if (!busy.compareAndSet(false, true)) return Result.success()
        try {
            return backUpAll()
        } finally {
            busy.set(false)
        }
    }

    private var foreground = false
    private var foregroundAsked = false
    private val started = System.currentTimeMillis()

    private fun showProgress(done: Int, total: Int, sent: Long = 0, size: Long = 0) {
        if (!foreground) return
        runCatching { setForegroundAsync(PhotoBackup.foregroundInfo(applicationContext, done, total, sent, size)) }
    }

    /** What one server's run came to. */
    private enum class Outcome { DONE, AGAIN, OUT_OF_TIME, STOPPED }

    private fun backUpAll(): Result {
        val c = applicationContext
        if (!PhotoBackup.hasPermission(c)) return Result.success()
        val on = PhotoBackup.destinations(c).filter { it.enabled }
        if (on.isEmpty()) return Result.success()
        val roll = PhotoBackup.cameraRoll(c)
        var again = false
        for (d in on) {
            if (!PhotoBackup.mayRun(c, d)) continue
            when (backUp(d, if (d.videos) roll else roll.filter { !it.video })) {
                Outcome.DONE -> {}
                Outcome.AGAIN -> again = true
                Outcome.OUT_OF_TIME -> {
                    PhotoBackup.continueLater(c)
                    return Result.success()
                }
                Outcome.STOPPED -> return Result.retry()
            }
        }
        return if (again) Result.retry() else Result.success()
    }

    private fun backUp(d: PhotoBackup.Dest, roll: List<PhotoBackup.Item>): Outcome {
        val c = applicationContext
        val candidates = PhotoBackup.servers(c, d)
        if (candidates.isEmpty()) {
            PhotoBackup.record(c, d.key, problem = "Open EmberStorm by its secure address once, and backup starts.")
            return Outcome.DONE
        }
        // Only while its own person is the one signed in there: the server
        // would refuse the photos anyway, and this says why.
        var server = candidates.first()
        var who: PhotoBackup.Person? = null
        var reached = false
        for (s in candidates) {
            try {
                who = PhotoBackup.whoIs(ServerAddress.origin(s))
                server = s
                reached = true
                break
            } catch (e: java.io.IOException) {
                // the next address
            }
        }
        if (!reached) {
            PhotoBackup.record(c, d.key, problem = "Could not reach the server; it will try again.")
            return Outcome.AGAIN
        }
        if (who == null) {
            PhotoBackup.record(c, d.key, problem = "Sign in to EmberStorm again to carry on backing up.")
            return Outcome.DONE
        }
        if (who.id != d.account) {
            PhotoBackup.record(c, d.key, problem = "Backup waits while someone else is signed in.")
            return Outcome.DONE
        }
        val known = PhotoBackup.confirmed(c, d.key)
        // The first address whose marker answers; none, and every photo is
        // checked, as with an older server.
        var markerNow: String? = null
        for (s in candidates.dropWhile { it != server }) {
            markerNow = PhotoBackup.marker(s, d.account)
            if (markerNow != null) {
                server = s
                break
            }
        }
        val full = known.isEmpty() || PhotoBackup.fullDue(d, markerNow)
        if (full) PhotoBackup.update(c, d.key) { it.fullPending = true }
        val waiting = if (full) roll else roll.filter { known[it.key] != it.stamp }
        PhotoBackup.record(c, d.key, total = roll.size, problem = "")
        PhotoBackup.running(c, d.key)
        var done = roll.size - waiting.size
        // The marker afterwards: what this run sent is its own doing.
        fun closeRun(completed: Boolean) {
            if (completed && full) PhotoBackup.finishFull(c, d.key, roll, known)
            PhotoBackup.marker(server, d.account)?.let { m -> PhotoBackup.update(c, d.key) { it.marker = m } }
        }
        try {
            for (batch in waiting.chunked(100)) {
                if (isStopped) return Outcome.STOPPED
                val sized = batch.map { it to PhotoBackup.length(c, PhotoBackup.original(c, it.uri)) }
                // The first address that answers, for the rest of this run.
                var have: BooleanArray? = null
                var lastError: java.io.IOException? = null
                for (s in candidates.dropWhile { it != server }) {
                    try {
                        have = PhotoBackup.check(s, d.account, sized)
                        server = s
                        break
                    } catch (e: java.io.IOException) {
                        lastError = e
                    }
                }
                if (have == null) throw lastError ?: java.io.IOException("no server")
                val already = batch.filterIndexed { i, _ -> have[i] }
                PhotoBackup.confirm(c, d.key, already)
                for (it in already) known[it.key] = it.stamp
                done += already.size
                PhotoBackup.record(c, d.key, done = done)
                for ((i, pair) in sized.withIndex()) {
                    if (have[i]) continue
                    if (isStopped) return Outcome.STOPPED
                    if (System.currentTimeMillis() - started > PhotoBackup.BUDGET_MS) {
                        closeRun(completed = false)
                        return Outcome.OUT_OF_TIME
                    }
                    val (item, size) = pair
                    val sentSoFar = done
                    if (!foregroundAsked) {
                        // Only once something is to be sent. Android may
                        // refuse this from the background (12 and later); then
                        // it carries on as an ordinary job, ten minutes at a time.
                        foregroundAsked = true
                        foreground = runCatching {
                            setForegroundAsync(PhotoBackup.foregroundInfo(c, done, roll.size)).get(); true
                        }.getOrDefault(false)
                    }
                    try {
                        PhotoBackup.send(c, server, d, item, PhotoBackup.original(c, item.uri), size) { sent ->
                            showProgress(sentSoFar, roll.size, sent, size)
                        }
                    } catch (e: PhotoBackup.Refused) {
                        // One photo the server will not take (a type it
                        // refuses, a file that cannot be read) is passed
                        // over: newest first, every retry met it first and
                        // nothing older was ever sent (a review). Space, the
                        // sign-in and access still stop the run.
                        // A server error or timeout is not this photo's fault: tried again
                        // later, never counted as backed up (a review, 2026-10-09).
                        if (e.code in listOf(401, 403, 408, 429, 507) || e.code >= 500) throw e
                        android.util.Log.w("PhotoBackup", "passed over ${item.name}: ${e.message}")
                        PhotoBackup.record(c, d.key, problem = "Passed over ${item.name}: ${e.message}")
                    }
                    PhotoBackup.confirm(c, d.key, listOf(item))
                    known[item.key] = item.stamp
                    done++
                    PhotoBackup.record(c, d.key, done = done)
                    showProgress(done, roll.size)
                }
            }
            closeRun(completed = true)
            return Outcome.DONE
        } catch (e: PhotoBackup.Refused) {
            // Said plainly in Settings. A full photo space or disk, or a
            // sign-in that has ended, will not mend itself by trying again in
            // a minute: the next scheduled job tries.
            val message = when (e.code) {
                401 -> "Sign in to EmberStorm again to carry on backing up."
                403 -> e.message?.takeIf { it.isNotBlank() } ?: "This account does not have Pictures."
                507 -> e.message ?: "There is no room left for photos."
                else -> e.message ?: "The server refused a photo."
            }
            PhotoBackup.record(c, d.key, problem = message)
            return if (e.code in listOf(401, 403, 507)) Outcome.DONE else Outcome.AGAIN
        } catch (e: java.io.IOException) {
            // The network: WorkManager tries again later by itself.
            android.util.Log.w("PhotoBackup", "send failed", e)
            PhotoBackup.record(c, d.key, problem = "Could not reach the server; it will try again.")
            return Outcome.AGAIN
        } catch (e: Exception) {
            android.util.Log.w("PhotoBackup", "backup failed", e)
            PhotoBackup.record(c, d.key, problem = "Backup stopped (${e.javaClass.simpleName}); it will try again.")
            return Outcome.AGAIN
        } finally {
            PhotoBackup.running(c, null)
        }
    }
}
