import CryptoKit
import Foundation

/// The signed release of EmberStorm for computers (internal/desktoprelease,
/// as EmberStorm.exe checks it on Windows): desktop.json lists the files the
/// installers run - install.sh, and docker-compose.yml naming EmberStorm's
/// image by its digest - each with its SHA-256, and desktop.json.sig is the
/// release key's signature on it, made on its YubiKey. The app runs nothing
/// that list does not vouch for: a change on GitHub the YubiKey did not sign
/// (a stolen token, the account taken over) reaches no Mac.
enum SignedRelease {
    /// The release keys, as box/release.pub (a Go test keeps them the same):
    /// the release key's YubiKey first, then the backup's.
    nonisolated static let keys: [String] = [
        "Us4q2TEBfE4aRqv8cMYlHAjqpjKNAbKB9GYlGtNqlAM=",
        "uv0pqc/uvWPTSdkPt0PO/YEP2gA86Fy0jUnYyNsm8Xg=",
    ]

    nonisolated struct File: Decodable, Sendable {
        let sha256: String
        let size: Int64
    }

    nonisolated struct Manifest: Decodable, Sendable {
        let kind: String
        let version: String
        let serial: Int64
        let commit: String
        let image: String
        let files: [String: File]
    }

    nonisolated static let needed = ["install.ps1", "install.sh", "docker-compose.yml"]

    /// Where the newest release's files are: GitHub's latest release.
    nonisolated static let base = URL(string: "https://github.com/\(Installer.repo)/releases/latest/download/")!

    nonisolated struct Refused: Error { let reason: String }

    /// Downloads the list, its signature and every file it names, checks them
    /// all, and only then writes them to `dir`, made afresh and private.
    nonisolated static func fetch(from base: URL = base, into dir: URL, keys: [String] = keys) async throws -> Manifest {
        let data = try await get(base.appending(path: "desktop.json"), limit: 1 << 20)
        let sig = try await get(base.appending(path: "desktop.json.sig"), limit: 4 << 10)
        let manifest = try verify(data, signature: sig, keys: keys)
        var files: [String: Data] = [:]
        for (name, file) in manifest.files {
            let body = try await get(base.appending(path: name), limit: file.size)
            let sum = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            guard Int64(body.count) == file.size, sum == file.sha256 else {
                throw Refused(reason: "\(name) is not the file the release signed")
            }
            files[name] = body
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, body) in files {
            let path = dir.appending(path: name)
            try body.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: name.hasSuffix(".sh") ? 0o700 : 0o600], ofItemAtPath: path.path)
        }
        return manifest
    }

    /// The list, if the signature is a release key's on these very bytes and
    /// it is a whole desktop release - the checks of desktoprelease.Verify.
    nonisolated static func verify(_ data: Data, signature: Data, keys: [String]) throws -> Manifest {
        guard let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64 else {
            throw Refused(reason: "the release's signature cannot be read")
        }
        let signed = keys.contains { key in
            guard let k = Data(base64Encoded: key), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: k) else { return false }
            return pub.isValidSignature(raw, for: data)
        }
        guard signed else { throw Refused(reason: "the release is not signed by EmberStorm's release key") }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw Refused(reason: "the release's list cannot be read")
        }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        guard m.kind == "emberstorm-desktop" else { throw Refused(reason: "the signed list is not a desktop release") }
        guard matches(m.version, "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"), m.serial > 0 else { throw Refused(reason: "the release has no version") }
        guard matches(m.commit, "^[0-9a-f]{40}$"), matches(m.image, "^ghcr\\.io/gabrielhollberg/soundstorm@sha256:[0-9a-f]{64}$") else {
            throw Refused(reason: "the release does not name its commit and image")
        }
        guard m.files.count <= 16 else { throw Refused(reason: "the release lists too many files") }
        for (name, f) in m.files {
            guard matches(name, "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"), !name.contains("..") else {
                throw Refused(reason: "the release names a file it may not: \(name)")
            }
            guard matches(f.sha256, "^[0-9a-f]{64}$"), f.size > 0, f.size <= 64 << 20 else {
                throw Refused(reason: "the release's entry for \(name) is not whole")
            }
        }
        for name in needed where m.files[name] == nil { throw Refused(reason: "the release has no \(name)") }
        return m
    }

    /// One address, at most `limit` bytes, a 200 only.
    nonisolated private static func get(_ url: URL, limit: Int64) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Refused(reason: "\(url.lastPathComponent) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard Int64(data.count) <= limit else { throw Refused(reason: "\(url.lastPathComponent) is larger than the release says") }
        return data
    }
}
