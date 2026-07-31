import Foundation
import Testing

@Suite("AppStorage defaults store")
struct AppStorageStoreTests {

    @Test("every @AppStorage declaration reads through DefaultsStore")
    func declarationsNameTheStore() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParolaApp")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("@AppStorage(") && !line.contains("store:") {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }

        #expect(scanned > 0, "no sources found under \(sources.path)")
        #expect(offenders.isEmpty, "@AppStorage without store: DefaultsStore.current at \(offenders.joined(separator: ", "))")
    }
}
