import AVFoundation
import SwiftUI

@main
struct SoundStormApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // The playback category is what lets the web page's audio carry on
        // when the phone locks or the ring switch is on silent. Without it,
        // UIBackgroundModes=audio in Info.plist does nothing: iOS treats the
        // page's audio as ambient and stops it with the screen.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .ignoresSafeArea()
                // A TV's sign-in code: soundstorm://link?server=&code= from
                // the page in Safari, or the QR's own address once Universal
                // Links are set up (TVLink).
                .onOpenURL { url in NotificationCenter.default.post(name: .tvLink, object: url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { NotificationCenter.default.post(name: .tvLink, object: url) }
                }
                .statusBarHidden(AppChrome.shared.statusBarHidden)
                .animation(.easeInOut(duration: 0.25), value: AppChrome.shared.statusBarHidden)
                // Light status bar text over the app's black background.
                .preferredColorScheme(.dark)
        }
    }
}

/// Photo backup's half of the app's life: its background task is registered
/// at launch, as iOS requires, and an upload that finished with the app closed
/// is told to it here.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PlayerLog.watchApp()
        PhotoBackup.shared.launched()
        // Files added that were still waiting carry on.
        FileUploads.shared.resume()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if FileUploads.identifiers.contains(identifier) {
            // Files added, ended with the app closed: the sessions made again
            // to hear about them.
            nonisolated(unsafe) let done = completionHandler
            FileUploads.shared.finishedEvents = { done() }
            FileUploads.shared.resume()
            return
        }
        guard identifier == Uploader.identifier || identifier == Uploader.wifiIdentifier else { return completionHandler() }
        nonisolated(unsafe) let done = completionHandler
        Uploader.shared.whenFinished { DispatchQueue.main.async { done() } }
    }
}

/// What the app's frame shows around the page. The status bar is hidden
/// while the page's Now Playing is open (the owner's asking: nothing on the
/// screen but the music) and shown everywhere else, since an iPhone has no
/// swipe that brings a hidden one back for a look at the time.
@Observable
final class AppChrome {
    static let shared = AppChrome()
    var statusBarHidden = false
}

struct RootView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> RootViewController { RootViewController() }
    func updateUIViewController(_ controller: RootViewController, context: Context) {}
}

/// Shows the connect screen until a server is known, then the server's own
/// web app. Changing server goes back to the connect screen.
final class RootViewController: UIViewController {
    private var current: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        NotificationCenter.default.addObserver(forName: .tvLink, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { self?.open(url) }
        }
        if let server = ServerAddress.saved {
            showWeb(server)
        } else {
            showConnect(prefill: nil)
        }
    }

    private func showConnect(prefill: URL?, offered: URL? = nil, invite: String? = nil) {
        let connect = ConnectViewController(prefill: prefill, offered: offered)
        connect.onConnected = { [weak self] url in
            ServerAddress.remember(url)
            // An invitation offered here goes on once its server is chosen.
            let same = invite != nil && offered.map { o in
                o.host() == url.host() || (o.host().flatMap(ServerAddress.installName)?.label != nil
                    && o.host().flatMap(ServerAddress.installName)?.label == url.host().flatMap(ServerAddress.installName)?.label)
            } == true
            self?.showWeb(url, invite: same ? invite : nil)
        }
        show(connect)
    }

    /// A TV's code: to the page showing that server if it is open, else that
    /// (known) server opened with the code - the app's own if the link named
    /// one it does not know.
    private func open(_ url: URL) {
        // Open my SoundStorm: a known server opened, an unknown one offered.
        if let link = TVLink.open(url) {
            if !link.known {
                showConnect(prefill: (current as? WebViewController)?.serverURL, offered: link.server)
            } else if (current as? WebViewController)?.serverURL != link.server {
                ServerAddress.remember(link.server)
                showWeb(link.server)
            }
            return
        }
        // An invitation: that server's page, making the account - straight
        // there for a server this app knows; one it does not is offered on
        // the connect screen, not saved by itself (anybody can make an
        // invitation for their own install, and the page there would get
        // the app's bridge and photo backup; the eleventh security pass).
        if let invite = TVLink.invite(url) {
            if invite.known {
                ServerAddress.remember(invite.server)
                showWeb(invite.server, invite: invite.token)
            } else {
                showConnect(prefill: (current as? WebViewController)?.serverURL, offered: invite.server, invite: invite.token)
            }
            return
        }
        guard let link = TVLink.parse(url), let server = link.server ?? ServerAddress.saved else { return }
        if let web = current as? WebViewController, web.serverURL == server {
            web.handLink(link.code)
        } else {
            ServerAddress.remember(server)
            showWeb(server, link: link.code)
        }
    }

    /// The server last shown, so music from it stops on going to another.
    private var shownServer: URL?

    private func showWeb(_ server: URL, link: String? = nil, invite: String? = nil) {
        // Another server: the last one's music stops, and the new page is not
        // told what the old one was playing (the blind security review).
        // Moving to another name of the same install (its code) is not that.
        if let last = shownServer, last != server,
           last.host().flatMap(ServerAddress.installName)?.label == nil
            || last.host().flatMap(ServerAddress.installName)?.label != server.host().flatMap(ServerAddress.installName)?.label {
            NativeAudio.shared.handle(["cmd": "stop"])
        }
        shownServer = server
        let web = WebViewController(server: server, link: link, invite: invite)
        web.onChangeServer = { [weak self] in
            self?.showConnect(prefill: server)
        }
        web.onMoved = { [weak self] url in
            self?.showWeb(url)
        }
        show(web)
    }

    private func show(_ controller: UIViewController) {
        current?.willMove(toParent: nil)
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        current = controller
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? { current }
}

extension Notification.Name {
    static let tvLink = Notification.Name("soundstorm.tvLink")
}
