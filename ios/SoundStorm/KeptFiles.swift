import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Downloads kept by the app in its own folder (the owner's rule, 2026-10-11:
/// a download is never deleted by anything but the person). In the web view
/// they lived in web storage, which WebKit may clear - under storage pressure,
/// over its quota, or after a site goes unused - so the page hands them to the
/// app instead (`soundstormApp.keep`, the contract in CLAUDE.md, "Downloads
/// kept by the apps"): the app fetches each server address into Application
/// Support/Kept, which iOS never clears, kept out of iCloud backups (the
/// owner's choice: films would fill them). The page reads a kept file at
/// `emberstorm-kept://<host:port>/<path>` (KeptScheme), the app's own player
/// plays a kept song from its file, and with the server out of reach the app
/// opens the page's own kept files there.
///
/// Everything is per server ("site", host and port): one server's page never
/// sees another's list.
@MainActor
final class KeptFiles: NSObject {
    static let shared = KeptFiles()
    static let scheme = "emberstorm-kept"
    nonisolated static let identifier = "dev.soundstorm.app.kept"

    /// One kept file: its name in the site's folder, its type, its size, and
    /// a page's own policy (the page itself, kept for opening offline).
    struct Entry: Codable {
        var file: String
        var type: String
        var size: Int64
        var csp: String?
        var at: Double
    }

    /// What one `add` (or the page's own files, `shell`) is waiting for.
    private struct Job {
        var site: String
        var waiting: Set<String>
        var kept: [String] = []
        var failed: [String] = []
        var total: Int
        var bytes: Int64 = 0
        var quiet: Bool // the page's own files: no answers
    }

    /// The answers for the page, for the site they belong to.
    var answer: ((_ site: String, _ answer: [String: Any]) -> Void)?
    /// iOS's call once every background download has been heard about.
    var finishedEvents: (() -> Void)?

    private var meta: [String: [String: Entry]] = [:]
    private var jobs: [String: Job] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: Where things are

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appending(path: "Kept", directoryHint: .isDirectory)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Out of iCloud backups (the owner's choice); never cleared by iOS
            // either, as Application Support is the app's own data.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        return folder
    }

    /// "host:port", lowercased, for an http(s) or kept address.
    nonisolated static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)
        return "\(host):\(port)"
    }

    nonisolated private static func folder(_ site: String) -> URL {
        let safe = site.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return root.appending(path: String(safe), directoryHint: .isDirectory)
    }

    /// What a file is kept under: the address's path and query.
    nonisolated static func key(of url: URL) -> String {
        var key = url.path(percentEncoded: true)
        if key.isEmpty { key = "/" }
        if let q = url.query(percentEncoded: true), !q.isEmpty { key += "?" + q }
        return key
    }

    nonisolated private static func fileName(_ key: String, type: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        // An extension from its type, so the player knows what it holds.
        let ext = UTType(mimeType: type)?.preferredFilenameExtension ?? "bin"
        return hash + "." + ext
    }

    private func entries(_ site: String) -> [String: Entry] {
        if let m = meta[site] { return m }
        let file = Self.folder(site).appending(path: "kept.json")
        let m = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
        meta[site] = m
        return m
    }

    private func save(_ site: String) {
        guard let m = meta[site] else { return }
        let folder = Self.folder(site)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: folder.appending(path: "kept.json"), options: .atomic)
        }
    }

    // MARK: For the page

    /// What the page reads before its own scripts: that the app keeps
    /// downloads, its list as last saved, every address kept, and how to
    /// read one - for this site only.
    func pageScript(for url: URL, server: URL) -> String {
        guard let site = Self.site(of: url) else { return "" }
        let index = (try? String(contentsOf: Self.folder(site).appending(path: "index.json"), encoding: .utf8)) ?? "null"
        let urls = entries(site).keys.sorted()
        let urlsJSON = (try? JSONSerialization.data(withJSONObject: urls)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let serverJSON = (try? JSONSerialization.data(withJSONObject: [server.absoluteString])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        // A stored index that is not JSON lists nothing, as the page's own did.
        let safeIndex = (try? JSONSerialization.jsonObject(with: Data(index.utf8))) != nil ? index : "null"
        return """
        (() => {
          const app = window.soundstormApp = window.soundstormApp || {};
          app.keeps = 1;
          app.keptIndex = \(safeIndex);
          app.keptURLs = \(urlsJSON);
          app.server = \(serverJSON)[0];
          app.keep = (cmd, data) =>
            window.webkit.messageHandlers.soundstorm.postMessage({ type: 'keep', cmd, data: data || {} });
          app.keptURL = (address) => {
            const u = new URL(address, location.href);
            // Always with its port, so the app knows which server it is.
            const port = u.port || (u.protocol === 'http:' ? '80' : '443');
            return '\(Self.scheme)://' + u.hostname + ':' + port + u.pathname + u.search;
          };
        })();
        """
    }

    /// The page's message. `page` is where the page is (its server's address,
    /// or the kept copy of it offline): only that site's files are touched.
    func handle(_ cmd: String, data: [String: Any], page: URL) {
        guard let site = Self.site(of: page) else { return }
        if page.scheme != Self.scheme { remember(origin: page, site: site) }
        // Addresses are the server's own: resolved against where the page
        // came from, and anything on another host refused.
        let origin = page.scheme == Self.scheme ? Self.origin(site) : page
        let addresses = ((data["urls"] as? [Any]) ?? []).compactMap { value -> URL? in
            guard let s = value as? String, let origin, let u = URL(string: s, relativeTo: origin)?.absoluteURL,
                  ["http", "https"].contains(u.scheme ?? ""), Self.site(of: u) == site else { return nil }
            return u
        }
        switch cmd {
        case "add":
            let id = data["id"] as? String ?? UUID().uuidString
            start(id: id, site: site, addresses: addresses, quiet: false, again: false)
        case "shell":
            start(id: "shell:" + site, site: site, addresses: addresses, quiet: true, again: true)
        case "stop":
            stop(id: data["id"] as? String ?? "")
        case "remove":
            remove(site: site, keys: addresses.map(Self.key))
        case "index":
            let folder = Self.folder(site)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "index.json")
            if let index = data["index"], !(index is NSNull),
               let json = try? JSONSerialization.data(withJSONObject: index) {
                try? json.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        case "clear":
            clear(site: site)
        default:
            break
        }
    }

    /// The server's own address (scheme, host, port), remembered from its
    /// page: a kept page offline, and a kept file's reader, need it.
    private func remember(origin page: URL, site: String) {
        guard let scheme = page.scheme, let host = page.host() else { return }
        var origin = "\(scheme)://\(host)"
        if let port = page.port { origin += ":\(port)" }
        let folder = Self.folder(site)
        let file = folder.appending(path: "origin.txt")
        if (try? String(contentsOf: file, encoding: .utf8)) == origin { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? origin.write(to: file, atomically: true, encoding: .utf8)
    }

    nonisolated static func origin(_ site: String) -> URL? {
        (try? String(contentsOf: folder(site).appending(path: "origin.txt"), encoding: .utf8)).flatMap { URL(string: $0 + "/") }
    }

    // MARK: Fetching

    private func start(id: String, site: String, addresses: [URL], quiet: Bool, again: Bool) {
        let have = entries(site)
        var job = Job(site: site, waiting: [], total: addresses.count, quiet: quiet)
        var seen = Set<String>()
        for url in addresses {
            let key = Self.key(of: url)
            guard seen.insert(key).inserted else { job.total -= 1; continue }
            if !again, let e = have[key], FileManager.default.fileExists(atPath: Self.folder(site).appending(path: e.file).path) {
                job.kept.append(key)
                continue
            }
            job.waiting.insert(key)
            Task {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                // The session's cookies: the web view keeps its own apart.
                _ = try? await WebCookies.apply(to: &request)
                let task = session.downloadTask(with: request)
                task.taskDescription = Self.describe(id: id, site: site, key: key)
                task.resume()
            }
        }
        jobs[id] = job
        report(id)
    }

    private func stop(id: String) {
        guard jobs.removeValue(forKey: id) != nil else { return }
        session.getAllTasks { tasks in
            for task in tasks where Self.parse(task.taskDescription)?.id == id { task.cancel() }
        }
    }

    nonisolated private static func describe(id: String, site: String, key: String) -> String {
        (try? JSONSerialization.data(withJSONObject: ["id": id, "site": site, "key": key]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    nonisolated private static func parse(_ text: String?) -> (id: String, site: String, key: String)? {
        guard let data = text?.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = d["id"], let site = d["site"], let key = d["key"] else { return nil }
        return (id, site, key)
    }

    /// A file arrived (already moved into place) or failed.
    private func arrived(id: String, site: String, key: String, entry: Entry?) {
        if let entry {
            var m = entries(site)
            if let old = m[key], old.file != entry.file {
                try? FileManager.default.removeItem(at: Self.folder(site).appending(path: old.file))
            }
            m[key] = entry
            meta[site] = m
            save(site)
        }
        guard var job = jobs[id], job.waiting.remove(key) != nil else { return }
        if let entry {
            job.kept.append(key)
            job.bytes += entry.size
        } else {
            job.failed.append(key)
        }
        jobs[id] = job
        report(id)
    }

    private func report(_ id: String) {
        guard let job = jobs[id] else { return }
        let done = job.kept.count + job.failed.count
        if !job.quiet {
            answer?(job.site, ["cmd": "progress", "id": id, "done": done, "total": job.total, "bytes": job.bytes])
        }
        if job.waiting.isEmpty {
            jobs[id] = nil
            if !job.quiet {
                answer?(job.site, ["cmd": "done", "id": id, "kept": job.kept, "failed": job.failed])
            }
        }
    }

    // MARK: Removing

    private func remove(site: String, keys: [String]) {
        var m = entries(site)
        for key in keys {
            guard let e = m.removeValue(forKey: key) else { continue }
            try? FileManager.default.removeItem(at: Self.folder(site).appending(path: e.file))
        }
        meta[site] = m
        save(site)
    }

    /// Everything for this server: signing out (the page's clearDownloads).
    private func clear(site: String) {
        for (id, job) in jobs where job.site == site { stop(id: id) }
        meta[site] = [:]
        try? FileManager.default.removeItem(at: Self.folder(site))
    }

    // MARK: Reading

    /// The kept file for a server address, if any.
    func file(for url: URL) -> (url: URL, entry: Entry)? {
        guard let site = Self.site(of: url) else { return nil }
        return file(site: site, key: Self.key(of: url))
    }

    func file(site: String, key: String) -> (url: URL, entry: Entry)? {
        guard let e = entries(site)[key] else { return nil }
        let file = Self.folder(site).appending(path: e.file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return (file, e)
    }

    /// Whether the page's own files are kept, for opening offline.
    func hasShell(for server: URL) -> Bool {
        guard let site = Self.site(of: server) else { return false }
        return file(site: site, key: "/") != nil && file(site: site, key: "/static/app.js") != nil
    }

    /// Where the kept page is opened from, offline.
    static func offlineAddress(for server: URL) -> URL? {
        guard let host = server.host(), let site = site(of: server) else { return nil }
        let port = site.split(separator: ":").last.map(String.init) ?? "443"
        return URL(string: "\(scheme)://\(host):\(port)/")
    }

    /// Picked up again at launch: downloads that finished while the app was
    /// closed are moved in by the delegate as the session is made again.
    func resume() { _ = session }
}

extension KeptFiles: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = Self.parse(downloadTask.taskDescription) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        var entry: KeptFiles.Entry?
        // Only a whole, good answer is kept: a refusal's body (signed out, a
        // 404) downloads like any other.
        if let response, response.statusCode == 200 {
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
            let name = Self.fileName(job.key, type: type)
            let folder = Self.folder(job.site)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appending(path: name)
            try? FileManager.default.removeItem(at: dest)
            // Moved now: iOS deletes the download's own copy when this returns.
            if (try? FileManager.default.moveItem(at: location, to: dest)) != nil {
                let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
                entry = KeptFiles.Entry(file: name, type: type, size: size,
                                        csp: response.value(forHTTPHeaderField: "Content-Security-Policy"),
                                        at: Date().timeIntervalSince1970)
            }
        }
        let found = entry
        Task { @MainActor in KeptFiles.shared.arrived(id: job.id, site: job.site, key: job.key, entry: found) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A success has been heard about in didFinishDownloadingTo; this is a
        // failure or a cancel.
        guard error != nil, let job = Self.parse(task.taskDescription) else { return }
        Task { @MainActor in KeptFiles.shared.arrived(id: job.id, site: job.site, key: job.key, entry: nil) }
    }

    /// No redirect off the server: the session's cookies would go with it.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let same = request.url.flatMap(Self.site(of:)) == task.originalRequest?.url.flatMap(Self.site(of:))
        completionHandler(same ? request : nil)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            KeptFiles.shared.finishedEvents?()
            KeptFiles.shared.finishedEvents = nil
        }
    }
}

/// emberstorm-kept://<host:port>/<path>: a kept file, for the page - the
/// whole of it, or a byte range (a film's player asks in pieces), with its
/// type, and allowed to the server's own page.
final class KeptScheme: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()
    private let reading = DispatchQueue(label: "kept.read", qos: .userInitiated)

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url, let site = KeptFiles.site(of: url),
              let (file, entry) = KeptFiles.shared.file(site: site, key: KeptFiles.key(of: url)) else {
            let missing = HTTPURLResponse(url: task.request.url ?? URL(string: "about:blank")!, statusCode: 404,
                                          httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(missing)
            task.didFinish()
            return
        }
        let size = entry.size
        // A range asked for (bytes=a-b, bytes=a-); open-ended ones are answered
        // a piece at a time, as a server may.
        var range: ClosedRange<Int64>?
        if let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="), size > 0 {
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let from = Int64(parts[0]) {
                let last = Int64(parts[1]) ?? min(size - 1, from + 8 << 20 - 1)
                if from < size { range = from...min(last, size - 1) }
            }
        }
        var headers = [
            "Content-Type": entry.type,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        // The server's own page reads it (fetch for a blob); the kept page
        // itself, offline, is its own origin.
        if let origin = KeptFiles.origin(site) {
            headers["Access-Control-Allow-Origin"] = String(origin.absoluteString.dropLast())
        }
        if let csp = entry.csp { headers["Content-Security-Policy"] = csp }
        let status: Int
        let span: ClosedRange<Int64>
        if let range {
            status = 206
            span = range
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        } else {
            status = 200
            span = 0...max(0, size - 1)
        }
        headers["Content-Length"] = String(size == 0 ? 0 : span.count)
        let id = ObjectIdentifier(task)
        let answer = headers
        // Answered on the main thread, as WebKit asks; only read elsewhere.
        nonisolated(unsafe) let task = task
        reading.async { [weak self] in
            var data = Data()
            if size > 0, let handle = try? FileHandle(forReadingFrom: file) {
                try? handle.seek(toOffset: UInt64(span.lowerBound))
                data = (try? handle.read(upToCount: span.count)) ?? Data()
                try? handle.close()
            }
            DispatchQueue.main.async {
                guard let self, !self.stopped.contains(id) else { return }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: answer)!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}
