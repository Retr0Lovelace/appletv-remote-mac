import SwiftUI

/// "Update available" sheet, in the remote's dark style.
struct UpdateSheet: View {
    @Bindable private var u = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = u.release {
                Text("Apple TV Remote \(r.version) is available (you have \(u.currentVersionText))").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(r.notes.isEmpty ? String(localized: "No release notes.") : r.notes)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 140)
                .padding(8)
                .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    if let page = r.pageURL { Link("View release page", destination: page).font(.caption) }
                    Spacer()
                    Button("Skip This Version") { u.skipVersion() }
                        .buttonStyle(.link).font(.caption).disabled(u.busy)
                }
            }
            status
            HStack {
                Spacer()
                Button("Later") { u.later() }.keyboardShortcut(.cancelAction).disabled(u.busy)
                Button("Install and Relaunch") { Task { await u.install() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(u.busy)
            }
        }
        .padding(18)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var status: some View {
        switch u.phase {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: u.progress)
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack { ProgressView().controlSize(.small); Text("Verifying signature…").font(.caption) }
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing…").font(.caption) }
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("Checking for updates…").font(.caption) }
        case .idle:
            if !u.errorText.isEmpty {
                Text(u.errorText).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
