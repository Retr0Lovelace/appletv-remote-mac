import SwiftUI
import AppKit
import ServiceManagement

struct ContentView: View {
    @Environment(ATVController.self) private var tv
    @State private var text = ""
    @FocusState private var textFocused: Bool
    @State private var monitor: Any?
    @State private var ledFlash = false
    @State private var hovering = false
    @State private var showAllApps = Snapshot.expandApps

    private let contentWidth: CGFloat = 190

    var body: some View {
        @Bindable var tv = tv
        return ZStack {
            RemoteBody().overlay(WindowDragHandle())
            VStack(spacing: 0) {
                topZone
                Clickpad(size: clickpadSize,
                         onSwipe: { tv.swipe($0, $1, $2, $3) },
                         onClick: { tv.click() },
                         onArrow: { d in
                             let name: String = switch d { case .up: "up"; case .down: "down"; case .left: "left"; case .right: "right" }
                             tv.key(name)
                         },
                         onLongPress: { tv.key("select", long: true) })
                buttons.padding(.top, 19)
                if tv.nowPlaying.visible {
                    NowPlayingCard().frame(width: contentWidth).padding(.top, 26)
                }
                appsSection.padding(.top, 26)
                textRow.padding(.top, 18)
                footer.padding(.top, 14).padding(.bottom, 34)
            }
        }
        .frame(width: remoteWidth)
        .fixedSize(horizontal: true, vertical: true)
        .onHover { hovering = $0 }
        .contextMenu { settingsItems }
        .padding(shadowPad)
        .background(WindowAccessor())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $tv.showPairing) { PairingView() }
        .onAppear { tv.start(); installMonitor() }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        .onChange(of: tv.activity) {
            ledFlash = true
            Task { try? await Task.sleep(for: .milliseconds(260)); ledFlash = false }
        }
    }

    // MARK: haut

    private var topZone: some View {
        ZStack(alignment: .top) {
            StatusLED(connected: tv.connected, flash: ledFlash).padding(.top, 42)
            HStack {
                Button { NSApp.keyWindow?.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(white: 0.3))
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .help("Fermer")
                Spacer()
                RoundKey(size: powerSize, help: tv.power == "on" ? "Mettre en veille" : "Allumer", action: { tv.powerToggle() }) {
                    Image(systemName: "power").font(.system(size: 14, weight: .light))
                }
            }
            .padding(.leading, 22).padding(.trailing, 30).padding(.top, 25)
        }
        .frame(width: remoteWidth, height: clickpadTop, alignment: .top)
    }

    // MARK: boutons

    private var buttons: some View {
        let gap = keyGapV
        return HStack(alignment: .top, spacing: keyGapH) {
            VStack(spacing: gap) {
                SymbolKey(symbol: "chevron.left", help: "Retour") { tv.key("menu") }
                SymbolKey(symbol: "playpause", help: "Lecture / Pause") { tv.playPause() }
                SymbolKey(symbol: tv.muted ? "speaker.slash.fill" : "speaker.slash",
                          help: tv.muted ? "Rétablir le son" : "Muet", enabled: tv.canMute) { tv.muteToggle() }
            }
            VStack(spacing: gap) {
                SymbolKey(symbol: "tv", help: "Accueil (appui long : Centre de contrôle)",
                          onLong: { tv.key("home_hold") }) { tv.key("home") }
                VolumePill(up: { tv.volumeUp() }, down: { tv.volumeDown() })
            }
        }
    }

    // MARK: apps

    private let rowHeight: CGFloat = appSize + 3 + 11   // bouton + espace + légende
    private let rowGap: CGFloat = 8

    /// Hauteur approximative de la télécommande sans la zone d'applications.
    private var baseHeight: CGFloat { 800 + (tv.nowPlaying.visible ? 175 : 0) }

    /// Nombre de rangées visibles quand « Plus » est ouvert : 3 au maximum, moins si l'écran est petit.
    private var maxVisibleRows: Int {
        let screenH = NSScreen.main?.visibleFrame.height ?? 800
        let free = screenH - 24 - baseHeight
        let rows = Int((free + rowGap) / (rowHeight + rowGap))
        return min(3, max(1, rows))
    }

    private func appRows(_ apps: [ATVApp]) -> some View {
        let rows = stride(from: 0, to: apps.count, by: 3).map { Array(apps[$0..<min($0 + 3, apps.count)]) }
        return VStack(spacing: rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { AppButton(app: $0) }
                    if row.count < 3 { ForEach(0..<(3 - row.count), id: \.self) { _ in Color.clear.frame(width: appSize, height: 1) } }
                }
            }
        }
    }

    private var appsSection: some View {
        VStack(spacing: 8) {
            if tv.apps.isEmpty {
                Text("Applications indisponibles").font(.system(size: 10)).engraved()
            }
            if showAllApps {
                let n = maxVisibleRows
                let totalRows = (tv.apps.count + 2) / 3
                let visible = min(n, totalRows)
                let height = CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * rowGap
                ScrollView(.vertical, showsIndicators: false) {
                    appRows(tv.apps).padding(.bottom, totalRows > n ? 14 : 0)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: contentWidth + 10, height: height)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Rectangle().fill(.black)
                        if totalRows > n {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                        }
                    }
                }
            } else {
                appRows(Array(tv.apps.prefix(6)))
            }
            if tv.apps.count > 6 {
                Button(showAllApps ? "Moins" : "Plus") { withAnimation(.easeOut(duration: 0.2)) { showAllApps.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).engraved()
            }
        }
    }

    // MARK: texte

    private var textRow: some View {
        HStack(spacing: 6) {
            TextField("Texte", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($textFocused)
                .onSubmit { tv.sendText(text) }
            Button { tv.clearText(); text = "" } label: {
                Image(systemName: "delete.left").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain).help("Effacer")
            Button { tv.sendText(text) } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
            }.buttonStyle(.plain).help("Envoyer")
        }
        .padding(.horizontal, 12)
        .frame(width: contentWidth, height: 30)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tv.keyboardFocused ? Theme.accent : .white.opacity(0.08),
                                        lineWidth: tv.keyboardFocused ? 1.5 : 1))
        .shadow(color: tv.keyboardFocused ? Theme.accent.opacity(0.6) : .clear, radius: 5)
        .help(tv.keyboardFocused ? "Clavier actif sur la TV" : "Envoyer du texte à la TV")
    }

    // MARK: pied

    private var statusText: String {
        switch tv.state {
        case .helperDown: "Assistant arrêté"
        case .idle: tv.selected == nil ? "Aucune Apple TV" : "Déconnectée"
        case .scanning: "Recherche…"
        case .connecting: "Connexion…"
        case .connected: tv.power == "off" ? "En veille" : "Connectée"
        case .lost: "Connexion perdue"
        }
    }

    private var footer: some View {
        VStack(spacing: 3) {
            if !tv.note.isEmpty {
                Text(tv.note).font(.system(size: 9)).foregroundStyle(Color(red: 0.55, green: 0.25, blue: 0.1))
                    .multilineTextAlignment(.center).frame(width: contentWidth)
            }
            Menu {
                if tv.devices.isEmpty { Text("Aucune Apple TV") }
                ForEach(tv.devices) { d in
                    Button(d.name + (d.online ? "" : " (hors ligne)") + (d.identifier == tv.selectedID ? " ✓" : "")) {
                        tv.select(d.identifier)
                    }
                }
                Divider()
                settingsItems
            } label: {
                Text(tv.selected?.name ?? "Apple TV").font(.system(size: 12, weight: .semibold)).engraved()
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            HStack(spacing: 6) {
                Text(statusText).font(.system(size: 9)).engraved()
                Menu { settingsItems } label: {
                    Image(systemName: "gearshape").font(.system(size: 9)).engraved()
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Réglages")
            }
        }
    }

    @ViewBuilder private var settingsItems: some View {
        Button("Rechercher des Apple TV") { Task { await tv.rescan() } }
        Button("Appairer…") { tv.pairStep = .idle; tv.showPairing = true }.disabled(tv.selected == nil)
        Button("Reconnecter") { Task { await tv.connect() } }.disabled(tv.selected == nil)
        Divider()
        Button("Oublier cet appareil", role: .destructive) { tv.forgetSelected() }.disabled(tv.selected == nil)
        Button("Redémarrer l'assistant") { tv.restartHelper() }
        Divider()
        SettingsToggles()
        Divider()
        Button("Quitter") { NSApp.terminate(nil) }
    }

    // MARK: raccourcis clavier

    private func installMonitor() {
        guard monitor == nil else { return }
        let controller = tv
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection([.command, .control, .option]) != [] { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            let code = event.keyCode
            let ch = event.charactersIgnoringModifiers ?? ""
            let handled: Bool = MainActor.assumeIsolated {
                switch code {
                case 126: controller.key("up")
                case 125: controller.key("down")
                case 123: controller.key("left")
                case 124: controller.key("right")
                case 36, 76: controller.key("select")
                case 51, 53: controller.key("menu")
                case 49: controller.playPause()
                default:
                    switch ch.lowercased() {
                    case "h": controller.key("home")
                    case "+", "=": controller.volumeUp()
                    case "-": controller.volumeDown()
                    default: return false
                    }
                }
                return true
            }
            return handled ? nil : event
        }
    }
}

struct NowPlayingCard: View {
    @Environment(ATVController.self) private var tv

    var body: some View {
        let np = tv.nowPlaying
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    if let img = np.artwork { Image(nsImage: img).resizable().scaledToFill() }
                    else { Image(systemName: "music.note").foregroundStyle(.secondary) }
                }
                .frame(width: 44, height: 44)
                .background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(np.title.isEmpty ? "Lecture en cours" : np.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if !np.subtitle.isEmpty { Text(np.subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1) }
                    if !np.app.isEmpty { Text(np.app).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            if let total = np.total, total > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let pos = min(np.currentPosition(at: ctx.date) ?? 0, total)
                    VStack(spacing: 2) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.15))
                                Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * pos / total)
                            }
                        }.frame(height: 3)
                        HStack { Text(Self.fmt(pos)); Spacer(); Text(Self.fmt(total)) }
                            .font(.system(size: 8.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            HStack(spacing: 22) {
                transport("backward.fill") { tv.key("previous") }
                transport(np.isPlaying ? "pause.fill" : "play.fill") { tv.playPause() }
                transport("forward.fill") { tv.key("next") }
            }
        }
        .padding(10)
        .background(Theme.screen, in: shape)
        .overlay(shape.strokeBorder(.black.opacity(0.9), lineWidth: 3).blur(radius: 3).clipShape(shape))
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 1))
        .foregroundStyle(.white)
    }

    private func transport(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    static func fmt(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct PairingView: View {
    @Environment(ATVController.self) private var tv
    @State private var pin = ""

    var body: some View {
        @Bindable var tv = tv
        VStack(alignment: .leading, spacing: 12) {
            Text("Appairage").font(.headline)
            Picker("Apple TV", selection: Binding(get: { tv.selectedID ?? "" }, set: { tv.select($0) })) {
                ForEach(tv.devices) { Text($0.name).tag($0.identifier) }
            }
            .disabled(isBusy)
            if let d = tv.selected {
                Text("\(d.model) · \(d.address)").font(.caption).foregroundStyle(.secondary)
                Text("Companion : \(d.companionPaired ? "appairé" : "non appairé")  ·  AirPlay : \(d.airplayPaired ? "appairé" : "non appairé")")
                    .font(.caption).foregroundStyle(.secondary)
                if d.companionPairing == "disabled" {
                    Text("L'appairage est désactivé sur cette Apple TV. Sur la TV : Réglages → AirPlay et HomeKit → Autoriser l'accès → « Tout le monde » ou « Toute personne sur le même réseau ».")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            stepView
            HStack {
                Spacer()
                Button(closeLabel) { tv.cancelPairing(); tv.showPairing = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }

    private var isBusy: Bool {
        switch tv.pairStep { case .idle, .done, .failed: false; default: true }
    }
    private var closeLabel: String { tv.pairStep == .done ? "Terminer" : "Annuler" }

    @ViewBuilder private var stepView: some View {
        switch tv.pairStep {
        case .idle:
            Text("Un code à 4 chiffres va s'afficher sur la TV, d'abord pour Companion (étape 1/2), puis pour AirPlay (étape 2/2).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Appairer") { pin = ""; tv.startPairing() }
                .buttonStyle(.borderedProminent).disabled(tv.selected == nil)
        case .starting(let p):
            HStack { ProgressView().controlSize(.small); Text("Étape \(num(p))/2 · \(name(p)) : demande du code…") }
        case .awaitingPIN(let p):
            Text("Étape \(num(p))/2 · \(name(p))").font(.subheadline.weight(.semibold))
            Text(p == "companion"
                 ? "Saisissez le code à 4 chiffres affiché sur la TV pour autoriser les commandes."
                 : "Saisissez le nouveau code à 4 chiffres affiché sur la TV pour autoriser la lecture en cours.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("0000", text: $pin).textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { tv.submitPIN(pin); pin = "" }
                Button("Valider") { tv.submitPIN(pin); pin = "" }
                    .buttonStyle(.borderedProminent).disabled(pin.count != 4)
            }
        case .verifying(let p):
            HStack { ProgressView().controlSize(.small); Text("Étape \(num(p))/2 · vérification…") }
        case .done:
            Label("Appairage terminé.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m):
            Text(m).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Réessayer") { pin = ""; tv.startPairing() }
        }
    }
    private func num(_ p: String) -> Int { p == "companion" ? 1 : 2 }
    private func name(_ p: String) -> String { p == "companion" ? "Companion" : "AirPlay" }
}

/// Réglages communs (menu ⚙, clic droit, barre des menus).
struct SettingsToggles: View {
    @Environment(ATVController.self) private var tv

    var body: some View {
        Toggle(tv.loginStatus == .requiresApproval ? "Ouvrir au démarrage (à approuver)" : "Ouvrir au démarrage",
               isOn: Binding(get: { tv.loginStatus == .enabled || tv.loginStatus == .requiresApproval },
                             set: { tv.setLaunchAtLogin($0) }))
        Toggle("Masquer l'icône du Dock",
               isOn: Binding(get: { tv.hideDock }, set: { tv.setHideDock($0) }))
    }
}
