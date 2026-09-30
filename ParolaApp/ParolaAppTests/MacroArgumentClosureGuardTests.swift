import Foundation
import Testing
import ParolaTestSupport

@Suite("No #expect/#require closure inside a wrapper closure")
struct MacroArgumentClosureGuardTests {
    /// Files another lane still edits that hold a closure inside #expect/#require within a wrapper closure; drop each once it's fixed.
    static let pendingRecordingLaneSweep: Set<String> = [
        "AppModelRecordingOptionsTests.swift",
        "RecordingSafetyTests.swift",
        "RecordingTrustTests.swift",
    ]

    private var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    @Test("every #expect/#require argument and trailing closure sits outside any wrapper closure")
    func noClosureInsideMacroArgumentsWithinAWrapperClosure() throws {
        let walker = try #require(FileManager.default.enumerator(at: testsDirectory, includingPropertiesForKeys: nil))

        let ownFileName = URL(fileURLWithPath: #filePath).lastPathComponent
        var scanned = 0
        var scannedSelf = false
        var violations: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            if url.lastPathComponent == ownFileName {
                scannedSelf = true
            }
            guard !Self.pendingRecordingLaneSweep.contains(url.lastPathComponent) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for violation in MacroArgumentClosureScanner.violations(in: source) {
                violations.append("\(url.lastPathComponent):\(violation.line): \(violation.snippet)")
            }
        }

        #expect(scanned > 50, "expected far more than \(scanned) Swift files under \(testsDirectory.path)")
        #expect(scannedSelf, "the walk never reached this guard's own file, so the count above can't be trusted")
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }
}
