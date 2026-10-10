import Foundation

/// The files shared to EmberStorm from another app (the Share extension),
/// waiting in the folder the app and the extension share until the app hands
/// them to the page. A share is a folder of its own under `inbox`, taken only
/// once `ready` is in it (the extension writes it last); a share handed over
/// moves to `taken`, its files sent and deleted by the app's uploads. Anything
/// left - a share never reviewed, files the review left out - goes after a
/// week, as on Android.
enum SharedInbox {
    static let group = "group.dev.soundstorm.app"
    static let ready = ".ready"
    static let keep: TimeInterval = 7 * 24 * 3600

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "Shared")
    }

    static var inbox: URL? { root?.appending(path: "inbox") }
    static var taken: URL? { root?.appending(path: "taken") }

    /// A folder for one share (the extension's).
    static func newShare() -> URL? {
        guard let inbox else { return nil }
        let folder = inbox.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }

    /// A name as a file in a folder: no separators, no hidden names.
    static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        s = String(s.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Shared file" : s
    }

    /// The shares that are ready, oldest first.
    static func readyShares() -> [URL] {
        guard let inbox else { return [] }
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return folders
            .filter { fm.fileExists(atPath: $0.appending(path: ready).path) }
            .sorted { created($0) < created($1) }
    }

    /// A share's files.
    static func files(in share: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: share, includingPropertiesForKeys: nil,
                                                                 options: .skipsHiddenFiles)) ?? []
        return all.filter { !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Handed to the page: out of the inbox, kept until sent or a week passes.
    static func markTaken(_ share: URL) -> URL? {
        guard let taken else { return nil }
        try? FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        let dest = taken.appending(path: share.lastPathComponent)
        return (try? FileManager.default.moveItem(at: share, to: dest)) != nil ? dest : nil
    }

    /// Shares older than a week, unless a file in one is still waiting to go.
    static func sweep(keeping inUse: Set<String>) {
        let fm = FileManager.default
        for parent in [inbox, taken].compactMap({ $0 }) {
            for folder in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                guard Date().timeIntervalSince(created(folder)) > keep else { continue }
                if files(in: folder).contains(where: { inUse.contains($0.path) }) { continue }
                try? fm.removeItem(at: folder)
            }
        }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
