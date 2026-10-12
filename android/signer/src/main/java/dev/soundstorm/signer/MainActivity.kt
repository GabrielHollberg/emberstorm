package dev.soundstorm.signer

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.util.Base64
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.nfc.NfcConfiguration
import com.yubico.yubikit.android.transport.nfc.NfcNotAvailable
import com.yubico.yubikit.core.keys.PublicKeyValues
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import com.yubico.yubikit.core.application.InvalidPinException
import com.yubico.yubikit.piv.KeyType
import com.yubico.yubikit.piv.PivSession
import com.yubico.yubikit.piv.Slot
import org.json.JSONObject
import java.net.CookieHandler
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * EmberStorm Signer: the developer's own app for signing a release away from
 * the PC, the release key's YubiKey held to the back of the phone.
 *
 * The PC makes the release and leaves it on the developer's own EmberStorm
 * server, waiting (httpapi/signing.go, SOUNDSTORM_SIGNING). Here: sign in to
 * that server as its owner, see what waits - read from the release's own
 * bytes, not from anything the server says of it - and sign. The YubiKey
 * signs those very bytes inside itself (Ed25519 in its PIV slot 9c, as
 * box/yubikey.py signs on the PC: the bytes themselves, nothing added), after
 * its PIN; the app first checks the key on it is one of EmberStorm's release
 * keys (box/release.pub, copied in at build). The signature goes back to the
 * server, which checks it again and keeps it beside the file. The key never
 * leaves the YubiKey; nothing is kept on the phone but the server's address.
 */
class MainActivity : Activity() {
    private val background = Executors.newSingleThreadExecutor()
    private val prefs by lazy { getSharedPreferences("signer", MODE_PRIVATE) }
    private lateinit var yubikit: YubiKitManager
    private lateinit var root: LinearLayout
    private var listening = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        // Cookies in memory only: signed in each time the app is opened.
        CookieHandler.setDefault(CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER))
        yubikit = YubiKitManager(this)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(48), dp(24), dp(32))
        }
        setContentView(ScrollView(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(root)
        })
        showSignIn()
    }

    override fun onPause() {
        super.onPause()
        stopNfc()
    }

    // --- screens -------------------------------------------------------------

    private fun showSignIn(message: String? = null) {
        root.removeAllViews()
        title("Sign in to your EmberStorm")
        text("Your own server, as its owner. Releases the PC left there to be signed show next.", muted = true)
        val server = field("Server address", prefs.getString("server", "") ?: "", InputType.TYPE_TEXT_VARIATION_URI)
        val user = field("Username", prefs.getString("user", "") ?: "", InputType.TYPE_CLASS_TEXT)
        val pass = field("Password", "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        message?.let { text(it, error = true) }
        button("Sign in") {
            val address = normalise(server.text.toString()) ?: return@button showSignIn("Type the server's address, starting https://")
            prefs.edit().putString("server", address).putString("user", user.text.toString().trim()).apply()
            busy("Signing in...")
            background.execute {
                val body = JSONObject().put("username", user.text.toString().trim()).put("password", pass.text.toString()).toString()
                val (code, answer) = call("POST", "/api/login", body)
                runOnUiThread {
                    when (code) {
                        200 -> showWaiting()
                        202 -> waitForApproval(JSONObject(answer).optString("pending"))
                        else -> showSignIn(errorOf(answer, "Could not sign in ($code)."))
                    }
                }
            }
        }
    }

    // A server that approves new devices holds the sign-in until a device
    // already signed in allows it (httpapi/devices.go).
    private fun waitForApproval(id: String) {
        root.removeAllViews()
        title("Waiting for approval")
        text("Allow this sign-in on a phone or computer already signed in to your EmberStorm.", muted = true)
        background.execute {
            repeat(200) {
                Thread.sleep(3000)
                val (code, answer) = call("GET", "/api/login/pending/$id", null)
                if (code == 200 && JSONObject(answer).optBoolean("signedIn")) {
                    runOnUiThread { showWaiting() }; return@execute
                }
                if (code == 403 || code == 404) {
                    runOnUiThread { showSignIn(errorOf(answer, "The sign-in was not allowed.")) }; return@execute
                }
            }
            runOnUiThread { showSignIn("Nobody allowed the sign-in in time.") }
        }
    }

    private fun showWaiting(message: String? = null) {
        root.removeAllViews()
        title("Waiting to be signed")
        message?.let { text(it) }
        busy("Looking...")
        background.execute {
            val (code, answer) = call("GET", "/api/signing", null)
            runOnUiThread {
                root.removeAllViews()
                title("Waiting to be signed")
                message?.let { text(it) }
                if (code == 404) {
                    text("This server is not set up for signing (SOUNDSTORM_SIGNING).", error = true)
                    return@runOnUiThread
                }
                if (code != 200) {
                    text(errorOf(answer, "Could not ask the server ($code)."), error = true)
                    button("Sign in again") { showSignIn() }
                    return@runOnUiThread
                }
                val items = JSONObject(answer).optJSONArray("items")
                if (items == null || items.length() == 0) {
                    text("Nothing is waiting. The PC leaves a release here when it is ready.", muted = true)
                }
                for (i in 0 until (items?.length() ?: 0)) {
                    val item = items!!.getJSONObject(i)
                    val data = Base64.decode(item.getString("data"), Base64.DEFAULT)
                    val name = item.getString("name")
                    val file = item.getString("file")
                    root.addView(card(describe(file, data)))
                    button("Sign this") { askPin(name, data) }
                }
                button("Look again", ghost = true) { showWaiting() }
            }
        }
    }

    /** What a release says of itself, from its own bytes. */
    private fun describe(file: String, data: ByteArray): String {
        val sha = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
        val m = runCatching { JSONObject(String(data, Charsets.UTF_8)) }.getOrNull()
            ?: return "A release that cannot be read ($file). Do not sign it."
        val lines = mutableListOf<String>()
        if (file == "manifest.json") {
            lines += "Box update ${m.optString("version")}"
            lines += "Serial ${m.optLong("serial")}"
            m.optString("notes").takeIf { it.isNotBlank() }?.let { lines += "What's new: $it" }
            lines += "${m.optJSONObject("images")?.length() ?: 0} programs, each pinned"
            lines += if (m.has("system")) "Includes the box's own files" else "Programs only"
            m.optString("expires").takeIf { it.isNotBlank() }?.let { lines += "Good until ${it.take(10)}" }
        } else {
            lines += "Desktop release ${m.optString("version")}"
            lines += "Serial ${m.optLong("serial")}"
            m.optString("commit").takeIf { it.isNotBlank() }?.let { lines += "From the code at ${it.take(12)}" }
            lines += "Files: " + (m.optJSONObject("files")?.keys()?.asSequence()?.joinToString(", ") ?: "none")
        }
        lines += "Fingerprint ${sha.take(16)}"
        return lines.joinToString("\n")
    }

    private fun askPin(name: String, data: ByteArray) {
        val pin = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            hint = "Signing PIN"
        }
        AlertDialog.Builder(this)
            .setTitle("Your signing PIN")
            .setMessage("The YubiKey's signing PIN - not the one for signing in to websites.")
            .setView(pin)
            .setPositiveButton("Next") { _, _ -> holdKey(name, data, pin.text.toString().toCharArray()) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun holdKey(name: String, data: ByteArray, pin: CharArray) {
        root.removeAllViews()
        title("Hold your YubiKey to the back of the phone")
        text("Keep it there until this says it is signed - a few seconds.", muted = true)
        button("Cancel", ghost = true) { stopNfc(); pin.fill(' '); showWaiting() }
        try {
            listening = true
            yubikit.startNfcDiscovery(NfcConfiguration().timeout(30_000), this) { device ->
                device.requestConnection(SmartCardConnection::class.java) { result ->
                    val outcome = runCatching { sign(result.value, data, pin) }
                    runOnUiThread {
                        stopNfc()
                        outcome.fold(
                            onSuccess = { sig -> upload(name, sig) },
                            onFailure = { e ->
                                pin.fill(' ')
                                val why = when (e) {
                                    is InvalidPinException -> "Wrong PIN - ${e.attemptsRemaining} tries left before the key locks its PIN."
                                    else -> e.message ?: "The YubiKey could not sign."
                                }
                                showWaiting(why)
                            },
                        )
                    }
                }
            }
        } catch (e: NfcNotAvailable) {
            listening = false
            showWaiting(if (e.isDisabled) "NFC is switched off: turn it on in the phone's settings." else "This phone has no NFC.")
        }
    }

    /** Signs on the YubiKey, once it is known to hold a release key. */
    private fun sign(conn: SmartCardConnection, data: ByteArray, pin: CharArray): ByteArray {
        val piv = PivSession(conn)
        val meta = piv.getSlotMetadata(Slot.SIGNATURE)
        if (meta.keyType != KeyType.ED25519) error("This YubiKey holds no release key.")
        val pub = (meta.publicKeyValues as? PublicKeyValues.Cv25519)?.bytes ?: error("This YubiKey holds no release key.")
        if (releaseKeys().none { it.contentEquals(pub) }) error("This YubiKey's key is not one of EmberStorm's release keys.")
        try {
            piv.verifyPin(pin)
        } finally {
            pin.fill(' ')
        }
        val sig = piv.rawSignOrDecrypt(Slot.SIGNATURE, KeyType.ED25519, data)
        if (sig.size != 64) error("The YubiKey's answer was not a signature.")
        return sig
    }

    private fun upload(name: String, sig: ByteArray) {
        busy("Handing the signature back...")
        background.execute {
            val body = JSONObject().put("signature", Base64.encodeToString(sig, Base64.NO_WRAP)).toString()
            val (code, answer) = call("PUT", "/api/signing/$name", body)
            runOnUiThread {
                if (code == 200) showWaiting("Signed. The PC can publish it now.")
                else showWaiting(errorOf(answer, "The server did not take the signature ($code)."))
            }
        }
    }

    // --- the server --------------------------------------------------------------

    private fun normalise(typed: String): String? {
        var s = typed.trim().trimEnd('/')
        if (s.isEmpty()) return null
        if (!s.startsWith("https://")) s = "https://" + s.removePrefix("http://")
        return runCatching { URL(s).let { "https://${it.host}" + if (it.port > 0) ":${it.port}" else "" } }.getOrNull()
    }

    private fun call(method: String, path: String, body: String?): Pair<Int, String> = runCatching {
        val conn = URL((prefs.getString("server", "") ?: "") + path).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.instanceFollowRedirects = false
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray()) }
        }
        val code = conn.responseCode
        val stream = if (code >= 400) conn.errorStream else conn.inputStream
        val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
        conn.disconnect()
        code to text
    }.getOrElse { 0 to JSONObject().put("error", "Could not reach the server: ${it.message}").toString() }

    private fun errorOf(answer: String, fallback: String) =
        runCatching { JSONObject(answer).optString("error").takeIf { it.isNotBlank() } }.getOrNull() ?: fallback

    private fun releaseKeys(): List<ByteArray> = assets.open("release.pub").bufferedReader().readLines()
        .map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
        .mapNotNull { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull()?.takeIf { k -> k.size == 32 } }

    private fun stopNfc() {
        if (listening) {
            listening = false
            runCatching { yubikit.stopNfcDiscovery(this) }
        }
    }

    // --- views ----------------------------------------------------------------

    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    private fun lp(top: Int = 0, bottom: Int = 12) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
        topMargin = dp(top); bottomMargin = dp(bottom)
    }

    private fun title(words: String) = root.addView(TextView(this).apply {
        text = words; setTextColor(Color.WHITE); setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f); setTypeface(Typeface.DEFAULT, Typeface.BOLD)
    }, lp(bottom = 12))

    private fun text(words: String, muted: Boolean = false, error: Boolean = false) = root.addView(TextView(this).apply {
        text = words
        setTextColor(if (error) Color.rgb(0xff, 0x8a, 0x80) else if (muted) Color.rgb(0xa8, 0xb0, 0xc0) else Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
    }, lp(bottom = 14))

    private fun card(words: String) = TextView(this).apply {
        text = words
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setLineSpacing(0f, 1.2f)
        setPadding(dp(16), dp(14), dp(16), dp(14))
        setBackgroundColor(Color.rgb(0x17, 0x1b, 0x24))
        layoutParams = lp(top = 8, bottom = 8)
    }

    private fun field(label: String, value: String, type: Int): EditText {
        root.addView(TextView(this).apply { text = label; setTextColor(Color.rgb(0xa8, 0xb0, 0xc0)) }, lp(bottom = 4))
        val f = EditText(this).apply {
            setText(value); inputType = type; setTextColor(Color.WHITE); setHintTextColor(Color.GRAY)
        }
        root.addView(f, lp(bottom = 12))
        return f
    }

    private fun button(label: String, ghost: Boolean = false, onTap: () -> Unit) = root.addView(Button(this).apply {
        text = label
        isAllCaps = false
        setTextColor(if (ghost) Color.WHITE else Color.BLACK)
        setBackgroundColor(if (ghost) Color.rgb(0x17, 0x1b, 0x24) else Color.rgb(0x5b, 0x9c, 0xff))
        setOnClickListener { onTap() }
    }, lp(top = 4, bottom = 8))

    private fun busy(words: String) {
        root.removeAllViews()
        root.addView(TextView(this).apply {
            text = words; setTextColor(Color.rgb(0xa8, 0xb0, 0xc0)); gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        }, lp(top = 40))
        root.visibility = View.VISIBLE
    }
}
