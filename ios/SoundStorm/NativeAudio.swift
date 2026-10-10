import AVFoundation
import ImageIO
import MediaPlayer
import UIKit
import WebKit

/// The page's audio element, played by iOS itself (the Android app's
/// NativeAudio, in Swift). Reported as: paused from the lock screen, the music
/// could not be started again there. The page played the music in its web
/// view, and a few seconds after a pause iOS suspends an app that is playing
/// nothing - the web view with it - so the lock screen's play had nothing
/// awake to answer it. A player of the app's own is woken by iOS for its
/// remote commands, and plays on from where it was.
///
/// The page script gives `<audio id="audio-player">` the Android app's
/// stand-in (`window.soundstormApp.nativeAudio`): a song on the server set
/// as its src, play, pause, seeking, volume and speed arrive here as "audio"
/// messages, and what the player does goes back through
/// `window.__soundstormAudio` as the element's own events. A downloaded song
/// (a blob: address) plays in the page as before. The page hands over the
/// songs ahead (`upcoming`), so the player moves into them by itself, with
/// the page asleep and the lock screen naming each.
@MainActor
final class NativeAudio: NSObject {
    static let shared = NativeAudio()

    weak var webView: WKWebView?
    /// Where the page is: only its own addresses are played.
    var isServer: (URL) -> Bool = { _ in false }

    private let player = AVQueuePlayer()
    private var urls: [ObjectIdentifier: String] = [:]
    private var upcomingMeta: [String: Meta] = [:]
    private var lastItem: AVPlayerItem?
    private var ended = false
    private var seeking = false
    private var rate: Float = 1
    private var failed = false
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    /// Messages are run in order: a load waits for the cookies, and the play
    /// sent straight after it must not overtake it.
    private var chain: Task<Void, Never>?

    /// What the page says is playing, and which lock-screen buttons it has.
    private var meta = Meta()
    private var actions: Set<String> = []
    private var artwork: (url: String, image: MPMediaItemArtwork)?

    struct Meta: Equatable {
        var title = "", artist = "", album = "", art = ""
    }

    private override init() {
        super.init()
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.changed() }
        })
        observations.append(player.observe(\.currentItem) { [weak self] _, _ in
            DispatchQueue.main.async { self?.itemChanged() }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(playedToEnd(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        // For a playback report: what went wrong on the way.
        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { note in
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError).map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "?"
            MainActor.assumeIsolated { PlayerLog.add("player: failed to play to the end: \(error)") }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PlayerLog.add("player: stalled (ran out of song)") }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: nil, queue: .main) { note in
            let e = (note.object as? AVPlayerItem)?.errorLog()?.events.last
            let line = e.map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? "?"
            MainActor.assumeIsolated { PlayerLog.add("player: network error: \(line)") }
        }
        commands()
    }

    // MARK: From the page

    func handle(_ m: [String: Any]) {
        let previous = chain
        chain = Task {
            await previous?.value
            await run(m)
        }
    }

    private func run(_ m: [String: Any]) async {
        let cmd = m["cmd"] as? String ?? ""
        switch cmd {
        case "load", "queue": PlayerLog.add("page: \(cmd) \(PlayerLog.song(m["url"] as? String))")
        case "upcoming": PlayerLog.add("page: upcoming, \((m["items"] as? [Any])?.count ?? 0) songs")
        case "seek": PlayerLog.add("page: seek to \((m["s"] as? NSNumber)?.doubleValue ?? 0)")
        case "play", "pause", "stop", "unqueue": PlayerLog.add("page: \(cmd)")
        case "place": PlayerLog.add("page: place \((m["place"] as? [String: Any])?["path"] as? String ?? "none")")
        case "sleep":
            let at = (m["at"] as? NSNumber)?.doubleValue ?? 0
            let wait = at / 1000 - Date().timeIntervalSince1970
            PlayerLog.add("page: sleep timer \(at > 0 && wait.isFinite ? "in \(Int(min(max(wait, -1e9), 1e9)))s" : "off")")
        default: break
        }
        // A new file: the book's place is told again once it plays there. Not
        // the file already playing - a page made again takes it over with a
        // load of it, paused, and no "playing" comes to tell the place again.
        if cmd == "load", player.currentItem.flatMap({ urls[ObjectIdentifier($0)] }) != m["url"] as? String {
            place = nil
        }
        switch cmd {
        case "place":
            setPlace(m["place"] as? [String: Any])
        case "load":
            guard let url = allowed(m["url"]) else { return }
            if let current = player.currentItem, urls[ObjectIdentifier(current)] == url.absoluteString {
                // Already this song: moved into it by itself, or asked for
                // again after it ended, which starts it over.
                if ended { await player.seek(to: .zero); ended = false }
                report()
                return
            }
            let items = player.items()
            if items.count > 1, urls[ObjectIdentifier(items[1])] == url.absoluteString {
                // The one queued next, reached early (a skip).
                ended = false
                player.advanceToNextItem()
            } else {
                let item = await makeItem(url)
                player.removeAllItems()
                ended = false
                failed = false
                player.insert(item, after: nil)
            }
            tookOver()
            report()
        case "queue":
            guard let url = allowed(m["url"]), player.currentItem != nil else { return }
            dropAfterCurrent()
            player.insert(await makeItem(url), after: player.items().last)
        case "upcoming":
            guard player.currentItem != nil else { return }
            dropAfterCurrent()
            for o in (m["items"] as? [[String: Any]] ?? []).prefix(50) {
                guard let url = allowed(o["url"]) else { break }
                upcomingMeta[url.absoluteString] = Meta(title: o["title"] as? String ?? "", artist: o["artist"] as? String ?? "",
                                                        album: o["album"] as? String ?? "", art: o["art"] as? String ?? "")
                player.insert(await makeItem(url), after: player.items().last)
            }
        case "unqueue":
            dropAfterCurrent()
        case "sleep":
            setSleep((m["at"] as? NSNumber)?.doubleValue ?? 0)
        case "play":
            play()
        case "pause":
            player.pause()
        case "state":
            report()
        case "seek":
            let s = max(0, (m["s"] as? NSNumber)?.doubleValue ?? 0)
            seeking = true
            ended = false
            await player.seek(to: CMTime(seconds: s, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            report()
        case "volume":
            player.volume = min(1, max(0, (m["v"] as? NSNumber)?.floatValue ?? 1))
        case "rate":
            rate = min(4, max(0.25, (m["r"] as? NSNumber)?.floatValue ?? 1))
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        case "stop":
            savePlace(force: true)
            place = nil
            player.pause()
            player.removeAllItems()
            urls.removeAll()
            lastItem = nil
            ended = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            report()
        default:
            break
        }
    }

    /// What the page's media session says: the song, and its buttons.
    func media(_ m: [String: Any]) {
        actions = Set(m["actions"] as? [String] ?? [])
        if let d = m["metadata"] as? [String: Any] {
            meta = Meta(title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "",
                        album: d["album"] as? String ?? "", art: (d["artwork"] as? [String])?.first ?? "")
        }
        enableCommands()
        nowPlaying()
    }

    private func allowed(_ value: Any?) -> URL? {
        guard let s = value as? String, let url = URL(string: s), url.scheme == "http" || url.scheme == "https",
              isServer(url) else { return nil }
        return url
    }

    private func dropAfterCurrent() {
        for item in player.items().dropFirst() { player.remove(item) }
    }

    private func makeItem(_ url: URL) async -> AVPlayerItem {
        // The player does not read the web view's cookies: the session's are
        // handed to it, as the Apple TV does.
        let cookies = await cookies(for: url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        let item = AVPlayerItem(asset: asset)
        urls[ObjectIdentifier(item)] = url.absoluteString
        observations.append(item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, item.status == .failed, item === self.player.currentItem else { return }
                PlayerLog.add("player: song failed: \(item.error.map { ($0 as NSError).domain + " \(($0 as NSError).code) " + $0.localizedDescription } ?? "?")")
                self.failed = true
                self.report()
            }
        })
        return item
    }

    private func cookies(for url: URL) async -> [HTTPCookie] {
        guard let host = url.host()?.lowercased() else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter { c in
            let domain = c.domain.lowercased()
            // Only the server's own: a cookie for a parent (.emberstorm.app) could be set by another install there (the eleventh security pass).
            return domain == host || domain == "." + host
        }
    }

    // An audiobook's place, saved by the player itself (Android 0.54's, the
    // owner's report of 2026-10-09: an hour listened with the screen off was an
    // hour back on the next device - iOS sleeps the page, and the page did the
    // saving). The page says where the place is saved and where each of the
    // book's files begins on its timeline (window.soundstormApp.place); while
    // the book plays, the place is sent every ten seconds, and once more
    // whenever it stops. The page still saves too while it is awake.
    private struct Place {
        let url: URL
        let duration: Double
        let files: [(path: String, offset: Double)]
    }
    private var place: Place?
    private var placeSavedAt = Date.distantPast
    private var placeLast = -1.0
    /// One save at a time, in order: an older one must not land after a newer.
    private var placeSending: Task<Void, Never>?

    private func setPlace(_ o: [String: Any]?) {
        place = nil
        placeSavedAt = .distantPast
        placeLast = -1
        guard let o, let path = o["path"] as? String, path.hasPrefix("/api/playback/") else { return }
        var files: [(path: String, offset: Double)] = []
        var origin: URL?
        for f in (o["files"] as? [[String: Any]] ?? []).prefix(2000) {
            guard let url = allowed(f["url"]) else { continue }
            let offset = (f["offset"] as? NSNumber)?.doubleValue ?? 0
            guard offset.isFinite, offset >= 0 else { continue }
            files.append((url.path, offset))
            if origin == nil { origin = url }
        }
        guard let origin, !path.contains("?"), !path.contains("#"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.host() == origin.host(), url.port == origin.port, isServer(url) else { return }
        let duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        place = Place(url: url, duration: duration.isFinite && duration > 0 ? duration : 0, files: files)
    }

    /// Sends the book's place if it is due: every ten seconds while playing,
    /// and at once when it stops (force).
    private func savePlace(force: Bool) {
        guard let pl = place, let item = player.currentItem, let current = urls[ObjectIdentifier(item)],
              let path = URL(string: current)?.path,
              let file = pl.files.firstIndex(where: { $0.path == path }) else { return }
        // Only from a settled player: not while loading, buffering or jumping,
        // when its position is not yet the book's (Android's review, 2026-10-09).
        guard !seeking, item.status == .readyToPlay,
              ended || player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { return }
        let now = Date()
        if !force, now.timeIntervalSince(placeSavedAt) < 10 { return }
        let at = player.currentTime().seconds
        let finished = ended && file == pl.files.count - 1
        let seconds = pl.files[file].offset + (at.isFinite ? max(0, at) : 0)
        if !finished, abs(seconds - placeLast) < 0.5 { return }
        placeSavedAt = now
        placeLast = seconds
        guard let body = try? JSONSerialization.data(withJSONObject: ["seconds": seconds, "duration": pl.duration, "finished": finished])
        else { return }
        let previous = placeSending
        placeSending = Task {
            await previous?.value
            var request = URLRequest(url: pl.url, timeoutInterval: 15)
            request.httpMethod = "PUT"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (field, value) in HTTPCookie.requestHeaderFields(with: await cookies(for: pl.url)) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            // No redirects: the Cookie header set here would go with one.
            do {
                let (_, response) = try await URLSession.shared.data(for: request, delegate: ArtNoRedirects())
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status >= 300 { PlayerLog.add("place not saved: \(status)") }
            } catch {
                PlayerLog.add("place not saved: \((error as NSError).code)")
            }
        }
    }

    /// The sleep timer (2026-10-07, the owner's report: a half-hour timer ran
    /// on for hours with the screen off - the page's timer sleeps with the
    /// page). Kept here, it runs while background audio keeps the app awake:
    /// at the moment the page gave (ms since 1970; 0 cancels), the music fades
    /// over eight seconds and pauses, as Android's does.
    private var sleepTimer: Timer?
    private var sleepFade: Timer?

    private func setSleep(_ at: Double) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepFade?.invalidate()
        sleepFade = nil
        guard at > 0 else { return }
        let wait = max(0, at / 1000 - Date().timeIntervalSince1970)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { NativeAudio.shared.sleepNow() }
        }
    }

    private func sleepNow() {
        sleepTimer = nil
        guard player.timeControlStatus != .paused else { return }
        PlayerLog.add("sleep timer: fading out")
        let start = player.volume
        let began = Date()
        sleepFade = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let me = NativeAudio.shared
                let t = Float(min(1, Date().timeIntervalSince(began) / 8))
                me.player.volume = start * (1 - t)
                if t < 1, me.player.timeControlStatus != .paused { return }
                me.sleepFade?.invalidate()
                me.sleepFade = nil
                me.player.pause()
                me.player.volume = start
                me.report()
            }
        }
    }

    private func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        if ended, player.currentItem != nil {
            player.seek(to: .zero)
            ended = false
        }
        player.defaultRate = rate
        player.play()
    }

    // MARK: What the player did

    /// The page changed the song itself (a song chosen, a skip, the same song
    /// started again after a lost connection): not the song ending. Taken for
    /// one, the page was told the song had ended and moved on to the next in
    /// its queue - reported as music stopping mid-song, and play then starting
    /// a different one.
    private func tookOver() {
        let item = player.currentItem
        if let last = lastItem, last !== item { urls[ObjectIdentifier(last)] = nil }
        lastItem = item
    }

    private func itemChanged() {
        let item = player.currentItem
        defer { lastItem = item }
        guard let last = lastItem, last !== item else { return }
        urls[ObjectIdentifier(last)] = nil
        failed = false
        // Moved into the queued song by itself: the page hears the last one
        // end, and sets this one, which it finds already playing.
        if let item, let next = urls[ObjectIdentifier(item)] {
            PlayerLog.add("player: moved on by itself to \(PlayerLog.song(next))")
            if let upcoming = upcomingMeta[next] { meta = upcoming; nowPlaying() }
            send(["ev": "ended", "next": next])
        }
    }

    @objc private func playedToEnd(_ note: Notification) {
        // The last song in the queue: the player stops on it.
        guard let item = note.object as? AVPlayerItem, item === player.currentItem,
              player.items().count <= 1 else { return }
        PlayerLog.add("player: reached the end of the queue")
        ended = true
        report()
    }

    @objc private func interrupted(_ note: Notification) {
        let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began ? "began" : "ended"
        PlayerLog.add("audio interruption \(kind)")
        // A call or an alarm over: play on if iOS says so.
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended,
              let o = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
              AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume),
              player.currentItem != nil else { return }
        play()
    }

    private var loggedStatus = ""

    private func changed() {
        let status: String
        switch player.timeControlStatus {
        case .playing: status = "playing"
        case .paused: status = "paused"
        default: status = "waiting: " + PlayerLog.waiting(player.reasonForWaitingToPlay)
        }
        if status != loggedStatus {
            loggedStatus = status
            PlayerLog.add("player: \(status) at \(Int(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0))s of \(PlayerLog.song(player.currentItem.flatMap { urls[ObjectIdentifier($0)] }))")
        }
        report()
        nowPlaying()
    }

    private func tick() {
        if player.timeControlStatus == .playing { report() }
    }

    private func state() -> [String: Any] {
        guard let item = player.currentItem else {
            return ["ev": "state", "state": "idle", "playing": false, "pwr": false]
        }
        let status = player.timeControlStatus
        let duration = item.duration.seconds
        let buffered = item.loadedTimeRanges.last.map { $0.timeRangeValue.end.seconds } ?? 0
        var o: [String: Any] = [
            "ev": "state",
            "state": ended ? "ended" : status == .waitingToPlayAtSpecifiedRate ? "buffering" : "ready",
            "playing": status == .playing,
            "pwr": status != .paused,
            "url": urls[ObjectIdentifier(item)] ?? "",
            "position": max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            "buffered": buffered.isFinite ? buffered : 0,
            "rate": Double(rate),
            "volume": Double(player.volume),
            "seeked": seeking && status != .waitingToPlayAtSpecifiedRate,
        ]
        if duration.isFinite, duration > 0 { o["duration"] = duration }
        if failed { o["error"] = 4 }
        return o
    }

    private func report() {
        let s = state()
        if s["seeked"] as? Bool == true { seeking = false }
        send(s)
        savePlace(force: player.timeControlStatus == .paused)
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__soundstormAudio && window.__soundstormAudio(\(json))")
    }

    /// A lock-screen button the page answers (next, previous, a jump).
    private func pageAction(_ action: String, _ details: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(withJSONObject: details),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__soundstormMediaAction && window.__soundstormMediaAction(\"\(action)\", \(json))")
    }

    #if DEBUG
    /// What the lock screen's play does, for the simulator's check.
    func debugRemotePlay() { play() }
    #endif

    // MARK: Lock screen, Control Centre, headphones, a car

    private func commands() {
        let c = MPRemoteCommandCenter.shared()
        // Play and pause are the player's own, so they work with the page
        // asleep - which is the whole point.
        c.playCommand.addTarget { [weak self] _ in
            guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
            self.play()
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.player.currentItem != nil else { return .noActionableNowPlayingItem }
            if self.player.timeControlStatus == .paused { self.play() } else { self.player.pause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.pageAction("nexttrack")
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.actions.contains("previoustrack") { self.pageAction("previoustrack") } else { self.player.seek(to: .zero) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            self?.pageAction("seekforward")
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            self?.pageAction("seekbackward")
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            if self.actions.contains("seekto") {
                self.pageAction("seekto", ["seekTime": event.positionTime])
            } else {
                self.player.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 1000))
            }
            return .success
        }
        enableCommands()
    }

    private func enableCommands() {
        let c = MPRemoteCommandCenter.shared()
        // An audiobook gets the jumps, not next and previous (as the page has it).
        let next = actions.contains("nexttrack")
        c.nextTrackCommand.isEnabled = next
        c.previousTrackCommand.isEnabled = next || actions.contains("previoustrack")
        c.skipForwardCommand.isEnabled = !next && actions.contains("seekforward")
        c.skipBackwardCommand.isEnabled = !next && actions.contains("seekbackward")
    }

    private func nowPlaying() {
        guard let item = player.currentItem else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: meta.title,
            MPMediaItemPropertyArtist: meta.artist,
            MPMediaItemPropertyAlbumTitle: meta.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if item.duration.seconds.isFinite { info[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds }
        if let artwork, artwork.url == meta.art { info[MPMediaItemPropertyArtwork] = artwork.image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if !meta.art.isEmpty, artwork?.url != meta.art { loadArtwork(meta.art) }
    }

    private nonisolated final class ArtNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        // The completion-handler form: Swift 6.3 crashes compiling the async one.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func loadArtwork(_ address: String) {
        guard let url = allowed(address) else { return }
        Task {
            var request = URLRequest(url: url)
            for (field, value) in HTTPCookie.requestHeaderFields(with: await cookies(for: url)) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            // Read up to 8MB and no further, and decoded straight to a
            // thumbnail (ImageIO) - a server's picture could be any size, and
            // whole it was read in full and decoded at full size first (the
            // eleventh security pass).
            // No redirects: the Cookie header set here would go with one.
            guard let (bytes, response) = try? await URLSession.shared.bytes(for: request, delegate: ArtNoRedirects()),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  response.expectedContentLength < 8 << 20 else { return }
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 8 << 20 { return }
                }
            } catch { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 600,
                                            kCGImageSourceShouldCacheImmediately: true]
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            let image = UIImage(cgImage: thumb)
            let art = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
            artwork = (address, art)
            nowPlaying()
        }
    }
}
