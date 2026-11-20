import Foundation
import CoreImage
import AppKit

/// Récupère les logos d'apps via l'API iTunes, les met en cache sur disque
/// (y compris les échecs) et renvoie un PNG monochrome. Tout se passe hors du main actor.
actor IconStore {
    static let shared = IconStore()

    private let dir: URL
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private var inflight: [String: Task<Data?, Never>] = [:]
    private let negativeTTL: TimeInterval = 7 * 24 * 3600

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("com.retr0.appletvremote/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func icon(bundleID: String, name: String) async -> Data? {
        if let t = inflight[bundleID] { return await t.value }
        let t = Task { await self.resolve(bundleID: bundleID, name: name) }
        inflight[bundleID] = t
        let r = await t.value
        inflight[bundleID] = nil
        return r
    }

    private func fileKey(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.map(String.init).joined()
    }

    private func resolve(bundleID: String, name: String) async -> Data? {
        let key = fileKey(bundleID)
        let png = dir.appendingPathComponent(key + ".img")
        let none = dir.appendingPathComponent(key + ".none")
        if let d = try? Data(contentsOf: png), let out = monochrome(d) { return out }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: none.path),
           let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < negativeTTL { return nil }

        guard let raw = await download(bundleID: bundleID, name: name), let out = monochrome(raw) else {
            try? Data().write(to: none)
            return nil
        }
        try? raw.write(to: png)
        try? FileManager.default.removeItem(at: none)
        return out
    }

    // MARK: réseau

    private func download(bundleID: String, name: String) async -> Data? {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        let candidates = [
            "https://itunes.apple.com/lookup?bundleId=\(enc(bundleID))&country=fr",
            "https://itunes.apple.com/lookup?bundleId=\(enc(bundleID))&country=fr&entity=tvSoftware",
            "https://itunes.apple.com/search?term=\(enc(name))&entity=software&country=fr&limit=1",
            "https://itunes.apple.com/search?term=\(enc(name))&entity=tvSoftware&country=fr&limit=1",
        ]
        for c in candidates {
            guard let url = URL(string: c), let art = await artworkURL(url), let d = await fetch(art) else { continue }
            return d
        }
        return nil
    }

    private func artworkURL(_ url: URL) async -> URL? {
        guard let data = await fetch(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        let s = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String)
        return s.flatMap(URL.init(string:))
    }

    private func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    // MARK: image

    /// Niveaux de gris + contraste légèrement relevé, PNG 256 px.
    private func monochrome(_ data: Data) -> Data? {
        guard var img = CIImage(data: data) else { return nil }
        let ext = img.extent
        guard ext.width > 0, ext.height > 0 else { return nil }
        let scale = min(1, 256 / max(ext.width, ext.height))
        if scale < 1 { img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let f = CIFilter(name: "CIColorControls")
        f?.setValue(img, forKey: kCIInputImageKey)
        f?.setValue(0.0, forKey: kCIInputSaturationKey)
        f?.setValue(1.15, forKey: kCIInputContrastKey)
        guard let out = f?.outputImage,
              let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
