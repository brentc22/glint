import Foundation
import Security

/// A `major.minor.patch` version. Tags like `v0.4.0` parse too; missing parts count as 0.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Pre-release suffixes (`1.0.0-beta.2`) are not something we publish; ignore them.
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The fields of GitHub's `releases/latest` response that the updater needs.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease, assets
    }

    public var version: AppVersion? { AppVersion(tagName) }

    /// The app zip: `Glint.zip` (or `Glint-0.5.0.zip`).
    /// Only https URLs on GitHub's own hosts qualify; anything else (a tampered feed, say)
    /// yields nil and the caller sends the user to the release page instead.
    public func zipURL(appName: String) -> URL? {
        assets.first { $0.name.hasPrefix(appName) && $0.name.hasSuffix(".zip") && Self.isTrustedDownload($0.browserDownloadURL) }?
            .browserDownloadURL
    }

    public static let trustedDownloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com"]

    public static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host.map { trustedDownloadHosts.contains($0.lowercased()) } == true
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }
}

public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether to offer `release`. A skipped version is only offered again when the
    /// user asks for a check themselves.
    public static func shouldOffer(_ release: Release, current: AppVersion,
                                   skipped: String?, userInitiated: Bool) -> Bool {
        guard !release.draft, !release.prerelease, let latest = release.version, latest > current else { return false }
        return userInitiated || skipped != latest.description
    }

    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case noAppInArchive
    case wrongApp(bundleID: String?)
    case wrongVersion(found: String?, expected: String)
    case invalidSignature(String)
    case command(String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .noAppInArchive: "The download doesn't contain an app."
        case .wrongApp(let id): "The download contains a different app (\(id ?? "unknown"))."
        case .wrongVersion(let found, let expected): "The download is version \(found ?? "unknown"), expected \(expected)."
        case .invalidSignature(let detail): "The downloaded app's signature doesn't check out: \(detail)"
        case .command(let cmd, let status): "\(cmd) failed (exit code \(status))."
        }
    }
}

/// Unpacks and checks a downloaded update, and swaps it in once the app has quit.
public enum UpdateInstaller {
    /// Unzips `zip` into `workDir` and returns the app inside it, after checking that the
    /// archive holds exactly one top-level entry, a real directory named `Glint.app`, that it
    /// is the same app (bundle id) and the promised version, and that macOS itself accepts
    /// its code signature against `requirement`.
    ///
    /// `requirement` is the running app's designated requirement (`runningRequirement()`).
    /// For a build signed with the Glint Self-Signed certificate it pins the bundle id and
    /// the certificate, so an update signed with anything else (including ad-hoc) is
    /// refused, and one that passes keeps the Screen Recording grant, which macOS ties to
    /// that same requirement. The decision is made by Security.framework on the code itself,
    /// never by parsing tool output, which the downloaded app's file names could forge.
    /// Apps never get re-signed: that would hide tampering.
    public static func prepare(zip: URL, in workDir: URL, bundleID: String, version: AppVersion,
                               requiredRequirement requirement: SecRequirement) throws -> URL {
        let unpacked = workDir.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

        let contents = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        guard contents.count == 1, let app = contents.first, app.lastPathComponent == appBundleName,
              (try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                  .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
        else { throw UpdateError.noAppInArchive }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let foundID = info?["CFBundleIdentifier"] as? String
        guard foundID == bundleID else { throw UpdateError.wrongApp(bundleID: foundID) }
        let foundVersion = info?["CFBundleShortVersionString"] as? String
        guard foundVersion.flatMap(AppVersion.init) == version else {
            throw UpdateError.wrongVersion(found: foundVersion, expected: version.description)
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalidSignature("couldn't read the code signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        switch status {
        case errSecSuccess: return app
        case errSecCSReqFailed: throw UpdateError.invalidSignature("signed by a different identity")
        default: throw UpdateError.invalidSignature("code validation failed (\(status))")
        }
    }

    public static let appBundleName = "Glint.app"

    /// The designated requirement of the running app, or nil when it isn't signed with a
    /// certificate (ad-hoc builds, `swift run`): then there is no identity to compare an
    /// update against and the caller should send the user to the download page.
    public static func runningRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        return certificateRequirement(of: staticCode)
    }

    private static func certificateRequirement(of code: SecStaticCode) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              requirementText(requirement)?.contains("certificate") == true
        else { return nil }
        return requirement
    }

    /// For display and for tests only; never for a security decision about downloaded code.
    public static func requirementText(_ requirement: SecRequirement) -> String? {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    public static func requirement(fromText text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// A shell script that waits for `pid` to exit and moves `newApp` over `destination`
    /// (restoring the old copy if that fails), then launches whichever copy is in place: the
    /// new one with `--after-update`, so it can tell it was just installed, or the old one
    /// again after a failed swap, so the user is never left without Glint. Run it detached,
    /// then quit.
    public static func swapScript(pid: Int32, newApp: URL, destination: URL, relaunch: Bool = true) -> String {
        let backup = newApp.deletingLastPathComponent().appendingPathComponent("previous.app")
        let reopenOld = relaunch ? "open \(quote(destination.path))" : ":"
        let openNew = relaunch ? "open \(quote(destination.path)) --args --after-update" : ":"
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(quote(backup.path))
        if ! mv \(quote(destination.path)) \(quote(backup.path)); then \(reopenOld); exit 1; fi
        if ! mv \(quote(newApp.path)) \(quote(destination.path)); then
          mv \(quote(backup.path)) \(quote(destination.path)); \(reopenOld); exit 1
        fi
        xattr -dr com.apple.quarantine \(quote(destination.path)) 2>/dev/null
        rm -rf \(quote(backup.path))
        \(openNew)
        """
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.command((tool as NSString).lastPathComponent, status: process.terminationStatus)
        }
    }
}
