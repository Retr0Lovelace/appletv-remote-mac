import SwiftUI
import AppKit
import ServiceManagement

struct ContentView: View {
    @Environment(ATVController.self) private var tv
    @State private var text = ""
    @State private var dictation = Dictation()
    @State private var pulse = false
    @FocusState private var textFocused: Bool
    @State private var monitor: Any?
    @State private var ledFlash = false
    @State private var hovering = false
    @State private var showAllApps = Snapshot.expandApps

    private let contentWidth: CGFloat = 190

    var body: some View {
        @Bindable var tv = tv
        @Bindable var updater = Updater.shared
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
                if tv.textVisible {
                    textRow.padding(.top, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                footer.padding(.top, 14).padding(.bottom, 34)
            }
        }
        .frame(width: remoteWidth)
        .fixedSize(horizontal: true, vertical: true)
        .onHover { hovering = $0 }
        .contextMenu { settingsItems }
        .padding(shadowPad)
        .ignoresSafeArea()   // no space reserved for the hidden title bar
        .background(WindowAccessor())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $tv.showPairing) { PairingView() }
        .sheet(isPresented: $updater.showSheet) { UpdateSheet() }
        .onAppear { tv.start(); installMonitor(); setupDictation(); Updater.shared.startScheduling() }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        .animation(.easeOut(duration: 0.25), value: tv.textVisible)
        .onChange(of: tv.keyboardFocused) { _, focused in
            if focused {
                // prefill with the TV's text, then focus the field
                Task {
                    if let t = await tv.currentText() { text = t }
                    try? await Task.sleep(for: .milliseconds(150))
                    textFocused = true
                }
            } else {
                dictation.stop(sendFinal: false)
                text = ""
                textFocused = false
            }
        }
        .onChange(of: tv.activity) {
            ledFlash = true
            Task { try? await Task.sleep(for: .milliseconds(260)); ledFlash = false }
        }
    }

    // MARK: top

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
                .help("Close")
                Spacer()
                RoundKey(size: powerSize, help: tv.power == "on" ? String(localized: "Put to sleep") : String(localized: "Turn on"), action: { tv.powerToggle() }) {
                    Image(systemName: "power").font(.system(size: 14, weight: .light))
                }
            }
            .padding(.leading, 22).padding(.trailing, 30).padding(.top, 25)
        }
        .frame(width: remoteWidth, height: clickpadTop, alignment: .top)
    }

    // MARK: buttons

    private var buttons: some View {
        let gap = keyGapV
        return HStack(alignment: .top, spacing: keyGapH) {
            VStack(spacing: gap) {
                SymbolKey(symbol: "chevron.left", help: String(localized: "Back")) { tv.key("menu") }
                SymbolKey(symbol: "playpause", help: String(localized: "Play / Pause")) { tv.playPause() }
                SymbolKey(symbol: tv.muted ? "speaker.slash.fill" : "speaker.slash",
                          help: tv.muted ? String(localized: "Unmute") : String(localized: "Mute"), enabled: tv.canMute) { tv.muteToggle() }
            }
            VStack(spacing: gap) {
                SymbolKey(symbol: "tv", help: String(localized: "Home (long press: Control Center)"),
                          onLong: { tv.key("home_hold") }) { tv.key("home") }
                VolumePill(up: { tv.volumeUp() }, down: { tv.volumeDown() })
            }
        }
    }

    // MARK: apps

    private let rowHeight: CGFloat = appSize + 3 + 11   // button + gap + caption
    private let rowGap: CGFloat = 8

    /// Approximate remote height without the apps area.
    private var baseHeight: CGFloat { 800 + (tv.nowPlaying.visible ? 175 : 0) + (tv.textVisible ? 48 : 0) }

    /// Number of visible rows when "More" is open: 3 at most, fewer on small screens.
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
                Text("Apps unavailable").font(.system(size: 10)).engraved()
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
                Button(showAllApps ? String(localized: "Less") : String(localized: "More")) { withAnimation(.easeOut(duration: 0.2)) { showAllApps.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).engraved()
            }
        }
    }

    // MARK: text

    private var textRow: some View {
        HStack(spacing: 6) {
            TextField("Text", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($textFocused)
                .onSubmit { tv.sendText(text) }
            Button { tv.clearText(); text = "" } label: {
                Image(systemName: "delete.left").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }.buttonStyle(.plain).help("Clear")
            micButton
            Button { tv.sendText(text) } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
            }.buttonStyle(.plain).help("Send")
        }
        .padding(.horizontal, 12)
        .frame(width: contentWidth, height: 30)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5))
        .shadow(color: Theme.accent.opacity(0.5), radius: 5)
        .help("Keyboard active on the TV")
    }

    /// Voice dictation (⌘D). While listening, the icon pulses between red and white.
    private var micButton: some View {
        Button { dictation.toggle() } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic").font(.system(size: 11))
                .foregroundStyle(dictation.isListening ? (pulse ? Color.red : Color.white.opacity(0.9)) : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: .command)
        .help(dictation.isListening ? String(localized: "Stop dictation (⌘D)") : String(localized: "Dictate text (⌘D)"))
        .onChange(of: dictation.isListening) { _, on in
            if on { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true } }
            else { withAnimation(.none) { pulse = false } }
        }
    }

    private func setupDictation() {
        let controller = tv
        dictation.onText = { text = $0 }
        dictation.onSend = { controller.sendText($0) }
        dictation.onProblem = { controller.flashNote($0) }
    }

    // MARK: footer

    private var statusText: String {
        switch tv.state {
        case .helperDown: String(localized: "Helper stopped")
        case .idle: tv.selected == nil ? String(localized: "No Apple TV") : String(localized: "Disconnected")
        case .scanning: String(localized: "Searching…")
        case .connecting: String(localized: "Connecting…")
        case .connected: tv.power == "off" ? String(localized: "Asleep") : String(localized: "Connected")
        case .lost: String(localized: "Connection lost")
        }
    }

    private var footer: some View {
        VStack(spacing: 3) {
            if !tv.note.isEmpty {
                Text(tv.note).font(.system(size: 9)).foregroundStyle(Color(red: 0.55, green: 0.25, blue: 0.1))
                    .multilineTextAlignment(.center).frame(width: contentWidth)
            }
            Menu {
                if tv.devices.isEmpty { Text("No Apple TV") }
                ForEach(tv.devices) { d in
                    Button(tv.displayName(d) + (d.online ? "" : String(localized: " (offline)")) + (d.identifier == tv.selectedID ? " ✓" : "")) {
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
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Settings")
            }
        }
    }

    @ViewBuilder private var settingsItems: some View {
        Button("Search for Apple TVs") { Task { await tv.rescan() } }
        Button("Pair…") { tv.pairStep = .idle; tv.showPairing = true }.disabled(tv.selected == nil)
        Button("Reconnect") { Task { await tv.connect() } }.disabled(tv.selected == nil)
        Divider()
        Button("Forget this device", role: .destructive) { tv.forgetSelected() }.disabled(tv.selected == nil)
        Button("Restart helper") { tv.restartHelper() }
        Divider()
        SettingsToggles()
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }

    // MARK: keyboard shortcuts

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
                    Text(np.title.isEmpty ? String(localized: "Now playing") : np.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
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
            Text("Pairing").font(.headline)
            Picker("Apple TV", selection: Binding(get: { tv.selectedID ?? "" }, set: { tv.select($0) })) {
                ForEach(tv.devices) { Text(tv.displayName($0)).tag($0.identifier) }
            }
            .disabled(isBusy)
            if let d = tv.selected {
                Text("\(d.model) · \(d.address)").font(.caption).foregroundStyle(.secondary)
                Text("Companion: \(d.companionPaired ? String(localized: "paired") : String(localized: "not paired"))  ·  AirPlay: \(d.airplayPaired ? String(localized: "paired") : String(localized: "not paired"))")
                    .font(.caption).foregroundStyle(.secondary)
                if d.companionPairing == "disabled" {
                    Text("Pairing is disabled on this Apple TV. On the TV: Settings → AirPlay and HomeKit → Allow Access → \"Everyone\" or \"Anyone on the Same Network\".")
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
    private var closeLabel: String { tv.pairStep == .done ? String(localized: "Done") : String(localized: "Cancel") }

    @ViewBuilder private var stepView: some View {
        switch tv.pairStep {
        case .idle:
            Text("A 4-digit code will appear on the TV, first for Companion (step 1/2), then for AirPlay (step 2/2).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Pair") { pin = ""; tv.startPairing() }
                .buttonStyle(.borderedProminent).disabled(tv.selected == nil)
        case .starting(let p):
            HStack { ProgressView().controlSize(.small); Text("Step \(num(p))/2 · \(name(p)): requesting code…") }
        case .awaitingPIN(let p):
            Text("Step \(num(p))/2 · \(name(p))").font(.subheadline.weight(.semibold))
            Text(p == "companion"
                 ? String(localized: "Enter the 4-digit code shown on the TV to authorize commands.")
                 : String(localized: "Enter the new 4-digit code shown on the TV to authorize now-playing info."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("0000", text: $pin).textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { tv.submitPIN(pin); pin = "" }
                Button("Confirm") { tv.submitPIN(pin); pin = "" }
                    .buttonStyle(.borderedProminent).disabled(pin.count != 4)
            }
        case .verifying(let p):
            HStack { ProgressView().controlSize(.small); Text("Step \(num(p))/2 · verifying…") }
        case .done:
            Label("Pairing complete.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m):
            Text(m).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { pin = ""; tv.startPairing() }
        }
    }
    private func num(_ p: String) -> Int { p == "companion" ? 1 : 2 }
    private func name(_ p: String) -> String { p == "companion" ? "Companion" : "AirPlay" }
}

/// Shared settings (⚙ menu, right-click, menu bar).
struct SettingsToggles: View {
    @Environment(ATVController.self) private var tv
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle(tv.loginStatus == .requiresApproval ? String(localized: "Open at login (needs approval)") : String(localized: "Open at login"),
               isOn: Binding(get: { tv.loginStatus == .enabled || tv.loginStatus == .requiresApproval },
                             set: { tv.setLaunchAtLogin($0) }))
        Toggle("Hide Dock icon",
               isOn: Binding(get: { tv.hideDock }, set: { tv.setHideDock($0) }))
        Toggle("Check for updates automatically",
               isOn: Binding(get: { Updater.shared.autoCheck }, set: { Updater.shared.autoCheck = $0 }))
        Button("Check for Updates…") {
            openWindow(id: "main")
            Updater.shared.checkNow()
        }
        .disabled(Updater.shared.busy)
    }
}
