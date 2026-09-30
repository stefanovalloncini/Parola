import Foundation
import Testing
import ParolaTestSupport

@Suite("No closures inside #expect/#require arguments")
struct MacroArgumentClosureGuardTests {
    /// The T38 recording (W3) lane still owns these files; remove an entry once it binds that file's waits.
    static let pendingRecordingLaneSweep: Set<String> = [
        "AppModelBatchTests.swift",
        "AppModelRecordingMockTests.swift",
        "AppModelRecordingOptionsTests.swift",
        "AppModelSelectionSafetyTests.swift",
        "ArrivalDrainTests.swift",
        "DiskSpaceGuardTests.swift",
        "DropRoutingTests.swift",
        "EntryOpenRefusalTests.swift",
        "IntentActionsTests.swift",
        "IntroductionControllerTests.swift",
        "LinkFailureBannerTests.swift",
        "ModelLabelTests.swift",
        "RecordingSafetyTests.swift",
        "RecordingTrustTests.swift",
        "SubtitleImportTests.swift",
        "YouTubeCommandsTests.swift",
        "LandingPolicyTests.swift",
        "ExportNoticeTests.swift",
        "MenuBarControllerTests.swift",
        "RecordingPredicateTests.swift",
        "RecordingSessionMirrorTests.swift",
        "RecordingSessionTests.swift",
        "TakeControlsTests.swift",
        "TakeLevelHistoryTests.swift",
    ]

    private var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    @Test("no #expect/#require argument holds an unbound awaited closure")
    func noAwaitedClosureInsideMacroArguments() throws {
        let violations = try swiftFiles(under: testsDirectory)
            .filter { !Self.pendingRecordingLaneSweep.contains($0.lastPathComponent) }
            .flatMap { file -> [String] in
                let source = try String(contentsOf: file, encoding: .utf8)
                return MacroArgumentClosureScanner.violations(in: source).map { violation in
                    "\(file.lastPathComponent):\(violation.line): \(violation.snippet)"
                }
            }
        #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
