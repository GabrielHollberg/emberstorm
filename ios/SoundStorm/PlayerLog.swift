import AVFoundation
import UIKit

/// What happened, for a playback report (the Android app's PlayerLog): the
/// player's stalls and errors, the page's commands, the app opening and
/// going away, photo backup runs, and how smoothly the page drew while Now
/// Playing was open. Sent from Settings' "Sound cut out? Send a report",
/// which the page shows on the developer's own install only. The last 600
/// lines, kept in memory.
@MainActor
enum PlayerLog {
    private static var lines: [String] = []
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func add(_ line: String) {
        lines.append("\(clock.string(from: Date())) \(line)")
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        #if DEBUG
        NSLog("PlayerLog %@", line)
        #endif
    }

    static var text: String {
        let device = UIDevice.current
        let head = "iPhone app, \(device.model) iOS \(device.systemVersion), low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        return ([head] + lines).joined(separator: "\n")
    }

    /// A song's address, short: the last part of its path and any retry mark.
    static func song(_ url: String?) -> String {
        guard let url, let u = URLComponents(string: url) else { return "none" }
        let tail = u.path.split(separator: "/").suffix(2).joined(separator: "/")
        let retry = u.queryItems?.first(where: { $0.name == "retry" }).map { " retry=\($0.value ?? "")" } ?? ""
        return tail + retry
    }

    static func waiting(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls?: return "to minimize stalls"
        case .evaluatingBufferingRate?: return "evaluating buffering rate"
        case .noItemToPlay?: return "no item"
        case .interstitialEvent?: return "interstitial"
        case .waitingForCoordinatedPlayback?: return "coordinated playback"
        case let r?: return r.rawValue
        case nil: return "-"
        }
    }

    /// The app opening, going to the background and coming back.
    static func watchApp() {
        add("app launched")
        let centre = NotificationCenter.default
        centre.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { add("app active") }
        }
        centre.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { add("app in background") }
        }
        centre.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
            MainActor.assumeIsolated { add("audio route changed (reason \(raw)): \(outputs)") }
        }
    }
}
