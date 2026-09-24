import Foundation

/// Minimal test harness. XCTest and swift-testing need Xcode, so tests run as a
/// plain executable: `swift run GlintTests`. Exit code 0 means green.
enum T {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var current = ""
    nonisolated(unsafe) private static var checks = 0

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        let before = failures.count
        let checksBefore = checks
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
            print("  FAIL \(name): threw \(error)")
            return
        }
        // A test that asserted nothing proves nothing.
        if checks == checksBefore {
            failures.append("\(name): made no assertions")
            print("  FAIL \(name): made no assertions")
        } else if failures.count == before {
            passed += 1
            print("  ok   \(name)")
        }
    }

    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        let entry = "\(current): \(message)  (\(file):\(line))"
        failures.append(entry)
        print("  FAIL \(entry)")
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        expect(actual == expected, "\(message) expected \(expected), got \(actual)", file: file, line: line)
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        for f in failures { print("  - \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
