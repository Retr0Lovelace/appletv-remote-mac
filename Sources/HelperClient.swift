import Foundation

/// Sendable JSON value, used to pass helper responses between actors without `Any`.
enum JSON: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
           ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JSON])
    case obj([String: JSON])

    init(stringLiteral v: String) { self = .str(v) }
    init(integerLiteral v: Int) { self = .num(Double(v)) }
    init(floatLiteral v: Double) { self = .num(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .obj(Dictionary(uniqueKeysWithValues: elements))
    }

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .num(n.doubleValue) }
        case let s as String: self = .str(s)
        case let a as [Any]: self = .arr(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .obj(d.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .num(let n): n
        case .str(let s): s
        case .arr(let a): a.map { $0.any }
        case .obj(let o): o.mapValues { $0.any }
        }
    }

    subscript(key: String) -> JSON { if case .obj(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .str(let s) = self { return s }; return nil }
    var double: Double? { if case .num(let n) = self { return n }; return nil }
    /// Exact integer only: nil for non-integral, NaN or out-of-range values.
    var int: Int? { double.flatMap { Int(exactly: $0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON] { if case .arr(let a) = self { return a }; return [] }
}

struct HelperError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Python process (JSON lines): requests/responses plus events.
@MainActor
final class HelperClient {
    var onEvent: ((String, JSON) -> Void)?
    var onRestart: (() -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var nextID = 1
    private var stopping = false
    private var restartCount = 0
    private let reader = LineReader()

    /// Where to run the helper: Python embedded in the app if present, otherwise the development environment (.venv).
    struct Location {
        let python: URL
        let script: URL
        let workDir: URL
        let bundled: Bool
    }

    /// Dev fallback only: the interpreter must be owned by the current user and not writable by group or others.
    static func isTrustedPython(_ url: URL) -> Bool {
        var link = stat(), target = stat()
        guard lstat(url.path, &link) == 0, stat(url.path, &target) == 0 else { return false }
        let uid = getuid()
        let writable = mode_t(S_IWGRP | S_IWOTH)
        return link.st_uid == uid && target.st_uid == uid && target.st_mode & writable == 0
    }

    static func projectRoot() -> URL {
        let fm = FileManager.default
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("AppleTVRemote")
        let bundle = Bundle.main.bundleURL
        let candidate = bundle.deletingLastPathComponent().deletingLastPathComponent()
        for root in [candidate, fallback] {
            let py = root.appendingPathComponent(".venv/bin/python")
            if fm.isExecutableFile(atPath: py.path), isTrustedPython(py) { return root }
        }
        return fallback
    }

    /// Kept under the original name so existing credentials and permissions carry over.
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Télécommande Apple TV")
    }

    static func locate() -> Location {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let py = res.appendingPathComponent("python/bin/python3")
            let script = res.appendingPathComponent("helper/atv_helper.py")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return Location(python: py, script: script, workDir: supportDir, bundled: true)
            }
        }
        let root = projectRoot()
        return Location(python: root.appendingPathComponent(".venv/bin/python"),
                        script: root.appendingPathComponent("helper/atv_helper.py"),
                        workDir: root, bundled: false)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Credentials file shared by all versions of the app. Copies (without moving) the old project
    /// `pyatv.conf` the first time. Returns nil if the path looks tampered with (symlink).
    static func storageFile(legacyRoot: URL?) -> URL? {
        let fm = FileManager.default
        let dest = supportDir.appendingPathComponent("pyatv.conf")
        if isSymlink(supportDir) { return nil }
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
        if isSymlink(dest) { return nil }
        let legacy = [legacyRoot, fm.homeDirectoryForCurrentUser.appendingPathComponent("AppleTVRemote")]
            .compactMap { $0?.appendingPathComponent("pyatv.conf") }
        // The legacy file holds private keys: tighten it whether or not we copy it.
        for f in legacy where fm.fileExists(atPath: f.path) && !isSymlink(f) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        }
        if !fm.fileExists(atPath: dest.path),
           let src = legacy.first(where: { fm.fileExists(atPath: $0.path) && !isSymlink($0) }),
           let data = try? Data(contentsOf: src) {
            // Created with 0600 from the start, so the keys are never readable by others.
            fm.createFile(atPath: dest.path, contents: data, attributes: [.posixPermissions: 0o600])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        if fm.fileExists(atPath: dest.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        return dest
    }

    /// Minimal environment for the helper: nothing inherited that could redirect Python or the PATH.
    private static func helperEnvironment(storage: URL, workDir: URL, bundled: Bool) -> [String: String] {
        let src = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": src["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": src["TMPDIR"] ?? NSTemporaryDirectory(),
            "ATV_STORAGE": storage.path,
            "ATV_ROOT": workDir.path,
        ]
        for k in ["LANG", "LC_ALL"] { if let v = src[k] { env[k] = v } }
        if bundled { env["PYTHONDONTWRITEBYTECODE"] = "1" }   // never modify the signed bundle
        return env
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard !isRunning else { return }
        stopping = false
        let loc = Self.locate()
        let python = loc.python, script = loc.script
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            onEvent?("helper_error", ["message": .str(String(localized: "Python environment missing. Run setup.sh."))])
            return
        }
        guard loc.bundled || Self.isTrustedPython(python) else {
            FileHandle.standardError.write(Data("helper: refusing untrusted development Python \(python.path)\n".utf8))
            onEvent?("helper_error", ["message": .str(String(localized: "The development Python is not trusted (wrong owner or writable by others)."))])
            return
        }
        guard let storage = Self.storageFile(legacyRoot: loc.bundled ? nil : loc.workDir) else {
            onEvent?("helper_error", ["message": .str(String(localized: "The credentials location is a symbolic link; refusing to use it."))])
            return
        }
        FileHandle.standardError.write(Data("helper: \(python.path) (\(loc.bundled ? "bundled" : "development"))\n".utf8))
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", "-u", script.path]   // isolated mode: ignores PYTHON* variables, user site and cwd
        try? FileManager.default.createDirectory(at: loc.workDir, withIntermediateDirectories: true)
        p.currentDirectoryURL = loc.workDir
        p.environment = Self.helperEnvironment(storage: storage, workDir: loc.workDir, bundled: loc.bundled)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let reader = self.reader
        reader.reset()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let (lines, overflow) = reader.feed(data)
            if overflow {
                FileHandle.standardError.write(Data("helper: output line exceeded \(LineReader.maxLine) bytes, restarting helper\n".utf8))
                Task { @MainActor in self?.process?.terminate() }   // terminated() restarts it
                return
            }
            for line in lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { continue }
                let json = JSON(any: obj)
                Task { @MainActor in self?.handle(json) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            FileHandle.standardError.write(d)
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.terminated(proc) }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
        } catch {
            onEvent?("helper_error", ["message": .str(String(localized: "Could not start the helper: \(error.localizedDescription)"))])
        }
    }

    private func terminated(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        stdin = nil
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: HelperError(message: String(localized: "Helper interrupted."))) }
        if stopping { return }
        restartCount += 1
        onEvent?("helper_died", ["code": .num(Double(proc.terminationStatus))])
        let delay = min(Double(restartCount) * 1.5, 10)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !self.stopping else { return }
            self.start()
            self.onRestart?()
        }
    }

    func stop() {
        stopping = true
        guard let p = process else { return }
        try? stdin?.write(contentsOf: Data("{\"id\":0,\"cmd\":\"shutdown\"}\n".utf8))
        try? stdin?.close()
        if p.isRunning {
            // give the clean shutdown a short chance, then terminate
            let deadline = Date().addingTimeInterval(0.6)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { p.terminate() }
        }
    }

    /// Helper messages are English; the known user-visible ones have a localized counterpart.
    static func localizedHelperError(_ message: String) -> String {
        Bundle.main.localizedString(forKey: message, value: message, table: nil)
    }

    private func handle(_ msg: JSON) {
        if let ev = msg["event"].string {
            if ev == "ready" { restartCount = 0 }
            onEvent?(ev, msg["data"])
            return
        }
        guard let id = msg["id"].int, let c = pending.removeValue(forKey: id) else { return }
        if msg["ok"].bool == true { c.resume(returning: msg["result"]) }
        else { c.resume(throwing: HelperError(message: Self.localizedHelperError(msg["error"].string ?? "Unknown error"))) }
    }

    @discardableResult
    func request(_ cmd: String, _ args: [String: JSON] = [:], timeout: Double = 30) async throws -> JSON {
        guard isRunning, let stdin else { throw HelperError(message: String(localized: "Helper not started.")) }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "cmd": cmd, "args": args.mapValues { $0.any }]
        let data = try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            if let c = self.pending.removeValue(forKey: id) {
                c.resume(throwing: HelperError(message: String(localized: "Timed out (\(cmd)).")))
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do { try stdin.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: HelperError(message: String(localized: "Write failed: \(error.localizedDescription)")))
            }
        }
    }
}

/// Splits a byte stream into lines (access protected by a lock) and caps the buffered line length.
final class LineReader: @unchecked Sendable {
    static let maxLine = 32 << 20   // 32 MB
    private let lock = NSLock()
    private var buffer = Data()

    func reset() { lock.lock(); buffer = Data(); lock.unlock() }

    /// Returns the complete lines and whether the cap was exceeded (the buffer is then dropped).
    func feed(_ data: Data) -> (lines: [String], overflow: Bool) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        if buffer.count > Self.maxLine {
            buffer = Data()
            return (lines, true)
        }
        return (lines, false)
    }
}
