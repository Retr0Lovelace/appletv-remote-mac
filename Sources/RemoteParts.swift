import SwiftUI
import AppKit

enum Theme {
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.95)
    static let button = Color(red: 0.082, green: 0.082, blue: 0.082)
    static let buttonPressed = Color(red: 0.24, green: 0.24, blue: 0.25)
    static let screen = Color(red: 0.067, green: 0.067, blue: 0.067)
    static let engraved = Color(red: 0.30, green: 0.30, blue: 0.32)
}

let remoteWidth: CGFloat = 240
let buttonSize: CGFloat = 70      // ~29 % de la largeur
let keyGapH: CGFloat = 16         // ~7 %
let keyGapV: CGFloat = 10         // ~4 %
let clickpadSize: CGFloat = 206   // ~86 %
let clickpadTop: CGFloat = 88     // ~37 % (le ⏻ est au-dessus du pavé)
let powerSize: CGFloat = 34       // ~14 %
let appSize: CGFloat = 48         // ~20 %
let shadowPad: CGFloat = 26

// MARK: fenêtre transparente

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let w = v?.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.hasShadow = false
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.isHidden = true
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zone de saisie de la fenêtre : SwiftUI ignore `isMovableByWindowBackground`,
/// on lance donc le déplacement nous-mêmes depuis l'aluminium.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: corps en aluminium

struct RemoteBody: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        ZStack {
            // aluminium sablé
            shape.fill(LinearGradient(stops: [.init(color: Color(red: 0.929, green: 0.929, blue: 0.937), location: 0),
                                              .init(color: Color(red: 0.788, green: 0.788, blue: 0.804), location: 0.55),
                                              .init(color: Color(red: 0.710, green: 0.710, blue: 0.729), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            // arrondi des flancs
            shape.fill(LinearGradient(stops: [.init(color: .black.opacity(0.07), location: 0),
                                              .init(color: .black.opacity(0.0), location: 0.06),
                                              .init(color: .white.opacity(0.14), location: 0.30),
                                              .init(color: .black.opacity(0.0), location: 0.94),
                                              .init(color: .black.opacity(0.08), location: 1)],
                                      startPoint: .leading, endPoint: .trailing))
            shape.strokeBorder(.black.opacity(0.22), lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 8)
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

// MARK: boutons ronds

struct BlackDisc: View {
    var pressed = false
    var body: some View {
        Circle()
            .fill(pressed ? Theme.buttonPressed : Theme.button)
            .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.0)],
                                                          startPoint: .top, endPoint: .center), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}

/// Bouton rond noir, appui court et appui long optionnel.
struct RoundKey<Label: View>: View {
    var size: CGFloat = buttonSize
    var enabled = true
    var help = ""
    var onLong: (() -> Void)? = nil
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var pressed = false
    @State private var longFired = false

    var body: some View {
        BlackDisc(pressed: pressed)
            .overlay(label().foregroundStyle(.white.opacity(enabled ? 0.95 : 0.3)))
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !pressed else { return }
                    pressed = true; longFired = false
                    if let onLong {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(550))
                            if pressed && !longFired { longFired = true; onLong() }
                        }
                    }
                }
                .onEnded { v in
                    let wasPressed = pressed
                    pressed = false
                    guard enabled, wasPressed, !longFired, hypot(v.translation.width, v.translation.height) < size else { return }
                    action()
                })
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

struct SymbolKey: View {
    let symbol: String
    var help = ""
    var enabled = true
    var onLong: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        RoundKey(enabled: enabled, help: help, onLong: onLong, action: action) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
        }
    }
}

/// Capsule de volume : deux zones de clic (+ en haut, − en bas).
struct VolumePill: View {
    let up: () -> Void
    let down: () -> Void
    @State private var pressedUp = false
    @State private var pressedDown = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        ZStack {
            shape.fill(Theme.button)
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0)],
                                                           startPoint: .top, endPoint: .center), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
            VStack(spacing: 0) {
                half(symbol: "plus", pressed: $pressedUp, help: "Volume +", action: up)
                half(symbol: "minus", pressed: $pressedDown, help: "Volume −", action: down)
            }
            .clipShape(shape)
        }
        .frame(width: buttonSize, height: buttonSize * 2 + keyGapV)
    }

    private func half(symbol: String, pressed: Binding<Bool>, help: String, action: @escaping () -> Void) -> some View {
        Rectangle()
            .fill(pressed.wrappedValue ? Color.white.opacity(0.14) : Color.clear)
            .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.95)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed.wrappedValue = true }
                .onEnded { v in
                    pressed.wrappedValue = false
                    if hypot(v.translation.width, v.translation.height) < 30 { action() }
                })
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: clickpad

struct RingSegment: Shape {
    var dir: PadDirection
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let r = R * clickpadInnerRatio
        let mid: Double = switch dir { case .right: 0; case .down: 90; case .left: 180; case .up: 270 }
        var p = Path()
        p.addArc(center: c, radius: R, startAngle: .degrees(mid - 45), endAngle: .degrees(mid + 45), clockwise: false)
        p.addArc(center: c, radius: r, startAngle: .degrees(mid + 45), endAngle: .degrees(mid - 45), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct Clickpad: View {
    let size: CGFloat
    let onSwipe: (Int, Int, Int, Int) -> Void
    let onClick: () -> Void
    let onArrow: (PadDirection) -> Void
    let onLongPress: () -> Void
    @State private var zone: PadZone?

    var body: some View {
        let inner = size * clickpadInnerRatio
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.085), Color(white: 0.07)],
                                         center: .center, startRadius: 0, endRadius: size / 2))
            Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1)
            if case .arrow(let d)? = zone {
                RingSegment(dir: d).fill(.white.opacity(0.12))
                    .clipShape(Circle())
            }
            // points
            ForEach(Array([(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)].enumerated()), id: \.offset) { _, v in
                Circle().fill(.white.opacity(0.85)).frame(width: 3.5, height: 3.5)
                    .offset(x: v.0 * size * 0.39, y: v.1 * size * 0.39)
            }
            // cercle intérieur
            Circle().fill(zone == .center ? Color(white: 0.15) : Color(white: 0.04))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: inner, height: inner)
            ClickpadView(onSwipe: onSwipe, onClick: onClick, onArrow: onArrow, onLongPress: onLongPress,
                         onPressZone: { zone = $0 })
                .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .animation(.easeOut(duration: 0.1), value: zone)
    }
}

// MARK: LED

struct StatusLED: View {
    let connected: Bool
    let flash: Bool
    var body: some View {
        let glow = flash ? 1.0 : (connected ? 0.35 : 0.0)
        Capsule()
            .fill(Color(white: 0.07))
            .overlay(Capsule().fill(Color(red: 0.75, green: 1.0, blue: 0.85).opacity(glow * 0.9)).padding(1.2).blur(radius: 1.2))
            .overlay(Capsule().strokeBorder(.black.opacity(0.4), lineWidth: 0.6))
            .shadow(color: Color(red: 0.6, green: 1.0, blue: 0.75).opacity(glow * 0.6), radius: 4)
            .frame(width: 15, height: 6)
            .animation(.easeOut(duration: 0.2), value: glow)
    }
}

// MARK: icône d'app

struct AppButton: View {
    @Environment(ATVController.self) private var tv
    let app: ATVApp

    private static let symbols: [(String, String)] = [
        // les identifiants Apple commencent presque tous par « com.apple.TV… » : du plus précis au plus général
        ("appstore", "a.square"), ("music", "music.note"), ("photos", "photo"),
        ("preferences", "gearshape"), ("settings", "gearshape"), ("tvwatchlist", "tv"),
        ("fitness", "figure.run"), ("arcade", "gamecontroller"), ("podcasts", "mic"),
        ("search", "magnifyingglass"),
    ]

    private var symbol: String? {
        guard app.bundleID.hasPrefix("com.apple.") else { return nil }
        let id = app.bundleID.lowercased(), n = app.name.lowercased()
        if n == "tv" || n == "apple tv" { return "tv" }
        return Self.symbols.first { id.contains($0.0) || n == $0.0 }?.1
    }

    var body: some View {
        VStack(spacing: 3) {
            RoundKey(size: appSize, help: app.name, action: { tv.launch(app) }) {
                if let img = tv.icons[app.bundleID] {
                    // le logo remplit tout le bouton, légèrement agrandi pour rogner le liseré de l'icône
                    Image(nsImage: img).resizable().scaledToFill()
                        .scaleEffect(1.12)
                        .frame(width: appSize, height: appSize)
                        .clipShape(Circle())
                        .opacity(0.9)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 16, weight: .light))
                } else {
                    Text(String(app.name.first.map { String($0) } ?? "?").uppercased())
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                }
            }
            Text(app.name).font(.system(size: 8, weight: .medium)).lineLimit(1)
                .foregroundStyle(Color(white: 0.28)).frame(width: appSize + 8)
        }
        .task(id: app.bundleID) { await tv.loadIcon(app) }
    }
}

extension View {
    /// Texte « gravé » dans l'aluminium.
    func engraved() -> some View {
        self.foregroundStyle(Theme.engraved)
            .shadow(color: .white.opacity(0.65), radius: 0, x: 0, y: 1)
    }
}
