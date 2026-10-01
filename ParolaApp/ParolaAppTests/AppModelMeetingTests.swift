import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("AppModel meeting detection")
    struct AppModelMeetingTests {
        private func makeModel() -> AppModel {
            AppModel(
                skipBootstrap: true,
                defaults: temporaryDefaults(),
                libraryURL: makeTempLibraryURL("meeting")
            )
        }

        @Test("a fired detection surfaces the app name on the model")
        func fireSetsDetectedApp() {
            let model = makeModel()
            model.meetingDetector.isEnabled = true
            model.meetingDetectedApp = nil

            model.meetingDetector.fire(appName: "Acme Conference")

            #expect(model.meetingDetectedApp == "Acme Conference")
            #expect(model.detectedMeetingAppName == "Acme Conference", "what the Record menu and the menu bar offer")
        }

        @Test("a second detection while the prompt is up keeps the first app")
        func secondDetectionKeepsFirstPrompt() {
            let model = makeModel()
            model.meetingDetector.isEnabled = true
            model.meetingDetectedApp = nil

            model.meetingDetector.fire(appName: "Zoom")
            model.meetingDetector.fire(appName: "Microsoft Teams")

            #expect(model.meetingDetectedApp == "Zoom")
        }

        @Test("dismissing the prompt clears the detected app")
        func dismissClearsDetectedApp() {
            let model = makeModel()
            model.meetingDetectedApp = "Zoom"

            model.dismissMeetingPrompt()

            #expect(model.meetingDetectedApp == nil)
        }

        @Test("starting a meeting recording tags it as a Meeting and clears the prompt")
        func startMeetingRecordingSelectsMeetingCategory() async throws {
            let fixture = try? makeSilentMeetingWAV()
            guard let fixture else { Issue.record("could not write fixture"); return }
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)

                let model = makeModel()
                model.meetingDetectedApp = "Zoom"

                model.startMeetingRecording()

                #expect(model.activeTake?.category == .meeting)
                #expect(model.pendingRecordingCategory == nil, "the take carries its category; the request slot is spent")
                #expect(model.meetingDetectedApp == nil)

                model.cancelCurrentWork()
                await waitUntil { model.activeTake == nil }
                #expect(model.pendingRecordingCategory == nil)
            }
        }

        @Test("app-only capture stashes the detected vendor's bundle IDs")
        func appOnlyCaptureStashesBundleIDs() async throws {
            let fixture = try? makeSilentMeetingWAV()
            guard let fixture else { Issue.record("could not write fixture"); return }
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)

                let model = makeModel()
                model.meetingCaptureAppOnly = true
                model.meetingDetectedApp = "Microsoft Teams"

                model.startMeetingRecording()

                #expect(model.activeTake?.captureTargets == ["com.microsoft.teams", "com.microsoft.teams2"])
                #expect(model.pendingCaptureBundleIDs == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("full-mix capture leaves no bundle ID stash")
        func fullMixCaptureLeavesNoStash() async throws {
            let fixture = try? makeSilentMeetingWAV()
            guard let fixture else { Issue.record("could not write fixture"); return }
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)

                let model = makeModel()
                model.meetingCaptureAppOnly = false
                model.meetingDetectedApp = "Zoom"

                model.startMeetingRecording()

                #expect(model.activeTake?.captureTargets.isEmpty == true)
                #expect(model.pendingCaptureBundleIDs == nil)
                model.cancelCurrentWork()
            }
        }

        @Test("the app-name overload tags the category and clears the prompt for a different app")
        func startMeetingRecordingWithAppNameSelectsCategoryAndBundleIDs() async throws {
            let fixture = try? makeSilentMeetingWAV()
            guard let fixture else { Issue.record("could not write fixture"); return }
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .system, fixtureURL: fixture)

                let model = makeModel()
                model.meetingCaptureAppOnly = true
                model.meetingDetectedApp = "Zoom"

                model.startMeetingRecording(appName: "Microsoft Teams")

                #expect(model.activeTake?.category == .meeting)
                #expect(model.meetingDetectedApp == nil)
                #expect(model.activeTake?.captureTargets == ["com.microsoft.teams", "com.microsoft.teams2"])
                model.cancelCurrentWork()
            }
        }

        @Test("vendor display names map back to every known bundle ID")
        func bundleIDsForAppName() {
            #expect(MeetingDetector.bundleIDs(forAppName: "Zoom") == ["us.zoom.xos"])
            #expect(MeetingDetector.bundleIDs(forAppName: "Webex").count == 3)
            #expect(MeetingDetector.bundleIDs(forAppName: "Nonexistent").isEmpty)
        }

        @Test("live takes get a category-and-date title instead of the temp filename")
        func liveRecordingTitleUsesCategoryAndDate() {
            let date = Date(timeIntervalSince1970: 1_784_452_000)
            let meeting = AppModel.liveRecordingTitle(category: .meeting, endedAt: date)
            let plain = AppModel.liveRecordingTitle(category: .transcription, endedAt: date)

            #expect(meeting.hasPrefix("Meeting "))
            #expect(plain.hasPrefix("Recording "))
            #expect(!meeting.contains("parola-"))
            #expect(meeting.contains(date.formatted(date: .abbreviated, time: .shortened)))
        }

        private func makeSilentMeetingWAV() throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let frames = Int(Double(sampleRate) * 0.3)
            let dataBytes = frames * channels * bytesPerSample
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(UInt16(channels))
            le32(UInt32(sampleRate)); le32(UInt32(sampleRate * channels * bytesPerSample))
            le16(UInt16(channels * bytesPerSample)); le16(UInt16(bytesPerSample * 8))
            ascii("data"); le32(UInt32(dataBytes))
            data.append(Data(count: dataBytes))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-meeting-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }
    }
}
