import UIKit
import WebKit
import Network

/// The server's own web app, full screen. The page is the app: this only
/// gives it what a browser tab would (dialogs, links out, recovering from a
/// failed load) plus the one thing a tab cannot - playing on with the phone
/// locked, which comes from the audio session in SoundStormApp.
final class WebViewController: UIViewController {
    var onChangeServer: (() -> Void)?

    private let server: URL
    /// Where the page is now. Usually `server`, but the page moves itself to
    /// the install's home name when it can reach it (see sameInstall).
    private var current: URL
    private var webView: WKWebView!
    private let failure = FailureView()

    /// A TV's sign-in code to hand the page when it has loaded.
    private var pendingLink: String?
    /// An invitation's token, opened from its QR code: the page makes the
    /// account it invites to.
    private var pendingInvite: String?
    private let scanner = CodeScanner()
    private let volumeKeys = VolumeKeys()
    /// Handing shared files to the page, tried until it takes them.
    private var sharedTries: Task<Void, Never>?
    #if DEBUG
    private var audioTested = false
    #endif

    init(server: URL, link: String? = nil, invite: String? = nil) {
        self.server = server
        self.current = server
        self.pendingLink = link
        self.pendingInvite = invite
        super.init(nibName: nil, bundle: nil)
    }

    /// The server this shows, for a link that names one.
    var serverURL: URL { server }

    /// A TV's code, scanned or opened from a link: the page asks "Sign in a
    /// TV?" at once if it can (music playing in it carries on); a page that
    /// cannot - not signed in yet, or older - is loaded again with the code
    /// in its address, asked once signed in.
    ///
    /// `scanned` when the app's own scanner read it: the page asks at once.
    /// A code that came in a link is the person's to type, as the TV shows it,
    /// so one sent by somebody else signs nothing in (the twelfth pass).
    func handLink(_ code: String, scanned: Bool = false) {
        let how = scanned ? ", \"scanned\"" : ""
        let js = "(typeof window.__soundstormLink === 'function' && window.__soundstormLink(\"\(code)\"\(how))) === true"
        webView.evaluateJavaScript(js) { [weak self] took, _ in
            guard (took as? Bool) != true, let self else { return }
            self.pendingLink = code
            self.load()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        // What an installed web app gets in Safari: media plays in the page
        // rather than jumping to the system player, and may start without a
        // fresh tap - the queue moving on to the next song is not a tap.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        // Keeps Safari's own user agent and adds a name the page can test for.
        config.applicationNameForUserAgent = "Mobile/15E148 Safari/604.1 SoundStormApp/1"

        // window.soundstormApp tells the page it is inside this app, so it
        // can offer what only the app can do (see "Change server" in app.js).
        let content = config.userContentController
        content.add(MessageRelay(self), name: "soundstorm")
        // Downloads kept by the app in its own folder (KeptFiles), read by the
        // page at emberstorm-kept://.
        config.setURLSchemeHandler(KeptScheme(), forURLScheme: KeptFiles.scheme)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Files shared from another app (Share > EmberStorm) wait until the app
        // is opened: handed to the page then.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handShared()
                if self?.current.scheme == KeptFiles.scheme { self?.watchServer() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopWatching() }
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The page lays itself out under the status bar and home indicator
        // with env(safe-area-inset-*), as it does installed from Safari.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Black until the page paints, instead of a white flash.
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // No bounce at a page's ends (pulling down at the top moved the tab
        // bar) and no scrollbars of the web view's own: the page draws none.
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        #if DEBUG
        webView.isInspectable = true // Safari → Develop → this iPhone
        #endif
        view.addSubview(webView)
        holdOpeningScreen()
        NativeAudio.shared.webView = webView
        KeptFiles.shared.answer = { [weak self] site, answer in
            guard let self, KeptFiles.site(of: self.current) == site else { return }
            self.callPage("__soundstormKeep", answer)
        }
        NativeAudio.shared.isServer = { [weak self] url in self?.isServer(url) ?? false }

        failure.frame = view.bounds
        failure.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        failure.isHidden = true
        failure.onRetry = { [weak self] in self?.load() }
        failure.onChangeServer = { [weak self] in self?.onChangeServer?() }
        view.addSubview(failure)
        if let opening { view.bringSubviewToFront(opening) }

        load()
    }

    /// The opening screen - the cloud on black, exactly as the launch screen
    /// draws it - kept over the page until it says it is ready, so the opening
    /// goes icon, then the app, with no blank between (as Android 0.40).
    private var opening: UIView?

    private func holdOpeningScreen() {
        let cover = UIView(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        let mark = UIImageView(image: UIImage(named: "LaunchMark"))
        mark.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        view.addSubview(cover)
        opening = cover
        // Eight seconds at most (the owner's limit): the page's own loading
        // screen, the same cloud in the same place, carries on from there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.letGoOfOpeningScreen() }
    }

    /// A short note at the top of the screen that goes by itself.
    private func showNote(_ text: String) {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        let note = UIView()
        note.backgroundColor = UIColor(white: 0.14, alpha: 0.96)
        note.layer.cornerRadius = 14
        note.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        note.addSubview(label)
        view.addSubview(note)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: note.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: note.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: note.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: note.trailingAnchor, constant: -16),
            note.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        note.alpha = 0
        UIView.animate(withDuration: 0.25) { note.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 5, options: []) { note.alpha = 0 } completion: { _ in note.removeFromSuperview() }
    }

    private func letGoOfOpeningScreen() {
        guard let cover = opening else { return }
        opening = nil
        UIView.animate(withDuration: 0.15, animations: { cover.alpha = 0 }, completion: { _ in cover.removeFromSuperview() })
    }

    /// The away twin has been tried since the last Try again.
    private var triedTwin = false
    /// The server's name in the newest zone has been tried (`inNewestZone`).
    private var triedZone = false
    /// Saved under an older zone and found under the newest: the app opens
    /// the server there (SoundStormApp).
    var onMoved: ((URL) -> Void)?

    /// The page's scripts for where it is about to be: the app's own, and
    /// the downloads kept for that server only (KeptFiles).
    private func setScripts(for url: URL) {
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: Self.versionScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: KeptFiles.shared.pageScript(for: url, server: server),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The app's version for Settings, About ("This phone's app: 1.0-42"), as
    /// Android sets it: digits, letters, dots and dashes only.
    private static let versionScript: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        var version = build.isEmpty || build == short ? short : short + "-" + build
        version = String(version.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }.prefix(20))
        guard !version.isEmpty else { return "" }
        return "if (window.soundstormApp) window.soundstormApp.appVersion = '\(version)';"
    }()

    /// Tried once a load: the server out of reach, its page kept - opened from
    /// the app's folder, on its downloads (the page takes the address as
    /// offline mode).
    private var triedKept = false
    /// Looking for the server while the kept page shows.
    private var watchTask: Task<Void, Never>?
    private var watchSince = Date()
    /// The kept page the app opened, which may be another of the install's
    /// addresses than the saved one.
    private var keptChosen: String?
    private var pathMonitor: NWPathMonitor?

    private func load() {
        stopWatching()
        failure.isHidden = true
        triedTwin = false
        triedKept = false
        current = server
        setScripts(for: server)
        AppChrome.shared.statusBarHidden = false
        var address = server
        if let code = pendingLink {
            pendingLink = nil
            address = server.appending(queryItems: [URLQueryItem(name: "link", value: code)])
        }
        if let token = pendingInvite {
            pendingInvite = nil
            address = server.appending(queryItems: [URLQueryItem(name: "invite", value: token)])
        }
        // A new box's setup code rides in the address only to its secure
        // name (found and checked as the same install); over plain http the
        // person types it on the page (the thirteenth pass, as Android 0.50).
        if let code = ServerAddress.pendingSetup {
            ServerAddress.pendingSetup = nil
            if server.scheme == "https" {
                address = server.appending(queryItems: [URLQueryItem(name: "setup", value: code)])
            }
        }
        webView.load(URLRequest(url: address))
    }

    /// Runs before the page's own scripts. It tells the page it is inside
    /// the app, and tells the app when Now Playing opens and closes (app.js
    /// marks the body np-open), so the status bar can go - watched from here
    /// rather than sent by app.js, so it needs no change to the web app.
    private static let pageScript = """
        window.soundstormApp = { version: 1 };
        // Phone photo backup (PhotoBackup): Settings turns it on and shows how
        // it is going, answered through window.__soundstormBackup - the same
        // messages as the Android app's, so the page has no iPhone code.
        window.soundstormApp.photoBackup = true;
        // Scanning a TV's sign-in QR code, and the volume buttons turning a
        // TV this phone controls (AppLinks.swift), as in the Android app.
        window.soundstormApp.scanCode = () =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'scanCode' });
        // Files added: the app picks (an iPhone's web view keeps its own
        // picker's files to itself), the page plans, reading the little it
        // needs through the app, and the app sends them in the background
        // (FileUploads.swift) - the Android app's uploads, answered the same.
        window.soundstormApp.pickFiles = () =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'pickFiles' });
        window.soundstormApp.readFile = (req, id, from, to) =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'readFile', req, id, from, to });
        window.soundstormApp.uploads = (cmd, data) =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'uploads', cmd, data: data || {} });
        window.soundstormApp.remoteVolume = (on) =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'remoteVolume', on: Boolean(on) });
        window.soundstormApp.backup = (cmd, options) =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'backup', cmd, options: options || {} });
        // A playback report (PlayerLog.swift), as the Android app's.
        window.soundstormApp.playerLog = () =>
          window.webkit.messageHandlers.soundstorm.postMessage({ type: 'playerLog' });
        // Songs played by the app's own player (NativeAudio.swift), as the
        // Android app's: paused on the lock screen, the page's own player
        // could not be started again there, as iOS had put the app to sleep.
        (() => {
          const post = (m) => window.webkit.messageHandlers.soundstorm.postMessage(m);
          window.soundstormApp.nativeAudio = true;
          window.soundstormApp.queueNext = (url) => post({ type: 'audio', cmd: url ? 'queue' : 'unqueue', url: url || '' });
          window.soundstormApp.queueUpcoming = (items) => post({ type: 'audio', cmd: 'upcoming', items: items || [] });
          // The sleep timer, kept by the app's player: a page whose screen is
          // off is asleep, timers and all, while the music plays on.
          window.soundstormApp.sleepAt = (at) => post({ type: 'audio', cmd: 'sleep', at: at || 0 });
          // Where an audiobook's place is saved and where its files begin, so
          // the player saves it itself while the screen is off (NativeAudio).
          window.soundstormApp.place = (place) => post({ type: 'audio', cmd: 'place', place: place || null });

          // The page's media session, passed to the app for the lock screen
          // (the page's own audio no longer plays a song from the server, so
          // the web view has nothing to show there), and still to the web
          // view's own for a downloaded song, which plays in the page.
          const real = navigator.mediaSession;
          const handlers = {};
          let metadata = null;
          let state = 'none';
          let queued = false;
          const send = () => {
            if (queued) return;
            queued = true;
            setTimeout(() => {
              queued = false;
              post({
                type: 'media', state, actions: Object.keys(handlers),
                metadata: metadata && {
                  title: metadata.title || '', artist: metadata.artist || '', album: metadata.album || '',
                  artwork: (metadata.artwork || []).map((a) => {
                    try { return new URL(a.src, location.href).href; } catch (e) { return ''; }
                  }).filter(Boolean),
                },
              });
            }, 0);
          };
          const session = {
            get metadata() { return metadata; },
            set metadata(value) { metadata = value; try { if (real) real.metadata = value; } catch (e) {} send(); },
            get playbackState() { return state; },
            set playbackState(value) { state = value || 'none'; try { if (real) real.playbackState = value; } catch (e) {} send(); },
            setActionHandler(action, handler) {
              if (handler) handlers[action] = handler; else delete handlers[action];
              try { if (real) real.setActionHandler(action, handler); } catch (e) {}
              send();
            },
            setPositionState(p) { try { if (real) real.setPositionState(p); } catch (e) {} },
          };
          Object.defineProperty(navigator, 'mediaSession', { value: session, configurable: true });
          window.__soundstormMediaAction = (action, details) => {
            const handler = handlers[action];
            if (handler) handler(Object.assign({ action }, details || {}));
          };

        // The page's audio element, played by the phone's own media player
        // (NativeAudio.swift; the Android app's NativeAudio): a song on the server is handed over and
        // played natively, and what the player does comes back as the element's
        // own events, so the page cannot tell. A song kept on the device (blob:)
        // plays in the page as before.
        const nativeAudio = (el) => {
          const proto = HTMLMediaElement.prototype;
          const getter = (name) => Object.getOwnPropertyDescriptor(proto, name).get;
          const setter = (name) => Object.getOwnPropertyDescriptor(proto, name).set;
          const def = (name, desc) => Object.defineProperty(el, name, Object.assign({ configurable: true }, desc));
          let native = false;
          let src = '';
          let pwr = false;
          let volume = 1;
          let rate = 1;
          let defaultRate = 1;
          let seekPending = false;
          const st = { state: 'idle', playing: false, position: 0, at: performance.now(), duration: NaN, buffered: 0, ended: false, error: null, url: '' };
          const fire = (type) => el.dispatchEvent(new Event(type));
          const send = (cmd, extra) => post(Object.assign({ type: 'audio', cmd: cmd }, extra || {}));
          const time = () => {
            let t = st.position;
            if (st.playing) t += ((performance.now() - st.at) / 1000) * rate;
            return Number.isFinite(st.duration) ? Math.min(t, st.duration) : t;
          };
          const ranges = (end) => ({ length: end > 0 ? 1 : 0, start: () => 0, end: () => end });
          let ticker = 0;
          const tick = (on) => {
            clearInterval(ticker);
            ticker = on ? setInterval(() => fire('timeupdate'), 250) : 0;
          };
          const serverSong = (v) => {
            try {
              const u = new URL(v, location.href);
              return (u.protocol === 'http:' || u.protocol === 'https:') && u.origin === location.origin ? u.href : '';
            } catch (e) { return ''; }
          };
          const toWeb = () => {
            if (!native) return;
            native = false;
            src = '';
            pwr = false;
            st.url = '';
            tick(false);
            send('stop');
          };
          def('src', {
            get() { return native ? src : getter('src').call(el); },
            set(v) {
              const url = serverSong(String(v));
              if (!url) { toWeb(); setter('src').call(el, v); return; }
              // Off the page's own player first, if it had a song.
              if (!native && getter('src').call(el)) { proto.pause.call(el); proto.removeAttribute.call(el, 'src'); proto.load.call(el); }
              // Taking over the song the player is already playing, for a page
              // made again: nothing is loaded again, and the next report brings the
              // page's play and playing.
              const adopting = !native && st.url === url && st.state !== 'idle' && st.state !== 'ended';
              if (adopting) { st.playing = false; pwr = false; }
              native = true;
              src = url;
              st.ended = false;
              st.error = null;
              // The player may already be in it (moved in by itself): then the
              // length is known and nothing is loaded again.
              const already = st.url === url && st.state !== 'idle' && st.state !== 'ended';
              if (!already) { st.duration = NaN; st.position = 0; st.at = performance.now(); st.playing = false; st.url = url; }
              send('load', { url: url });
              fire('emptied');
              fire('loadstart');
              if (already && Number.isFinite(st.duration)) { fire('durationchange'); fire('loadedmetadata'); fire('canplay'); }
            },
          });
          def('currentSrc', { get() { return native ? src : getter('currentSrc').call(el); } });
          def('currentTime', {
            get() { return native ? time() : getter('currentTime').call(el); },
            set(v) {
              if (!native) { setter('currentTime').call(el, v); return; }
              const s = Math.max(0, Number(v) || 0);
              st.position = s;
              st.at = performance.now();
              seekPending = true;
              send('seek', { s: s });
              fire('seeking');
              fire('timeupdate');
            },
          });
          def('duration', { get() { return native ? st.duration : getter('duration').call(el); } });
          def('paused', { get() { return native ? !pwr : getter('paused').call(el); } });
          def('ended', { get() { return native ? st.ended : getter('ended').call(el); } });
          def('readyState', { get() { return native ? (st.state === 'ready' || st.playing ? 4 : (Number.isFinite(st.duration) ? 1 : 0)) : getter('readyState').call(el); } });
          def('networkState', { get() { return native ? 2 : getter('networkState').call(el); } });
          def('buffered', { get() { return native ? ranges(st.buffered) : getter('buffered').call(el); } });
          def('seekable', { get() { return native ? ranges(Number.isFinite(st.duration) ? st.duration : 0) : getter('seekable').call(el); } });
          def('error', { get() { return native ? (st.error ? { code: st.error } : null) : getter('error').call(el); } });
          def('volume', {
            get() { return native ? volume : getter('volume').call(el); },
            set(v) {
              volume = Math.min(1, Math.max(0, Number(v)));
              setter('volume').call(el, volume);
              if (native) { send('volume', { v: volume }); fire('volumechange'); }
            },
          });
          def('playbackRate', {
            get() { return native ? rate : getter('playbackRate').call(el); },
            set(v) {
              rate = Number(v) || 1;
              setter('playbackRate').call(el, rate);
              if (native) { send('rate', { r: rate }); fire('ratechange'); }
            },
          });
          def('defaultPlaybackRate', {
            get() { return native ? defaultRate : getter('defaultPlaybackRate').call(el); },
            set(v) { defaultRate = Number(v) || 1; setter('defaultPlaybackRate').call(el, defaultRate); },
          });
          def('play', { value() {
            if (!native) return proto.play.call(el);
            send('rate', { r: rate });
            send('volume', { v: volume });
            send('play');
            if (!pwr) { pwr = true; st.ended = false; fire('play'); }
            if (st.playing) fire('playing');
            return Promise.resolve();
          } });
          def('pause', { value() {
            if (!native) return proto.pause.call(el);
            // The page's own pause: not an interruption (see pausedAt below).
            window.__soundstormPausedAt = Date.now();
            send('pause');
            if (pwr) {
              pwr = false;
              st.position = time();
              st.at = performance.now();
              st.playing = false;
              tick(false);
              setTimeout(() => fire('pause'), 0);
            }
          } });
          def('load', { value() {
            if (!native) return proto.load.call(el);
            if (src) send('load', { url: src });
          } });
          def('removeAttribute', { value(name) {
            if (String(name).toLowerCase() === 'src' && native) toWeb();
            return proto.removeAttribute.call(el, name);
          } });

          // What the native player did.
          // What the player is doing, kept even while the page has not handed it a
          // song: a page made again finds the
          // music still playing and takes it over (app.js adoptNativePlayback).
          let outside = null;
          window.soundstormApp.nativeState = () => outside;
          window.soundstormApp.askState = () => send('state');
          window.__soundstormAudio = (m) => {
            if (!native) {
              if (m.ev === 'state' && m.url) {
                outside = { url: m.url, pwr: !!m.pwr, playing: !!m.playing, position: m.position || 0 };
                st.url = m.url;
                st.state = m.state;
                if (typeof m.position === 'number') { st.position = m.position; st.at = performance.now(); }
                st.duration = typeof m.duration === 'number' ? m.duration : NaN;
                if (typeof m.buffered === 'number') st.buffered = m.buffered;
              }
              return;
            }
            if (m.ev === 'ended') {
              // It moved into the queued song by itself: the page hears this one
              // end, and sets the next, which it will find already playing.
              st.url = m.next || '';
              st.ended = true;
              st.duration = NaN;
              // Starting afresh, so the next report's "playing" starts the clock
              // and its time updates again (they queue the song after it).
              st.playing = false;
              st.position = 0;
              st.at = performance.now();
              pwr = false;
              tick(false);
              fire('pause');
              fire('ended');
              return;
            }
            // A report about the song before the one the page just set: ignored.
            if (m.url && m.url !== st.url) return;
            const wasPlaying = st.playing;
            const hadDuration = Number.isFinite(st.duration);
            st.state = m.state;
            if (typeof m.position === 'number') {
              // A report is a little old by the time it arrives, so taking it
              // as it is set the clock back a few hundredths of a second twice
              // a second, and every animation reading the clock stuttered. While
              // the song plays on, a report only slightly off eases the clock
              // towards it; a real jump (a seek, a stall) is taken at once.
              const now = performance.now();
              const ours = time();
              const off = m.position - ours;
              st.position = (wasPlaying && m.playing && Math.abs(off) < 0.35) ? ours + off * 0.15 : m.position;
              st.at = now;
            }
            st.playing = !!m.playing;
            if (typeof m.duration === 'number') st.duration = m.duration;
            if (typeof m.buffered === 'number') st.buffered = m.buffered;
            // The player's volume is the page's to set: should the two ever differ
            // (the sound gone while the song plays on, reported and not explained),
            // the page's is sent again.
            if (typeof m.volume === 'number' && Math.abs(m.volume - volume) > 0.02) send('volume', { v: volume });
            if (m.error) { st.error = m.error; fire('error'); return; }
            if (!hadDuration && Number.isFinite(st.duration)) { fire('durationchange'); fire('loadedmetadata'); fire('canplay'); }
            // Played or paused from outside the page: the lock screen, a
            // notification, headphones, an alarm taking the sound.
            if (!!m.pwr !== pwr && m.state !== 'ended') {
              pwr = !!m.pwr;
              fire(pwr ? 'play' : 'pause');
            }
            if (st.playing && !wasPlaying) { fire('playing'); tick(true); }
            if (!st.playing && wasPlaying) tick(false);
            if (pwr && m.state === 'buffering') fire('waiting');
            if (seekPending && m.seeked) { seekPending = false; fire('seeked'); fire('timeupdate'); }
            if (m.state === 'ended' && !st.ended) {
              st.ended = true;
              pwr = false;
              tick(false);
              fire('pause');
              fire('ended');
            }
          };
        };
        // In place the moment the element is parsed - before the page's own
        // script, later in the page, first touches it.
        const found = () => {
          const el = document.getElementById('audio-player');
          if (!el || el.__native) return !!el;
          el.__native = true;
          nativeAudio(el);
          return true;
        };
        if (!found()) {
          const watch = new MutationObserver(() => { if (found()) watch.disconnect(); });
          watch.observe(document, { childList: true, subtree: true });
        }
        })();
        (() => {
          let open = false;
          // How smoothly the page draws while Now Playing is open, for a
          // playback report: every five seconds, frames counted, how many came
          // late (over 25ms and over 50ms) and the worst gap.
          let raf = 0, last = 0, n = 0, late = 0, veryLate = 0, worst = 0, since = 0;
          const frame = (t) => {
            if (last) {
              const gap = t - last;
              n++;
              if (gap > 25) late++;
              if (gap > 50) veryLate++;
              if (gap > worst) worst = gap;
            }
            last = t;
            if (t - since > 5000) {
              if (n) window.webkit.messageHandlers.soundstorm.postMessage({ type: 'frames', n, late, veryLate, worst: Math.round(worst) });
              n = late = veryLate = worst = 0;
              since = t;
            }
            raf = requestAnimationFrame(frame);
          };
          const timeFrames = (on) => {
            cancelAnimationFrame(raf);
            raf = 0; last = 0; n = late = veryLate = worst = 0; since = performance.now();
            if (on) raf = requestAnimationFrame(frame);
          };
          const report = () => {
            const now = document.body.classList.contains('np-open');
            if (now === open) return;
            open = now;
            timeFrames(open);
            window.webkit.messageHandlers.soundstorm.postMessage({ type: 'nowPlaying', open });
          };
          const watch = () => {
            new MutationObserver(report).observe(document.body, { attributes: true, attributeFilter: ['class'] });
            report();
          };
          if (document.body) watch(); else document.addEventListener('DOMContentLoaded', watch);
        })();
        """

    fileprivate func showFailure(_ error: Error) {
        let error = error as NSError
        // A navigation replaced by another, or turned into a download, is
        // not a failure anybody needs to see.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == WKError.errorDomain && error.code == 102 { return } // frame load interrupted
        // Saved under soundstorm.dev, which servers stopped answering when
        // they moved to emberstorm.app (2026-10-08): the same name there is
        // tried, and if it answers it becomes the saved address, the sign-in
        // carried across (a session is the server's, whatever its name).
        if !triedZone, error.domain == NSURLErrorDomain, let moved = ServerAddress.inNewestZone(server) {
            triedZone = true
            let old = server
            Task { [weak self] in
                guard let self else { return }
                if await ServerAddress.movesHere(from: old, to: moved), (try? await ServerAddress.check(moved)) != nil {
                    await Self.copyCookies(from: old, to: moved)
                    ServerAddress.moved(old, to: moved)
                    self.onMoved?(moved)
                } else {
                    self.showFailure(error)
                }
            }
            return
        }
        // A home name is not reached away from home: its away twin is tried
        // once (followed, not saved), as the Android app does.
        if error.domain == NSURLErrorDomain,
           [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
            NSURLErrorDNSLookupFailed, NSURLErrorNetworkConnectionLost].contains(error.code),
           !triedTwin, let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? current as URL?,
           let twin = ServerAddress.twin(failed, level: "net"), ServerAddress.installName(failed.host() ?? "")?.level == "home" {
            triedTwin = true
            current = twin
            setScripts(for: twin)
            Task {
                await Self.mirrorCookies(from: failed, to: twin)
                self.webView.load(URLRequest(url: twin))
            }
            return
        }
        // Out of reach with the page kept: the app opens on its downloads,
        // as Android's does from its service worker.
        // Looked for under any of the install's addresses, the one holding
        // the downloads first (as Android 0.61-0.63): a certificate refused
        // counts too, as it is in the same domain.
        let failedAt = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? current
        if !triedKept, error.domain == NSURLErrorDomain, current.scheme != KeptFiles.scheme,
           let offline = KeptFiles.shared.keptPage(failed: failedAt, server: server) {
            triedKept = true
            watchSince = Date()
            keptChosen = KeptFiles.site(of: offline)
            current = offline
            setScripts(for: offline)
            webView.load(URLRequest(url: offline))
            return
        }
        AppChrome.shared.statusBarHidden = false
        failure.show(host: server.host() ?? server.absoluteString, detail: error.localizedDescription)
        letGoOfOpeningScreen() // the app's own failure screen: nothing to wait for
    }

    /// Calls a page function with a JSON argument.
    private func callPage(_ function: String, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.\(function) && window.\(function)(\(json))")
    }

    /// How this server's photo backup is going, to the page's Settings.
    private func reportBackup(_ status: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: status),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__soundstormBackup && window.__soundstormBackup(\(json))")
    }

    /// "Is this your iPhone?" being asked now: one at a time, as the page
    /// asks for backup's status every few seconds.
    private var askingWhose = false

    fileprivate func received(_ message: WKScriptMessage) {
        // Only the server's own pages may ask the app for anything.
        let origin = message.frameInfo.securityOrigin
        // Scheme, host and port, as isServer: a page on another port of the
        // same machine is not the server.
        let defaultPort = current.scheme == "https" ? 443 : 80
        guard message.frameInfo.isMainFrame,
              origin.host.lowercased() == current.host()?.lowercased(),
              origin.protocol == current.scheme,
              (origin.port == 0 ? defaultPort : origin.port) == (current.port ?? defaultPort)
        else { return }
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            letGoOfOpeningScreen()
        case "changeServer":
            AppChrome.shared.statusBarHidden = false
            onChangeServer?()
        case "nowPlaying":
            AppChrome.shared.statusBarHidden = body["open"] as? Bool ?? false
            PlayerLog.add("now playing \((body["open"] as? Bool ?? false) ? "opened" : "closed")")
        case "frames":
            let n = (body["n"] as? NSNumber)?.intValue ?? 0
            let late = (body["late"] as? NSNumber)?.intValue ?? 0
            let veryLate = (body["veryLate"] as? NSNumber)?.intValue ?? 0
            let worst = (body["worst"] as? NSNumber)?.intValue ?? 0
            PlayerLog.add("frames \(n), late \(late), over 50ms \(veryLate), worst \(worst)ms")
        case "playerLog":
            if let data = try? JSONSerialization.data(withJSONObject: [PlayerLog.text]),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.__soundstormPlayerLog && window.__soundstormPlayerLog(\(json)[0])")
            }
        case "retry":
            // The kept page's Try again: the server afresh, past the kept copy.
            load()
        case "keep":
            if body["cmd"] as? String == "shell" { KeptFiles.shared.livesAt(saved: server, page: current) }
            KeptFiles.shared.handle(body["cmd"] as? String ?? "", data: body["data"] as? [String: Any] ?? [:], page: current)
        case "audio":
            NativeAudio.shared.handle(body)
        case "media":
            NativeAudio.shared.media(body)
        case "scanCode":
            let tell = { [weak self] (what: String) in
                self?.webView.evaluateJavaScript("window.__soundstormScanned && window.__soundstormScanned(\"\(what)\")")
            }
            scanner.scan(over: self, failed: { tell("failed") }) { [weak self] text in
                guard let text else { return } // cancelled
                guard let code = TVLink.code(in: text) else {
                    tell("not-ours")
                    return
                }
                self?.handLink(code, scanned: true)
            }
        case "pickFiles":
            FileUploads.shared.pick(over: self) { [weak self] files in
                let list = files.map { ["id": $0.id, "name": $0.name, "size": $0.size, "lastModified": $0.modified] as [String: Any] }
                self?.callPage("__soundstormPicked", list)
            }
        case "readFile":
            let req = body["req"] as? Int ?? 0
            let from = (body["from"] as? NSNumber)?.int64Value ?? 0
            let to = (body["to"] as? NSNumber)?.int64Value ?? 0
            let data = FileUploads.shared.read(body["id"] as? String ?? "", from: from, to: to)
            let b64 = data.map { "\"" + $0.base64EncodedString() + "\"" } ?? "null"
            webView.evaluateJavaScript("window.__soundstormFileData && window.__soundstormFileData(\(req), \(b64))")
        case "uploads":
            let command = body["cmd"] as? String ?? ""
            let data = body["data"] as? [String: Any] ?? [:]
            let origin = URL(string: message.frameInfo.securityOrigin.protocol + "://" + message.frameInfo.securityOrigin.host
                             + (message.frameInfo.securityOrigin.port == 0 ? "" : ":\(message.frameInfo.securityOrigin.port)"))
            Task {
                if let answer = await FileUploads.shared.handle(command, data: data, pageOrigin: origin) {
                    callPage("__soundstormUploads", answer)
                }
            }
        case "remoteVolume":
            volumeKeys.onPress = { [weak self] dir in
                self?.webView.evaluateJavaScript("window.__soundstormVolumeKey && window.__soundstormVolumeKey(\(dir))")
            }
            volumeKeys.set(body["on"] as? Bool ?? false, in: view.window)
        case "backup":
            // Each server's backup belongs to this phone's own person there
            // (PhotoBackup): who is signed in is asked of the server, so no
            // page message - nor a second person signing in - changes another
            // person's backup.
            let command = body["cmd"] as? String ?? ""
            let options = body["options"] as? [String: Any] ?? [:]
            // A page that knows whose phone it is (`phones`) is told so; an
            // older page sees only its own person's backup, as before.
            let knowsPhones = options["phones"] != nil
            let page = current
            let typed = server
            Task {
                let backup = PhotoBackup.shared
                guard let who = await backup.whoIs(page) else { return }
                if command != "status" {
                    await backup.handle(command, options: options, page: page, typed: typed, who: who)
                }
                if backup.shouldAsk(page, who), !askingWhose, page == current {
                    askingWhose = true
                    let yes = await askWhosePhone(on: who.serverName)
                    askingWhose = false
                    backup.answered(yes, page: page, typed: typed, who: who)
                    if yes { showNote("You can turn on photo backup in Settings, Your photos, whenever you like.") }
                }
                let status = backup.status(page, who)
                if knowsPhones || status["phone"] as? String == "mine" { reportBackup(status) }
                // The page is up and signed in: a run that found no sign-in
                // at launch can go now - but not one per message.
                backup.pageAsked()
            }
        default:
            break
        }
    }

    /// Same scheme, host and port as where the page is now: everything else
    /// leaves the app for Safari, as a link out of an installed web app does.
    private func isServer(_ url: URL) -> Bool {
        url.scheme == current.scheme && url.host()?.lowercased() == current.host()?.lowercased()
            && url.port == current.port
    }

    /// The page moving itself to this install's secure home name, which it
    /// does after checking it can reach it (moveToSecureName in app.js): from
    /// the away-from-home name <id>.net.soundstorm.dev when the phone is at
    /// home, or from a LAN address like http://192.168.0.50:8099. That is the
    /// same server, not a link out, and was being sent to Safari.
    ///
    /// Only this install's names count. Anybody can get a *.net name for a
    /// server of their own, so from one of the zones' addresses the label
    /// must match - in either zone (soundstorm.dev moved to emberstorm.app,
    /// 2026-10-08, the same ids) - or, for a name its owner chose
    /// (yourname.home.emberstorm.app) where the label is not the code, both
    /// addresses' /healthz must answer with the same install id, as Android
    /// 0.46 checks. From a LAN address the id is not known, and any home name
    /// on the same port is accepted: home names only ever point at private
    /// addresses, and the page asking to go there is the server's own.
    /// The app's own question, once per person on a server where this phone
    /// is nobody's yet: whose phone it is - not whether to back up (the
    /// owner's wording, 2026-10-12: it only makes backup possible later).
    private func askWhosePhone(on serverName: String) async -> Bool {
        let device = UIDevice.current.model // iPhone, iPad
        let place = serverName.isEmpty ? "this server" : serverName
        return await withCheckedContinuation { done in
            let ask = UIAlertController(title: "Is this your \(device)?",
                                        message: "Saying yes doesn't back anything up. It only means that later, if you want to, you can turn on photo backup for this \(device) in your Settings. Only one person on \(place) can.",
                                        preferredStyle: .alert)
            ask.addAction(UIAlertAction(title: "Not mine", style: .cancel) { _ in done.resume(returning: false) })
            ask.addAction(UIAlertAction(title: "Yes, it's mine", style: .default) { _ in done.resume(returning: true) })
            var top: UIViewController = self
            while let shown = top.presentedViewController { top = shown }
            top.present(ask, animated: true)
        }
    }

    /// The sign-in's cookies (session, device, profile) from one of an
    /// install's names to another, and taken from there when gone from here
    /// (signed out). Only those, only the host's own.
    private static func mirrorCookies(from: URL, to: URL) async {
        guard let a = from.host()?.lowercased(), let b = to.host()?.lowercased() else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all = await store.allCookies()
        let ours = { (c: HTTPCookie) in c.name.hasPrefix("soundstorm_") || c.name.hasPrefix("__Host-soundstorm_") }
        let here = all.filter { $0.domain.lowercased() == a && ours($0) }
        for cookie in here {
            var props = cookie.properties ?? [:]
            props[.domain] = b
            if let copy = HTTPCookie(properties: props) { await store.setCookie(copy) }
        }
        let kept = Set(here.map(\.name))
        for cookie in all where cookie.domain.lowercased() == b && ours(cookie) && !kept.contains(cookie.name) {
            await store.deleteCookie(cookie)
        }
    }

    /// The sign-in for one of the server's names, given to another: the
    /// web view keeps cookies per name.
    private static func copyCookies(from old: URL, to new: URL) async {
        guard let oldHost = old.host()?.lowercased(), let newHost = new.host()?.lowercased() else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where cookie.domain.lowercased() == oldHost {
            var props = cookie.properties ?? [:]
            props[.domain] = newHost
            if let copy = HTTPCookie(properties: props) { await store.setCookie(copy) }
        }
    }

    private func sameInstall(_ url: URL) async -> Bool {
        guard url.scheme == "https", url.port == current.port,
              let host = url.host()?.lowercased(),
              let name = ServerAddress.installName(host), name.level == "home"
        else { return false }
        if let mine = current.host().flatMap(ServerAddress.installName) {
            if name.label == mine.label { return true }
            // Another of the install's names (one its owner chose): the same
            // id from both, and both names leading to one machine.
            async let theirs = ServerAddress.healthID(url)
            async let ours = ServerAddress.healthID(current)
            async let one = ServerAddress.sameMachine(url, current)
            guard let a = await theirs, let b = await ours, a == b else { return false }
            return await one
        }
        // From a plain-http address: only a home name that resolves to it and
        // answers with the same install id (the eleventh and thirteenth
        // passes - anybody can point a name at a private address).
        guard current.scheme == "http" else { return false }
        async let theirs = ServerAddress.healthID(url)
        async let ours = ServerAddress.healthID(current)
        guard let a = await theirs, let b = await ours, a == b else { return false }
        return await ServerAddress.sameMachine(url, current)
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // No target frame is a new window, which createWebViewWith decides
        // (only for a link somebody tapped) - not the page itself.
        let mainFrame = action.targetFrame?.isMainFrame ?? false
        // The kept page of this server only, opened offline (KeptFiles): its
        // saved address's, or the one the app chose among the install's.
        if url.scheme == KeptFiles.scheme {
            let site = KeptFiles.site(of: url)
            guard mainFrame, site == KeptFiles.site(of: server) || (site != nil && site == keptChosen) else { return .cancel }
            current = url
            setScripts(for: url)
            return .allow
        }
        if mainFrame, await sameInstall(url) {
            // Followed for now, never saved: the address typed stays the one
            // the app starts from. Saving a name reached from a plain-http
            // page let someone on the same Wi-Fi pin the app to a server of
            // their own for good (the security review; Android the same).
            if KeptFiles.site(of: url) != KeptFiles.site(of: current) { setScripts(for: url) }
            current = url
            return .allow
        }
        if mainFrame && !isServer(url) && ["http", "https"].contains(url.scheme ?? "") {
            // Safari only for a link somebody followed: a page sending itself
            // elsewhere by script would otherwise throw the person out of the
            // app, as often as it liked (the security review; Android the same).
            if action.navigationType == .linkActivated {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
        if mainFrame && ["blob", "data"].contains(url.scheme ?? "") && !action.shouldPerformDownload {
            // A page made of a blob or data address would sit in the app's
            // window, looking like SoundStorm, with no address to show it is
            // not. Frames may (a book's pages are blobs); the app never is.
            return .cancel
        }
        if !["http", "https", "blob", "data", "about"].contains(url.scheme ?? "") {
            // mailto:, tel: and the like belong to other apps - only when
            // somebody followed such a link on the page itself, never because
            // a frame or a script asked.
            if mainFrame && action.navigationType == .linkActivated {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
        return .allow
    }

    // MARK: Shared from another app

    /// Share > EmberStorm (the Share extension): what is waiting is handed to
    /// the page's own review, as Add media's picked files are, once somebody
    /// is signed in - the page says whether it took them, and is asked again
    /// every few seconds for a minute after it loads (it signs in after).
    private func handShared() {
        sharedTries?.cancel()
        SharedInbox.sweep(keeping: FileUploads.shared.waitingFiles)
        guard !SharedInbox.readyShares().isEmpty else { return }
        sharedTries = Task {
            for _ in 0..<20 {
                if await offerShared() { return }
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            }
        }
    }

    /// One try: every ready share moved to "taken" and handed over together;
    /// put back if the page does not take them.
    private func offerShared() async -> Bool {
        let shares = SharedInbox.readyShares()
        guard !shares.isEmpty else { return true }
        var moved: [(from: URL, to: URL)] = []
        var files: [FileUploads.Picked] = []
        for share in shares {
            guard let to = SharedInbox.markTaken(share) else { continue }
            moved.append((share, to))
            for file in SharedInbox.files(in: to) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = ((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000
                files.append(FileUploads.Picked(id: UUID().uuidString.lowercased(), name: file.lastPathComponent,
                                                size: size, modified: modified, file: file.path))
            }
        }
        guard !files.isEmpty else { return true }
        FileUploads.shared.register(files)
        let list = files.map { ["id": $0.id, "name": $0.name, "size": $0.size, "lastModified": $0.modified] as [String: Any] }
        let took: Bool
        if let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) {
            let answer = try? await webView.evaluateJavaScript(
                "(typeof window.__soundstormShared === 'function' && window.__soundstormShared(\(json))) === true")
            took = answer as? Bool == true
        } else {
            took = false
        }
        if !took {
            FileUploads.shared.forget(files.map(\.id))
            for m in moved { try? FileManager.default.moveItem(at: m.to, to: m.from) }
        }
        return took
    }

    /// A new page (a reload, the move to the secure name, a server changed):
    /// the volume buttons go back to the phone. Left on, they kept turning a
    /// TV the new page knew nothing of, and the phone's own volume stayed
    /// stuck in the middle - the page says again if it still controls one.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new page (signed in or out, another person chosen): who is signed
        // in is asked afresh.
        PhotoBackup.shared.forgetWho(current)
        volumeKeys.set(false, in: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        // -keptTest YES: the downloads kept by the app, tried against a plain
        // server of test files (/static/song.bin, /static/pic.svg; KeptFiles),
        // logged as KEPTTEST - online it keeps and reads them, offline it
        // reports the kept page.
        if UserDefaults.standard.bool(forKey: "keptTest") {
            webView.callAsyncJavaScript("""
                const answers = []; window.__soundstormKeep = (a) => answers.push(a);
                const app = window.soundstormApp || {};
                const out = { at: location.protocol + '//' + location.host, keeps: app.keeps, keptURLs: (app.keptURLs || []).length, index: app.keptIndex };
                if (location.protocol !== 'emberstorm-kept:') {
                  app.keep('shell', { urls: ['/', '/static/app.js'] });
                  app.keep('add', { id: 't', urls: ['/static/song.bin', '/static/pic.svg', '/nope-404', 'https://example.com/x'] });
                  app.keep('index', { index: { groups: [{ id: 'g' }], items: {} } });
                  for (let i = 0; i < 60 && !answers.some((a) => a.cmd === 'done'); i++) await new Promise((r) => setTimeout(r, 200));
                  out.done = answers.find((a) => a.cmd === 'done');
                  const orig = await (await fetch('/static/song.bin')).arrayBuffer();
                  out.origLen = orig.byteLength;
                }
                const u = app.keptURL('/static/song.bin');
                const whole = await fetch(u);
                const wb = await whole.arrayBuffer();
                const part = await fetch(u, { headers: { Range: 'bytes=100-199' } });
                const pb = new Uint8Array(await part.arrayBuffer());
                Object.assign(out, { url: u, status: whole.status, len: wb.byteLength, type: whole.headers.get('content-type'),
                  range: part.status, rangeLen: pb.length, rangeFirst: pb[0], title: document.title });
                return JSON.stringify(out);
                """, arguments: [:], in: nil, in: .page) { r in NSLog("KEPTTEST %@", String(describing: r)) }
        }
        #endif
        handShared()
        // On the kept page: the server is looked for until it answers.
        if current.scheme == KeptFiles.scheme { watchServer() }
        // Which install this address is, so a failure here can open the kept
        // page of another of its addresses.
        if current.scheme != KeptFiles.scheme {
            let here = current
            Task {
                let health = await ServerAddress.health(here)
                if let id = health?.id ?? ServerAddress.installName(here.host() ?? "")?.label {
                    KeptFiles.shared.rememberId(here, id: id)
                }
                // The router's outside port, for the away twin (another
                // EmberStorm in the house may hold the usual one).
                if let health { ServerAddress.rememberPorts(here, awayPort: health.awayPort) }
            }
        }
        // What the server calls itself now, for the list of servers (the
        // owner may have renamed it since).
        let server = self.server
        Task { try? await ServerAddress.check(server) }
        // The sign-in carried to this name's twin (home <-> away), so leaving
        // the Wi-Fi does not ask for it again (as Android 0.52).
        if let twin = ServerAddress.installName(current.host() ?? "").flatMap({ ServerAddress.twin(current, level: $0.level == "home" ? "net" : "home") }) {
            let here = current
            Task { await Self.mirrorCookies(from: here, to: twin) }
        }
        #if DEBUG
        audioTest(webView)
        #endif
    }

    #if DEBUG
    /// For the simulator, which has no lock screen to press: `-audioTest
    /// <path>` plays that address through the page's audio element, pauses
    /// it, then plays it again as the lock screen's play does, printing what
    /// the page sees at each step.
    private func audioTest(_ webView: WKWebView) {
        guard let path = UserDefaults.standard.string(forKey: "audioTest"), !audioTested else { return }
        audioTested = true
        let look = { (step: String) in
            webView.evaluateJavaScript("(() => { const a = document.getElementById('audio-player'); return JSON.stringify({ paused: a.paused, t: a.currentTime, d: a.duration, src: a.src }); })()") { r, _ in
                NSLog("audioTest %@: %@", step, "\(r ?? "nil")")
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            _ = try? await webView.evaluateJavaScript("(() => { const a = document.getElementById('audio-player'); a.src = location.origin + '\(path)'; a.play(); return 1; })()")
            try? await Task.sleep(for: .seconds(6)); look("playing")
            _ = try? await webView.evaluateJavaScript("document.getElementById('audio-player').pause(); 1")
            try? await Task.sleep(for: .seconds(4)); look("paused")
            NativeAudio.shared.debugRemotePlay()
            try? await Task.sleep(for: .seconds(4)); look("lock screen play")
        }
    }
    #endif

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    // MARK: Looking for the server while offline

    /// While the kept page shows, the server is asked for every 15 seconds for
    /// two minutes, then every minute, and at once on coming to the front or
    /// the network changing; answering, it is opened. Not in the background.
    func watchServer() {
        watchTask?.cancel()
        guard current.scheme == KeptFiles.scheme, UIApplication.shared.applicationState != .background else { return }
        let addresses = [server] + [ServerAddress.twin(server, level: "net")].compactMap { $0 }.filter { $0 != server }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                for address in addresses where await Self.answers(address) {
                    guard !Task.isCancelled, let self, self.current.scheme == KeptFiles.scheme else { return }
                    PlayerLog.add("server answers again: leaving the kept page")
                    self.load()
                    return
                }
                guard let self else { return }
                let wait: Double = Date().timeIntervalSince(self.watchSince) < 120 ? 15 : 60
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in
                    guard let self, self.current.scheme == KeptFiles.scheme else { return }
                    self.watchServer()
                }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// The server's /healthz answering, asked with no cookies.
    nonisolated private static func answers(_ server: URL) async -> Bool {
        var request = URLRequest(url: server.appending(path: "healthz"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        guard let (_, response) = try? await ServerAddress.smallData(request, session: watchSession) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    nonisolated private static let watchSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS reclaims a background web view's memory by killing its page.
        // Reloading is what Safari does when you come back to such a tab.
        volumeKeys.set(false, in: nil)
        load()
    }
}

extension WebViewController: WKUIDelegate {
    // A web view shows no alert(), confirm() or prompt() unless its app does,
    // and SoundStorm asks before removing downloads and big files.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
            show(alert) { done.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            show(alert) { done.resume(returning: false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            show(alert) { done.resume(returning: nil) }
        }
    }

    /// Shows a dialog over whatever is on top. When it cannot be shown - the
    /// app is not on screen, or another dialog is up - it answers at once as
    /// Cancel would (`otherwise`): a question never shown never answered,
    /// and the page's confirm() waited for ever.
    /// Another dialog up, or one still closing (the page asking twice in a
    /// row): it waits for it, a few seconds at most, rather than answering
    /// Cancel straight away - which turned down a question nobody saw.
    private func show(_ alert: UIAlertController, otherwise: @escaping () -> Void, tries: Int = 0) {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        guard view.window != nil else {
            otherwise()
            return
        }
        if top is UIAlertController || top.isBeingDismissed || top.isBeingPresented {
            guard tries < 20 else {
                otherwise()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return otherwise() }
                self.show(alert, otherwise: otherwise, tries: tries + 1)
            }
            return
        }
        top.present(alert, animated: true)
    }

    /// target="_blank" (the ListenBrainz and LRCLIB links in Account): Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Only a link somebody followed, and only to the web: not a window a
        // script opened, nor any other kind of address.
        if let url = action.request.url, action.navigationType == .linkActivated,
           ["http", "https"].contains(url.scheme ?? "") {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

/// WKUserContentController holds its handlers strongly, and the controller
/// holds the web view, so a direct reference would never be freed.
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var target: WebViewController?

    init(_ target: WebViewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.received(message)
    }
}

/// Shown when the server cannot be reached, with the two ways forward: try
/// again, or point the app at a different address.
private final class FailureView: UIView {
    var onRetry: (() -> Void)?
    var onChangeServer: (() -> Void)?

    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        title.font = .preferredFont(forTextStyle: .title3)
        title.textColor = .white
        title.numberOfLines = 0
        title.textAlignment = .center

        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center

        var retry = UIButton.Configuration.filled()
        retry.title = "Try again"
        retry.baseBackgroundColor = UIColor(red: 0x6a / 255, green: 0xa8 / 255, blue: 0xff / 255, alpha: 1)
        retry.baseForegroundColor = .black
        retry.cornerStyle = .large
        let retryButton = UIButton(configuration: retry)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        var change = UIButton.Configuration.plain()
        change.title = "Change server"
        change.baseForegroundColor = .secondaryLabel
        let changeButton = UIButton(configuration: change)
        changeButton.addAction(UIAction { [weak self] _ in self?.onChangeServer?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [title, detail, retryButton, changeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(24, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(host: String, detail text: String) {
        title.text = "Can't reach EmberStorm at \(host)"
        detail.text = text
        isHidden = false
    }
}
