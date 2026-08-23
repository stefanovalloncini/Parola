import Foundation
import Testing
@testable import ParolaCore

@Suite("Spotlight indexer logging", .serialized)
struct SpotlightIndexerLoggingTests {
    @Test("the indexer no longer owns a private Logger")
    func usesSharedFacade() throws {
        let source = try String(
            contentsOfFile: #filePath
                .replacingOccurrences(
                    of: "Tests/ParolaCoreTests/SpotlightIndexerLoggingTests.swift",
                    with: "Sources/ParolaCore/Library/SpotlightIndexer.swift"
                ),
            encoding: .utf8
        )
        #expect(source.contains("Logger(subsystem") == false)
        #expect(source.contains("localizedDescription") == false)
        let facadeCalls = source.components(separatedBy: "ParolaLog.error(.librarySpotlight,").count - 1
        #expect(
            facadeCalls == 2,
            "both the index and deindex catch blocks must report through the facade"
        )
        #expect(source.contains(#"static let domainID = "com.parola.library""#))
    }
}
