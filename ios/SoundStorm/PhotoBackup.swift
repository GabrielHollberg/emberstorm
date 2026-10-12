import BackgroundTasks
import Foundation
import Network
import Photos
import UIKit
import WebKit

/// Backing up this iPhone's photos and videos to the person's own folder on
/// their server (pictures/Personal/<name>/<year>/<month>/), as the Android
/// app does (android/ PhotoBackup.kt); the server's half is
/// httpapi/personalphotos.go, and the page's Settings drives it through
/// window.soundstormApp.backup, answered through window.__soundstormBackup.
///
/// **To any number of servers, one account on each, and each server's backup
/// belongs to the phone's own person there** (the owner's design,
/// 2026-10-12). The first person to sign in to a server on this phone is
/// asked, by the app, "Is this your iPhone?" - which only makes backup
/// possible for them later. Yes, and that server's backup is theirs: its
/// switch and options appear in their Settings, off until they turn it on.
/// No, and the next person to sign in there is asked; anyone may still claim
/// an unclaimed phone from Settings (an accidental No). Once claimed, nobody
/// else on that server on this phone is asked or sees a switch - only whose it
/// is - and the owner alone lets it go ("This isn't my iPhone"). Who is
/// signed in is asked of the server (`/api/session`), never taken from the
/// page: a second person signing in, or a page's message, cannot change
/// another's backup. Each server's backup has its own switch, options,
/// progress, confirmed list and marker (`Destination`).
///
/// iOS decides when an app may work in the background, so it runs: while the
/// app is open, when a photo is added while it is open, the half minute iOS
/// allows after the phone locks, and as a background processing task iOS
/// starts when it chooses - usually charging, on Wi-Fi, overnight. Newest
/// first. Files are handed to iOS ahead - up to 200, or a gigabyte, waiting
/// at once - in a background URLSession, which goes on sending them with the
/// phone locked and the app suspended or ended; each is counted as sent when
/// iOS says it arrived, whenever that is. (Sending one at a time and waiting
/// for each, backup stopped a few seconds after the screen locked.)
///
/// The phone keeps no list of what it sent (2026-10-03, as Android 0.37): each
/// run asks the server about every photo and sends what it lacks, so the
/// server is the one record - what it lost is sent again, and what somebody
/// deleted there it remembers and answers "have it" for. It signs in with the
/// web view's own cookie, so a server's backup goes only while its owner is
/// the one signed in there.
final class PhotoBackup: NSObject {
    static let shared = PhotoBackup()
    static let taskID = "dev.soundstorm.app.photobackup"

    private let defaults = UserDefaults.standard
    private let network = NWPathMonitor()
    private var onWiFi = true
    private var run: Task<Void, Never>?
    private var watching = false
    private var changed: Task<Void, Never>?

    private override init() {
        super.init()
        network.pathUpdateHandler = { @Sendable path in
            // Not "expensive" (cellular, a phone's hotspot) or "constrained"
            // (Low Data Mode): what Wi-Fi only means to a person.
            let wifi = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in PhotoBackup.shared.wifiChanged(wifi) }
        }
        network.start(queue: DispatchQueue(label: "photo-backup-network"))
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Plugged in: a run waiting for it can go.
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhotoBackup.shared.conditionsChanged() }
        }
        migrate()
    }

    // MARK: Each server's backup

    /// One server's backup on this phone: whose phone it is there, and how
    /// its backup is set and going.
    struct Destination: Codable {
        /// The server: the install's label, else host and port.
        var key: String
        /// What the server calls itself, for "also backs up to".
        var name: String
        /// Where photos go: its secure address.
        var server: String?
        /// The address the app was opened with then (the last resort).
        var typed: String
        /// Whose phone this is there (the server's id for the account).
        var account: String
        var person: String
        var enabled = false
        var wifiOnly = true
        var videos = true
        var charging = false
        var done = 0
        var total = 0
        var problem = ""
        var marker: String?
        var lastFull: Date?
        var fullPending = true
        var lastWholeRun: Date?
    }

    private var destinations: [Destination] {
        get {
            (defaults.data(forKey: "backup.destinations")).flatMap { try? JSONDecoder().decode([Destination].self, from: $0) } ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "backup.destinations") }
    }

    private func destination(_ key: String) -> Destination? { destinations.first { $0.key == key } }

    private func update(_ key: String, _ change: (inout Destination) -> Void) {
        var all = destinations
        guard let i = all.firstIndex(where: { $0.key == key }) else { return }
        change(&all[i])
        destinations = all
    }

    /// Who answered No to "Is this your iPhone?", by server.
    private var declined: [String: [String]] {
        get { defaults.dictionary(forKey: "backup.declined") as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: "backup.declined") }
    }

    /// Any server's backup is on.
    var enabled: Bool { destinations.contains { $0.enabled } }

    var permitted: Bool {
        [.authorized, .limited].contains(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Which server an address is: the install's label (its home and away
    /// names, and a chosen one, are one server), else host and port.
    static func serverKey(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        if let n = ServerAddress.installName(host) { return n.label }
        return host + ":" + String(url.port ?? (url.scheme == "http" ? 80 : 443))
    }

    private static func origin(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// A phone from before servers had backups of their own: its one backup
    /// becomes that server's, its owner the account it was turned on for.
    private func migrate() {
        guard defaults.data(forKey: "backup.destinations") == nil else { return }
        defer { if defaults.data(forKey: "backup.destinations") == nil { destinations = [] } }
        guard let typed = defaults.string(forKey: "backup.typed").flatMap(URL.init(string:)),
              let account = defaults.string(forKey: "backup.account"), !account.isEmpty else { return }
        let old = { (k: String, d: Bool) in self.defaults.object(forKey: "backup." + k) as? Bool ?? d }
        let key = Self.serverKey(typed)
        var d = Destination(key: key, name: typed.host() ?? key, server: defaults.string(forKey: "backup.server"),
                            typed: typed.absoluteString, account: account, person: "")
        d.enabled = old("enabled", false)
        d.wifiOnly = old("wifiOnly", true)
        d.videos = old("videos", true)
        d.charging = old("charging", false)
        d.done = defaults.integer(forKey: "backup.done")
        d.total = defaults.integer(forKey: "backup.total")
        d.marker = defaults.string(forKey: "backup.marker")
        d.lastFull = defaults.object(forKey: "backup.lastFull") as? Date
        d.fullPending = old("fullPending", true)
        destinations = [d]
        let oldList = Self.folder.appending(path: "backup-confirmed.txt")
        if defaults.string(forKey: "backup.confirmedScope") != nil {
            try? FileManager.default.moveItem(at: oldList, to: Self.confirmedFile(key))
        }
    }

    // MARK: Who is asking

    /// The person signed in on a server, as the server says (never the page).
    struct Person: Sendable {
        let id: String
        let name: String
        let pictures: Bool
        let serverName: String
    }

    private var people: [String: (person: Person?, at: Date)] = [:]

    /// Asked of the server with the web view's cookie: the page asks every
    /// few seconds while Settings is open.
    func whoIs(_ page: URL) async -> Person? {
        guard let origin = Self.origin(page) else { return nil }
        let key = origin.absoluteString
        // Somebody signed in is kept a quarter minute (each new page asks
        // afresh, `forgetWho`); nobody signed in is not kept at all, so a
        // sign-in shows at once.
        if let known = people[key], known.person != nil, Date().timeIntervalSince(known.at) < 15 { return known.person }
        var request = URLRequest(url: origin.appending(path: "api/session"))
        request.timeoutInterval = 15
        var person: Person?
        if (try? await WebCookies.apply(to: &request)) == true,
           let (data, response) = try? await Self.plain.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, data.count < 256 << 10,
           let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           answer["signedIn"] as? Bool == true, let user = answer["user"] as? [String: Any],
           let id = user["id"] as? String, !id.isEmpty {
            let libraries = user["libraries"] as? [String] ?? []
            person = Person(id: id, name: user["name"] as? String ?? "", pictures: libraries.contains("picture"),
                            serverName: answer["serverName"] as? String ?? "")
        }
        people[key] = (person, Date())
        return person
    }

    /// Signed in or out, or switched person: asked afresh.
    func forgetWho(_ page: URL) {
        if let origin = Self.origin(page) { people[origin.absoluteString] = nil }
    }

    // MARK: For the page

    /// Whether "Is this your iPhone?" is to be asked now: a server nobody has
    /// claimed this phone on, a person with Pictures who has not answered.
    func shouldAsk(_ page: URL, _ who: Person) -> Bool {
        let key = Self.serverKey(page)
        guard who.pictures, destination(key) == nil else { return false }
        return !(declined[key] ?? []).contains(who.id)
    }

    /// Their answer: Yes claims the phone on this server; No is kept, so they
    /// are not asked again (Settings still offers the claim).
    func answered(_ yes: Bool, page: URL, typed: URL, who: Person) {
        if yes {
            claim(page: page, typed: typed, who: who)
        } else {
            let key = Self.serverKey(page)
            var all = declined
            all[key, default: []].append(who.id)
            declined = all
        }
    }

    private func claim(page: URL, typed: URL, who: Person) {
        let key = Self.serverKey(page)
        guard destination(key) == nil, who.pictures else { return }
        var d = Destination(key: key, name: who.serverName.isEmpty ? (page.host() ?? key) : who.serverName,
                            server: nil, typed: Self.origin(typed)?.absoluteString ?? typed.absoluteString,
                            account: who.id, person: who.name)
        if page.scheme == "https" { d.server = Self.origin(page)?.absoluteString }
        destinations = destinations + [d]
    }

    /// What the page asked, for the person signed in on its server.
    func handle(_ command: String, options: [String: Any], page: URL, typed: URL, who: Person) async {
        let key = Self.serverKey(page)
        switch command {
        case "claim":
            // "This is my iPhone", in Settings: only while nobody has.
            claim(page: page, typed: typed, who: who)
        case "release":
            // "This isn't my iPhone": the owner lets it go; everyone may be
            // asked again.
            guard destination(key)?.account == who.id else { return }
            destinations = destinations.filter { $0.key != key }
            var all = declined
            all[key] = nil
            declined = all
            try? FileManager.default.removeItem(at: Self.confirmedFile(key))
            if !enabled { run?.cancel() }
            schedule()
        case "set":
            // Only the phone's own person on this server changes its backup:
            // another account's "off" (signing in after them, signing out) is
            // not theirs to give.
            guard destination(key)?.account == who.id else { return }
            var options = options
            if options["enabled"] as? Bool == true && !permitted {
                let answer = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                // Refused, backup stays off and the page says why.
                if ![.authorized, .limited].contains(answer) { options["enabled"] = false }
            }
            update(key) { d in
                if let v = options["enabled"] as? Bool { d.enabled = v }
                if let v = options["wifiOnly"] as? Bool { d.wifiOnly = v }
                if let v = options["videos"] as? Bool { d.videos = v }
                if let v = options["charging"] as? Bool { d.charging = v }
                d.problem = ""
                d.person = who.name
                if !who.serverName.isEmpty { d.name = who.serverName }
                // Its secure address, from the page (the address typed is
                // often plain http; photos go only over https).
                if page.scheme == "https" { d.server = Self.origin(page)?.absoluteString }
            }
            if destination(key)?.enabled == true {
                start()
            } else {
                if !enabled { run?.cancel() }
                schedule()
            }
        default:
            break
        }
    }

    /// This server's backup, as the person signed in there may see it.
    func status(_ page: URL, _ who: Person?) -> [String: Any] {
        let key = Self.serverKey(page)
        let mine = destination(key).flatMap { d in d.account == who?.id ? d : nil }
        var out: [String: Any] = [
            "phone": mine != nil ? "mine" : (destination(key) != nil ? "theirs" : "unclaimed"),
            "permission": permitted,
            "enabled": mine?.enabled ?? false,
            "decided": mine != nil,
            "wifiOnly": mine?.wifiOnly ?? true, "videos": mine?.videos ?? true, "charging": mine?.charging ?? false,
            "done": mine?.done ?? 0, "total": mine?.total ?? 0,
            "running": mine != nil && (runningKey == key || Uploader.shared.pending(key).count > 0),
            "problem": mine?.problem ?? "",
        ]
        if let d = destination(key), mine == nil { out["phoneOwner"] = d.person }
        if mine != nil {
            // How far through the file going now, when it is this server's.
            if defaults.string(forKey: "backup.sendingDest") == key {
                out["sendingSize"] = defaults.integer(forKey: "backup.sendingSize")
                out["sendingSent"] = defaults.integer(forKey: "backup.sendingSent")
                out["sendingVideo"] = defaults.bool(forKey: "backup.sendingVideo")
            }
            out["elsewhere"] = destinations.filter { $0.key != key && $0.enabled }.map(\.name)
        }
        return out
    }

    // MARK: When it runs

    /// At launch: the background task, and watching for new photos.
    func launched() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in PhotoBackup.shared.runInBackground(task) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PhotoBackup.shared.pageAsked() }
        }
        // The phone locking (or the app put away): iOS allows about half a
        // minute more, spent handing it as many files as fit; it sends those
        // with the app suspended.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in PhotoBackup.shared.wentToBackground() }
        }
        if enabled { pageAsked() }
    }

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func wentToBackground() {
        guard enabled, permitted else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") {
                Task { @MainActor in PhotoBackup.shared.endBackgroundTime() }
            }
        }
        start()
    }

    private func endBackgroundTime() {
        // Out of time: what is already with iOS goes on; the run stops here.
        run?.cancel()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    /// A run asked for while the last one's files were still with iOS: it
    /// starts once they are through.
    private var startWhenSent = false
    /// The server said it was busy (429): nothing new until then.
    private var busyUntil = Date.distantPast
    /// The server a run is on now.
    private var runningKey: String?

    /// The page sends a backup message every few seconds (its status), and
    /// each one used to start a run - a question to the server about every
    /// photo - which is most of what flooded the server on the first full
    /// backup. From the page now, a run starts only when the last did not
    /// get through (not signed in yet, the network, put away) or ten minutes
    /// have passed; photos taken meanwhile start one of their own. So does
    /// opening the app: every opening used to check every photo again.
    func pageAsked() {
        // A run that ended early (waiting for Wi-Fi or charging, not signed
        // in, the server not answering) is not started again for every
        // message the page sends: a report showed one starting every four
        // seconds the whole time the app was open, each reading the photo
        // library before giving up.
        if let began = lastStarted, Date().timeIntervalSince(began) < 60 { return }
        let recent = destinations.filter(\.enabled).allSatisfy { d in
            d.lastWholeRun.map { Date().timeIntervalSince($0) < 600 } ?? false
        }
        if enabled && recent {
            // Still watching for new photos, which start a run of their own.
            if permitted, !watching {
                PHPhotoLibrary.shared().register(self)
                watching = true
            }
            return
        }
        start()
    }

    /// Starts a run, unless one is going, no backup is on, or files from the
    /// last run are still with iOS - a run then would ask the server about
    /// every photo again while those are on their way, which the iPhone's
    /// first full backup did every few seconds (885 checks in fifteen
    /// minutes). It starts by itself once they are through.
    func start() {
        guard enabled, permitted, run == nil else { return }
        // Waiting for Wi-Fi or the charger, every server: no run until then
        // (one starts by itself when they come, `conditionsChanged`).
        guard destinations.contains(where: { $0.enabled && mayRun($0) }) else {
            if !waitingForConditions { PlayerLog.add("photo backup: waiting for Wi-Fi or the charger") }
            waitingForConditions = true
            if !watching {
                PHPhotoLibrary.shared().register(self)
                watching = true
            }
            return
        }
        waitingForConditions = false
        lastStarted = Date()
        if Uploader.shared.pendingAll.count > 0 || Date() < busyUntil {
            if !startWhenSent { PlayerLog.add("photo backup: waiting for \(Uploader.shared.pendingAll.count) files still with iOS") }
            startWhenSent = true
            if Date() < busyUntil {
                let wait = busyUntil.timeIntervalSinceNow
                Task { try? await Task.sleep(for: .seconds(wait + 1)); PhotoBackup.shared.sentSome() }
            }
            return
        }
        startWhenSent = false
        if !watching {
            PHPhotoLibrary.shared().register(self)
            watching = true
        }
        run = Task {
            await Uploader.shared.restored()
            // Each server's backup in turn, the ones waiting for Wi-Fi or the
            // charger left for later.
            for d in destinations where d.enabled {
                guard !Task.isCancelled else { break }
                guard mayRun(d) else {
                    waitingForConditions = true
                    continue
                }
                update(d.key) { $0.lastWholeRun = nil }
                runningKey = d.key
                await backUp(d.key)
                runningKey = nil
            }
            run = nil
            schedule()
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    private func runInBackground(_ task: BGTask) {
        task.expirationHandler = {
            Task { @MainActor in PhotoBackup.shared.run?.cancel() }
        }
        start()
        Task {
            await run?.value
            // Asked for again whether or not a run went: one that did not
            // (waiting for Wi-Fi, files still with iOS, run minutes ago) left
            // no next one asked for, and background runs stopped for good.
            schedule()
            task.setTaskCompleted(success: true)
        }
    }

    /// Asks iOS for the next background run: soon while there is more to
    /// send, in a few hours otherwise, for photos taken meanwhile.
    private func schedule() {
        let on = destinations.filter(\.enabled)
        guard !on.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.requiresNetworkConnectivity = true
        // Power only when every server's backup waits for it.
        request.requiresExternalPower = on.allSatisfy(\.charging)
        let more = on.contains { $0.done < $0.total }
        request.earliestBeginDate = Date(timeIntervalSinceNow: more ? 15 * 60 : 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// When a run last began, and whether one is waiting for Wi-Fi or the
    /// charger.
    private var lastStarted: Date?
    private var waitingForConditions = false

    private func wifiChanged(_ wifi: Bool) {
        let was = onWiFi
        onWiFi = wifi
        if wifi != was { conditionsChanged() }
    }

    private func conditionsChanged() {
        if waitingForConditions, destinations.contains(where: { $0.enabled && mayRun($0) }) { start() }
    }

    /// Whether a server's files may go now: Wi-Fi and charging, if asked for.
    private func mayRun(_ d: Destination) -> Bool {
        if d.wifiOnly && !onWiFi { return false }
        if d.charging && ![.charging, .full].contains(UIDevice.current.batteryState) { return false }
        return true
    }

    // MARK: Sending

    struct Refused: Error { let code: Int; let message: String }

    /// One file to send: a photo, a video, or a Live Photo's moving part -
    /// which is kept track of apart from its still (`<id>#live`), so a phone
    /// whose stills went up before clips were sent still sends the clips.
    nonisolated private struct Item: @unchecked Sendable {
        let key: String
        let assetID: String
        let resource: PHAssetResource
        let name: String
        let taken: Int64
        let video: Bool
        /// As Photos records it (`size(of:)`), worked out with the rest.
        let size: Int64
        /// When the photo last changed (`stamp(of:)`): an edit is checked again.
        let stamp: String
    }

    /// When a photo last changed, as kept with the photos the server has
    /// confirmed: an edit changes it, so an edited photo is checked again.
    nonisolated private static func stamp(of asset: PHAsset) -> String {
        String(Int64(((asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0) * 1000))
    }

    /// Something of Photos' handed between threads; only read.
    nonisolated private struct Handed<T>: @unchecked Sendable { let value: T }

    nonisolated private static func isLive(_ asset: PHAsset) -> Bool { asset.mediaSubtypes.contains(.photoLive) }
    nonisolated private static func liveKey(_ asset: PHAsset) -> String { asset.localIdentifier + "#live" }

    /// Files waiting with iOS at once, at most: enough to go on for hours
    /// with the phone locked, not so many that their copies fill the phone.
    static let maxQueued = 200
    static let maxQueuedBytes: Int64 = 1 << 30

    /// Stops handing iOS more in this run: a refusal that will not mend by
    /// itself (signed out, no Pictures, no room).
    private var halted = false
    /// What is on the server, as far as this run has learnt.
    private var known: Set<String> = []

    /// One server's backup: its photos checked with it, and what it lacks
    /// handed to iOS.
    private func backUp(_ key: String) async {
        guard let dest = destination(key) else { return }
        let began = Date()
        PlayerLog.add("photo backup: run started for \(dest.name)")
        defer { PlayerLog.add("photo backup: run ended after \(Int(Date().timeIntervalSince(began)))s") }
        let servers = candidates(dest)
        guard var server = servers.first else { return }
        // Only while its own person is the one signed in there: the cookie is
        // theirs, and the server refuses another account's photos.
        var signedIn = await whoIs(server)
        if signedIn == nil, servers.count > 1 { signedIn = await whoIs(servers[1]) }
        guard let who = signedIn else {
            update(key) { $0.problem = "Sign in to \(dest.name) on this iPhone to carry on backing up." }
            return
        }
        guard who.id == dest.account else {
            update(key) { $0.problem = "Backup waits while someone else is signed in to \(dest.name) on this iPhone." }
            return
        }
        let account = [URLQueryItem(name: "account", value: dest.account)]
        // Photos' lookups (the roll, each photo's files and sizes) are run off
        // the main thread: there, a batch of them held up the web view's
        // frames, which pass through it - the looks skipped for as long as a
        // run went on after opening the app (the owner's report, 2026-10-06).
        let videos = dest.videos
        let roll = await Task.detached(priority: .utility) { Handed(value: Self.cameraRoll(videos: videos)) }.value.value
        known = []
        var sent = known
        // Only what is new, while the server's marker of the photo folder
        // holds (see "Checking only what is new"); every photo when it moved,
        // daily, or with no marker at all.
        let confirmed = confirmedList(key)
        var markerNow: String?
        for candidate in servers {
            markerNow = await marker(candidate, account)
            if markerNow != nil { server = candidate; break }
        }
        let full = confirmed.isEmpty || fullDue(dest, markerNow)
        if full { update(key) { $0.fullPending = true } }
        let stamps = full ? [:] : await Task.detached(priority: .utility) {
            Dictionary(roll.map { ($0.localIdentifier, (Self.stamp(of: $0), Self.isLive($0))) }, uniquingKeysWith: { a, _ in a })
        }.value
        // A Live Photo counts as one, still and clip together.
        let waiting = full ? roll : roll.filter { asset in
            guard let (stamp, live) = stamps[asset.localIdentifier] else { return true }
            return confirmed[asset.localIdentifier] != stamp || (live && confirmed[asset.localIdentifier + "#live"] != stamp)
        }
        PlayerLog.add("photo backup: \(full ? "checking every photo" : "checking \(waiting.count) new or changed") of \(roll.count)")
        update(key) {
            $0.done = roll.count - waiting.count
            $0.total = roll.count
            $0.problem = ""
        }
        halted = false
        var whole = false
        defer { closeRun(key, server, account, completed: !halted && !Task.isCancelled && whole, full: full, roll: roll) }
        do {
            var start = 0
            while start < waiting.count {
                let assets = Array(waiting[start..<min(start + 60, waiting.count)])
                start += 60
                // Nothing to send of something with no file at all (a photo
                // shared to the phone but never downloaded): done, or it
                // would count as waiting for ever.
                var batch: [Item] = []
                let handed = Handed(value: assets)
                let found = await Task.detached(priority: .utility) { handed.value.map { Self.items($0) } }.value
                let pendingHere = Uploader.shared.pending(key).keys
                for (asset, units) in zip(assets, found) {
                    if units.isEmpty {
                        sent.insert(asset.localIdentifier)
                        confirm(key, [(asset.localIdentifier, stamps[asset.localIdentifier]?.0 ?? Self.stamp(of: asset))])
                        bumpDone(key)
                    }
                    batch += units.filter { !sent.contains($0.key) && !pendingHere.contains($0.key) }
                }
                guard !batch.isEmpty else { continue }
                guard !Task.isCancelled, let now = destination(key), now.enabled, mayRun(now), !halted else { return }
                // The first address that answers, for the rest of this run.
                var have: [Bool]?
                var lastError: Error = URLError(.cannotConnectToHost)
                for candidate in servers.drop(while: { $0 != server }) {
                    do {
                        have = try await check(candidate, batch, account)
                        server = candidate
                        break
                    } catch let e as Refused {
                        throw e
                    } catch {
                        lastError = error
                    }
                }
                guard let have else { throw lastError }
                for (item, had) in zip(batch, have) where had {
                    sent.insert(item.key)
                    if isLast(item, sent: sent) { bumpDone(key) }
                }
                confirm(key, zip(batch, have).filter { $0.1 }.map { ($0.0.key, $0.0.stamp) })
                for (item, had) in zip(batch, have) where !had {
                    // Room with iOS first: topped up as files arrive.
                    while Uploader.shared.pendingAll.count >= Self.maxQueued || Uploader.shared.pendingAll.bytes >= Self.maxQueuedBytes {
                        try await Task.sleep(for: .seconds(3))
                    }
                    guard !Task.isCancelled, let now = destination(key), now.enabled, mayRun(now), !halted else { return }
                    let queued = Uploader.shared.pending(key).keys
                    let pendingOthers = batch.filter { $0.assetID == item.assetID && $0.key != item.key && !sent.contains($0.key) }
                    do {
                        try await enqueue(item, to: server, dest: now, account: account,
                                          last: pendingOthers.allSatisfy { queued.contains($0.key) })
                    } catch let e as ExportFailed {
                        // One photo the library would not hand over (iCloud
                        // refusing it, a file gone): named and passed over -
                        // as "could not reach the server" it stopped the run
                        // and stayed on screen after later runs went through.
                        update(key) { $0.problem = "Couldn't read \(item.name) from your photos (\(e.reason)). The rest carry on." }
                    }
                }
            }
            if !halted {
                whole = true
                update(key) { $0.lastWholeRun = Date() }
            }
        } catch let e as Refused {
            stopFor(key, e)
        } catch is CancellationError {
            // Put away or switched off; what is with iOS goes on, and the next
            // run carries on from there.
        } catch {
            if !Task.isCancelled { update(key) { $0.problem = Self.unreachable } }
        }
    }

    /// Whether this file completes its photo (a Live Photo's still and clip
    /// both there).
    private func isLast(_ item: Item, sent: Set<String>) -> Bool {
        sent.contains(item.assetID) && (sent.contains(item.assetID + "#live") || !item.key.hasSuffix("#live") && !hasClip(item.assetID))
    }

    private func hasClip(_ id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject.map(Self.isLive) ?? false
    }

    private func bumpDone(_ key: String) { update(key) { $0.done += 1 } }

    /// Said plainly in Settings. A full photo space or disk, or a sign-in
    /// that has ended, will not mend itself in a minute: nothing more is
    /// handed to iOS this run.
    private func stopFor(_ key: String, _ e: Refused) {
        halted = true
        let problem = switch e.code {
            case 401: "Sign in to EmberStorm again to carry on backing up."
            case 403: e.message.isEmpty ? "This account does not have Pictures." : e.message
            case 507: e.message.isEmpty ? "There is no room left for photos." : e.message
            default: e.message.isEmpty ? "The server refused a photo." : e.message
        }
        update(key) { $0.problem = problem }
    }

    /// Which server an upload is for: its own, else (handed to iOS before
    /// servers had backups of their own) the one backup there was.
    private func destKey(_ meta: Uploader.Meta) -> String? {
        meta.dest ?? destinations.first?.key
    }

    /// A file iOS says arrived (or the server had already): counted, even
    /// when this is a relaunch after the app was ended.
    func uploaded(_ meta: Uploader.Meta) {
        defer { sentSome() }
        guard let key = destKey(meta) else { return }
        if let stamp = meta.stamp { confirm(key, [(meta.key, stamp)]) }
        if meta.last { bumpDone(key) }
        // A file through: a network problem said earlier is over.
        update(key) { if $0.problem == Self.unreachable { $0.problem = "" } }
    }

    static let unreachable = "Could not reach the server; it will try again."

    /// One of the files with iOS is through: the run that waited for them
    /// starts once all are.
    func sentSome() {
        saveMarkerIfSent()
        if startWhenSent, Uploader.shared.pendingAll.count == 0, Date() >= busyUntil { start() }
    }

    /// A file the server refused. Signed out, no Pictures or no room stop the
    /// run; anything else is that one file, named and passed over - one bad
    /// file used to stop backup for good (as Android 0.18 found).
    func refused(_ meta: Uploader.Meta, code: Int, message: String) {
        defer { sentSome() }
        guard let key = destKey(meta) else { return }
        // The server busy: not this photo's fault. Nothing more is handed to
        // iOS for a minute, and the next run sends it again (it was counted
        // as passed over, and 898 were, in the first full backup).
        if code == 429 || code == 503 {
            halted = true
            busyUntil = Date().addingTimeInterval(60)
            startWhenSent = true
            return
        }
        if [401, 403, 507].contains(code) {
            stopFor(key, Refused(code: code, message: message))
        } else if code >= 500 || code == 408 {
            // The server's trouble, not this photo's: sent again next run.
            update(key) { $0.problem = Self.unreachable }
        } else {
            // Passed over, and not asked about again until it changes.
            if let stamp = meta.stamp { confirm(key, [(meta.key, stamp)]) }
            update(key) { $0.problem = "Couldn't back up \(meta.name)\(message.isEmpty ? "" : ": " + message). The rest carry on." }
        }
    }

    /// The addresses to try, best first: the page's secure one, its away
    /// twin (a home name does not answer away from home).
    private func candidates(_ d: Destination) -> [URL] {
        var out: [URL] = []
        if let s = d.server, let u = URL(string: s) {
            out.append(u)
            if ServerAddress.installName(u.host() ?? "")?.level == "home", let twin = ServerAddress.twin(u, level: "net") {
                out.append(twin)
            }
        }
        // Only the server backup was turned on for, and its twin, over https
        // (the thirteenth pass): the address typed or saved could be plain
        // http, which whatever answers at that address elsewhere could take,
        // or another server altogether.
        return out.filter { $0.scheme == "https" }
    }

    /// Every photo, and video if asked for, newest first.
    nonisolated private static func cameraRoll(videos: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = videos
            ? NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var out: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// The files a photo is: the original, its name as the camera gave it -
    /// and for a Live Photo its moving part too, named as the still with .MOV
    /// (IMG_0090.HEIC and IMG_0090.MOV) and taken at the same moment, so it
    /// lands in the same month. The server's photo library joins the two by
    /// the identifier Apple writes inside both files, not by name. The clip
    /// goes even with videos left out: it is part of the photo.
    nonisolated private static func items(_ asset: PHAsset) -> [Item] {
        let resources = PHAssetResource.assetResources(for: asset)
        let video = asset.mediaType == .video
        let wanted: [PHAssetResourceType] = video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        guard let resource = resources.first(where: { wanted.contains($0.type) }) else { return [] }
        let when = asset.creationDate ?? asset.modificationDate ?? Date()
        let taken = Int64(when.timeIntervalSince1970 * 1000)
        let stamp = Self.stamp(of: asset)
        var out = [Item(key: asset.localIdentifier, assetID: asset.localIdentifier, resource: resource,
                        name: resource.originalFilename, taken: taken, video: video, size: size(of: resource), stamp: stamp)]
        if Self.isLive(asset), let clip = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) {
            let base = (resource.originalFilename as NSString).deletingPathExtension
            out.append(Item(key: Self.liveKey(asset), assetID: asset.localIdentifier, resource: clip,
                            name: base + ".MOV", taken: taken, video: true, size: size(of: clip), stamp: stamp))
        }
        return out
    }

    /// A resource's size as Photos records it, without reading the file (so
    /// a photo kept in iCloud is not downloaded to ask). Photos has no public
    /// call for it; the property is looked for first, and 0 if it is not there.
    nonisolated private static func size(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: Selector(("fileSize"))),
              let n = resource.value(forKey: "fileSize") as? NSNumber else { return 0 }
        return max(0, n.int64Value)
    }

    /// Which of these the server already has, by name and when taken.
    private func check(_ server: URL, _ items: [Item], _ account: [URLQueryItem]) async throws -> [Bool] {
        var request = URLRequest(url: address(server, "/api/photos/backup/check", query: account))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await signIn(&request)
        // The file's real size where the phone knows it, so a different
        // picture of the same name and month (the camera's numbering starting
        // over, another device's file) is not taken for the one already
        // there. 0 where it does not: the server then matches name and month.
        let list = items.map { ["name": $0.name, "taken": $0.taken, "size": $0.size] as [String: Any] }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["items": list])
        let (data, response) = try await Self.plain.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Refused(code: code, message: Self.errorText(data)) }
        let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let have = answer?["have"] as? [Bool] ?? []
        return items.indices.map { $0 < have.count ? have[$0] : false }
    }

    /// Hands one photo or video to iOS: the original written to a file of
    /// its own, then that file as the whole request body, in the background
    /// session - not waited for. iOS sends it when it can, the phone locked
    /// or not.
    private func enqueue(_ item: Item, to server: URL, dest: Destination, account: [URLQueryItem], last: Bool) async throws {
        let file = try await export(item.resource)
        var query = account
        query.insert(URLQueryItem(name: "taken", value: String(item.taken)), at: 0)
        query.insert(URLQueryItem(name: "name", value: item.name), at: 0)
        var request = URLRequest(url: address(server, "/api/photos/backup", query: query))
        request.httpMethod = "PUT"
        request.setValue(item.video ? "video/*" : "image/*", forHTTPHeaderField: "Content-Type")
        do {
            try await signIn(&request)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        Uploader.shared.enqueue(request, file: file, size: size, wifiOnly: dest.wifiOnly,
                                meta: Uploader.Meta(key: item.key, list: dest.account, last: last, name: item.name,
                                                    video: item.video, stamp: item.stamp, dest: dest.key))
    }

    /// The original resource to a file of its own, from iCloud if that is
    /// where it is - kept with the app's own files rather than in temporary
    /// ones, which iOS may clear while it still has them to send.
    private func export(_ resource: PHAssetResource) async throws -> URL {
        let ext = (resource.originalFilename as NSString).pathExtension
        let file = Uploader.queueFolder
            .appending(path: "backup-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        } catch {
            try? FileManager.default.removeItem(at: file)
            if Task.isCancelled { throw CancellationError() }
            throw ExportFailed(reason: (error as NSError).localizedDescription)
        }
        return file
    }

    struct ExportFailed: Error { let reason: String }

    /// A path on the server with a query, "+" and ";" encoded, which
    /// URLComponents leaves and Go reads as a space and refuses.
    private func address(_ server: URL, _ path: String, query: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.path = path
        if !query.isEmpty {
            parts.queryItems = query
            parts.percentEncodedQuery = parts.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: ";", with: "%3B")
        }
        return parts.url!
    }

    /// The web view's session cookie, for this server only. The web view
    /// keeps its own cookies, apart from URLSession's, so it is copied over.
    private func signIn(_ request: inout URLRequest) async throws {
        // None for this server: signed out (no cookies at all is "not known
        // yet", thrown by WebCookies as a cancellation, and the run ends quietly).
        guard try await WebCookies.apply(to: &request) else { throw Refused(code: 401, message: "") }
    }

    private static func errorText(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
    }

    /// For the check: no cookies of its own, no redirects (the cookie goes
    /// only to the server it was made for).
    private static let plain: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Checking only what is new
    //
    // A run used to ask the server about every photo on the phone, every time,
    // and look each one up in the photo library first (the owner's asking,
    // 2026-10-09: no more work than needed; Android 0.53 does this). Now the
    // phone keeps the photos each server has confirmed, with their stamp, and
    // that server's marker of the person's photo folder from when the last
    // run's files were through. While the marker is unchanged, only photos not
    // confirmed (new, or edited since) are checked. When it has changed - a
    // photo deleted or lost there, files moved by hand - or a day has passed,
    // or the server has no marker (an older one), every photo is checked, as
    // before; a full check cut short is finished by the next run. The server
    // stays the record: the list only says what need not be asked about while
    // nothing there has changed.

    static let fullEvery: TimeInterval = 24 * 3600

    private static func confirmedFile(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return folder.appending(path: "backup-confirmed-\(safe).txt")
    }

    /// The photos a server has confirmed, by key, with their stamp.
    private func confirmedList(_ key: String) -> [String: String] {
        guard let text = try? String(contentsOf: Self.confirmedFile(key), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            out[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return out
    }

    private func confirm(_ key: String, _ entries: [(key: String, stamp: String)]) {
        guard !entries.isEmpty, destination(key) != nil else { return }
        let file = Self.confirmedFile(key)
        let text = entries.map { "\($0.key)\t\($0.stamp)\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file, options: .atomic)
        }
    }

    private func fullDue(_ d: Destination, _ marker: String?) -> Bool {
        guard let marker else { return true }
        return d.fullPending || d.marker != marker || Date().timeIntervalSince(d.lastFull ?? .distantPast) > Self.fullEvery
    }

    /// The server's marker of this person's photo folder, or nil (an older
    /// server, or no answer).
    private func marker(_ server: URL, _ account: [URLQueryItem]) async -> String? {
        var request = URLRequest(url: address(server, "/api/photos/backup/marker", query: account))
        request.timeoutInterval = 20
        guard (try? await signIn(&request)) != nil,
              let (data, response) = try? await Self.plain.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64 << 10,
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let marker = answer["marker"] as? String, !marker.isEmpty else { return nil }
        return marker
    }

    /// The marker is read once a run's files are through (they change it:
    /// what the run sent is its own doing); until then, where to ask.
    private var markerAfterSent: [String: (server: URL, account: [URLQueryItem])] = [:]

    private func closeRun(_ key: String, _ server: URL, _ account: [URLQueryItem], completed: Bool, full: Bool, roll: [PHAsset]) {
        if completed, full {
            // A full check got through every photo: the list is what is on
            // the phone now, as far as the server confirmed it.
            let ids = Set(roll.map(\.localIdentifier))
            let keep = confirmedList(key).filter { ids.contains($0.key.replacingOccurrences(of: "#live", with: "")) }
            let text = keep.map { "\($0.key)\t\($0.value)\n" }.joined()
            try? Data(text.utf8).write(to: Self.confirmedFile(key), options: .atomic)
            update(key) {
                $0.fullPending = false
                $0.lastFull = Date()
            }
        }
        markerAfterSent[key] = (server, account)
        saveMarkerIfSent()
    }

    private func saveMarkerIfSent() {
        for (key, at) in markerAfterSent where Uploader.shared.pending(key).count == 0 {
            markerAfterSent[key] = nil
            Task {
                if let m = await marker(at.server, at.account) { update(key) { $0.marker = m } }
            }
        }
    }
}

extension PhotoBackup: PHPhotoLibraryChangeObserver {
    /// A photo added while the app is open goes up a little later, once the
    /// camera has finished with it.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            let backup = PhotoBackup.shared
            backup.changed?.cancel()
            backup.changed = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                backup.start()
            }
        }
    }
}

nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The background sessions the files go up in: iOS carries the uploads on
/// with the phone locked and the app suspended or ended, and wakes the app to
/// say how each ended. Two sessions, as a session's network rules are fixed
/// when it is made: one that waits for Wi-Fi (not cellular, a hotspot or Low
/// Data Mode), one that sends on anything.
///
/// What each upload is goes with its task (taskDescription), so a relaunch
/// knows; `pending` is what iOS still has, by file, read back from the
/// sessions at launch so nothing already waiting is handed over again.
nonisolated final class Uploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = Uploader()
    static let identifier = "dev.soundstorm.app.backup"
    static let wifiIdentifier = "dev.soundstorm.app.backup.wifi"

    /// What an upload is: the sent-list key, which list, whether it completes
    /// its photo, and its name for a message.
    struct Meta: Codable, Sendable {
        let key: String
        let list: String
        let last: Bool
        let name: String
        let video: Bool
        /// The photo's stamp, kept with it once confirmed (missing from an
        /// upload handed over before there were stamps).
        var stamp: String?
        /// Which server's backup (PhotoBackup.Destination's key); missing from
        /// one handed over before servers had backups of their own.
        var dest: String? = nil
        var file = ""
        var size: Int64 = 0
    }

    /// The exported copies waiting to go.
    static var queueFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "backup-queue")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let lock = NSLock()
    private var waiting: [String: Meta] = [:] // by server and key: two servers send the same photo
    private var bodies: [Int: Data] = [:]
    private var shown = Date.distantPast
    private var finishedEvents: (@Sendable () -> Void)?
    private var restoring: Task<Void, Never>?
    /// Uploads that finished while the sessions' tasks were being read back.
    private var finished: Set<String> = []
    private var restoreDone = false

    private(set) var anyNetwork: URLSession!
    private(set) var wifiOnly: URLSession!

    /// Files with iOS now, for every server: how many, how many bytes.
    var pendingAll: (count: Int, bytes: Int64) {
        lock.withLock { (waiting.count, waiting.values.reduce(0) { $0 + $1.size }) }
    }

    /// Files with iOS now for one server's backup, and their keys.
    func pending(_ dest: String) -> (count: Int, keys: Set<String>) {
        lock.withLock {
            let mine = waiting.values.filter { ($0.dest ?? dest) == dest }
            return (mine.count, Set(mine.map(\.key)))
        }
    }

    private static func slot(_ meta: Meta) -> String { (meta.dest ?? "") + "|" + meta.key }

    func whenFinished(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { finishedEvents = handler }
    }

    private override init() {
        super.init()
        anyNetwork = Self.session(Self.identifier, wifi: false, delegate: self)
        wifiOnly = Self.session(Self.wifiIdentifier, wifi: true, delegate: self)
        restoring = Task { await self.restore() }
    }

    private static func session(_ id: String, wifi: Bool, delegate: Uploader) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: id)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if wifi {
            config.allowsExpensiveNetworkAccess = false
            config.allowsConstrainedNetworkAccess = false
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// What iOS still has from before (a relaunch), and copies it no longer
    /// has a task for cleared away.
    private func restore() async {
        var keep = Set<String>()
        for session in [anyNetwork!, wifiOnly!] {
            for task in await session.allTasks {
                guard let meta = Self.meta(task), task.state == .running || task.state == .suspended else { continue }
                // One that finished while its list was being read is not taken
                // back as waiting: it would wait for ever, and every run after
                // waited on it ("files still with iOS").
                let added = lock.withLock { () -> Bool in
                    guard !finished.contains(meta.file) else { return false }
                    waiting[Self.slot(meta)] = meta
                    return true
                }
                if added { keep.insert(meta.file) }
            }
        }
        lock.withLock {
            finished.removeAll()
            restoreDone = true
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.queueFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keep.contains(file.path) { try? FileManager.default.removeItem(at: file) }
    }

    func restored() async { await restoring?.value }

    private static func meta(_ task: URLSessionTask) -> Meta? {
        task.taskDescription.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
    }

    func enqueue(_ request: URLRequest, file: URL, size: Int64, wifiOnly onWifi: Bool, meta: Meta) {
        var meta = meta
        meta.file = file.path
        meta.size = size
        let task = (onWifi ? wifiOnly! : anyNetwork!).uploadTask(with: request, fromFile: file)
        task.taskDescription = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
        lock.withLock { waiting[Self.slot(meta)] = meta }
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard now.timeIntervalSince(shown) > 1 else { return false }
            shown = now
            return true
        }
        guard due else { return }
        // How far through the file sending now, for Settings.
        UserDefaults.standard.set(Int(totalBytesSent), forKey: "backup.sendingSent")
        UserDefaults.standard.set(Int(totalBytesExpectedToSend), forKey: "backup.sendingSize")
        UserDefaults.standard.set(Self.meta(task)?.video ?? false, forKey: "backup.sendingVideo")
        UserDefaults.standard.set(Self.meta(task)?.dest, forKey: "backup.sendingDest")
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // the cookie goes only to the server it was made for
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) ?? Data() }
        guard let meta = Self.meta(task) else { return }
        let remaining = lock.withLock { () -> Int in
            waiting.removeValue(forKey: Self.slot(meta))
            if !restoreDone { finished.insert(meta.file) }
            return waiting.count
        }
        try? FileManager.default.removeItem(atPath: meta.file)
        if remaining == 0 {
            UserDefaults.standard.set(0, forKey: "backup.sendingSent")
            UserDefaults.standard.set(0, forKey: "backup.sendingSize")
        }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? ""
        Task { @MainActor in
            if error == nil, (200..<300).contains(code) || code == 409 {
                // 409: the server had it after all, under that name.
                PhotoBackup.shared.uploaded(meta)
            } else if code >= 400 {
                PhotoBackup.shared.refused(meta, code: code, message: message)
            } else {
                // A network failure: not counted, so the next run sends it again.
                PhotoBackup.shared.sentSome()
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { finishedEvents = nil }
            return finishedEvents
        }
        DispatchQueue.main.async { done?() }
    }
}
