import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Source app of a take")
    struct SourceAppTakeTests {
        private func makeModel(installed: String? = "us.zoom.xos") -> AppModel {
            let model = AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL("source-app")
            )
            model.installedBundleID = { ids in installed.flatMap { ids.contains($0) ? $0 : nil } }
            return model
        }

        private func withSilentFixture(_ body: @MainActor (URL) async throws -> Void) async throws {
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("parola-source-app-\(UUID().uuidString).wav")
            try Self.silentWAV().write(to: fixture)
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: nil, fixtureURL: fixture)
                try await body(fixture)
            }
        }

        private func landedBundleID(of model: AppModel) async throws -> String? {
            let take = try #require(model.activeTake)
            let saving = model.saveTake(
                Transcript(segments: [], language: "en", modelName: "tiny"),
                audio: nil, title: "Call", source: take.source.entrySource, category: take.category,
                landingAs: .recording, recovery: nil, take: take.id, annotations: model.annotations(of: take.id)
            )
            return try await saving.value.sourceAppBundleID
        }

        @Test("a meeting limited to its app lands with that app")
        func appOnlyMeeting() async throws {
            try await withSilentFixture { _ in
                let model = makeModel()
                model.meetingCaptureAppOnly = true

                model.startMeetingRecording(appName: "Zoom")

                #expect(model.activeTake?.sourceAppBundleID == "us.zoom.xos")
                let landed = try await landedBundleID(of: model)
                #expect(landed == "us.zoom.xos")
                model.cancelCurrentWork()
            }
        }

        @Test("a whole-system meeting is still its app's")
        func wholeSystemMeeting() async throws {
            try await withSilentFixture { _ in
                let model = makeModel()
                model.meetingCaptureAppOnly = false

                model.startMeetingRecording(appName: "Zoom")

                #expect(model.activeTake?.captureTargets.isEmpty == true)
                let landed = try await landedBundleID(of: model)
                #expect(landed == "us.zoom.xos")
                model.cancelCurrentWork()
            }
        }

        @Test("of an app's several bundle IDs, the installed one is kept")
        func installedOneWins() async throws {
            try await withSilentFixture { _ in
                let model = makeModel(installed: "com.microsoft.teams2")
                model.meetingCaptureAppOnly = true

                model.startMeetingRecording(appName: "Microsoft Teams")

                #expect(model.activeTake?.sourceAppBundleID == "com.microsoft.teams2")
                #expect(model.activeTake?.captureTargets == ["com.microsoft.teams", "com.microsoft.teams2"])
                model.cancelCurrentWork()
            }
        }

        @Test("an app that is not installed leaves the take with no source app")
        func notInstalled() async throws {
            try await withSilentFixture { _ in
                let model = makeModel(installed: nil)

                model.startMeetingRecording(appName: "Zoom")

                #expect(model.activeTake?.sourceAppBundleID == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("a take whose capture is exactly one app is that app's, and two apps are nobody's")
        func singleCaptureTarget() async throws {
            try await withSilentFixture { _ in
                let one = makeModel()
                one.pendingCaptureBundleIDs = ["us.zoom.xos"]
                one.startRecording(source: .systemAudio)
                #expect(one.activeTake?.sourceAppBundleID == "us.zoom.xos")
                one.cancelCurrentWork()

                let two = makeModel()
                two.pendingCaptureBundleIDs = ["us.zoom.xos", "com.google.Meet"]
                two.startRecording(source: .systemAudio)
                #expect(two.activeTake?.sourceAppBundleID == nil)
                two.cancelCurrentWork()
            }
        }

        @Test("a whole-system take with no known app and a microphone take have none")
        func noSourceApp() async throws {
            try await withSilentFixture { _ in
                let system = makeModel()
                system.startRecording(source: .systemAudio)
                #expect(system.activeTake?.sourceAppBundleID == nil)
                system.cancelCurrentWork()

                let mic = makeModel()
                mic.pendingCaptureBundleIDs = ["us.zoom.xos"]
                mic.pendingSourceAppBundleID = "us.zoom.xos"
                mic.startRecording(source: .microphone)
                #expect(mic.activeTake?.sourceAppBundleID == nil)
                mic.cancelCurrentWork()
            }
        }

        @Test("the request that named the app is spent once the take has it")
        func requestIsSpent() async throws {
            try await withSilentFixture { _ in
                let model = makeModel()
                model.startMeetingRecording(appName: "Zoom")
                #expect(model.pendingSourceAppBundleID == nil)
                model.cancelCurrentWork()
            }
        }

        private static func silentWAV() -> Data {
            let sampleRate = 16_000
            let dataBytes = Int(Double(sampleRate) * 0.3) * 2
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(1)
            le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
            ascii("data"); le32(UInt32(dataBytes))
            data.append(Data(count: dataBytes))
            return data
        }
    }
}
