import Foundation
import AppKit
import CryptoKit
import Observation

// MARK: - Configuration

/// Update settings. The test hooks are honoured only when `ATV_ENABLE_SNAPSHOT=1` (like snapshot mode):
/// `ATV_UPDATE_FEED=<url>` overrides the releases API URL and allows `http://127.0.0.1` for the feed and the assets,
/// `ATV_UPDATE_AUTOINSTALL=1` installs immediately without the sheet.
enum UpdateConfig {
    static let env = ProcessInfo.processInfo.environment
    static let testHooks = env["ATV_ENABLE_SNAPSHOT"] == "1"
    static let feedOverride: URL? = testHooks ? env["ATV_UPDATE_FEED"].flatMap { URL(string: $0) } : nil
    static let feedURL: URL = feedOverride ?? URL(string: "https://api.github.com/repos/Retr0Lovelace/appletv-remote-mac/releases/latest")!
    static let allowLoopback = feedOverride != nil
    static let autoInstall = testHooks && env["ATV_UPDATE_AUTOINSTALL"] == "1"

    /// Ed25519 public key (base64, raw 32 bytes). Info.plist `ATVUpdatePublicKey` wins, this constant is the fallback.
    static let fallbackPublicKey = "nMZjtN03OHaNqXH9OkbKqGejO/R7puGa1+LOCtfcF+c="
    static var publicKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "ATVUpdatePublicKey") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackPublicKey
    }

    static let maxFeedBytes = 1_000_000
    static let maxDownloadBytes: Int64 = 300 * 1024 * 1024
    static let maxSignatureBytes: Int64 = 4096
    static let appName = "Apple TV Remote.app"

    static func log(_ s: String) {
        guard testHooks else { return }
        FileHandle.standardError.write(Data("update: \(s)\n".utf8))
    }
}

// MARK: - Model types

struct ReleaseAsset: Sendable {
    let name: String
    let url: URL
    let size: Int64
}

struct ReleaseInfo: Sendable {
    let version: String
    let notes: String
    let pageURL: URL?
    let assets: [ReleaseAsset]
    func asset(named n: String) -> ReleaseAsset? { assets.first { $0.name == n } }
}

enum UpdateError: Error, Sendable {
    case network(String)
    case badResponse
    case tooLarge
    case sizeMismatch
    case untrustedURL
    case missingAsset
    case badSignature
    case mount
    case wrongApp
    case badCodeSignature
    case io(String)

    var message: String {
        switch self {
        case .network(let m): String(localized: "Network error: \(m)")
        case .badResponse: String(localized: "The update server sent an invalid response.")
        case .tooLarge: String(localized: "The update is too large.")
        case .sizeMismatch: String(localized: "The downloaded update does not match its declared size.")
        case .untrustedURL: String(localized: "The update points to an untrusted address; it was refused.")
        case .missingAsset: String(localized: "The release does not contain the expected update files.")
        case .badSignature: String(localized: "The update's signature is invalid. The download was deleted and nothing was installed.")
        case .mount: String(localized: "Could not open the update image.")
        case .wrongApp: String(localized: "The update does not contain the expected app or version.")
        case .badCodeSignature: String(localized: "The update's code signature is invalid.")
        case .io(let m): String(localized: "Could not prepare the update: \(m)")
        }
    }
}

// MARK: - Pure helpers (no actor isolation)

enum UpdateOps {
    enum Eligibility { case ok, development, readOnly }

    static func eligibility() -> Eligibility {
        let app = Bundle.main.bundleURL
        let python = app.appendingPathComponent("Contents/Resources/python/bin/python3").path
        guard FileManager.default.isExecutableFile(atPath: python) else { return .development }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else { return .readOnly }
        return .ok
    }

    /// https on github.com / api.github.com; redirects may also go to *.githubusercontent.com.
    /// `http://127.0.0.1` is accepted only when `loopback` (test hooks) is on.
    static func allowed(_ url: URL, redirect: Bool, loopback: Bool) -> Bool {
        guard let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if url.scheme == "https", url.port == nil || url.port == 443 {
            if host == "github.com" || host == "api.github.com" { return true }
            if redirect && (host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")) { return true }
        }
        return loopback && url.scheme == "http" && host == "127.0.0.1"
    }

    static func components(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var out: [Int] = []
        for p in parts { guard let n = Int(p), n >= 0 else { return nil }; out.append(n) }
        return out
    }

    /// Numeric semver comparison; false when either version is malformed.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = components(candidate), var b = components(current) else { return false }
        while a.count < b.count { a.append(0) }
        while b.count < a.count { b.append(0) }
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }

    private struct FeedAsset: Decodable { let name: String; let browser_download_url: String; let size: Int64 }
    private struct Feed: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [FeedAsset]?
    }

    /// nil = drafts and prereleases (ignored).
    static func parseRelease(_ data: Data, loopback: Bool) throws -> ReleaseInfo? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { throw UpdateError.badResponse }
        if feed.draft == true || feed.prerelease == true { return nil }
        let version = feed.tag_name.hasPrefix("v") ? String(feed.tag_name.dropFirst()) : feed.tag_name
        guard components(version) != nil else { throw UpdateError.badResponse }
        var notes = (feed.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 4000 { notes = String(notes.prefix(4000)) + "…" }
        let page = feed.html_url.flatMap { URL(string: $0) }.flatMap { allowed($0, redirect: false, loopback: loopback) ? $0 : nil }
        let assets = (feed.assets ?? []).compactMap { a -> ReleaseAsset? in
            guard let u = URL(string: a.browser_download_url) else { return nil }
            return ReleaseAsset(name: a.name, url: u, size: a.size)
        }
        return ReleaseInfo(version: version, notes: notes, pageURL: page, assets: assets)
    }

    static func makePrivateTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppleTVRemote-update-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw UpdateError.io(error.localizedDescription) }
        return dir
    }

    /// Ed25519 verification of the file's bytes against a base64 signature.
    static func verify(file: URL, signatureFile: URL, publicKeyB64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyB64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigText = try? String(contentsOf: signatureFile, encoding: .utf8),
              let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              sig.count == 64,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    static func run(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.io(error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func stagingURL(for app: URL) -> URL { app.deletingLastPathComponent().appendingPathComponent(".Apple TV Remote.update.app") }
    static func oldURL(for app: URL) -> URL { app.deletingLastPathComponent().appendingPathComponent(".Apple TV Remote.old.app") }

    /// Mounts the image, checks the app inside (identity, version, code signature) and copies it next to the
    /// installed app so the final rename is atomic. The image is always detached.
    static func stage(dmg: URL, tmp: URL, version: String, bundleID: String, installed: URL) throws -> URL {
        let fm = FileManager.default
        let mnt = tmp.appendingPathComponent("mnt", isDirectory: true)
        do { try fm.createDirectory(at: mnt, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw UpdateError.io(error.localizedDescription) }
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mnt.path, dmg.path])
        guard attach.status == 0 else { throw UpdateError.mount }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mnt.path, "-force"]) }

        let src = mnt.appendingPathComponent(UpdateConfig.appName)
        if (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != false { throw UpdateError.wrongApp }
        guard let info = NSDictionary(contentsOf: src.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else { throw UpdateError.wrongApp }
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", src.path]).status == 0 else { throw UpdateError.badCodeSignature }

        let staged = stagingURL(for: installed)
        try? fm.removeItem(at: staged)
        guard try run("/usr/bin/ditto", [src.path, staged.path]).status == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError.io("copy failed")
        }
        guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]).status == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError.badCodeSignature
        }
        return staged
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func installerScript(pid: Int32, app: URL, staged: URL, old: URL, tmp: URL) -> String {
        let a = shellQuote(app.path), s = shellQuote(staged.path), o = shellQuote(old.path), t = shellQuote(tmp.path)
        return """
        #!/bin/sh
        PID=\(pid)
        APP=\(a)
        STAGED=\(s)
        OLD=\(o)
        TMP=\(t)
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i + 1))
          if [ "$i" -gt 60 ]; then rm -rf "$STAGED"; rm -rf "$TMP"; exit 1; fi
          sleep 0.5
        done
        rm -rf "$OLD"
        if ! mv "$APP" "$OLD"; then
          rm -rf "$STAGED"; open "$APP"; rm -rf "$TMP"; exit 1
        fi
        if ! mv "$STAGED" "$APP"; then
          mv "$OLD" "$APP"; rm -rf "$STAGED"; open "$APP"; rm -rf "$TMP"; exit 1
        fi
        rm -rf "$OLD"
        /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
        open "$APP"
        rm -rf "$TMP"

        """
    }

    /// Writes the installer into the private temp dir and starts it detached (nohup, background, own stdio).
    static func launchInstaller(tmp: URL, installed: URL, staged: URL) throws {
        let script = tmp.appendingPathComponent("install.sh")
        let text = installerScript(pid: ProcessInfo.processInfo.processIdentifier, app: installed, staged: staged,
                                   old: oldURL(for: installed), tmp: tmp)
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch { throw UpdateError.io(error.localizedDescription) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh \"$0\" >/dev/null 2>&1 </dev/null &", script.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.io(error.localizedDescription) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.io("installer did not start") }
    }

    // MARK: network entry points

    static func fetchLatest(feed: URL, loopback: Bool) async throws -> ReleaseInfo? {
        guard allowed(feed, redirect: false, loopback: loopback) else { throw UpdateError.untrustedURL }
        let data = try await UpdateNet(loopback: loopback).fetch(feed, maxBytes: UpdateConfig.maxFeedBytes)
        return try parseRelease(data, loopback: loopback)
    }

    static func download(_ asset: ReleaseAsset, to dest: URL, maxBytes: Int64, loopback: Bool,
                         progress: (@Sendable (Double) -> Void)?) async throws {
        guard allowed(asset.url, redirect: false, loopback: loopback) else { throw UpdateError.untrustedURL }
        guard asset.size > 0, asset.size <= maxBytes else { throw UpdateError.tooLarge }
        try await UpdateNet(loopback: loopback).download(asset.url, to: dest, maxBytes: maxBytes, declared: asset.size, progress: progress)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
        guard size == asset.size else { try? FileManager.default.removeItem(at: dest); throw UpdateError.sizeMismatch }
    }
}

/// Built outside any actor so the closure is not tied to the main actor.
nonisolated func makeProgressSink(_ u: Updater) -> @Sendable (Double) -> Void {
    { [weak u] p in Task { @MainActor in u?.progress = p } }
}

// MARK: - Networking

/// One-shot URLSession delegate: refuses redirects to untrusted hosts, enforces size caps while downloading.
final class UpdateNet: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let loopback: Bool
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: UpdateError?
    private var blocked = false
    private var finished = false
    private var dest: URL?
    private var maxBytes: Int64 = 0
    private var declared: Int64 = 1
    private var onProgress: (@Sendable (Double) -> Void)?

    init(loopback: Bool) { self.loopback = loopback }

    private func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = resourceTimeout
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("AppleTVRemote/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (macOS updater)",
                   forHTTPHeaderField: "User-Agent")
        return r
    }

    func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let session = makeSession(resourceTimeout: 15)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: request(url, accept: "application/vnd.github+json"))
            guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
            guard http.statusCode == 200 else {
                throw lock.withLock { blocked } ? UpdateError.untrustedURL : UpdateError.network("HTTP \(http.statusCode)")
            }
            if http.expectedContentLength > Int64(maxBytes) { throw UpdateError.tooLarge }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes { throw UpdateError.tooLarge }
            }
            return data
        } catch let e as UpdateError { throw e }
        catch { throw UpdateError.network(error.localizedDescription) }
    }

    func download(_ url: URL, to dest: URL, maxBytes: Int64, declared: Int64, progress: (@Sendable (Double) -> Void)?) async throws {
        let session = makeSession(resourceTimeout: 1800)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock {
                continuation = cont
                self.dest = dest
                self.maxBytes = maxBytes
                self.declared = max(declared, 1)
                onProgress = progress
            }
            session.downloadTask(with: request(url, accept: "application/octet-stream")).resume()
        }
    }

    // Redirects: only to trusted hosts.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let u = request.url, UpdateOps.allowed(u, redirect: true, loopback: loopback) {
            completionHandler(request)
        } else {
            lock.withLock { blocked = true }
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let (cb, total, over) = lock.withLock { () -> ((@Sendable (Double) -> Void)?, Int64, Bool) in
            let over = totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes
            if over { failure = .tooLarge }
            return (onProgress, declared, over)
        }
        if over { downloadTask.cancel(); return }
        cb?(min(Double(totalBytesWritten) / Double(total), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.withLock {
            guard failure == nil, let dest else { return }
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
                failure = blocked ? .untrustedURL : .badResponse
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                finished = true
            } catch { failure = .io(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cont, fail, ok) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, UpdateError?, Bool) in
            let c = continuation
            continuation = nil
            return (c, failure, finished)
        }
        guard let cont else { return }
        if let fail { cont.resume(throwing: fail) }
        else if let error { cont.resume(throwing: UpdateError.network(error.localizedDescription)) }
        else if ok { cont.resume() }
        else { cont.resume(throwing: UpdateError.badResponse) }
    }
}

// MARK: - Updater

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable { case idle, checking, downloading, verifying, installing }

    var phase: Phase = .idle
    var release: ReleaseInfo?
    var showSheet = false
    var progress: Double = 0
    var errorText = ""
    var autoCheck: Bool = (UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }
    var busy: Bool { phase != .idle }

    @ObservationIgnored private var scheduled = false

    private static let lastCheckKey = "updateLastCheck"
    private static let skippedKey = "updateSkippedVersion"
    private var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var currentVersionText: String { currentVersion }

    // MARK: scheduling

    /// Automatic checks: 10 s after launch, then every 24 h while running (last-check date in UserDefaults).
    func startScheduling() {
        guard !scheduled else { return }
        scheduled = true
        guard UpdateOps.eligibility() == .ok || UpdateConfig.feedOverride != nil else { return }
        let testRun = UpdateConfig.feedOverride != nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(testRun ? 3 : 10))
            while !Task.isCancelled {
                if testRun || (autoCheck && isDue) { await check(manual: false) }
                if testRun { return }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var isDue: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= 24 * 3600
    }

    // MARK: user actions

    func checkNow() {
        NSApp.activate()
        for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        Task { @MainActor in await check(manual: true) }
    }

    func later() { showSheet = false }

    func skipVersion() {
        if let v = release?.version { UserDefaults.standard.set(v, forKey: Self.skippedKey) }
        showSheet = false
    }

    private func notify(_ message: String) {
        UpdateConfig.log(message)
        ATVController.current?.flashNote(message)
    }

    // MARK: check

    func check(manual: Bool) async {
        guard phase == .idle else { return }
        if UpdateConfig.feedOverride == nil {
            switch UpdateOps.eligibility() {
            case .development:
                if manual { notify(String(localized: "Updates are disabled in development builds.")) }
                return
            case .readOnly:
                if manual { notify(String(localized: "Move Apple TV Remote to your Applications folder to enable updates.")) }
                return
            case .ok: break
            }
        }
        phase = .checking
        UpdateConfig.log("checking \(UpdateConfig.feedURL.absoluteString)")
        do {
            let info = try await UpdateOps.fetchLatest(feed: UpdateConfig.feedURL, loopback: UpdateConfig.allowLoopback)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            phase = .idle
            guard let info, UpdateOps.isNewer(info.version, than: currentVersion) else {
                UpdateConfig.log("up to date")
                if manual { notify(String(localized: "You're up to date")) }
                return
            }
            release = info
            UpdateConfig.log("found \(info.version) (current \(currentVersion))")
            if UpdateConfig.autoInstall { await install(); return }
            if !manual && UserDefaults.standard.string(forKey: Self.skippedKey) == info.version { return }
            errorText = ""
            showSheet = true
        } catch {
            phase = .idle
            let m = (error as? UpdateError)?.message ?? error.localizedDescription
            if manual { notify(String(localized: "Could not check for updates: \(m)")) } else { UpdateConfig.log("check failed: \(m)") }
        }
    }

    // MARK: install

    func install() async {
        guard let rel = release, phase == .idle else { return }
        let loopback = UpdateConfig.allowLoopback
        let key = UpdateConfig.publicKey
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
        errorText = ""
        progress = 0
        guard UpdateOps.eligibility() == .ok,
              let dmgAsset = rel.asset(named: "AppleTVRemote-\(rel.version)-macOS-arm64.dmg"),
              let sigAsset = rel.asset(named: "AppleTVRemote-\(rel.version)-macOS-arm64.dmg.sig") else {
            fail(UpdateError.missingAsset, tmp: nil)
            return
        }
        var tmp: URL?
        do {
            let dir = try UpdateOps.makePrivateTempDir()
            tmp = dir
            let dmg = dir.appendingPathComponent("update.dmg")
            let sig = dir.appendingPathComponent("update.dmg.sig")

            phase = .downloading
            UpdateConfig.log("downloading \(dmgAsset.name) (\(dmgAsset.size) bytes)")
            let sink = makeProgressSink(self)
            try await UpdateOps.download(dmgAsset, to: dmg, maxBytes: UpdateConfig.maxDownloadBytes, loopback: loopback, progress: sink)
            try await UpdateOps.download(sigAsset, to: sig, maxBytes: UpdateConfig.maxSignatureBytes, loopback: loopback, progress: nil)

            phase = .verifying
            let ok = await Task.detached { UpdateOps.verify(file: dmg, signatureFile: sig, publicKeyB64: key) }.value
            guard ok else {
                try? FileManager.default.removeItem(at: dmg)
                UpdateConfig.log("signature verification FAILED; download deleted")
                throw UpdateError.badSignature
            }
            UpdateConfig.log("signature verified")

            phase = .installing
            let version = rel.version
            let staged = try await Task.detached {
                try UpdateOps.stage(dmg: dmg, tmp: dir, version: version, bundleID: bundleID, installed: installed)
            }.value
            try UpdateOps.launchInstaller(tmp: dir, installed: installed, staged: staged)
            UpdateConfig.log("installer launched; quitting (pid \(ProcessInfo.processInfo.processIdentifier))")
            AppDelegate.dismissSheets()
            NSApp.terminate(nil)
        } catch {
            fail((error as? UpdateError) ?? UpdateError.io(error.localizedDescription), tmp: tmp)
        }
    }

    private func fail(_ error: UpdateError, tmp: URL?) {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        phase = .idle
        errorText = error.message
        let m = String(localized: "Update failed: \(error.message)")
        if !showSheet || UpdateConfig.autoInstall { notify(m) } else { UpdateConfig.log(m) }
    }
}
