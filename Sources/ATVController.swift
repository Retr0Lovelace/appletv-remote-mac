import Foundation
import Observation
import AppKit
import ServiceManagement

enum ConnState: Equatable {
    case helperDown, idle, scanning, connecting, connected, lost
}

struct ATVDevice: Identifiable, Hashable, Codable {
    var id: String { identifier }
    var name: String
    var identifier: String
    var address: String
    var model: String
    var companionPaired = false
    var airplayPaired = false
    var companionPairing = ""
    var online = false
    var isAppleTV = true
}

struct ATVApp: Identifiable, Hashable {
    var id: String { bundleID }
    let name: String
    let bundleID: String
}

struct NowPlaying: Equatable {
    var state = "idle"
    var title = ""
    var artist = ""
    var album = ""
    var app = ""
    var position: Double?
    var total: Double?
    var stamp = Date()
    var artwork: NSImage?
    var isPlaying: Bool { state == "playing" }
    var visible: Bool { state != "idle" && state != "stopped" && !(title.isEmpty && artist.isEmpty) }
    var subtitle: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " · ") }

    func currentPosition(at date: Date) -> Double? {
        guard let p = position else { return nil }
        let t = isPlaying ? p + date.timeIntervalSince(stamp) : p
        return min(max(t, 0), total ?? t)
    }
}

enum PairStep: Equatable {
    case idle
    case starting(String)       // protocole en cours de démarrage
    case awaitingPIN(String)    // "companion" ou "airplay"
    case verifying(String)
    case done
    case failed(String)
}

@MainActor
@Observable
final class ATVController {
    static let favorites = ["netflix", "youtube", "disney", "prime", "apple tv", "canal", "plex", "infuse"]

    var devices: [ATVDevice] = []
    var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedID") } }
    var state: ConnState = .helperDown
    var note = ""
    var power = "unknown"
    var volume: Double?
    var nowPlaying = NowPlaying()
    var apps: [ATVApp] = []
    var keyboardFocused = false
    var features: [String: Bool] = [:]
    var pairStep: PairStep = .idle
    var showPairing = false
    var pyatvVersion = ""
    var muted = false
    var activity = 0
    var icons: [String: NSImage] = [:]
    var hideDock = UserDefaults.standard.bool(forKey: "hideDock")
    var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    @ObservationIgnored private var iconRequested = Set<String>()

    @ObservationIgnored private let helper = HelperClient()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var userDisconnect = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var swipeBusy = false
    @ObservationIgnored private var lastArtworkB64 = ""

    var selected: ATVDevice? { devices.first { $0.identifier == selectedID } }
    var connected: Bool { state == .connected }

    /// Instance active (utilisée par le mode `--snapshot`).
    @ObservationIgnored nonisolated(unsafe) static weak var current: ATVController?

    init() {
        Self.current = self
        if let d = UserDefaults.standard.data(forKey: "devices"),
           let list = try? JSONDecoder().decode([ATVDevice].self, from: d) { devices = list }
        selectedID = UserDefaults.standard.string(forKey: "selectedID")
        helper.onEvent = { [weak self] name, data in self?.handle(name, data) }
        helper.onRestart = { [weak self] in self?.state = .helperDown }
    }

    // MARK: cycle de vie

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [helper] _ in
            MainActor.assumeIsolated { helper.stop() }
        }
        helper.start()
    }

    private func persistDevices() {
        if let d = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(d, forKey: "devices") }
    }

    // MARK: événements

    private func handle(_ name: String, _ d: JSON) {
        switch name {
        case "ready":
            pyatvVersion = d["pyatv"].string ?? ""
            state = .idle
            note = ""
            Task { await rescan(); if selectedID != nil { await connect() } }
        case "helper_error":
            note = d["message"].string ?? "Erreur de l'assistant."
            state = .helperDown
        case "helper_died":
            state = .helperDown
            note = "L'assistant s'est arrêté, redémarrage…"
        case "connected":
            state = .connected
            note = ""
            features = d["features"].asBools
            muted = false
            Task { await refreshApps() }
            Task { await refreshPower() }
        case "disconnected":
            if state != .scanning { state = .idle }
        case "connection_lost":
            guard !userDisconnect else { return }
            state = .lost
            note = "Connexion perdue, nouvelle tentative…"
            scheduleReconnect()
        case "power":
            power = d["state"].string ?? "unknown"
        case "volume":
            volume = d["level"].double
        case "keyboard":
            keyboardFocused = d["focused"].bool ?? false
        case "now_playing":
            applyNowPlaying(d)
        default: break
        }
    }

    private func applyNowPlaying(_ d: JSON) {
        var np = NowPlaying()
        np.state = d["state"].string ?? "idle"
        np.title = d["title"].string ?? d["series_name"].string ?? ""
        np.artist = d["artist"].string ?? ""
        np.album = d["album"].string ?? ""
        np.app = d["app"].string ?? ""
        np.position = d["position"].double
        np.total = d["total_time"].double
        if let b64 = d["artwork"].string, !b64.isEmpty {
            if b64 != lastArtworkB64 { lastArtworkB64 = b64; np.artwork = Data(base64Encoded: b64).flatMap(NSImage.init(data:)) }
            else { np.artwork = nowPlaying.artwork }
        } else { lastArtworkB64 = "" }
        nowPlaying = np
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for attempt in 1...6 {
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                guard let self, !Task.isCancelled, self.state == .lost else { return }
                await self.connect(silent: true)
                if self.state == .connected { return }
            }
            self?.state = .idle
            self?.note = "Appareil injoignable. Vérifiez qu'il est allumé."
        }
    }

    // MARK: commandes de base

    func rescan() async {
        guard helper.isRunning else { return }
        let before = state
        if state != .connected { state = .scanning }
        do {
            let r = try await helper.request("scan", ["timeout": 5], timeout: 40)
            var found: [ATVDevice] = []
            for x in r.array where x["is_apple_tv"].bool == true {
                var dev = ATVDevice(name: x["name"].string ?? "Apple TV",
                                    identifier: x["identifier"].string ?? "",
                                    address: x["address"].string ?? "",
                                    model: x["model"].string ?? "")
                for s in x["services"].array {
                    let p = s["protocol"].string ?? ""
                    if p == "companion" { dev.companionPaired = s["paired"].bool ?? false; dev.companionPairing = s["pairing"].string ?? "" }
                    if p == "airplay" { dev.airplayPaired = s["paired"].bool ?? false }
                }
                dev.online = true
                found.append(dev)
            }
            for i in devices.indices { devices[i].online = false }
            for f in found {
                if let i = devices.firstIndex(where: { $0.identifier == f.identifier }) { devices[i] = f } else { devices.append(f) }
            }
            persistDevices()
            if selectedID == nil || selected == nil, let first = devices.first { selectedID = first.identifier }
            note = found.isEmpty ? "Aucune Apple TV trouvée sur le réseau." : ""
        } catch { note = error.localizedDescription }
        state = before == .connected ? .connected : .idle
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        resetMedia()
        Task { await connect() }
    }

    private func resetMedia() {
        nowPlaying = NowPlaying(); apps = []; keyboardFocused = false; volume = nil; power = "unknown"; muted = false
    }

    func connect(silent: Bool = false) async {
        guard let id = selectedID, helper.isRunning else { return }
        userDisconnect = false
        if !silent { state = .connecting; note = "" }
        do {
            try await helper.request("connect", ["identifier": .str(id)], timeout: 40)
            state = .connected
        } catch {
            if !silent || state != .lost { state = .idle }
            let m = error.localizedDescription
            note = m.contains("Non connecté") ? "" : m
            if selected.map({ !$0.companionPaired }) == true { note = "Cette Apple TV n'est pas appairée. Ouvrez ⚙ → Appairer." }
        }
    }

    /// Demande l'état d'alimentation après la connexion (les notifications push peuvent tarder ou manquer).
    private func refreshPower() async {
        for delay in [0.5, 2.0, 5.0] {
            try? await Task.sleep(for: .seconds(delay))
            guard connected else { return }
            if let r = try? await helper.request("power_state", timeout: 10), let s = r.string, s != "unknown" {
                power = s
                return
            }
        }
    }

    func setHideDock(_ on: Bool) {
        hideDock = on
        UserDefaults.standard.set(on, forKey: "hideDock")
        NSApp.setActivationPolicy(on ? .accessory : .regular)
        NSApp.activate()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            flashNote("Ouverture au démarrage impossible : \(error.localizedDescription)")
        }
        loginStatus = SMAppService.mainApp.status
        if loginStatus == .requiresApproval {
            flashNote("Approuvez l'app dans Réglages Système → Éléments de connexion.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func flashNote(_ m: String) {
        note = m
        Task { try? await Task.sleep(for: .seconds(8)); if note == m { note = "" } }
    }

    func disconnect() async {
        userDisconnect = true
        reconnectTask?.cancel()
        _ = try? await helper.request("disconnect")
        state = .idle
    }

    private func send(_ cmd: String, _ args: [String: JSON] = [:]) {
        activity &+= 1
        Task {
            do { try await helper.request(cmd, args, timeout: 20) }
            catch {
                let m = error.localizedDescription
                note = m
                Task { try? await Task.sleep(for: .seconds(4)); if note == m { note = "" } }
            }
        }
    }

    func key(_ name: String, long: Bool = false) {
        guard connected else { note = "Non connecté."; return }
        send("key", ["name": .str(name), "long": .bool(long)])
    }

    func swipe(_ sx: Int, _ sy: Int, _ ex: Int, _ ey: Int, ms: Int = 120) {
        guard connected, !swipeBusy else { return }
        swipeBusy = true
        Task {
            defer { swipeBusy = false }
            do { try await helper.request("swipe", ["start_x": .num(Double(sx)), "start_y": .num(Double(sy)),
                                                    "end_x": .num(Double(ex)), "end_y": .num(Double(ey)),
                                                    "duration_ms": .num(Double(ms))], timeout: 10) }
            catch { fallbackArrow(sx, sy, ex, ey) }
        }
    }

    /// Si les gestes tactiles ne sont pas disponibles, on traduit en flèches.
    private func fallbackArrow(_ sx: Int, _ sy: Int, _ ex: Int, _ ey: Int) {
        let dx = ex - sx, dy = ey - sy
        if abs(dx) > abs(dy) { key(dx > 0 ? "right" : "left") } else { key(dy > 0 ? "down" : "up") }
    }

    func muteToggle() {
        guard connected else { note = "Non connecté."; return }
        activity &+= 1
        Task {
            do {
                let r = try await helper.request("mute_toggle", timeout: 20)
                muted = r["muted"].bool ?? false
            } catch {
                let m = error.localizedDescription
                note = m
                Task { try? await Task.sleep(for: .seconds(4)); if note == m { note = "" } }
            }
        }
    }

    var canMute: Bool { features["SetVolume"] != false }

    /// Charge (lazy, hors thread principal) l'icône monochrome d'une app.
    func loadIcon(_ app: ATVApp) async {
        let id = app.bundleID
        guard icons[id] == nil, !iconRequested.contains(id), !id.hasPrefix("com.apple.") else { return }
        iconRequested.insert(id)
        if let data = await IconStore.shared.icon(bundleID: id, name: app.name), let img = NSImage(data: data) {
            icons[id] = img
        }
    }

    func click() { key("select") }
    func playPause() { key("play_pause") }
    func volumeUp() { key("volume_up") }
    func volumeDown() { key("volume_down") }

    func sendText(_ text: String) {
        guard connected else { return }
        send("text_set", ["text": .str(text)])
    }
    func clearText() { guard connected else { return }; send("text_clear") }

    func refreshApps() async {
        guard connected else { return }
        if let r = try? await helper.request("apps", timeout: 20) {
            let list = r.array.compactMap { x -> ATVApp? in
                guard let id = x["bundle_id"].string else { return nil }
                return ATVApp(name: x["name"].string ?? id, bundleID: id)
            }
            apps = list.sorted { a, b in
                let ra = Self.favRank(a.name), rb = Self.favRank(b.name)
                if ra != rb { return ra < rb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    private static func favRank(_ n: String) -> Int {
        let l = n.lowercased()
        return favorites.firstIndex { l.contains($0) } ?? favorites.count
    }

    func launch(_ app: ATVApp) { guard connected else { return }; send("launch", ["bundle_id": .str(app.bundleID)]) }

    func powerToggle() {
        Task {
            if !connected { await connect() }
            guard connected else { return }
            send(power == "on" ? "power_off" : "power_on")
        }
    }

    func restartHelper() {
        state = .helperDown
        helper.stop()
        Task { try? await Task.sleep(for: .seconds(0.8)); helper.start() }
    }

    func forgetSelected() {
        guard let id = selectedID else { return }
        Task {
            _ = try? await helper.request("forget", ["identifier": .str(id)], timeout: 20)
            devices.removeAll { $0.identifier == id }
            persistDevices()
            selectedID = devices.first?.identifier
            state = .idle
            await rescan()
        }
    }

    // MARK: appairage

    func startPairing() {
        guard let dev = selected else { return }
        pairStep = .idle
        Task { await pair(dev, proto: dev.companionPaired ? "airplay" : "companion") }
    }

    private func pair(_ dev: ATVDevice, proto: String) async {
        pairStep = .starting(proto)
        if connected { await disconnect() }
        do {
            try await helper.request("pair_begin", ["identifier": .str(dev.identifier), "protocol": .str(proto)], timeout: 40)
            pairStep = .awaitingPIN(proto)
        } catch { pairStep = .failed(error.localizedDescription) }
    }

    func submitPIN(_ pin: String) {
        guard case .awaitingPIN(let proto) = pairStep, let dev = selected else { return }
        pairStep = .verifying(proto)
        Task {
            do {
                try await helper.request("pair_pin", ["pin": .str(pin)], timeout: 40)
                await rescan()
                if proto == "companion" && !(selected?.airplayPaired ?? false) {
                    await pair(dev, proto: "airplay")
                } else {
                    pairStep = .done
                    await connect()
                }
            } catch { pairStep = .failed(error.localizedDescription) }
        }
    }

    func cancelPairing() {
        Task { _ = try? await helper.request("pair_cancel") }
        pairStep = .idle
    }
}

extension JSON {
    var asBools: [String: Bool] {
        guard case .obj(let o) = self else { return [:] }
        return o.compactMapValues { $0.bool }
    }
}
