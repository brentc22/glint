import Foundation

/// Matching for the capture history's search box: every word of the query has to appear
/// somewhere in the file name or the text read from the image, ignoring case and accents —
/// "factuur acme" finds "Factuur 2291 · ACME bv", "cafe" finds "Café".
public enum HistorySearch {
    public static func matches(_ query: String, name: String, text: String?) -> Bool {
        let words = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = normalize(name + "\n" + (text ?? ""))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Cache key for a file's recognized text: a changed file (edited after capture) is read again.
    public static func key(path: String, modified: Date) -> String {
        "\(path)|\(Int(modified.timeIntervalSince1970))"
    }
}
