import Foundation
import CoreImage
import AppKit
import ImageIO
import CryptoKit

/// Fetches app logos through the iTunes API, caches them on disk (including definitive misses)
/// and returns a monochrome PNG. Everything happens off the main actor.
///
/// Network hardening: HTTPS only, artwork limited to `*.mzstatic.com`, ephemeral session,
/// strict size caps and pixel-dimension checks before any decoding.
actor IconStore {
    static let shared = IconStore()

    private static let apiHost = "itunes.apple.com"
    private static let artworkHostSuffix = ".mzstatic.com"
    private static let jsonCap = 1 << 20          // 1 MB
    private static let imageCap = 2 << 20         // 2 MB
    private static let maxPixels = 2048

    private let dir: URL
    private let session: URLSession
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private var inflight: [String: Task<Data?, Never>] = [:]
    private let negativeTTL: TimeInterval = 7 * 24 * 3600

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("com.retr0.appletvremote", isDirectory: true)
        dir = root.appendingPathComponent("icons", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func icon(bundleID: String, name: String) async -> Data? {
        if let t = inflight[bundleID] { return await t.value }
        let t = Task { await self.resolve(bundleID: bundleID, name: name) }
        inflight[bundleID] = t
        let r = await t.value
        inflight[bundleID] = nil
        return r
    }

    /// Cache key: SHA-256 hex of the bundle id (never trust the id as a file name).
    private func fileKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func resolve(bundleID: String, name: String) async -> Data? {
        let key = fileKey(bundleID)
        let png = dir.appendingPathComponent(key + ".img")
        let none = dir.appendingPathComponent(key + ".none")
        if let d = try? Data(contentsOf: png), let out = monochrome(d) { return out }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: none.path),
           let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < negativeTTL { return nil }

        let result = await download(bundleID: bundleID, name: name)
        guard case .found(let raw) = result, let out = monochrome(raw) else {
            // Only definitive answers are remembered: transient errors must stay retryable.
            if case .definitiveMiss = result {
                try? Data().write(to: none)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: none.path)
            }
            return nil
        }
        try? raw.write(to: png, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: png.path)
        try? FileManager.default.removeItem(at: none)
        return out
    }

    // MARK: network

    private enum Fetch { case ok(Data), definitive, transient }
    private enum Download { case found(Data), definitiveMiss, transient }

    private func lookupURLs(bundleID: String, name: String) -> [URL] {
        func make(_ path: String, _ items: [(String, String)]) -> URL? {
            var c = URLComponents()
            c.scheme = "https"
            c.host = Self.apiHost
            c.path = path
            c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
            return c.url
        }
        return [
            make("/lookup", [("bundleId", bundleID), ("country", "fr")]),
            make("/lookup", [("bundleId", bundleID), ("country", "fr"), ("entity", "tvSoftware")]),
            make("/search", [("term", name), ("entity", "software"), ("country", "fr"), ("limit", "1")]),
            make("/search", [("term", name), ("entity", "tvSoftware"), ("country", "fr"), ("limit", "1")]),
        ].compactMap { $0 }
    }

    private func download(bundleID: String, name: String) async -> Download {
        var sawTransient = false
        for url in lookupURLs(bundleID: bundleID, name: name) {
            switch await artworkURL(url) {
            case .transient:
                sawTransient = true
            case .definitive:
                continue
            case .ok(let art):
                switch await fetch(art, cap: Self.imageCap) {
                case .ok(let d): return .found(d)
                case .transient: sawTransient = true
                case .definitive: continue
                }
            }
        }
        return sawTransient ? .transient : .definitiveMiss
    }

    private enum ArtResult { case ok(URL), definitive, transient }

    private func artworkURL(_ url: URL) async -> ArtResult {
        switch await fetch(url, cap: Self.jsonCap) {
        case .transient: return .transient
        case .definitive: return .definitive
        case .ok(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]],
                  let first = results.first else { return .definitive }
            let s = (first["artworkUrl512"] as? String) ?? (first["artworkUrl100"] as? String)
            guard let s, let art = Self.sanitizedArtworkURL(s) else { return .definitive }
            return .ok(art)
        }
    }

    /// Upgrades http to https, then only accepts https URLs on `*.mzstatic.com`.
    nonisolated static func sanitizedArtworkURL(_ s: String) -> URL? {
        guard var c = URLComponents(string: s) else { return nil }
        if c.scheme?.lowercased() == "http" { c.scheme = "https" }
        guard let u = c.url, isAllowedArtworkURL(u) else { return nil }
        return u
    }

    nonisolated static func isAllowedArtworkURL(_ u: URL) -> Bool {
        guard u.scheme == "https", let host = u.host?.lowercased() else { return false }
        return host.hasSuffix(artworkHostSuffix)
    }

    nonisolated static func isAllowedAPIURL(_ u: URL) -> Bool {
        u.scheme == "https" && u.host?.lowercased() == apiHost
    }

    /// Refuses redirects that leave the allowed hosts.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            if let u = request.url, IconStore.isAllowedArtworkURL(u) || IconStore.isAllowedAPIURL(u) {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    private func fetch(_ url: URL, cap: Int) async -> Fetch {
        guard Self.isAllowedArtworkURL(url) || Self.isAllowedAPIURL(url) else { return .definitive }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (bytes, resp) = try await session.bytes(for: req, delegate: RedirectGuard())
            guard let http = resp as? HTTPURLResponse else { return .transient }
            if http.statusCode == 404 { return .definitive }
            guard http.statusCode == 200 else { return .transient }
            if resp.expectedContentLength > Int64(cap) { return .definitive }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > cap { return .definitive }   // aborts the transfer when the stream is dropped
            }
            return .ok(data)
        } catch {
            return .transient
        }
    }

    // MARK: image

    /// Pixel size read from the header, without decoding the bitmap.
    private func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Grayscale + slightly raised contrast, 256 px PNG.
    private func monochrome(_ data: Data) -> Data? {
        guard data.count <= Self.imageCap, let (pw, ph) = pixelSize(data),
              pw > 0, ph > 0, pw <= Self.maxPixels, ph <= Self.maxPixels else { return nil }
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
