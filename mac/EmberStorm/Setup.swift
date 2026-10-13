import AppKit
import Foundation

/// What the window shows, and the work behind each page. Not installed: a
/// welcome, the questions (all of them, before anything is done - as the
/// Windows setup asks them, so nobody comes back to a question), then the
/// setup going and its finish. Installed: EmberStorm started and opened, the
/// Windows desktop icon's job, with Update and Uninstall at hand.
@MainActor
@Observable
final class Setup {
    enum Page {
        case looking, welcome, questions, working, finished(Installer.Result)
        case launching, running, removing, removed(String), failed(String, Retry)
    }
    enum Retry { case setup, launch, uninstall }

    var page: Page = .looking
    let installer = Installer()
    var launchStatus = "Starting EmberStorm..."

    /// Where it is installed, or will be.
    private(set) var dir = Install.defaultFolder
    private(set) var installed = false
    /// Updating by itself at night (Nightly), shown in the menu bar's cloud.
    private(set) var autoUpdate = true
    /// The answers.
    var library: URL?
    var keepAwake = true
    /// The Mac's password, asked on the questions page and checked there,
    /// so nothing waits on it later.
    var password = ""
    private(set) var passwordWrong = false
    private(set) var checking = false
    /// Whether anything needs it: installing Docker, or the power settings.
    var needsPassword: Bool { dockerNeeded || (askAwake && keepAwake) }
    private(set) var askAwake = false
    private(set) var laptop = false
    /// Updating rather than installing: nothing is asked.
    private var updating = false

    var libraryShown: URL { library ?? dir.appending(path: "library") }
    var dockerNeeded: Bool { !Docker.installed }
    /// About 30GB for EmberStorm's programs (19GB of images, room to unpack), and Docker Desktop itself.
    var roomNeeded: Int64 { (dockerNeeded ? 35 : 30) << 30 }
    var roomFree: Int64 { ThisMac.freeSpace(at: FileManager.default.homeDirectoryForCurrentUser) }
    var roomShort: Bool { roomFree < roomNeeded }

    private var started = false

    func appeared() async {
        // The window can be shown again (the menu bar's Update, a failure):
        // what happens at opening happens once.
        guard !started else { return }
        started = true
        #if DEBUG
        // -page questions|working|finished|run: straight to a page, to look at it.
        switch UserDefaults.standard.string(forKey: "page") {
        case "questions": askAwake = true; page = .questions; return
        case "working": page = .working; return
        case "closeAndShow":  // the window closed by its red button, then put back
            page = .running
            installed = true
            Task {
                try? await Task.sleep(for: .seconds(1)); Self.window?.performClose(nil)
                try? await Task.sleep(for: .seconds(1)); print("after close, found:", Self.window != nil, "visible:", Self.window?.isVisible ?? false)
                Self.showWindow(); print("shown:", Self.window?.isVisible ?? false)
            }
            return
        case "run": setUp(); return  // with -script: a pretend setup, to time the window
        case "finished":
            page = .finished(Installer.Result(url: "http://localhost:8099", setup: "/?setup=x", code: "A1B2-C3D4-E5F6-A7B8-C9D0",
                                              secure: "https://k3x9m2p7qa.home.emberstorm.app:8099", library: dir.appending(path: "library").path))
            return
        default: break
        }
        #endif
        if let found = await Install.find() {
            dir = found
            // A setup stopped part way (closed, the Mac switched off during
            // the download) left a folder that looks installed: the questions
            // again, and install.sh carries on there. With no mark, Docker is
            // started first to ask it (an install from before the mark).
            var done = await Install.finished(found)
            if !done, Install.setting("SOUNDSTORM_INSTALLED", in: found) == nil, Docker.installed, !(await Docker.reachable()) {
                page = .launching
                launchStatus = "Starting Docker..."
                if await Docker.start(status: { [weak self] s in self?.launchStatus = s }) {
                    done = await Install.finished(found)
                }
            }
            guard done else {
                askAwake = !(await ThisMac.neverSleeps())
                laptop = await ThisMac.isLaptop
                page = .welcome
                return
            }
            installed = true
            UserDefaults.standard.set(found.path, forKey: "installDir")
            autoUpdate = Nightly.isOn(in: found)
            Nightly.keep(in: found)
            await launch()
        } else {
            askAwake = !(await ThisMac.neverSleeps())
            laptop = await ThisMac.isLaptop
            page = .welcome
        }
    }

    // MARK: Setting up

    /// Set up, from the questions page: the password checked first.
    func start() {
        guard needsPassword else { return setUp() }
        checking = true
        passwordWrong = false
        Task {
            let ok = await Installer.checkPassword(password)
            checking = false
            guard ok else {
                passwordWrong = true
                return
            }
            setUp()
        }
    }

    func setUp() {
        if dockerNeeded { Installer.quietDockerFirstStart() }
        page = .working
        let hiding = hideDockerWhileSettingUp()
        Task {
            defer { hiding.cancel() }
            var args: [String] = []
            if let library, library.standardizedFileURL != dir.appending(path: "library").standardizedFileURL {
                args += ["--library", library.path]
            }
            do {
                let result = try await installer.run(dir: dir, arguments: args, keepAwake: !updating && askAwake && keepAwake,
                                                     password: !updating && needsPassword ? password : nil)
                installed = true
                UserDefaults.standard.set(dir.path, forKey: "installDir")
                autoUpdate = Nightly.isOn(in: dir)
                Nightly.keep(in: dir)
                page = .finished(result)
            } catch let e as Installer.Failed {
                page = .failed(e.message, .setup)
            } catch is Installer.Stopped {
                page = installed ? .running : .questions
            } catch {
                page = .failed(error.localizedDescription, .setup)
            }
            updating = false
        }
    }

    /// Docker Desktop's own window, put away while the setup runs: its first
    /// start opened it over everything (the first real run, 2026-10-10), and
    /// it then sat waiting for somebody - though nothing in it is needed, its
    /// terms accepted when it was installed and its engine running anyway.
    private func hideDockerWhileSettingUp() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                // Its window is a second app, the Electron dashboard
                // (com.electron.dockerdesktop), not com.docker.docker itself:
                // hiding only the first left the window up (the second run).
                for app in NSWorkspace.shared.runningApplications
                where ["com.docker.docker", "com.electron.dockerdesktop"].contains(app.bundleIdentifier ?? "") && !app.isHidden {
                    app.hide()
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func update() {
        updating = true
        setUp()
    }

    func setAutoUpdate(_ on: Bool) {
        Nightly.set(on, in: dir)
        autoUpdate = Nightly.isOn(in: dir)
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Keep media here"
        panel.message = "Choose where EmberStorm keeps your music, films, books and photos - an external drive is fine."
        if panel.runModal() == .OK, let url = panel.url { library = url }
    }

    /// Opens what the setup ended with: its first screen, with the setup code
    /// in the address, marked as this computer.
    func open(_ r: Installer.Result) {
        let base = (r.url.isEmpty ? "http://localhost:\(Install.port(in: dir))" : r.url) + r.setup
        let address = base + (base.contains("?") ? "&" : "?") + "here=server"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    // MARK: Installed

    func launch() async {
        page = .launching
        launchStatus = "Starting EmberStorm..."
        let hiding = hideDockerWhileSettingUp()
        defer { hiding.cancel() }
        do {
            try await Install.launch(dir) { [weak self] s in self?.launchStatus = s }
            page = .running
            // The browser has it now; this window would only cover it. The
            // menu bar's cloud has Open, Update and Uninstall (the owner's
            // choice, 2026-10-10: the window came up over the browser).
            Self.hideWindow()
        } catch let e as Installer.Failed {
            page = .failed(e.message, .launch)
            Self.showWindow()
        } catch {
            page = .failed(error.localizedDescription, .launch)
            Self.showWindow()
        }
    }

    /// Opening the app again, or Open EmberStorm in the menu bar: the
    /// browser, unless the window is busy (setting up, removing), which is
    /// then brought forward.
    func openAgain() {
        switch page {
        case .running, .failed(_, .launch): Task { await launch() }
        default: Self.showWindow()
        }
    }

    // The one window, found among the app's (SwiftUI's Window scene keeps
    // it when closed, so it can be put back).
    private static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    static func showWindow() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func hideWindow() {
        window?.orderOut(nil)
    }

    /// Removing it asks first, one window, each change the setup made as
    /// its own choice (as the Windows uninstall asks): shown only for what
    /// the setup changed (.env's record), Docker Desktop and sleep unticked -
    /// somebody may rely on them by now. install.sh takes the answers as
    /// EMBERSTORM_UNINSTALL_*.
    func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Remove EmberStorm from this Mac?"
        alert.informativeText = "Its accounts, settings and the media servers' data are removed. Your media - music, films, books and photos - stays where it is."
        func box(_ title: String, _ on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = on ? .on : .off
            return b
        }
        let copy = box("Keep a copy of your accounts, in case you install EmberStorm again", true)
        let programs = box("Remove EmberStorm's downloaded programs (about 12 GB)", true)
        var choices = [copy, programs]
        // Docker Desktop only when EmberStorm installed it: one already here
        // was somebody's own.
        let docker = Install.setting("SOUNDSTORM_DOCKER_INSTALLED", in: dir).map { !$0.isEmpty } == true
            ? box("Remove Docker Desktop too (EmberStorm installed it)", false) : nil
        let sleep = Install.setting("SOUNDSTORM_WAS_MAC_SLEEP", in: dir).map { !$0.isEmpty } == true
            ? box("Let this Mac go to sleep on its own again, as before EmberStorm", false) : nil
        choices += [docker, sleep].compactMap { $0 }
        let stack = NSStackView(views: choices)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(choices.count) * 26)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func yes(_ b: NSButton?) -> String { b?.state == .on ? "yes" : "no" }
        let answers = [
            "EMBERSTORM_UNINSTALL_COPY": yes(copy),
            "EMBERSTORM_UNINSTALL_PROGRAMS": yes(programs),
            "EMBERSTORM_UNINSTALL_DOCKER": yes(docker),
            "EMBERSTORM_UNINSTALL_SLEEP": yes(sleep),
            "EMBERSTORM_UNINSTALL_LID": "no",
        ]
        let library = Install.setting("SOUNDSTORM_LIBRARY_PATH", in: dir).map { URL(fileURLWithPath: $0, relativeTo: dir).standardizedFileURL.path }
            ?? dir.appending(path: "library").path
        page = .removing
        Task {
            do {
                _ = try await installer.run(dir: dir, arguments: ["--uninstall"], keepAwake: false, extra: answers)
                installed = false
                UserDefaults.standard.removeObject(forKey: "installDir")
                // What the app kept for itself: the night's update and the
                // checked release.
                Nightly.unschedule()
                try? FileManager.default.removeItem(at: Installer.privateFolder.appending(path: "release"))
                page = .removed(library)
                offerTrash()
            } catch let e as Installer.Failed {
                page = .failed(e.message, .uninstall)
            } catch {
                page = .failed(error.localizedDescription, .uninstall)
            }
        }
    }

    /// Removed: the app itself offered to the Trash, the last thing left.
    private func offerTrash() {
        let alert = NSAlert()
        alert.messageText = "Move the EmberStorm app to the Trash?"
        alert.informativeText = "EmberStorm has been removed. The app is all that is left of it on this Mac."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep the app")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: Installer.privateFolder)
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "dev.soundstorm.mac")
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func retry(_ what: Retry) {
        switch what {
        case .setup: setUp()
        case .launch: Task { await launch() }
        case .uninstall: uninstall()
        }
    }
}
