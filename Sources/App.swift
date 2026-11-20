import SwiftUI

@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var tv = ATVController()

    init() { Snapshot.scheduleIfRequested() }

    var body: some Scene {
        Window("Télécommande Apple TV", id: "main") {
            ContentView().environment(tv)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)   // toujours rouvrir la télécommande au lancement
        .restorationBehavior(.disabled)

        MenuBarExtra("Télécommande Apple TV", systemImage: "appletv") {
            MenuContent().environment(tv)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Délégué d'application : applique le mode « sans Dock » au lancement et garantit que « Quitter » aboutit toujours,
/// même si une feuille (appairage…) est ouverte.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "hideDock") {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.dismissSheets() }
        return .terminateNow
    }

    @MainActor static func dismissSheets() {
        if let tv = ATVController.current {
            if tv.showPairing { tv.cancelPairing() }
            tv.showPairing = false
        }
        for w in NSApp.windows {
            for sheet in w.sheets { w.endSheet(sheet); sheet.orderOut(nil) }
        }
    }
}

struct MenuContent: View {
    @Environment(ATVController.self) private var tv
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(tv.selected?.name ?? "Aucune Apple TV")
        Divider()
        Button("Lecture / Pause") { tv.playPause() }
        Button("Volume +") { tv.volumeUp() }
        Button("Volume −") { tv.volumeDown() }
        Button("Muet") { tv.muteToggle() }
        Button(tv.power == "on" ? "Mettre en veille" : "Allumer") { tv.powerToggle() }
        Divider()
        Button("Ouvrir la télécommande") {
            openWindow(id: "main")
            NSApp.activate()
            // en mode « sans Dock » (accessory), on force la fenêtre au premier plan
            DispatchQueue.main.async {
                NSApp.activate()
                for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); w.orderFrontRegardless() }
            }
        }
        Divider()
        SettingsToggles()
        Divider()
        Button("Quitter") { NSApp.terminate(nil) }
    }
}

/// Captures d'écran pour le README : `--snapshot <dossier>` photographie les fenêtres de l'app
/// elle-même (aucune autorisation d'enregistrement d'écran nécessaire), puis quitte.
/// Options par variables d'environnement (des arguments en plus empêchent l'ouverture de la fenêtre) :
/// `SNAPSHOT_EXPAND_APPS=1`, `SNAPSHOT_PAIRING=1`, `SNAPSHOT_DELAY=<s>`.
@MainActor
enum Snapshot {
    static let args = CommandLine.arguments
    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static let env = ProcessInfo.processInfo.environment
    static let expandApps = env["SNAPSHOT_EXPAND_APPS"] == "1"

    static func scheduleIfRequested() {
        guard let dir = value(after: "--snapshot") else { return }
        let delay = Double(env["SNAPSHOT_DELAY"] ?? "") ?? 8
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if env["SNAPSHOT_PAIRING"] == "1", let tv = ATVController.current {
                tv.showPairing = true
                try? await Task.sleep(for: .seconds(1.5))
            }
            for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("window-\(n).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            AppDelegate.dismissSheets()
            NSApp.terminate(nil)
        }
    }
}
