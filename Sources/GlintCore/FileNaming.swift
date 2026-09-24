import Foundation

public enum FileNaming {
    /// `Glint 2026-09-24 at 15.04.12.png` — sorts chronologically in Finder, and
    /// avoids `:`, which Finder shows as `/`.
    public static func name(for date: Date = Date(), prefix: String = "Glint", ext: String = "png") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let clean = prefix.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return (clean.isEmpty ? "" : clean + " ") + "\(f.string(from: date)).\(ext)"
    }

    /// `name`, or `name 2`, `name 3`… when a file with that name already exists.
    public static func unique(_ name: String, in dir: URL, exists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while exists(url) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
