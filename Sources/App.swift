import SwiftUI

@main
struct AppleTVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var tv = ATVController()

    init() { Snapshot.scheduleIfRequested() }

    var body: some Scene {
        Window("Apple TV Remote", id: "main") {
            ContentView().environment(tv)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)   // always reopen the remote at launch
        .restorationBehavior(.disabled)

        MenuBarExtra("Apple TV Remote", systemImage: "appletv") {
            MenuContent().environment(tv)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App delegate: applies the "no Dock icon" mode at launch and makes sure Quit always succeeds,
/// even if a sheet (pairing...) is open.
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
        if let name = tv.selected?.name { Text(name) } else { Text("No Apple TV") }
        Divider()
        Button("Play / Pause") { tv.playPause() }
        Button("Volume +") { tv.volumeUp() }
        Button("Volume −") { tv.volumeDown() }
        Button("Mute") { tv.muteToggle() }
        Button(tv.power == "on" ? String(localized: "Put to sleep") : String(localized: "Turn on")) { tv.powerToggle() }
        Divider()
        Button("Open remote") {
            openWindow(id: "main")
            NSApp.activate()
            // in "no Dock" (accessory) mode, force the window to the front
            DispatchQueue.main.async {
                NSApp.activate()
                for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); w.orderFrontRegardless() }
            }
        }
        Divider()
        SettingsToggles()
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// Screenshots for the README: `--snapshot <dir>` photographs the app's own windows
/// (no screen-recording permission needed), then quits.
/// For safety it only activates when `ATV_ENABLE_SNAPSHOT=1` is also set and `<dir>` is an existing directory.
/// Options via environment variables (extra arguments prevent the window from opening):
/// `SNAPSHOT_EXPAND_APPS=1`, `SNAPSHOT_PAIRING=1`, `SNAPSHOT_SHOW_TEXT=1`, `SNAPSHOT_TOPCHECK=1`,
/// `SNAPSHOT_DELAY=<s>`, and `SNAPSHOT_DEMO=1` (neutral device name, hidden IP and fake now-playing state).
@MainActor
enum Snapshot {
    static let args = CommandLine.arguments
    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static let env = ProcessInfo.processInfo.environment

    /// Canonical output directory, or nil when snapshot mode is not (validly) requested.
    static let directory: URL? = {
        guard env["ATV_ENABLE_SNAPSHOT"] == "1", let raw = value(after: "--snapshot") else { return nil }
        let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }()
    static var active: Bool { directory != nil }
    static let demo = directory != nil && env["SNAPSHOT_DEMO"] == "1"
    static let expandApps = directory != nil && env["SNAPSHOT_EXPAND_APPS"] == "1"
    static let showText = directory != nil && env["SNAPSHOT_SHOW_TEXT"] == "1"

    static func scheduleIfRequested() {
        guard let dir = directory else { return }
        let delay = Double(env["SNAPSHOT_DELAY"] ?? "") ?? 8
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if env["SNAPSHOT_PAIRING"] == "1", let tv = ATVController.current {
                tv.showPairing = true
                try? await Task.sleep(for: .seconds(1.5))
            }
            if env["SNAPSHOT_TOPCHECK"] == "1", let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.fullSizeContentView) }),
               let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
                w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: vf.maxY + 500))
                FileHandle.standardError.write(Data("topcheck: class=\(type(of: w)) frame=\(w.frame) maxY=\(w.frame.maxY) visibleMaxY=\(vf.maxY) allowed=\(vf.maxY + shadowPad) safeTop=\(w.contentView?.safeAreaInsets.top ?? -1)\n".utf8))
                try? await Task.sleep(for: .milliseconds(300))
            }
            for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView?.superview ?? w.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = dir.appendingPathComponent("window-\(n).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            AppDelegate.dismissSheets()
            NSApp.terminate(nil)
        }
    }
}
