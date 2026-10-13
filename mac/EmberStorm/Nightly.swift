import Foundation

/// Updating by itself at night, as the Windows and Linux installs do
/// (2026-10-13): a LaunchAgent of the person's own runs this app with
/// `--nightly-update` once a day at a time chosen once between 2 and 5. It
/// installs only a signed release newer than the one installed (checked as
/// Update checks it, SignedRelease), asks nothing, and install.sh puts the old
/// version back when the new one does not start. On unless turned off in the
/// menu bar's cloud; off is kept as SOUNDSTORM_AUTO_UPDATE=off in .env, as on
/// Linux, so an update does not turn it back on.
enum Nightly {
    static let label = "dev.soundstorm.mac.update"
    static let argument = "--nightly-update"

    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static func isOn(in dir: URL) -> Bool {
        Install.setting("SOUNDSTORM_AUTO_UPDATE", in: dir) != "off"
    }

    /// Turned on or off from the menu.
    static func set(_ on: Bool, in dir: URL) {
        Install.setSetting("SOUNDSTORM_AUTO_UPDATE", on ? "on" : "off", in: dir)
        if on { schedule() } else { unschedule() }
    }

    /// At each opening: the agent made when it should be there (and pointed
    /// at wherever the app is now), taken away when it should not.
    static func keep(in dir: URL?) {
        if let dir, isOn(in: dir) { schedule() } else { unschedule() }
    }

    private static func schedule() {
        guard let program = Bundle.main.executableURL?.path else { return }
        // The time chosen once and kept, so it does not move at every opening.
        var at = UserDefaults.standard.integer(forKey: "nightlyMinute")
        if at < 120 || at >= 300 {
            at = Int.random(in: 120..<300)
            UserDefaults.standard.set(at, forKey: "nightlyMinute")
        }
        let wanted: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program, argument],
            "StartCalendarInterval": ["Hour": at / 60, "Minute": at % 60],
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        if let old = NSDictionary(contentsOf: plist), old.isEqual(to: wanted) { return }
        try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (wanted as NSDictionary).write(to: plist, atomically: true) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    static func unschedule() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// The night's run, with no window: nothing done unless installed, on,
    /// Docker running and the signed release newer than the one installed.
    @MainActor
    static func run() async {
        let log = Installer.privateFolder.appending(path: "update.log")
        try? FileManager.default.createDirectory(at: Installer.privateFolder, withIntermediateDirectories: true)
        func say(_ s: String) {
            let line = "\(Date()) \(s)\n"
            if let h = try? FileHandle(forWritingTo: log) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: log, atomically: true, encoding: .utf8)
            }
        }
        guard let dir = await Install.find() else { return say("not installed: nothing to update") }
        guard isOn(in: dir) else { return say("updating at night is off") }
        // EmberStorm runs only while Docker Desktop does; a Mac where it is
        // not running is not woken into it at night.
        guard await Docker.reachable() else { return say("Docker Desktop is not running: not updated") }
        let release: [String: String]
        do {
            (_, release) = try await Installer.fetchScript()
        } catch let e as Installer.Failed {
            return say(e.message)
        } catch {
            return say("the release could not be fetched: \(error.localizedDescription)")
        }
        let have = Int(Install.setting("SOUNDSTORM_RELEASE_SERIAL", in: dir) ?? "") ?? 0
        guard let serial = Int(release["SOUNDSTORM_RELEASE_SERIAL"] ?? ""), serial > have else {
            return say("up to date")
        }
        say("updating to EmberStorm \(release["SOUNDSTORM_RELEASE_VERSION"] ?? "")")
        do {
            _ = try await Installer().run(dir: dir, arguments: [], keepAwake: false, unattended: true)
            say("updated")
        } catch let e as Installer.Failed {
            say("not updated: \(e.message)")
        } catch {
            say("not updated: \(error.localizedDescription)")
        }
    }
}
