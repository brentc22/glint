import Foundation

/// Finds things that shouldn't end up in a shared screenshot.
///
/// Numbers with a checksum (IBAN, card) are validated, so an order number or a
/// timestamp that happens to look similar doesn't get blurred.
public enum SensitiveMatcher {
    public enum Kind: String, CaseIterable, Sendable {
        case email, phone, iban, card, apiKey, jwt, ipAddress, custom

        public var title: String {
            switch self {
            case .email: "Email addresses"
            case .phone: "Phone numbers"
            case .iban: "IBANs"
            case .card: "Card numbers"
            case .apiKey: "API keys & secrets"
            case .jwt: "Tokens (JWT)"
            case .ipAddress: "IP addresses"
            case .custom: "Your own terms"
            }
        }
    }

    public struct Match: Equatable, Sendable {
        public let kind: Kind
        public let range: Range<String.Index>
    }

    private static let patterns: [(Kind, NSRegularExpression)] = ([
        (.jwt, #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        (.apiKey, #"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}|pk_live_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sbp_[a-f0-9]{40}|re_[A-Za-z0-9]{8,}_[A-Za-z0-9]{16,})"#),
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        (.iban, #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b"#),
        (.card, #"\b\d(?:[ -]?\d){12,18}\b"#),
        (.phone, #"(?:\+|\b00|\b0)\d(?:[ ./-]?\(?\d\)?){7,13}\b"#),
        (.ipAddress, #"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b"#),
    ] as [(Kind, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// - Parameter customTerms: extra things to hide — names, customer IDs, project codes.
    ///   Plain terms match case-insensitively; `/…/` is a regular expression.
    public static func matches(in text: String, kinds: Set<Kind> = Set(Kind.allCases), customTerms: [String] = []) -> [Match] {
        var found: [Match] = []
        let full = NSRange(text.startIndex..., in: text)
        let custom = kinds.contains(.custom) ? customTerms.compactMap(customPattern).map { (Kind.custom, $0) } : []
        for (kind, regex) in custom + patterns where kinds.contains(kind) {
            for result in regex.matches(in: text, range: full) {
                guard let range = Range(result.range, in: text) else { continue }
                // Earlier (more specific) patterns win: a card number inside an IBAN,
                // or digits inside an API key, aren't reported twice.
                guard !found.contains(where: { $0.range.overlaps(range) }) else { continue }
                guard isValid(kind, String(text[range])) else { continue }
                found.append(Match(kind: kind, range: range))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func customPattern(_ term: String) -> NSRegularExpression? {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.count > 2, t.hasPrefix("/"), t.hasSuffix("/") {
            return try? NSRegularExpression(pattern: String(t.dropFirst().dropLast()))
        }
        return try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: t), options: .caseInsensitive)
    }

    static func isValid(_ kind: Kind, _ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        switch kind {
        case .iban: return ibanChecksumValid(value)
        case .card: return (13...19).contains(digits.count) && luhnValid(digits)
        case .phone: return (9...15).contains(digits.count)
        default: return true
        }
    }

    /// ISO 13616: move the first four characters to the end, letters to numbers, mod 97 == 1.
    static func ibanChecksumValid(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for ch in rearranged {
            guard let v = ch.isNumber ? ch.wholeNumberValue : ch.isLetter ? Int(ch.asciiValue ?? 0) - 55 : nil else { return false }
            for d in String(v) { remainder = (remainder * 10 + d.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    static func luhnValid(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
