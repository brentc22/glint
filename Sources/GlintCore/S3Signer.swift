import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3-compatible storage (Cloudflare R2, AWS S3, Backblaze B2,
/// MinIO). Just enough for one signed request: no SDK, no dependency.
public struct S3Signer: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let region: String
    public let service: String

    public init(accessKey: String, secretKey: String, region: String, service: String = "s3") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    /// The headers to send with the request, `Authorization` included. `headers` are the
    /// request's own (Content-Type and the like); `host` and `x-amz-date` are added here.
    public func sign(method: String, url: URL, headers: [String: String] = [:], payloadHash: String,
                     date: Date = Date()) -> [String: String] {
        let (amzDate, day) = Self.timestamps(date)
        var all = headers
        all["host"] = url.port.map { "\(url.host ?? ""):\($0)" } ?? (url.host ?? "")
        all["x-amz-date"] = amzDate
        if service == "s3" { all["x-amz-content-sha256"] = payloadHash }

        let canonical = Dictionary(all.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
                                   uniquingKeysWith: { $1 })
        let names = canonical.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let request = [
            method,
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            names.map { "\($0):\(canonical[$0]!)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hex(SHA256.hash(data: Data(request.utf8)))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] { key = SymmetricKey(data: Self.hmac(key, part)) }
        let signature = Self.hex(Self.hmac(key, toSign))

        var out = all
        out["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return out
    }

    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    // MARK: Canonical form

    /// Each path segment URI-encoded once, slashes kept.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.map { (encode($0.name), encode($0.value ?? "")) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// RFC 3986 unreserved characters stay, everything else is %XX.
    public static func encode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func timestamps(_ date: Date) -> (String, String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = f.string(from: date)
        return (amz, String(amz.prefix(8)))
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Names for uploaded files: a random, unguessable key, so a public bucket can't be listed
/// by counting — nobody finds your other screenshots by changing a digit in the link.
public enum UploadKey {
    public static func make(ext: String, date: Date = Date()) -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let id = String((0..<16).map { _ in alphabet[Int(rng.next(upperBound: UInt(alphabet.count)))] })
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return "\(year)/\(id).\(ext)"
    }
}
