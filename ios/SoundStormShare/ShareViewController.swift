import UIKit
import UniformTypeIdentifiers

/// Share > EmberStorm (the Android app's Shared.kt, for the iPhone): what is
/// shared from another app - songs, films, photos, an EPUB, a PDF, a zip - is
/// copied into the folder the app and this extension share, because a share
/// only lends its files while the sheet is open. The app hands them to the
/// page the next time it is opened, which reviews them as Add media does and
/// sends them in the background. A share extension may not open its app, so
/// the sheet says to open EmberStorm.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let button = UIButton(type: .system)

    /// What is taken: the shelves' kinds, and a zip (a photo download).
    private static let kinds: [UTType] = [.audio, .movie, .image, .pdf, .zip, UTType("org.idpf.epub-container") ?? .data]
    /// At most this many files from one share.
    private static let most = 200

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .title3)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Adding to EmberStorm..."
        button.setTitle("Done", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.isHidden = true
        button.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        Task { await take() }
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func take() async {
        guard let inbox = SharedInbox.newShare() else {
            finish("EmberStorm couldn't keep these files.")
            return
        }
        var count = 0
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            guard count < Self.most else { break }
            guard let type = Self.kinds.first(where: { kind in
                provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: kind) == true }
            }) else { continue }
            let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
            if await copy(provider, identifier, into: inbox) { count += 1 }
        }
        guard count > 0 else {
            try? FileManager.default.removeItem(at: inbox)
            finish("Nothing here EmberStorm can keep: it takes music, films, photos, audiobooks, ebooks and PDFs.")
            return
        }
        // Ready: the app takes a share only once this is there.
        FileManager.default.createFile(atPath: inbox.appending(path: SharedInbox.ready).path, contents: Data())
        finish("\(count == 1 ? "1 file is" : "\(count) files are") ready. Open EmberStorm to choose where \(count == 1 ? "it goes" : "they go") and add \(count == 1 ? "it" : "them").")
    }

    /// The file, under its own name where it has one, else one from its type.
    private func copy(_ provider: NSItemProvider, _ identifier: String, into folder: URL) async -> Bool {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { return done.resume(returning: false) }
                var name = SharedInbox.safeName(suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
                if (name as NSString).pathExtension.isEmpty {
                    let ext = url.pathExtension.isEmpty ? (UTType(identifier)?.preferredFilenameExtension ?? "") : url.pathExtension
                    if !ext.isEmpty { name += "." + ext }
                }
                var dest = folder.appending(path: name)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = folder.appending(path: "\((name as NSString).deletingPathExtension) \(n)" +
                                            ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension))
                    n += 1
                }
                // The file is lent only for this call: copied now.
                done.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil)
            }
        }
    }

    private func finish(_ text: String) {
        label.text = text
        button.isHidden = false
    }
}
