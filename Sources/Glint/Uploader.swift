import AppKit
import GlintCore
import Security
import UniformTypeIdentifiers

/// Uploads a capture to your own S3-compatible bucket (Cloudflare R2, S3, B2, MinIO) and
/// copies a link to it. Off until you fill in Settings → More → Share links; until then Glint
/// uploads nothing (its only request is the daily update check). The secret key lives in the Keychain, not in preferences.
@MainActor
enum Uploader {
    struct Config {
        var endpoint: String
        var region: String
        var bucket: String
        var accessKey: String
        var secretKey: String
        var publicURL: String
    }

    enum UploadError: LocalizedError {
        case notConfigured, badEndpoint, badPublicURL, server(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Set up share links first: Settings → More → Share links."
            case .badEndpoint: "The endpoint under Settings → More → Share links must be an https:// address."
            case .badPublicURL: "Uploaded, but “Links start with” under Settings → More → Share links isn't a valid address."
            case let .server(code, message): "Upload failed (\(code))\(message.isEmpty ? "" : ": \(message)")"
            }
        }
    }

    /// Without touching the Keychain: the toolbar and cards ask this on every redraw.
    static var isConfigured: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: "uploadHasSecret")
            && ["uploadEndpoint", "uploadBucket", "uploadAccessKey", "uploadPublicURL"]
                .allSatisfy { !(d.string(forKey: $0) ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static var config: Config? {
        let d = UserDefaults.standard
        let c = Config(endpoint: d.string(forKey: "uploadEndpoint") ?? "", region: d.string(forKey: "uploadRegion") ?? "auto",
                       bucket: d.string(forKey: "uploadBucket") ?? "", accessKey: d.string(forKey: "uploadAccessKey") ?? "",
                       secretKey: Keychain.secret ?? "", publicURL: d.string(forKey: "uploadPublicURL") ?? "")
        let required = [c.endpoint, c.bucket, c.accessKey, c.secretKey, c.publicURL]
        return required.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? nil : c
    }

    /// Uploads, copies the link, and says so. Stills are redacted first when that's on:
    /// a link travels further than a file.
    static func share(_ capture: Capture) {
        Task {
            Toast.show("Uploading…", symbol: "icloud.and.arrow.up")
            do {
                let (data, ext, type) = try await payload(for: capture)
                let link = try await upload(data, ext: ext, contentType: type)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                Toast.show("Link copied", symbol: "link")
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private static func payload(for capture: Capture) async throws -> (Data, String, String) {
        if capture.isVideo, let file = capture.file {
            return (try Data(contentsOf: file), "mp4", "video/mp4")
        }
        var image = capture.image
        if Prefs.redactBeforeUpload {
            let regions = await TextRecognizer.sensitiveRegions(in: image, kinds: Prefs.redactKinds, customTerms: Prefs.customTerms)
            if !regions.isEmpty, let redacted = Renderer.render(image, annotations: regions.map { Annotation(Prefs.redactStyle.kind($0)) }) {
                image = redacted
            }
        }
        let type: UTType = Prefs.format == .png ? .png : .jpeg
        return (Capture.encode(image, scale: capture.scale, as: type), type == .png ? "png" : "jpg", type.preferredMIMEType ?? "image/png")
    }

    static func upload(_ data: Data, ext: String, contentType: String, to target: Config? = config) async throws -> URL {
        guard let c = target else { throw UploadError.notConfigured }
        let key = UploadKey.make(ext: ext)
        let base = c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/\(S3Signer.encode(c.bucket))/\(key)"), isSafe(url) else { throw UploadError.badEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let signer = S3Signer(accessKey: c.accessKey, secretKey: c.secretKey, region: c.region.isEmpty ? "auto" : c.region)
        let headers = signer.sign(method: "PUT", url: url,
                                  headers: ["content-type": contentType, "cache-control": "public, max-age=31536000, immutable"],
                                  payloadHash: S3Signer.sha256Hex(data))
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }

        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // S3 errors are XML; the <Message> is the useful part.
            let text = String(decoding: body, as: UTF8.self)
            let message = text.range(of: "<Message>(.*?)</Message>", options: .regularExpression)
                .map { String(text[$0]).replacingOccurrences(of: "</?Message>", with: "", options: .regularExpression) } ?? ""
            throw UploadError.server(status, message)
        }
        let publicBase = c.publicURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let link = URL(string: "\(publicBase)/\(key)"), link.scheme != nil else { throw UploadError.badPublicURL }
        return link
    }
}

extension Uploader {
    /// HTTPS, or plain HTTP to this Mac only (a local MinIO) — keys never cross a network unencrypted.
    static func isSafe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
        default: false
        }
    }
}

/// The upload secret, in the login keychain.
enum Keychain {
    private static let service = "com.brentc22.Glint.upload"

    static var secret: String? {
        get {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
            SecItemDelete(query as CFDictionary)
            UserDefaults.standard.set(!(newValue ?? "").isEmpty, forKey: "uploadHasSecret")
            guard let newValue, !newValue.isEmpty else { return }
            var item = query
            item[kSecValueData] = Data(newValue.utf8)
            item[kSecAttrLabel] = "Glint upload secret key"
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
