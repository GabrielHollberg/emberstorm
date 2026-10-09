package dev.soundstorm.app

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.app.UiModeManager
import android.content.res.Configuration
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Message
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.window.OnBackInvokedDispatcher
import android.webkit.CookieManager
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.Toast
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Shows the connect screen until a server is known, then the server's own web
 * app, full screen. The page is the app: this only gives it what a browser
 * tab would (dialogs, file pickers, full-screen video, links out, recovering
 * from a failed load) plus what a tab cannot - playing on with the screen off,
 * with lock-screen controls (PlaybackService). The Android counterpart of the
 * iPhone app's RootViewController, ConnectViewController and WebViewController.
 */
class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var content: FrameLayout
    private lateinit var statusScrim: View
    private lateinit var navScrim: View
    private var webView: WebView? = null
    private var server: Uri? = null
    private var failure: View? = null
    private var fullscreen: View? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private var safeCss = ""
    private var safeScript: androidx.webkit.ScriptHandler? = null
    /** Set once the saved home name failed and its away twin was tried. */
    private var triedAway = false
    private val background = Executors.newSingleThreadExecutor()

    /** On a TV (Google TV, Android TV, Fire TV): the page lays itself out for
     *  the room and the remote, told by its user agent. */
    private val isTv by lazy {
        getSystemService(UiModeManager::class.java)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature("android.software.leanback")
    }

    // Whether there is something to show: the page has let its loading
    // screen go (signed in, or the sign-in, or a message), or one of the
    // app's own screens is up.
    @Volatile private var ready = false

    /**
     * Keeps the system's opening screen (the icon on black) up until the app
     * is ready to be used, so opening it goes from the icon straight to the
     * app - it used to go icon, blank, icon (the owner). Eight seconds at most
     * (the owner's choice): then the page's own loading screen, the same icon,
     * carries on, and says what is wrong if anything is.
     */
    private fun holdOpeningScreen() {
        val v = findViewById<View>(android.R.id.content)
        val until = android.os.SystemClock.uptimeMillis() + OPENING_HOLD_MS
        v.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (!ready && android.os.SystemClock.uptimeMillis() < until) return false
                v.viewTreeObserver.removeOnPreDrawListener(this)
                return true
            }
        })
        v.postDelayed({ markReady() }, OPENING_HOLD_MS)
    }

    private fun markReady() {
        if (ready) return
        ready = true
        findViewById<View>(android.R.id.content)?.invalidate()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Both bars hidden, everywhere (the owner's asking - the one thing
        // the installed web app could never do, as Chrome owns its bars): a
        // swipe in from an edge shows them for a moment, as in a game or a
        // video. The app draws into the camera cutout too, so there is no
        // black strip across the top; the page is kept clear of the cutout
        // itself, and that sliver is painted in the page's theme colour.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        hideBars()
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        content = FrameLayout(this)
        statusScrim = View(this).apply { setBackgroundColor(Color.BLACK) }
        navScrim = View(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(content, FrameLayout.LayoutParams(MATCH, MATCH))
        root.addView(statusScrim, FrameLayout.LayoutParams(MATCH, 0, Gravity.TOP))
        root.addView(navScrim, FrameLayout.LayoutParams(MATCH, 0, Gravity.BOTTOM))
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            // The bars' own space only (none while they are hidden). The
            // camera cutout is not padded: the page draws up into it, and
            // the web view tells the page where it is (env(safe-area-inset-*)),
            // which the page already keeps its words clear of.
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
            val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            setSafeArea(cut.top, cut.right, cut.bottom, cut.left)
            content.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            statusScrim.layoutParams = (statusScrim.layoutParams as FrameLayout.LayoutParams).apply { height = bars.top }
            navScrim.layoutParams = (navScrim.layoutParams as FrameLayout.LayoutParams).apply { height = bars.bottom }
            WindowInsetsCompat.CONSUMED
        }
        setContentView(root)
        holdOpeningScreen()
        // Back, the new way. From Android 16 an app built for it no longer
        // gets onBackPressed: without this the system closed the app on
        // Back, from inside a menu or Now Playing - found on the TV.
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { goBack() }
        }

        // (A server address given in the launching intent, once used for
        // testing, is gone: the activity is exported, so any app on the device
        // could have pointed EmberStorm at its own server - found by a
        // security review.)
        val saved = ServerAddress.saved(this)
        // Opened from a TV's sign-in code: the server's page asks "Sign in a
        // TV?" for it.
        val link = tvLink(intent)
        if (link != null) pendingLink = link.second
        // Opened from Open my EmberStorm on emberstorm.app.
        val opened = if (link == null) openLink(intent) else null
        val start = link?.first ?: opened?.first?.takeIf { opened.second } ?: saved
        when {
            opened != null && !opened.second -> showConnect(opened.first)
            start != null -> {
                if (opened != null) ServerAddress.remember(this, start)
                showWeb(start)
            }
            else -> showConnect(null)
        }
        // Opened from the Share sheet: the files go to the page once it is up.
        // Not again when the activity is only made again (a rotation).
        if (savedInstanceState == null) takeShare(intent)
        // Photo backup's jobs, if it is on: kept up to date with its options.
        if (!isTv) PhotoBackup.schedule(applicationContext)
    }

    /**
     * Tells the page how much room the camera cutout needs, in CSS pixels, as
     * the --safe-* values style.css spaces its edges by. The web view itself
     * reports 0 for a cutout the app draws into, which would put the page's
     * header under the camera. Set before each page's own scripts run (a
     * document-start script, replaced when the cutout changes, as on turning
     * the phone) and on the page already showing.
     */
    private fun setSafeArea(top: Int, right: Int, bottom: Int, left: Int) {
        // A TV has no cutout; its margins are the page's own (html.tv).
        if (isTv) return
        val d = resources.displayMetrics.density
        val css = "t=${(top / d).toInt()};r=${(right / d).toInt()};b=${(bottom / d).toInt()};l=${(left / d).toInt()}"
        if (css == safeCss) return
        safeCss = css
        applySafeArea()
    }

    private fun safeAreaScript(): String {
        val v = safeCss.split(';').associate { it.substringBefore('=') to it.substringAfter('=') }
        return "(() => { const s = document.documentElement.style;" +
            " s.setProperty('--safe-top', '${v["t"] ?: 0}px'); s.setProperty('--safe-right', '${v["r"] ?: 0}px');" +
            " s.setProperty('--safe-bottom', '${v["b"] ?: 0}px'); s.setProperty('--safe-left', '${v["l"] ?: 0}px'); })();"
    }

    private fun applySafeArea() {
        val view = webView ?: return
        val origin = server?.let(ServerAddress::origin) ?: return
        if (safeCss.isEmpty()) return
        val script = safeAreaScript()
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            safeScript?.remove()
            safeScript = WebViewCompat.addDocumentStartJavaScript(view, script, setOf(origin))
        }
        view.evaluateJavascript(script, null)
    }

    /** Hides the status and navigation bars; a swipe from an edge shows them briefly. */
    private fun hideBars() {
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    // Hidden again whenever the window comes back - after a dialog, the file
    // picker, another app, or the screen waking.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideBars()
    }

    override fun onResume() {
        super.onResume()
        PlayerLog.add("app in front")
        resumed = true
        hideBars()
        // The page Android ended while the app was in the background, made
        // again now it is looked at.
        if (pageLost) {
            pageLost = false
            server?.let { showWeb(it, keepMusic = true) }
        }
    }

    // The sign-in is a cookie, which the web view writes to storage in its own
    // time; Android often ends a backgrounded app before it has, and the next
    // open asked for the password again (the owner's report). Written the
    // moment the app is left.
    override fun onPause() {
        PlayerLog.add("app left")
        resumed = false
        CookieManager.getInstance().flush()
        mirrorCookies()
        super.onPause()
    }

    private var resumed = false
    private var pageLost = false

    /**
     * True while the page controls a TV (Play on): the volume buttons then
     * turn the TV's volume, not the phone's - the page sends it and shows the
     * level. Only while the app is in front; with the screen off or another
     * app open they are the phone's as always.
     */
    private var remoteVolume = false

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val dir = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> 1
            KeyEvent.KEYCODE_VOLUME_DOWN -> -1
            else -> 0
        }
        val view = webView
        if (dir != 0 && remoteVolume && view != null) {
            // Held down, the button repeats: each repeat is a step.
            if (event.action == KeyEvent.ACTION_DOWN) {
                view.evaluateJavascript("window.__soundstormVolumeKey && window.__soundstormVolumeKey($dir)", null)
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        webView?.let {
            MediaBridge.detach(it)
            NativeAudio.detachView(it)
            (it.parent as? android.view.ViewGroup)?.removeView(it)
            it.destroy()
        }
        background.shutdownNow()
        super.onDestroy()
    }

    // ---------------------------------------------------------------- connect

    /** Counts connect screens shown, so a search finishing late finds it gone. */
    private var connectScreen = 0

    private fun showConnect(prefill: Uri?) {
        markReady()
        tearDownWeb()
        setStatusColor(Color.BLACK)
        val surface = Color.rgb(0x17, 0x1b, 0x22)
        val accent = Color.rgb(0x6a, 0xa8, 0xff)

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(24))
        }
        val logo = ImageView(this).apply {
            setImageResource(R.drawable.logo)
            clipToOutline = true
            background = GradientDrawable().apply { cornerRadius = dp(18).toFloat(); setColor(Color.BLACK) }
        }
        column.addView(logo, LinearLayout.LayoutParams(dp(80), dp(80)).apply { bottomMargin = dp(16) })
        column.addView(TextView(this).apply {
            text = getString(R.string.app_name)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 32f)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD_ITALIC)
        }, wrap(bottom = 16))
        // Servers found on this network that are not saved yet: one tap,
        // nothing to type (ServerDiscovery), filled in as the search answers.
        val nearby = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE }
        column.addView(nearby, fill(bottom = 16))
        // Your servers: the latest used first, the one in use ticked; a tap
        // switches, a hold offers Rename and Remove.
        val servers = ServerAddress.all(this)
        if (servers.isNotEmpty()) {
            column.addView(TextView(this).apply {
                text = "Your servers"
                setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            }, fill(bottom = 8))
            val inUse = ServerAddress.saved(this)?.let(ServerAddress::origin)
            for (s in servers) column.addView(serverRow(s, ServerAddress.origin(s.url) == inUse, surface, accent), fill(bottom = 8))
        }
        column.addView(TextView(this).apply {
            text = if (servers.isEmpty()) "Enter your server's address - the one you open in a browser - or just the code at its start (abc123)."
                else "Or add another - its address, or just the code at its start."
            setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            gravity = Gravity.CENTER
        }, fill(top = if (servers.isEmpty()) 0 else 16, bottom = 28))
        val known = prefill != null && servers.any { ServerAddress.origin(it.url) == ServerAddress.origin(prefill) }
        val field = EditText(this).apply {
            hint = "abc123.home.emberstorm.app"
            // Without the scheme for https (the default when none is typed),
            // with it for plain http, which would otherwise be read as https.
            // A server already in the list is not typed out again.
            setText(prefill?.takeUnless { known }?.let {
                val hostPort = it.host + if (it.port != -1) ":${it.port}" else ""
                if (it.scheme == "https") hostPort else "${it.scheme}://$hostPort"
            } ?: "")
            setTextColor(Color.WHITE)
            setHintTextColor(Color.argb(0x66, 0xff, 0xff, 0xff))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            isSingleLine = true
            setPadding(dp(14), 0, dp(14), 0)
            background = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(surface) }
        }
        column.addView(field, fill(height = 50, bottom = 16))
        val button = Button(this).apply {
            text = "Connect"
            isAllCaps = false
            setTextColor(Color.BLACK)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(typeface, Typeface.BOLD)
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(accent) }
            stateListAnimator = null
        }
        column.addView(button, fill(height = 52, bottom = 16))
        val busy = ProgressBar(this).apply { visibility = View.GONE; isIndeterminate = true }
        column.addView(busy, wrap(bottom = 8))
        val message = TextView(this).apply {
            setTextColor(Color.rgb(0xff, 0x45, 0x3a))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
        }
        column.addView(message, fill())

        // Centred in whatever the keyboard leaves, and no wider than 420dp so
        // it stays a column on a tablet.
        // Scrolls once the list is longer than the screen.
        val holder = FrameLayout(this)
        holder.addView(column, FrameLayout.LayoutParams(minOf(dp(420), resources.displayMetrics.widthPixels), FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        val scroller = android.widget.ScrollView(this).apply { isFillViewport = true }
        scroller.addView(holder, FrameLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT))
        content.removeAllViews()
        content.addView(scroller, FrameLayout.LayoutParams(MATCH, MATCH))

        var checking = false
        // A phone leaves the house, so it keeps the away name when there is
        // one (the page moves to the home name when it can); a TV stays put
        // and keeps the home name.
        val preferAway = !isTv
        fun connect() {
            if (checking) return
            val typed = field.text.toString()
            if (ServerAddress.candidates(typed, preferAway) == null) {
                message.text = "That doesn't look like a web address."
                return
            }
            message.text = ""
            checking = true
            field.isEnabled = false
            button.text = "Connecting"
            busy.visibility = View.VISIBLE
            background.execute {
                var found: Uri? = null
                val problem = try {
                    found = ServerAddress.find(typed, preferAway)
                    null
                } catch (e: ServerAddress.CheckFailed) {
                    e.message
                }
                runOnUiThread {
                    checking = false
                    field.isEnabled = true
                    button.text = "Connect"
                    busy.visibility = View.GONE
                    val url = found
                    if (url != null) {
                        ServerAddress.remember(this, url)
                        hideKeyboard(field)
                        showWeb(url)
                    } else {
                        message.text = problem
                    }
                }
            }
        }
        // The network search: again after a while, as the server may still be
        // starting - every 10 seconds while nothing is found, 30 once
        // something is - for as long as this screen is the one showing.
        val screen = ++connectScreen
        val savedHosts = servers.mapNotNull { it.url.host }.toSet()
        fun use(server: ServerDiscovery.Found) {
            if (checking) return
            checking = true
            busy.visibility = View.VISIBLE
            background.execute {
                // A home name's code finds the away name too, which a phone keeps.
                val code = ServerAddress.homeCode(server.url.host)
                val url = code?.let { runCatching { ServerAddress.find(it, preferAway) }.getOrNull() } ?: server.url
                runOnUiThread {
                    checking = false
                    busy.visibility = View.GONE
                    if (screen != connectScreen) return@runOnUiThread
                    ServerAddress.remember(this, url)
                    server.name?.let { ServerAddress.rename(this, url, it) }
                    hideKeyboard(field)
                    showWeb(url)
                }
            }
        }
        // A new box (no owner yet): the setup code from its sticker, scanned
        // or typed, and the page opened with it, so its sign-up asks only a
        // name and a password - as the iPhone app does.
        fun setUp(box: ServerDiscovery.Found) {
            if (checking) return
            askSetupCode { code ->
                if (screen != connectScreen) return@askSetupCode
                ServerAddress.remember(this, box.url)
                hideKeyboard(field)
                // The code goes in the address only to the box's own secure
                // name (ServerDiscovery checks it is the same box). Over
                // plain http the page asks for it on screen instead, where
                // the person sees the address it goes to (the twelfth
                // security pass).
                if (box.url.scheme == "https") {
                    showWeb(box.url.buildUpon().appendQueryParameter("setup", code).build())
                } else {
                    Toast.makeText(this, "Type the setup code again on the next screen: $code", Toast.LENGTH_LONG).show()
                    showWeb(box.url)
                }
            }
        }
        fun foundButton(label: String, onTap: () -> Unit) = Button(this).apply {
            text = label
            isAllCaps = false
            setTextColor(Color.BLACK)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(typeface, Typeface.BOLD)
            background = android.graphics.drawable.StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                    cornerRadius = dp(14).toFloat(); setColor(accent); setStroke(dp(3), Color.WHITE)
                })
                addState(intArrayOf(), GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(accent) })
            }
            stateListAnimator = null
            setOnClickListener { onTap() }
        }
        // Under each server found, where it is: its name is only what it says
        // of itself, and anything on the network can say "Gabriel's EmberStorm"
        // (a security review).
        fun whereItIs(f: ServerDiscovery.Found) = TextView(this).apply {
            text = f.url.host ?: ""
            setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
        }
        fun heading(words: String) = TextView(this).apply {
            text = words
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        fun showFound(found: List<ServerDiscovery.Found>) {
            nearby.removeAllViews()
            nearby.visibility = if (found.isEmpty()) View.GONE else View.VISIBLE
            if (found.isEmpty()) return
            // Something to tap: the keyboard put up for typing an address goes.
            if (field.text.isEmpty()) hideKeyboard(field)
            val fresh = found.filter { !it.setUp }
            val ready = found.filter { it.setUp }
            if (fresh.isNotEmpty()) {
                nearby.addView(heading(if (fresh.size == 1) "We found your new EmberStorm" else "We found new EmberStorms - which is yours?"), fill(bottom = 10))
                if (isTv) {
                    // A TV cannot read the sticker: the owner's phone sets it
                    // up first, as on the Apple TV.
                    nearby.addView(TextView(this).apply {
                        text = "Set it up with the EmberStorm app on your phone first, then sign in here."
                        setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                        gravity = Gravity.CENTER
                    }, fill(bottom = 16))
                } else {
                    for (f in fresh) {
                        nearby.addView(foundButton(if (fresh.size == 1) "Set it up" else "Set up ${f.label}") { setUp(f) }, fill(height = 52, bottom = 2))
                        nearby.addView(whereItIs(f), fill(bottom = 8))
                    }
                }
            }
            if (ready.isNotEmpty()) {
                val one = ready.size == 1
                nearby.addView(heading(when {
                    one && ready[0].name != null -> "We found ${ready[0].name} on your network"
                    one -> "We found EmberStorm on your network"
                    else -> "We found EmberStorm on your network - which one?"
                }), fill(top = if (fresh.isEmpty()) 0 else 12, bottom = 10))
                for (f in ready) {
                    val label = if (!one) f.label else if (f.name != null) "Sign in" else "Use it - ${f.label}"
                    nearby.addView(foundButton(label) { use(f) }, fill(height = 52, bottom = 2))
                    nearby.addView(whereItIs(f), fill(bottom = 8))
                }
            }
            // On a TV the remote lands on the first button.
            if (isTv && servers.isEmpty()) (0 until nearby.childCount).map { nearby.getChildAt(it) }.firstOrNull { it is Button }?.requestFocus()
        }
        fun search() {
            background.execute {
                val found = ServerDiscovery.search().filter { it.url.host !in savedHosts }
                runOnUiThread {
                    if (screen != connectScreen) return@runOnUiThread
                    showFound(found)
                    content.postDelayed({ if (screen == connectScreen) search() }, if (found.isEmpty()) 10_000L else 30_000L)
                }
            }
        }
        search()
        button.setOnClickListener { connect() }
        field.setOnEditorActionListener { _, action, event ->
            if (action == EditorInfo.IME_ACTION_GO || event?.keyCode == KeyEvent.KEYCODE_ENTER) {
                connect(); true
            } else false
        }
        // The keyboard only when there is nothing to pick from.
        if (servers.isEmpty()) {
            field.requestFocus()
            field.post { getSystemService(InputMethodManager::class.java).showSoftInput(field, 0) }
        }
    }

    /**
     * Asks for a new box's setup code: scanned off its sticker with Google's
     * scanner (the code alone, or an address carrying ?setup=), or typed.
     * Capitals, spaces and dashes do not matter; the server checks it.
     */
    private fun askSetupCode(then: (String) -> Unit) {
        val field = EditText(this).apply {
            hint = "ABCD-EFGH-..."
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSingleLine = true
        }
        val pad = LinearLayout(this).apply {
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(field, LinearLayout.LayoutParams(MATCH, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Set up your EmberStorm")
            .setMessage("Type the setup code printed on the sticker on the box, or scan its QR code.")
            .setView(pad)
            .setPositiveButton("Continue", null)
            .setNeutralButton("Scan the sticker", null)
            .setNegativeButton("Cancel", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val code = setupCodeIn(field.text.toString())
                if (code.isEmpty()) return@setOnClickListener
                dialog.dismiss()
                then(code)
            }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                val options = com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions.Builder()
                    .setBarcodeFormats(com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE)
                    .build()
                com.google.mlkit.vision.codescanner.GmsBarcodeScanning.getClient(this, options).startScan()
                    .addOnSuccessListener { barcode ->
                        val code = setupCodeIn(barcode.rawValue ?: "")
                        if (code.isEmpty()) return@addOnSuccessListener
                        dialog.dismiss()
                        then(code)
                    }
                    .addOnFailureListener { Toast.makeText(this, "Could not scan - type the code instead.", Toast.LENGTH_LONG).show() }
            }
        }
        dialog.show()
    }

    /** The setup code in what was typed or scanned: an address's ?setup=, or the text itself. */
    private fun setupCodeIn(text: String): String {
        val raw = text.trim()
        val fromLink = runCatching { Uri.parse(raw) }.getOrNull()
            ?.takeIf { it.isHierarchical && it.scheme != null }?.getQueryParameter("setup")
        return (fromLink ?: raw).filter { it.isLetterOrDigit() || it == '-' }.take(64)
    }

    /** One saved server on the connect screen. */
    private fun serverRow(s: ServerAddress.Server, inUse: Boolean, surface: Int, accent: Int): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(10))
            isClickable = true
            isFocusable = true
            // A ring for the TV remote's focus, the fill otherwise.
            background = android.graphics.drawable.StateListDrawable().apply {
                addState(intArrayOf(android.R.attr.state_focused), GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat(); setColor(surface); setStroke(dp(2), Color.WHITE)
                })
                addState(intArrayOf(android.R.attr.state_pressed), GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat(); setColor(Color.rgb(0x24, 0x2a, 0x34))
                })
                addState(intArrayOf(), GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(surface) })
            }
        }
        val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(TextView(this).apply {
            text = s.name
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        texts.addView(TextView(this).apply {
            text = ServerAddress.origin(s.url).removePrefix("https://")
            setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
        })
        row.addView(texts, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (inUse) row.addView(TextView(this).apply {
            text = "✓"
            contentDescription = "In use"
            setTextColor(accent)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = dp(10) })
        row.setOnClickListener {
            ServerAddress.remember(this, s.url)
            hideKeyboard(row)
            showWeb(s.url)
        }
        row.setOnLongClickListener {
            AlertDialog.Builder(this)
                .setTitle(s.name)
                .setItems(arrayOf("Rename", "Remove")) { _, which ->
                    if (which == 0) renameServer(s) else {
                        AlertDialog.Builder(this)
                            .setTitle("Remove ${s.name}?")
                            .setMessage("It comes off this list. Nothing on the server changes, and you can add it again with its address.")
                            .setPositiveButton("Remove") { _, _ ->
                                ServerAddress.forget(this, s.url)
                                showConnect(null)
                            }
                            .setNegativeButton("Cancel", null)
                            .show()
                    }
                }
                .show()
            true
        }
        return row
    }

    private fun renameServer(s: ServerAddress.Server) {
        val box = EditText(this).apply {
            setText(s.name)
            setSelectAllOnFocus(true)
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS
        }
        val frame = FrameLayout(this).apply { setPadding(dp(20), dp(8), dp(20), 0); addView(box) }
        AlertDialog.Builder(this)
            .setTitle("Rename")
            .setView(frame)
            .setPositiveButton("Save") { _, _ ->
                ServerAddress.rename(this, s.url, box.text.toString().take(60))
                showConnect(null)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // -------------------------------------------------------------------- web

    @SuppressLint("SetJavaScriptEnabled")
    private fun showWeb(target: Uri, keepMusic: Boolean = false) {
        connectScreen++ // the connect screen's network search stops
        tearDownWeb(keepMusic)
        server = target
        content.removeAllViews()
        val view = WebView(this)
        view.setBackgroundColor(Color.BLACK)
        // No stretch at the end of a page: the whole page is this one view,
        // so Android's stretch moved the tab bar and the header with it.
        view.overScrollMode = View.OVER_SCROLL_NEVER
        // No scrollbar of the web view's own at the edge: the page hides its
        // scrollbars, but this one is the view's, drawn over it (the owner).
        view.isVerticalScrollBarEnabled = false
        view.isHorizontalScrollBarEnabled = false
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // The queue moving on to the next song is not a tap.
            mediaPlaybackRequiresUserGesture = false
            setSupportMultipleWindows(true)
            javaScriptCanOpenWindowsAutomatically = false
            // Nothing on the phone is the page's to read (a security review).
            allowContentAccess = false
            allowFileAccess = false
            // Chrome's own user agent, with a name the page can test for.
            userAgentString = "$userAgentString SoundStormApp/1" + if (isTv) " SoundStormTV/1" else ""
        }
        // chrome://inspect only in a build marked debuggable, which the
        // published one is not (build.gradle.kts): with it, anyone with adb
        // access had a console inside the signed-in page.
        WebView.setWebContentsDebuggingEnabled((applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0)

        val origin = ServerAddress.origin(target)
        ServerAddress.current = origin
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(view, "SoundStormNative", setOf(origin)) { _, message, source, isMainFrame, _ ->
                if (isMainFrame && source.toString().trimEnd('/') == origin) received(message.data)
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(view, PageScript.SOURCE, setOf(origin))
        }
        view.webViewClient = Client()
        view.webChromeClient = Chrome()
        content.addView(view, FrameLayout.LayoutParams(MATCH, MATCH))
        webView = view
        MediaBridge.attach(view)
        NativeAudio.attachView(view)
        safeScript = null
        applySafeArea()
        load()
    }

    /**
     * Scans a TV's sign-in QR code with Google's own scanner (Play services:
     * its screen, no camera permission for the app), and hands the code to
     * the page, which asks "Sign in a TV?". The QR holds the TV's address
     * with ?link=<code>; a code alone, or a soundstorm://link, also does.
     */
    private fun scanTvCode() {
        val options = com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions.Builder()
            .setBarcodeFormats(com.google.mlkit.vision.barcode.common.Barcode.FORMAT_QR_CODE)
            .build()
        val tell = { what: String ->
            webView?.evaluateJavascript("window.__soundstormScanned && window.__soundstormScanned(" + JSONObject.quote(what) + ")", null)
        }
        com.google.mlkit.vision.codescanner.GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { barcode ->
                val code = scannedCode(barcode.rawValue)
                if (code == null) {
                    tell("not-ours")
                    return@addOnSuccessListener
                }
                webView?.evaluateJavascript("window.__soundstormLink && window.__soundstormLink(" + JSONObject.quote(code) + ", 'scanned')", null)
            }
            .addOnFailureListener { tell("failed") }
    }

    private fun scannedCode(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val uri = runCatching { Uri.parse(raw.trim()) }.getOrNull()
        val fromLink = uri?.let { u ->
            if (u.isHierarchical) u.getQueryParameter("link") ?: u.getQueryParameter("code") else null
        }
        val code = (fromLink ?: raw).uppercase().filter { it.isLetterOrDigit() }
        return code.takeIf { it.length == 6 && (fromLink != null || raw.trim().length <= 9) }
    }

    /** Files shared to EmberStorm, waiting for the page to take them. */
    private var pendingShare: org.json.JSONArray? = null

    /**
     * Files from the Share sheet: copied into the app (slow for a film, so not
     * on the main thread) and handed to the page, which shows its review as
     * for Add media. Answers whether the intent was a share.
     */
    private fun takeShare(intent: Intent?): Boolean {
        if (isTv) return false
        val uris = Shared.urisOf(intent)
        if (uris.isEmpty()) return false
        Toast.makeText(this, if (uris.size == 1) "Getting the file ready..." else "Getting ${uris.size} files ready...", Toast.LENGTH_SHORT).show()
        val c = applicationContext
        Thread {
            val list = Shared.receive(c, uris, intent?.type)
            runOnUiThread {
                pendingShare = list
                offerShare(0)
            }
        }.start()
        return true
    }

    /**
     * The page takes shared files once somebody is signed in; until then (it
     * is loading, or asking for a password) it is asked again, for a few
     * minutes.
     */
    private fun offerShare(tries: Int) {
        val list = pendingShare ?: return
        val view = webView
        if (view == null) {
            if (tries < 120) content.postDelayed({ offerShare(tries + 1) }, 1500)
            return
        }
        view.evaluateJavascript("(typeof window.__soundstormShared === 'function' && window.__soundstormShared($list)) === true") { took ->
            if (took == "true") pendingShare = null
            else if (tries < 120) content.postDelayed({ offerShare(tries + 1) }, 1500)
        }
    }

    /** A TV's sign-in code waiting for the page to load (soundstorm://link). */
    private var pendingLink: String? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (takeShare(intent)) return
        openLink(intent)?.let { (to, known) ->
            if (!known) showConnect(to)
            else if (server?.let(ServerAddress::origin) != ServerAddress.origin(to)) {
                ServerAddress.remember(this, to)
                showWeb(to)
            }
            return
        }
        val link = tvLink(intent) ?: return
        val view = webView
        if (view != null && server?.let(ServerAddress::origin) == ServerAddress.origin(link.first)) {
            // The page is there: it asks at once, nothing reloaded (music
            // playing in it carries on). A page that cannot - not signed in,
            // or loaded before it knew how (the owner's first try just
            // brought the app forward) - is loaded again with the code.
            val code = link.second
            view.evaluateJavascript(
                "(typeof window.__soundstormLink === 'function' && window.__soundstormLink(" + JSONObject.quote(code) + ")) === true",
            ) { took ->
                if (took != "true") {
                    pendingLink = code
                    load()
                }
            }
        } else {
            pendingLink = link.second
            showWeb(link.first)
        }
    }

    /**
     * A soundstorm://link?server=&code= link: the server it is for and the
     * code. Only a server this app already knows - its saved ones, or the
     * install's secure name it moved to - is opened: a link must never point
     * the app somewhere new. Unknown, the app's own server is used, where a
     * code from elsewhere simply finds no TV.
     */
    private fun tvLink(intent: Intent?): Pair<Uri, String>? {
        val data = intent?.data ?: return null
        val host = data.host?.lowercase() ?: return null
        val (rawCode, wanted) = when {
            data.scheme == "soundstorm" && host == "link" ->
                (data.getQueryParameter("code") ?: return null) to data.getQueryParameter("server")?.let(ServerAddress::parse)
            // The QR's own address, opened by the camera (an App Link).
            data.scheme == "https" && ServerAddress.isInstallName(host) &&
                data.pathSegments.size == 2 && data.pathSegments[0] == "link" ->
                data.pathSegments[1] to data.buildUpon().path("/").clearQuery().fragment(null).build()
            else -> return null
        }
        val code = rawCode.uppercase().filter { it.isLetterOrDigit() }
        if (code.length != 6) return null
        val known = ServerAddress.all(this).map { it.url } + listOfNotNull(ServerAddress.saved(this))
        val installId = { u: Uri -> u.host?.lowercase()?.takeIf { ServerAddress.zoneOf(it) != null }?.substringBefore('.') }
        val match = wanted?.let { w ->
            known.firstOrNull { ServerAddress.origin(it) == ServerAddress.origin(w) }
                ?: known.firstOrNull { installId(it) != null && installId(it) == installId(w) }
                ?: ServerAddress.current?.let(ServerAddress::parse)?.takeIf { ServerAddress.origin(it) == ServerAddress.origin(w) }
        }
        val saved = ServerAddress.saved(this)
        // A link naming a server this app does not know is not handed to its
        // own: anybody could send one carrying a code of theirs, and one
        // "Allow" would sign their TV in as this person (a security review).
        // The install's chosen name is known only by where it leads: the
        // same address as the server saved.
        // A link naming no server is nobody's in particular: not handed to
        // the saved one (the twelfth security pass).
        val server = match ?: when {
            wanted == null -> null
            saved != null && sameAddress(wanted, saved) -> saved
            else -> null
        } ?: return null
        return server to code
    }

    /** Whether two addresses' names lead to one machine; asked off the main
     *  thread, two seconds at most, as a link is being opened. */
    private fun sameAddress(a: Uri, b: Uri): Boolean {
        var same = false
        val look = Thread {
            same = runCatching {
                val there = java.net.InetAddress.getAllByName(a.host).map { it.hostAddress }.toSet()
                java.net.InetAddress.getAllByName(b.host).any { it.hostAddress in there }
            }.getOrDefault(false)
        }
        look.start()
        look.join(2000)
        return same
    }

    /**
     * https://names.emberstorm.app/open?to=<server> (or names.soundstorm.dev,
     * from before the rename), from Open my EmberStorm on emberstorm.app. A server this app knows (by its address or the
     * install's id, as tvLink matches) is opened - the saved address, which
     * may be the away name the found home one is a twin of - and true comes
     * with it. One it does not know is not opened: it is put in the Connect
     * screen for the person to choose, as a link must never point the app
     * somewhere new by itself.
     */
    private fun openLink(intent: Intent?): Pair<Uri, Boolean>? {
        val data = intent?.data ?: return null
        if (data.scheme != "https" || data.host?.lowercase() !in ServerAddress.ZONES.map { "names.$it" } || data.path != "/open") return null
        // No server named (away from home, where nothing was found): the
        // app's own server.
        if (data.getQueryParameter("to").isNullOrEmpty()) return ServerAddress.saved(this)?.let { it to true }
        val to = data.getQueryParameter("to")?.let(ServerAddress::parse) ?: return null
        val host = to.host?.lowercase() ?: return null
        if (to.scheme != "https" || !ServerAddress.isInstallName(host)) return null
        val known = ServerAddress.all(this).map { it.url } + listOfNotNull(ServerAddress.saved(this))
        val installId = { u: Uri -> u.host?.lowercase()?.takeIf { ServerAddress.zoneOf(it) != null }?.substringBefore('.') }
        val match = known.firstOrNull { ServerAddress.origin(it) == ServerAddress.origin(to) }
            ?: known.firstOrNull { installId(it) != null && installId(it) == installId(to) }
        return if (match != null) match to true else to to false
    }

    private fun load() {
        failure?.let { content.removeView(it) }
        failure = null
        server?.let { s ->
            val code = pendingLink
            pendingLink = null
            webView?.loadUrl(if (code != null) s.buildUpon().appendQueryParameter("link", code).build().toString() else s.toString())
        }
    }

    private fun tearDownWeb(keepMusic: Boolean = false) {
        webView?.let {
            MediaBridge.detach(it)
            NativeAudio.detachView(it)
            // A page Android ended is not the music ending: the native player
            // plays on through the songs it was handed.
            if (!keepMusic) NativeAudio.handle(applicationContext, org.json.JSONObject().put("cmd", "stop"))
            it.stopLoading()
            it.destroy()
        }
        webView = null
        // Nothing can play without the page.
        PlaybackService.stop(this)
    }

    private fun received(data: String?) {
        val message = runCatching { JSONObject(data ?: "") }.getOrNull() ?: return
        when (message.optString("type")) {
            // Posted, so the web view is not torn down inside its own callback.
            "changeServer" -> content.post { showConnect(server) }
            // The page let its loading screen go: the opening screen may too.
            "ready" -> content.post { markReady() }
            "media" -> MediaBridge.update(applicationContext, message)
            "audio" -> {
                // Songs from the server now play natively: whatever the page
                // was playing the old way (a download) is let go.
                if (message.optString("cmd") == "load") PlaybackService.stop(this)
                NativeAudio.handle(applicationContext, message)
            }
            "interrupted" -> MediaBridge.interruption(true)
            "resumed" -> MediaBridge.interruption(false)
            "themeColor" -> setStatusColor(runCatching { Color.parseColor(message.optString("color")) }.getOrDefault(Color.BLACK))
            "scanCode" -> scanTvCode()
            "uploads" -> uploads(message.optString("cmd"), message.optJSONObject("data") ?: JSONObject())
            "remoteVolume" -> remoteVolume = message.optBoolean("on")
            // A piece of a file shared to EmberStorm, for the page (Shared).
            "readFile" -> {
                val req = message.optLong("req")
                val id = message.optString("id")
                val from = message.optLong("from")
                val to = message.optLong("to")
                Thread {
                    val b64 = Shared.read(applicationContext, id, from, to)
                    runOnUiThread {
                        webView?.evaluateJavascript(
                            "window.__soundstormFileData && window.__soundstormFileData($req, " +
                                (b64?.let { "\"" + it + "\"" } ?: "null") + ")", null)
                    }
                }.start()
            }
            // A playback report: what the native player saw (PlayerLog).
            "playerLog" -> webView?.evaluateJavascript(
                "window.__soundstormPlayerLog && window.__soundstormPlayerLog(" +
                    JSONObject.quote(PlayerLog.text(applicationContext)) + ")", null)
            "backup" -> backup(message.optString("cmd"), message.optJSONObject("options") ?: JSONObject())
        }
    }

    /**
     * Phone photo backup, as the page's Settings asks: "status" answers how
     * it is going; "set" turns it on or off and changes its options, asking
     * for the camera roll first when it is turned on.
     */
    private fun backup(cmd: String, options: JSONObject) {
        if (isTv) return
        when (cmd) {
            "set" -> {
                // Where photos go is this phone's question, never the page's
                // alone: a page could otherwise send a phone's whole camera
                // roll to another server (the twelfth security pass). The
                // first time, and whenever the page is another server's,
                // the phone asks, naming it.
                val here = ServerAddress.current?.takeIf { it.startsWith("https://") }
                if (options.optBoolean("enabled")) {
                    if (here == null) {
                        Toast.makeText(this, "Photos are backed up only over a secure address. Open EmberStorm by its emberstorm.app address first.", Toast.LENGTH_LONG).show()
                        options.put("enabled", false)
                    } else if (here != PhotoBackup.rememberedServer(this) && options.optBoolean("confirmedHere").not()) {
                        val host = Uri.parse(here).host ?: here
                        AlertDialog.Builder(this)
                            .setTitle("Back up this phone's photos?")
                            .setMessage("Your photos and videos will be sent to $host. Do it only if that is your own EmberStorm.")
                            .setPositiveButton("Back up") { _, _ ->
                                PhotoBackup.rememberServer(applicationContext, here)
                                backup("set", options.put("confirmedHere", true))
                            }
                            .setNegativeButton("Not now") { _, _ ->
                                PhotoBackup.configure(applicationContext, JSONObject().put("enabled", false))
                                reportBackup()
                            }
                            .show()
                        return
                    }
                }
                if (options.optBoolean("enabled") && !PhotoBackup.hasPermission(this)) {
                    pendingBackup = options
                    requestPermissions(PhotoBackup.permissions(), BACKUP_PERMISSION)
                    return
                }
                PhotoBackup.configure(applicationContext, options)
            }
        }
        reportBackup()
    }

    private var pendingBackup: JSONObject? = null

    /** Adding files in the background (Uploads), as the page asks. */
    private fun uploads(cmd: String, data: JSONObject) {
        if (isTv) return
        val c = applicationContext
        val answer = when (cmd) {
            "add" -> Uploads.add(c, data.optString("server"), data.optJSONArray("jobs") ?: org.json.JSONArray()).put("ev", "added")
            "stop" -> { Uploads.stop(c); Uploads.status(c).put("ev", "status") }
            "set" -> { Uploads.configure(c, data); Uploads.status(c).put("ev", "status") }
            "seen" -> { Uploads.markSeen(c); return }
            else -> Uploads.status(c).put("ev", "status")
        }
        webView?.evaluateJavascript("window.__soundstormUploads && window.__soundstormUploads($answer)", null)
    }

    private fun reportBackup() {
        val view = webView ?: return
        view.evaluateJavascript(
            "window.__soundstormBackup && window.__soundstormBackup(" + PhotoBackup.status(this) + ")", null)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != BACKUP_PERMISSION) return
        val options = pendingBackup ?: return
        pendingBackup = null
        // Refused, backup stays off and the page says why.
        if (!PhotoBackup.hasPermission(this)) options.put("enabled", false)
        PhotoBackup.configure(applicationContext, options)
        reportBackup()
    }

    private fun setStatusColor(color: Int) {
        statusScrim.setBackgroundColor(color)
    }

    /**
     * The sign-in, this device's mark and who is kept on it, copied from the
     * install name in use to its twin (home to away, away to home). Cookies
     * belong to one name, so signed in at home the away name knew nobody and
     * asked again the first time the phone was off the Wi-Fi (the owner's
     * report). A cookie gone here - signed out - goes there too.
     */
    private fun mirrorCookies(from: Uri? = server) {
        val s = from ?: return
        if (s.scheme != "https") return
        val twin = ServerAddress.twinHost(s.host) ?: return
        val port = if (s.port != -1) ":${s.port}" else ""
        val here = "https://${s.host}$port/"
        val there = "https://$twin$port/"
        val cm = CookieManager.getInstance()
        val have = (cm.getCookie(here) ?: "").split(";").mapNotNull {
            val kv = it.trim()
            val i = kv.indexOf('=')
            if (i > 0) kv.substring(0, i) to kv.substring(i + 1) else null
        }.toMap()
        for (name in MIRRORED_COOKIES) {
            val v = have[name]
            val age = if (v != null) 30L * 24 * 3600 else 0L
            cm.setCookie(there, "$name=${v ?: ""}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=$age")
        }
        cm.flush()
    }

    private fun isServer(url: Uri): Boolean {
        val s = server ?: return false
        return url.scheme == s.scheme && url.host == s.host && url.port == s.port
    }

    /**
     * https on one of this install's own names, on the port in use now. When
     * the server is known by one of its names, only its twin (the same id,
     * home and away) - any install can get a name under emberstorm.app, and a
     * security review found a page could send the app to another's. From a
     * plain address (a LAN IP) the name cannot be checked, so the move is only
     * followed, never saved (see shouldOverrideUrlLoading).
     */
    private fun isOwnSecureName(url: Uri): Boolean {
        val s = server ?: return false
        val host = url.host?.lowercase() ?: return false
        if (url.scheme != "https" || isServer(url)) return false
        if (!ServerAddress.isInstallName(host)) return false
        if (url.port != s.port) return false
        val current = s.host?.lowercase() ?: return false
        // From one of its names to another: its twin is followed at once; a
        // different label (the install's chosen name, yourname.home... for
        // k3x9m2p7qa.net...) only once both answer with the same install id
        // (shouldOverrideUrlLoading).
        return true
    }

    private fun openOutside(url: Uri) {
        // Never a file: - Android throws on handing one to another app, which
        // crashed the app.
        if (url.scheme == "file" || url.scheme == "content") return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, url).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: Exception) {
        }
    }

    // The longest the opening screen waits for the app to be ready.
    private val OPENING_HOLD_MS = 8000L

    private fun showFailure(detail: String) {
        markReady()
        failure?.let { content.removeView(it) }
        val host = server?.host ?: ""
        val accent = Color.rgb(0x6a, 0xa8, 0xff)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(32), dp(32), dp(32), dp(32))
            setBackgroundColor(Color.BLACK)
            isClickable = true
        }
        column.addView(TextView(this).apply {
            text = "Can't reach EmberStorm at $host"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            gravity = Gravity.CENTER
        }, fill(bottom = 12))
        column.addView(TextView(this).apply {
            text = detail
            setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.CENTER
        }, fill(bottom = 24))
        column.addView(Button(this).apply {
            text = "Try again"
            isAllCaps = false
            setTextColor(Color.BLACK)
            background = GradientDrawable().apply { cornerRadius = dp(14).toFloat(); setColor(accent) }
            stateListAnimator = null
            // From the address the app starts from: after one failure on the
            // home name it had moved to the away name, and Try again kept
            // loading that one for as long as the app ran (a review).
            setOnClickListener {
                triedAway = false
                val saved = ServerAddress.saved(this@MainActivity)
                if (saved != null && saved != server) showWeb(saved) else load()
            }
        }, LinearLayout.LayoutParams(dp(200), dp(48)).apply { bottomMargin = dp(8) })
        column.addView(Button(this).apply {
            text = "Change server"
            isAllCaps = false
            setTextColor(Color.argb(0x99, 0xeb, 0xeb, 0xf5))
            setBackgroundColor(Color.TRANSPARENT)
            stateListAnimator = null
            setOnClickListener { showConnect(server) }
        }, LinearLayout.LayoutParams(dp(200), dp(48)))
        content.addView(column, FrameLayout.LayoutParams(MATCH, MATCH))
        failure = column
    }

    private inner class Client : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val url = request.url
            val scheme = url.scheme ?: return true
            // The page moving itself to the install's secure name - which it
            // does, after checking it can reach it, when opened by a home
            // address like http://192.168.0.50:8099. That is the same server,
            // not a link out: it is kept as the address from now on, and the
            // page reopened there (the page's script and messages are allowed
            // for one origin). Found on a TV set up by its LAN address, which
            // sat on the loading spinner, the move refused as a link out.
            if (request.isForMainFrame && isOwnSecureName(url)) {
                val target = ServerAddress.parse(url.toString())
                val current = server
                // A TV's code rides along: the page is reopened at the name's
                // root, which dropped it, so "Sign in a TV?" never came (the
                // owner's report).
                url.getQueryParameter("link")?.uppercase()?.filter { it.isLetterOrDigit() }
                    ?.takeIf { it.length == 6 }?.let { pendingLink = it }
                if (target != null && current != null && ServerAddress.zoneOf(current.host) == null) {
                    // From a plain address the name cannot be told apart from
                    // another install's by its text, and the page that asked
                    // came over plain http. So it is followed only if it
                    // names the very address in use: an attacker's name would
                    // point at their own machine (a security review).
                    Thread {
                        // The name leads to the address in use, and both say
                        // they are one install: any install can point a name
                        // at any private address (the twelfth security pass).
                        val same = runCatching {
                            java.net.InetAddress.getAllByName(target.host).any { it.hostAddress == current.host } &&
                                ServerAddress.installIdAt(current).let { id -> id != null && id == ServerAddress.installIdAt(target) }
                        }.getOrDefault(false)
                        if (same) content.post { if (server == current) showWeb(target) }
                    }.start()
                    return true
                }
                val currentHost = current?.host?.lowercase()
                if (target != null && currentHost != null && ServerAddress.zoneOf(currentHost) != null &&
                    target.host?.lowercase()?.substringBefore('.') != currentHost.substringBefore('.')) {
                    // Another of the install's names - its chosen name, the
                    // owner's design (2026-10-08) - is followed only when it
                    // and the address in use answer with one install id:
                    // anybody can get a name under the zone, and a page must
                    // not be able to send the app to theirs. An id is only
                    // what a server says of itself, and anybody can say
                    // another's (it is the first part of its name), so the two
                    // names must also lead to one address: a chosen name is
                    // pointed at its install's own (a security review).
                    Thread {
                        val same = runCatching {
                            val here = ServerAddress.installIdAt(current)
                            val there = java.net.InetAddress.getAllByName(target.host).map { it.hostAddress }.toSet()
                            here != null && here == ServerAddress.installIdAt(target) &&
                                java.net.InetAddress.getAllByName(currentHost).any { it.hostAddress in there }
                        }.getOrDefault(false)
                        if (same) content.post { if (server == current) showWeb(target) }
                    }.start()
                    return true
                }
                if (target != null) {
                    // Followed for now, never saved: the address typed stays
                    // the one the app starts from. Saving the home name made a
                    // phone that had come home unable to reach the server once
                    // out again, and saving any name from a plain-http page let
                    // someone on the same Wi-Fi pin the app to their own server
                    // for good (a security review).
                    content.post { showWeb(target) }
                    return true
                }
            }
            if (request.isForMainFrame && scheme in setOf("http", "https") && !isServer(url)) {
                // A link off the server leaves for the browser, as one out of
                // an installed web app does - one somebody tapped, not a page
                // sending people away on its own.
                if (request.hasGesture() || request.isRedirect) openOutside(url)
                return true
            }
            if (scheme !in setOf("http", "https", "blob", "data", "about")) {
                // mailto:, tel: and the like belong to other apps - but only
                // from a link somebody followed in the page itself, never from
                // a frame or a script on its own (a security review).
                if (request.isForMainFrame && request.hasGesture()) openOutside(url)
                return true
            }
            return false
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (!request.isForMainFrame) return
            // A home name (<id>.home.emberstorm.app) cannot be reached away
            // from home; its away twin (<id>.net...) can, when remote access
            // is on. Tried once, without being saved.
            val s = server
            val host = s?.host?.lowercase()
            val awayHost = ServerAddress.awayHost(host)
            if (s != null && awayHost != null && !triedAway) {
                triedAway = true
                mirrorCookies(s)
                val away = s.buildUpon().encodedAuthority(
                    awayHost + if (s.port != -1) ":${s.port}" else ""
                ).build()
                content.post { showWeb(away) }
                return
            }
            showFailure(error.description?.toString() ?: "")
        }

        // A form posted elsewhere, or a data: or blob: page, does not pass
        // through shouldOverrideUrlLoading: anything that is not the server
        // starting in the app's own window is stopped, and the server shown
        // again (a security review).
        override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
            // A new page controls nothing until it says so.
            remoteVolume = false
            val u = url?.let { runCatching { Uri.parse(it) }.getOrNull() }
            if (u == null || url == "about:blank" || isServer(u)) return
            view.stopLoading()
            content.post { load() }
        }

        override fun onPageFinished(view: WebView, url: String?) {
            // Loaded: the next failure may try the away name again.
            triedAway = false
            CookieManager.getInstance().flush()
            mirrorCookies()
        }

        override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
            // Android reclaims a background web view's memory by killing its
            // page. Start it afresh, as a browser does on coming back to a tab -
            // without stopping the music, which this used to do: tearing the
            // old page down told the native player to stop, so music stopped
            // whenever Android ended the page while somebody was in another
            // app. In the background the page is made again on coming back.
            if (resumed) server?.let { showWeb(it, keepMusic = true) }
            else {
                tearDownWeb(keepMusic = true)
                pageLost = true
            }
            return true
        }
    }

    private inner class Chrome : WebChromeClient() {
        // A web view shows alert(), confirm() and prompt() in its own plain
        // way; these match the system's dialogs. EmberStorm asks before
        // removing downloads and big files.
        override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
            AlertDialog.Builder(this@MainActivity).setMessage(message)
                .setPositiveButton("OK") { _, _ -> result.confirm() }
                .setOnCancelListener { result.cancel() }.show()
            return true
        }

        override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean {
            AlertDialog.Builder(this@MainActivity).setMessage(message)
                .setPositiveButton("OK") { _, _ -> result.confirm() }
                .setNegativeButton("Cancel") { _, _ -> result.cancel() }
                .setOnCancelListener { result.cancel() }.show()
            return true
        }

        override fun onJsPrompt(view: WebView, url: String?, message: String?, defaultValue: String?, result: JsPromptResult): Boolean {
            val input = EditText(this@MainActivity).apply { setText(defaultValue ?: "") }
            AlertDialog.Builder(this@MainActivity).setMessage(message).setView(input)
                .setPositiveButton("OK") { _, _ -> result.confirm(input.text.toString()) }
                .setNegativeButton("Cancel") { _, _ -> result.cancel() }
                .setOnCancelListener { result.cancel() }.show()
            return true
        }

        /** target="_blank" (the ListenBrainz and LRCLIB links in Account): the browser. */
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            // Only for a link somebody tapped, and only to a web address.
            if (!isUserGesture) return false
            val catcher = WebView(this@MainActivity)
            var done = false
            fun finish(v: WebView, url: Uri?) {
                if (done) return
                done = true
                if (url != null && url.scheme in setOf("http", "https")) openOutside(url)
                v.stopLoading()
                v.post { v.destroy() }
            }
            catcher.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    finish(v, request.url)
                    return true
                }

                // A posted form never reaches shouldOverrideUrlLoading: it is
                // caught as it starts, and nothing loads in the hidden view.
                override fun onPageStarted(v: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                    if (url == null || url == "about:blank") return
                    finish(v, Uri.parse(url))
                }
            }
            // A window nothing ever navigates is let go.
            catcher.postDelayed({ if (!done) { done = true; catcher.destroy() } }, 10_000)
            (resultMsg.obj as WebView.WebViewTransport).webView = catcher
            resultMsg.sendToTarget()
            return true
        }

        /** Add media, Import playlist, Change cover: the system's file picker. */
        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
            fileCallback?.onReceiveValue(null)
            fileCallback = callback
            // The documents picker, so the app may go on reading what was
            // picked after it is left: files added from this phone are sent
            // by the app in the background (Uploads).
            val types = params.acceptTypes.filter { it.isNotBlank() }
            val open = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (types.size == 1 && !types[0].startsWith(".")) types[0] else "*/*"
                val mimes = types.filter { it.contains('/') }
                if (mimes.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.mode == FileChooserParams.MODE_OPEN_MULTIPLE)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }
            return try {
                startActivityForResult(open, PICK_FILES)
                true
            } catch (_: ActivityNotFoundException) {
                try {
                    startActivityForResult(params.createIntent(), PICK_FILES)
                    true
                } catch (_: ActivityNotFoundException) {
                    fileCallback = null
                    false
                }
            }
        }

        /** A film's full screen. */
        override fun onShowCustomView(view: View, callback: CustomViewCallback) {
            if (fullscreen != null) {
                callback.onCustomViewHidden()
                return
            }
            fullscreen = view
            fullscreenCallback = callback
            root.addView(view, FrameLayout.LayoutParams(MATCH, MATCH))
            hideBars()
        }

        override fun onHideCustomView() {
            fullscreen?.let { root.removeView(it) }
            fullscreen = null
            fullscreenCallback = null
            hideBars()
        }
    }

    @Deprecated("The platform Activity's result API, which is all this needs.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == PICK_FILES) {
            var uris = WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            // Several picked: parseResult may give only the first.
            val clip = data?.clipData
            if (resultCode == RESULT_OK && clip != null && clip.itemCount > (uris?.size ?: 0)) {
                uris = Array(clip.itemCount) { clip.getItemAt(it).uri }
            }
            Uploads.rememberPicked(applicationContext, uris)
            fileCallback?.onReceiveValue(uris)
            fileCallback = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * Back steps back through the page first - the page keeps a history entry
     * armed while a menu, a book or Now Playing is open, and closes the top
     * one on back. With nothing left, the app goes to the background rather
     * than closing, which would stop the music.
     */
    @Deprecated("The platform Activity's back handling, for Android before 13.")
    override fun onBackPressed() {
        goBack()
    }

    private fun goBack() {
        val view = webView
        when {
            fullscreen != null -> fullscreenCallback?.onCustomViewHidden()
            failure == null && view != null && view.canGoBack() -> view.goBack()
            else -> moveTaskToBack(true)
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun wrap(bottom: Int = 0) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { bottomMargin = dp(bottom) }

    private fun fill(height: Int = 0, bottom: Int = 0, top: Int = 0) =
        LinearLayout.LayoutParams(MATCH, if (height > 0) dp(height) else ViewGroup.LayoutParams.WRAP_CONTENT)
            .apply { bottomMargin = dp(bottom); topMargin = dp(top) }

    private fun hideKeyboard(view: View) {
        getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(view.windowToken, 0)
    }

    companion object {
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private val MIRRORED_COOKIES = listOf(
            "__Host-soundstorm_session", "__Host-soundstorm_device", "__Host-soundstorm_profiles",
        )
        private const val PICK_FILES = 1
        private const val BACKUP_PERMISSION = 2
    }
}
