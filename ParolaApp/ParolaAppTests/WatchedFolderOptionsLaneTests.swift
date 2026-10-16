import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Watched-folder options in the lane", .serialized)
    struct WatchedFolderOptionsLaneTests {

        private static let appleSpeech = "apple-speech-analyzer"

        private struct Rig {
            let model: AppModel
            let root: URL
            let folder: URL
            let exportFolder: URL
            let folderID: UUID
            let files: [String: URL]
        }

        private var srt: ExportPreset { ExportPreset.builtIn(for: .srt)! }
        private var txt: ExportPreset { ExportPreset.builtIn(for: .txt)! }

        private func withRig(
            _ label: String, options: WatchedFolderOptions, files: [String] = ["Standup"], rules: [AutoExportRule] = [],
            chooseExportFolder: Bool = false, _ body: (Rig) async throws -> Void
        ) async throws {
            let rig = try await makeRig(label, options: options, files: files, rules: rules, chooseExportFolder: chooseExportFolder)
            do {
                try await body(rig)
            } catch {
                await finish(rig)
                throw error
            }
            await finish(rig)
        }

        private func makeRig(
            _ label: String, options: WatchedFolderOptions, files: [String] = ["Standup"], rules: [AutoExportRule] = [],
            chooseExportFolder: Bool = false
        ) async throws -> Rig {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-lane-options-\(label)-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("Inbox", isDirectory: true)
            let exportFolder = root.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            var made: [String: URL] = [:]
            for name in files { made[name] = try makeWAV(name, in: folder) }
            let bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let watched = WatchedFolder(bookmark: bookmark, displayPath: folder.path, options: options)
            let defaults = temporaryDefaults()
            defaults.set(try JSONEncoder().encode([watched]), forKey: "watchedFolders")
            let model = AppModel(
                skipBootstrap: true, defaults: defaults,
                libraryURL: makeTempLibraryURL("lane-options-\(label)"), features: Set(ParolaFeature.allCases)
            )
            model.selectedModel = Self.appleSpeech
            model.cardMetadataOperation = { _ in CardMetadata(title: "Titled", summary: "Summed up.") }
            model.completionSoundPlayer = {}
            model.playSoundWhenFinished = false
            model.sweptFolders = { [] }
            model.autoExportRules = rules
            if chooseExportFolder { #expect(model.setAutoExportFolder(exportFolder)) }
            _ = model.watchedFolders
            await waitUntil { model.watchedFolders.watcher(for: watched.id) != nil }
            return Rig(model: model, root: root, folder: folder, exportFolder: exportFolder, folderID: watched.id, files: made)
        }

        private func finish(_ rig: Rig) async {
            await rig.model.watchedFolders.stopWatching()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.folder.path)
            try? FileManager.default.removeItem(at: rig.root)
        }

        private func makeWAV(_ name: String, in folder: URL, seconds: Double = 0.3) throws -> URL {
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
            let url = folder.appendingPathComponent("\(name).wav")
            try data.write(to: url)
            return url
        }

        private func install() async {
            let gate = MockTranscriberGate()
            await MockTranscriberRegistry.shared.install(engineID: .appleSpeech, response: MockTranscriberResponse(
                segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "from the watched folder")],
                failure: nil,
                gate: gate
            ))
            await gate.open()
        }

        private func names(in folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }

        private func landed(_ model: AppModel) async {
            await waitUntil(timeoutMs: 10_000) { model.watchedLaneIsIdle }
            await model.awaitLandingSteps()
        }

        @Test("Auto-Transcribe off adds the file to Batch as a pending job and starts nothing")
        func autoTranscribeOffHoldsInBatch() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.autoTranscribes = false
                try await withRig("held", options: options, files: ["One", "Two"]) { rig in
                    let model = rig.model

                    model.handleWatchedArrival(try #require(rig.files["One"]))
                    #expect(model.arrivalNotice?.state == .queued(1))
                    #expect(model.arrivalNotice?.title() == "Added One to Batch")
                    model.handleWatchedArrival(try #require(rig.files["Two"]))
                    model.handleWatchedArrival(try #require(rig.files["Two"]))

                    #expect(model.arrivalNotice?.state == .queued(2))
                    #expect(model.arrivalNotice?.title() == "Added 2 files to Batch")
                    #expect(model.batchJobs.map(\.displayName) == ["One", "Two"])
                    let allPending = model.batchJobs.allSatisfy { $0.status == .pending }
                    #expect(allPending)
                    #expect(model.watchedArrivals.isEmpty)
                    #expect(model.batchTask == nil)
                    #expect(await model.library.list().isEmpty)
                    #expect(model.canResumeBatch)
                }
            }
        }

        @Test("a held file waits through another batch and runs when the user resumes")
        func heldFilesWaitForResume() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.autoTranscribes = false
                try await withRig("resume", options: options, files: ["Held", "Other"]) { rig in
                    let model = rig.model
                    model.handleWatchedArrival(try #require(rig.files["Held"]))

                    model.addBatchFiles([try #require(rig.files["Other"])])
                    await waitUntil(timeoutMs: 20_000) { model.batchJobs.first { $0.displayName == "Other" }?.status == .done }
                    await waitUntil(timeoutMs: 10_000) { model.batchTask == nil }
                    let heldStatus = model.batchJobs.first { $0.displayName == "Held" }?.status
                    #expect(heldStatus == .pending)

                    model.resumePendingBatchJobs()
                    await waitUntil(timeoutMs: 20_000) { model.batchJobs.allSatisfy { $0.status == .done } }
                    #expect(model.heldBatchJobIDs.isEmpty)
                }
            }
        }

        @Test("Open Batch on the toast goes to the queue")
        func openBatchFromTheToast() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.autoTranscribes = false
                try await withRig("toast", options: options) { rig in
                    let model = rig.model
                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    let notice = try #require(model.arrivalNotice)
                    #expect(ParolaAutomationServer.arrivalButtons(notice) == [.openBatch, .dismiss])

                    model.openBatchFromNotice()

                    #expect(model.arrivalNotice == nil)
                    #expect(model.route == .queue)
                }
            }
        }

        @Test("a folder with Save to Library off exports the transcript and keeps nothing in the library")
        func exportOnly() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.savesToLibrary = false
                options.exportPresetIDs = [srt.id]
                try await withRig("export-only", options: options) { rig in
                    let model = rig.model

                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    await landed(model)

                    #expect(await model.library.list().isEmpty)
                    #expect(names(in: rig.folder) == ["Standup.srt", "Standup.wav"])
                    #expect(OutputMarker.isMarked(rig.folder.appendingPathComponent("Standup.srt")))
                    #expect(model.arrivalNotice?.state == .exported)
                    #expect(model.arrivalNotice?.title() == "Transcribed Standup and exported it")
                    #expect(model.exportNotice == nil)
                }
            }
        }

        @Test("when every export fails the transcript is saved to the library anyway, with a failure notice")
        func failedExportsFallBackToTheLibrary() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.savesToLibrary = false
                options.exportPresetIDs = [srt.id]
                try await withRig("export-fails", options: options) { rig in
                    let model = rig.model
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.folder.path)

                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    await landed(model)

                    let entries = await model.library.list()
                    #expect(entries.count == 1)
                    #expect(model.exportNotice != nil)
                    #expect(model.arrivalNotice?.state == .saved(try #require(entries.first).id))
                }
            }
        }

        @Test("a folder's formats go beside the file with the global rules, and a preset both name is written once")
        func noDoubleWrite() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.exportPresetIDs = [srt.id, txt.id]
                let rules = [AutoExportRule(sourceExtensions: ["wav"], presetIDs: [srt.id])]
                try await withRig("no-double", options: options, rules: rules) { rig in
                    let model = rig.model

                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    await landed(model)

                    #expect(names(in: rig.folder) == ["Standup.srt", "Standup.txt", "Standup.wav"])
                    #expect(await model.library.list().count == 1)
                }
            }
        }

        @Test("Export To the Auto-Export folder writes the folder's formats there, leaving the global rules beside the file")
        func exportsToTheAutoExportFolder() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                var options = WatchedFolderOptions()
                options.exportPresetIDs = [srt.id]
                options.exportsToAutoExportFolder = true
                let rules = [AutoExportRule(sourceExtensions: ["wav"], presetIDs: [txt.id])]
                try await withRig("to-folder", options: options, rules: rules, chooseExportFolder: true) { rig in
                    let model = rig.model

                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    await landed(model)

                    #expect(names(in: rig.folder) == ["Standup.txt", "Standup.wav"])
                    #expect(names(in: rig.exportFolder).count == 1)
                    #expect(names(in: rig.exportFolder).first?.hasSuffix(".srt") == true)
                }
            }
        }

        @Test("a folder at its defaults behaves as before: the file is saved and nothing else is written")
        func defaultsChangeNothing() async throws {
            try await withMocksCleared(.transcriber) {
                await install()
                try await withRig("defaults", options: .default) { rig in
                    let model = rig.model

                    model.handleWatchedArrival(try #require(rig.files["Standup"]))
                    await landed(model)

                    #expect(names(in: rig.folder) == ["Standup.wav"])
                    #expect(await model.library.list().count == 1)
                }
            }
        }
    }
}
