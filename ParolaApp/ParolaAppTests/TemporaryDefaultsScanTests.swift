import Foundation
import Testing

@Suite("Temporary defaults coverage")
struct TemporaryDefaultsScanTests {

    /// The at-exit sweeper only knows the suites `temporarySuiteName` registered; the rest are permanent.
    @Test("every test-built defaults suite is registered with the sweeper")
    func suitesGoThroughTheHelper() throws {
        let here = URL(fileURLWithPath: #filePath)
        let tests = here.deletingLastPathComponent()
        let skipped: Set<String> = [here.lastPathComponent]
        let walker = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !skipped.contains(url.lastPathComponent) else { continue }
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("UserDefaults(suiteName:") {
                let named = lines[max(0, index - 3)...index].contains { $0.contains("temporarySuiteName") }
                guard !named else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        #expect(scanned > 0, "no test sources found under \(tests.path)")
        #expect(
            offenders.isEmpty,
            "build the suite with temporaryDefaults()/temporarySuiteName() at \(offenders.joined(separator: ", "))"
        )
    }
}
