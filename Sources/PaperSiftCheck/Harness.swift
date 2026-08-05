import Foundation

/// Minimal test harness.
///
/// `Testing` and `XCTest` are both absent from the Command Line Tools, and this
/// project deliberately builds without Xcode — so the suite is an executable and
/// this is the assertion vocabulary it uses. Sixty lines, no dependency, and
/// `swift run PaperSiftCheck` works on any Mac.
struct TestFailure: Error {}

@MainActor
final class TestRun {
    private var checks = 0
    private var cases = 0
    private var failures: [String] = []
    private var currentCase = ""

    /// A named group of cases. Each case is independent; a throwing case fails
    /// and the run carries on.
    func suite(_ title: String, _ cases: [(String, @Sendable (TestRun) async throws -> Void)]) async {
        print("\n\(title)")
        for (name, body) in cases {
            self.cases += 1
            currentCase = name
            let before = failures.count
            do {
                try await body(self)
            } catch is TestFailure {
                // Already recorded by `require`.
            } catch {
                record("threw \(error)")
            }
            print(failures.count == before ? "  ✓ \(name)" : "  ✗ \(name)")
        }
    }

    func expect(
        _ condition: Bool, _ message: @autoclosure () -> String = "",
        file: StaticString = #fileID, line: UInt = #line
    ) {
        checks += 1
        guard !condition else { return }
        let detail = message()
        record(detail.isEmpty ? "expectation failed" : detail, file: file, line: line)
    }

    func equal<T: Equatable>(
        _ actual: T, _ expected: T, _ label: @autoclosure () -> String = "",
        file: StaticString = #fileID, line: UInt = #line
    ) {
        checks += 1
        guard actual != expected else { return }
        let prefix = label().isEmpty ? "" : "\(label()): "
        record("\(prefix)expected \(expected), got \(actual)", file: file, line: line)
    }

    /// Unwraps or fails the case — the equivalent of swift-testing's `#require`.
    func require<T>(
        _ value: T?, _ label: @autoclosure () -> String = "",
        file: StaticString = #fileID, line: UInt = #line
    ) throws -> T {
        checks += 1
        guard let value else {
            let prefix = label().isEmpty ? "unexpected nil" : "\(label()) was nil"
            record(prefix, file: file, line: line)
            throw TestFailure()
        }
        return value
    }

    private func record(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failures.append("\(currentCase) — \(message)  (\(file):\(line))")
    }

    /// Prints the summary and reports whether everything passed.
    func summarize() -> Bool {
        print("")
        if failures.isEmpty {
            print("✅ \(checks) checks in \(cases) cases — all passed")
            return true
        }
        for failure in failures { print("  ✗ \(failure)") }
        print("❌ \(failures.count) of \(checks) checks failed (\(cases) cases)")
        return false
    }
}
