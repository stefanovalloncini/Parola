import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Duplicate import policy", .serialized)
    struct DuplicateImportPolicyTests {

        private func makeModel(_ label: String, defaults: UserDefaults = temporaryDefaults()) -> AppModel {
            AppModel(
                skipBootstrap: true,
                defaults: defaults,
                libraryURL: makeTempLibraryURL(label),
                features: Set(ParolaFeature.allCases)
            )
        }

        private func makeWAV(_ label: String, seconds: Double = 0.3) throws -> URL {
            let sampleRate = 16_000, channels = 1, bytesPerSample = 2
            let frames = Int(Double(sampleRate) * seconds)
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
                .appendingPathComponent("parola-duplicate-policy-\(label)-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        private func waitUntil(timeoutMs: Int = 5_000, _ condition: @MainActor () -> Bool) async -> Bool {
            var elapsed = 0
            while elapsed < timeoutMs {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(15))
                elapsed += 15
            }
            return condition()
        }

        @discardableResult
        private func seedLibrary(_ model: AppModel, with audio: URL) async throws -> LibraryEntry {
            let transcript = Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "already here")],
                language: "en",
                modelName: "openai_whisper-tiny"
            )
            return try await model.library.add(transcript: transcript, audioSource: audio, title: "Board meeting")
        }

        @Test("the default still opens the sheet")
        func alwaysAskOpensTheSheet() async throws {
            let model = makeModel("policy-ask")
            #expect(model.duplicateImportPolicy == .alwaysAsk)
            let wav = try makeWAV("ask")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()

            #expect(model.duplicateImport != nil)
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("transcribeAgain re-runs the file with no sheet")
        func transcribeAgainSkipsTheSheet() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "again")], delayMs: 500
                ))
                let model = makeModel("policy-again")
                model.duplicateImportPolicy = .transcribeAgain
                let wav = try makeWAV("again")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await seedLibrary(model, with: wav)

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()

                #expect(model.duplicateImport == nil)
                #expect(model.fileTranscribeTask != nil)
                #expect(model.sourceFileURL == wav)
                model.cancelCurrentWork()
            }
        }

        @Test("openExisting selects the entry with no sheet and no run")
        func openExistingSkipsTheSheet() async throws {
            let model = makeModel("policy-open")
            model.duplicateImportPolicy = .openExisting
            let wav = try makeWAV("open")
            defer { try? FileManager.default.removeItem(at: wav) }
            let existing = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()

            #expect(model.duplicateImport == nil)
            #expect(await waitUntil { model.selectedEntryID == existing.id })
            #expect(model.fileTranscribeTask == nil)
        }

        @Test("the sheet's checkbox writes the policy it pressed")
        func rememberingWritesThePolicy() async throws {
            try await withMocksCleared(.transcriber) {
                await MockTranscriberRegistry.shared.install(engineID: nil, response: MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "again")], delayMs: 500
                ))
                let defaults = temporaryDefaults()
                let model = makeModel("policy-remember", defaults: defaults)
                let wav = try makeWAV("remember")
                defer { try? FileManager.default.removeItem(at: wav) }
                _ = try await seedLibrary(model, with: wav)

                model.transcribe(fileURL: wav)
                await model.awaitDuplicateCheck()
                model.transcribeDuplicateAgain(remembering: true)

                #expect(model.duplicateImportPolicy == .transcribeAgain)
                #expect(defaults.string(forKey: "duplicateImportPolicy") == "transcribeAgain")
                model.cancelCurrentWork()
            }
        }

        @Test("pressing without the checkbox leaves the policy alone")
        func notRememberingKeepsThePolicy() async throws {
            let model = makeModel("policy-no-remember")
            let wav = try makeWAV("no-remember")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()
            model.openExistingDuplicate(remembering: false)

            #expect(model.duplicateImportPolicy == .alwaysAsk)
        }

        @Test("the bridge presses the button and can tick the checkbox")
        func bridgeRemembersTheChoice() async throws {
            let model = makeModel("policy-bridge")
            let wav = try makeWAV("bridge")
            defer { try? FileManager.default.removeItem(at: wav) }
            _ = try await seedLibrary(model, with: wav)

            model.transcribe(fileURL: wav)
            await model.awaitDuplicateCheck()

            let server = try ParolaAutomationServer(model: model)
            let context = AutomationContext(model: model, server: server)
            let commands = Dictionary(uniqueKeysWithValues: server.libraryCommands().map { ($0.name, $0) })
            let command = try #require(commands["resolveDuplicateImport"])
            let args = try command.validate(AutomationArgs([
                "choice": .string("openExisting"),
                "remember": .bool(true),
            ]))

            let reply = try await command.handler(args, context)
            withExtendedLifetime(server) {}

            guard case .object(let fields) = reply else {
                Issue.record("resolveDuplicateImport returned no object")
                return
            }
            #expect(fields["duplicateImportPolicy"] == .string("openExisting"))
            #expect(model.duplicateImportPolicy == .openExisting)
        }

        @Test("the policy is read at bootstrap and again on reload")
        func policyLoadsAtBootstrapAndOnReload() {
            let defaults = temporaryDefaults()
            defaults.set("openExisting", forKey: "duplicateImportPolicy")

            let model = makeModel("policy-bootstrap", defaults: defaults)
            #expect(model.duplicateImportPolicy == .openExisting)

            defaults.set("transcribeAgain", forKey: "duplicateImportPolicy")
            model.reloadSettings()

            #expect(model.duplicateImportPolicy == .transcribeAgain)
        }

        @Test("the picker writes the key the bridge and the General pane share")
        func policyPersistsUnderTheSharedKey() {
            let defaults = temporaryDefaults()
            let model = makeModel("policy-key", defaults: defaults)

            model.duplicateImportPolicy = .transcribeAgain

            #expect(defaults.string(forKey: "duplicateImportPolicy") == "transcribeAgain")
            #expect(ParolaAutomationServer.writableSettingKeys.contains("duplicateImportPolicy"))
            #expect(SettingsPaneScope.general.defaultsKeys.contains("duplicateImportPolicy"))
        }
    }
}
