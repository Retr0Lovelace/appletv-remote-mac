import Foundation

/// Valeur JSON Sendable, pour passer les réponses de l'assistant entre acteurs sans Any.
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
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON] { if case .arr(let a) = self { return a }; return [] }
}

struct HelperError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Dialogue avec le processus Python (JSON lignes) : requêtes/réponses + événements.
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

    static func projectRoot() -> URL {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppleTVRemote")
        let bundle = Bundle.main.bundleURL
        let candidate = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let py = candidate.appendingPathComponent(".venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: py.path) ? candidate : fallback
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard !isRunning else { return }
        stopping = false
        let root = Self.projectRoot()
        let python = root.appendingPathComponent(".venv/bin/python")
        let script = root.appendingPathComponent("helper/atv_helper.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            onEvent?("helper_error", ["message": "Environnement Python absent. Lancez setup.sh."])
            return
        }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-u", script.path]
        p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["ATV_ROOT"] = root.path
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let reader = self.reader
        reader.reset()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            for line in reader.feed(data) {
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
            onEvent?("helper_error", ["message": .str("Impossible de lancer l'assistant : \(error.localizedDescription)")])
        }
    }

    private func terminated(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        stdin = nil
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: HelperError(message: "Assistant interrompu.")) }
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
            // laisse une courte chance à l'arrêt propre, puis termine
            let deadline = Date().addingTimeInterval(0.6)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if p.isRunning { p.terminate() }
        }
    }

    private func handle(_ msg: JSON) {
        if let ev = msg["event"].string {
            if ev == "ready" { restartCount = 0 }
            onEvent?(ev, msg["data"])
            return
        }
        guard let id = msg["id"].int, let c = pending.removeValue(forKey: id) else { return }
        if msg["ok"].bool == true { c.resume(returning: msg["result"]) }
        else { c.resume(throwing: HelperError(message: msg["error"].string ?? "Erreur inconnue")) }
    }

    @discardableResult
    func request(_ cmd: String, _ args: [String: JSON] = [:], timeout: Double = 30) async throws -> JSON {
        guard isRunning, let stdin else { throw HelperError(message: "Assistant non démarré.") }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "cmd": cmd, "args": args.mapValues { $0.any }]
        let data = try JSONSerialization.data(withJSONObject: payload) + Data("\n".utf8)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            if let c = self.pending.removeValue(forKey: id) {
                c.resume(throwing: HelperError(message: "Délai dépassé (\(cmd))."))
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do { try stdin.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: HelperError(message: "Écriture impossible : \(error.localizedDescription)"))
            }
        }
    }
}

/// Découpe un flux d'octets en lignes (accès protégé par un verrou).
final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func reset() { lock.lock(); buffer = Data(); lock.unlock() }

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        return lines
    }
}
