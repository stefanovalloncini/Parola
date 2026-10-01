import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind them first.
@MainActor
@Suite("Meeting defaults")
struct MeetingDefaultsTests {
    @Test("a system-audio take files as a meeting unless told otherwise")
    func systemAudioIsAMeeting() {
        #expect(AppModel.defaultCategory(for: .systemAudio) == .meeting)
        #expect(AppModel.defaultCategory(for: .microphone) == .transcription)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Meeting defaults takes", .serialized)
    struct MeetingDefaultsTakeTests {
        private func makeModel(_ label: String) throws -> (model: AppModel, audio: URL) {
            let model = makeRecordingModel(label)
            model.useStreaming = false
            let audio = try makeTakeWAV(label)
            model.takeCaptureOverride = { _ in StubSource(url: audio) }
            return (model, audio)
        }

        private func end(_ model: AppModel) async {
            model.cancelCurrentWork()
            let released = await waitUntil { !model.recordingActive }
            #expect(released)
        }

        @Test("a take that names no category files by its source: Mac audio as a meeting, the microphone as a note")
        func recordFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-source")
                defer { try? FileManager.default.removeItem(at: audio) }

                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)
                await end(model)

                model.startRecording(source: .microphone)
                #expect(model.activeTake?.category == .transcription)
                #expect(model.recording?.category == .transcription)
                await end(model)
            }
        }

        @Test("a Record that names its category keeps it, and the next take that names none goes back to its source's")
        func namedCategoryWins() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-named")
                defer { try? FileManager.default.removeItem(at: audio) }

                model.pendingRecordingCategory = .transcription
                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .transcription)
                await end(model)

                model.startRecording(source: .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                await end(model)
            }
        }

        @Test("a count-in already shows a Mac-audio take as a meeting, and the take it hands over to stays one")
        func countInFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-count-in")
                defer { try? FileManager.default.removeItem(at: audio) }
                model.recordingCountInSeconds = 1

                model.startRecording(source: .systemAudio)
                #expect(model.recordingCountdown != nil)
                #expect(model.recording?.category == .meeting)
                #expect(model.recording?.title.hasPrefix("Meeting ") == true)

                let handedOver = await waitUntil(timeoutMs: 10_000) { model.activeTake != nil }
                #expect(handedOver)
                #expect(model.activeTake?.category == .meeting)
                #expect(model.recording?.category == .meeting)
                await end(model)
            }
        }

        @Test("the menu bar's Record System Audio records a meeting")
        func menuBarSystemAudioIsAMeeting() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-menu-bar")
                defer { try? FileManager.default.removeItem(at: audio) }
                model.showMenuBarExtra = false
                let controller = MenuBarController()
                controller.bind(model)
                let snapshot = MenuBarController.MenuSnapshot(
                    mode: .full, dictateTitle: "", showsDictation: false, showsMicRecording: true, showsSystemAudio: true
                )
                let items = MenuBarController.items(for: snapshot, target: controller)
                let submenu = items.first { $0.title == "Record Meeting" }?.submenu
                let found = submenu?.items.first { $0.title == "Record System Audio" }
                let systemAudio = try #require(found)
                let action = try #require(systemAudio.action)

                _ = controller.perform(action, with: systemAudio)

                #expect(model.activeTake?.source == .systemAudio)
                #expect(model.activeTake?.category == .meeting)
                await end(model)
            }
        }

        private func startRecording(
            _ server: ParolaAutomationServer, _ model: AppModel, _ args: [String: AutomationValue]
        ) async throws -> [String: AutomationValue] {
            let commands = Dictionary(uniqueKeysWithValues: server.recordingCommands().map { ($0.name, $0) })
            let command = try #require(commands["startRecording"])
            let context = AutomationContext(model: model, server: server)
            let reply = try await command.handler(try command.validate(AutomationArgs(args)), context)
            guard case .object(let fields) = reply else { throw AutomationError.precondition("startRecording did not reply with an object") }
            return fields
        }

        @Test("the bridge's startRecording files Mac audio as a meeting unless it names a category, and says which")
        func bridgeFilesBySource() async throws {
            try await withMocksCleared(.audioSource) {
                let (model, audio) = try makeModel("meeting-default-bridge")
                defer { try? FileManager.default.removeItem(at: audio) }
                let server = try ParolaAutomationServer(model: model)

                let plain = try await startRecording(server, model, ["source": .string("systemAudio")])
                #expect(model.activeTake?.category == .meeting)
                #expect(plain["category"] == .string("meeting"))
                await end(model)

                let named = try await startRecording(server, model, ["source": .string("systemAudio"), "category": .string("transcription")])
                #expect(model.activeTake?.category == .transcription)
                #expect(named["category"] == .string("transcription"))
                await end(model)

                let mic = try await startRecording(server, model, [:])
                #expect(model.activeTake?.category == .transcription)
                #expect(mic["category"] == .string("transcription"))
                await end(model)
                withExtendedLifetime(server) {}
            }
        }
    }
}
