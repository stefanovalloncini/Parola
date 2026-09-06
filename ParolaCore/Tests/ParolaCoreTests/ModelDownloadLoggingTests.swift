import Foundation
import Testing
@testable import ParolaCore

@Suite("Model download logging", .serialized)
struct ModelDownloadLoggingTests {
    private static let parakeet = "nvidia_parakeet-tdt-0.6b-v2"
    private static let tiny = "openai_whisper-tiny"

    private func withSink(_ body: (CapturingDiagnosticsSink) async throws -> Void) async rethrows {
        let sink = CapturingDiagnosticsSink()
        try await ParolaLog.withSink(sink) { try await body(sink) }
    }

    private func modelRecords(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.category == .models && $0.message.rendered == message }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-download-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(managed: [String: Any] = [:]) throws -> ModelStore {
        ModelStore(
            modelsDirectory: try temporaryDirectory(),
            managedConfiguration: ManagedConfiguration(plistOverride: managed)
        )
    }

    // Removing an entry needs write permission on its parent, not on the entry itself.
    private func withReadOnly(_ directory: URL, _ body: () throws -> Void) throws {
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try body()
    }

    @Test("a models directory that cannot be created is reported")
    func modelsDirectoryFailure() async throws {
        try await withSink { sink in
            let parent = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            try withReadOnly(parent) {
                _ = ModelStore(modelsDirectory: parent.appendingPathComponent("store", isDirectory: true))
            }
            let record = try #require(
                modelRecords(sink, message: "could not create the models directory").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains(parent.lastPathComponent) == false)
        }
    }

    @Test("an unknown model id renders through the allowlist, never raw")
    func unknownModel() async throws {
        try await withSink { sink in
            let store = try makeStore()
            await #expect(throws: ParolaError.self) {
                _ = try await store.download(variant: "whisper-tiny", registry: EngineRegistry())
            }
            let record = try #require(modelRecords(sink, message: "unknown model unrecognized").first)
            #expect(record.level == .error)
        }
    }

    @Test("a managed policy that disables downloads is reported")
    func policyBlocksDownloads() async throws {
        try await withSink { sink in
            let store = try makeStore(managed: ["disableModelDownloads": true])
            await #expect(throws: ParolaError.self) {
                _ = try await store.download(variant: Self.tiny, registry: EngineRegistry())
            }
            let record = try #require(
                modelRecords(sink, message: "download blocked by policy").first
            )
            #expect(record.level == .notice)
        }
    }

    @Test("a managed engine allowlist reports the engine it turned down")
    func policyBlocksEngine() async throws {
        try await withSink { sink in
            let store = try makeStore(managed: ["allowedEngines": ["whisperkit"]])
            await #expect(throws: ParolaError.self) {
                _ = try await store.download(variant: Self.parakeet, registry: EngineRegistry())
            }
            let record = try #require(
                modelRecords(sink, message: "download blocked by policy for parakeet").first
            )
            #expect(record.level == .notice)
        }
    }

    @Test("a registry download reports its start and its finish")
    func downloadStartAndFinish() async throws {
        try await withSink { sink in
            let store = try makeStore()
            let registry = EngineRegistry()
            await registry.register(
                engineID: .whisperKit,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() },
                downloader: { name, store, _ in
                    let url = store.installedURL(for: name)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data("weights".utf8).write(to: url.appendingPathComponent("model.bin"))
                    return url
                }
            )
            _ = try await store.download(variant: Self.tiny, registry: registry)

            let start = try #require(
                modelRecords(sink, message: "download starting for \(Self.tiny)").first
            )
            #expect(start.level == .info)
            #expect(start.fields[.bytes]?.text == String(ModelCatalog.variant(id: Self.tiny)!.sizeBytes))

            let finish = try #require(
                modelRecords(sink, message: "download finished for \(Self.tiny)").first
            )
            #expect(finish.level == .info)
            #expect((finish.fields[.bytes].flatMap { Int64($0.text) } ?? 0) > 0)
            #expect(finish.fields[.elapsed] != nil)
        }
    }

    @Test("a registry download's start and finish tokens match, even when the download name differs")
    func downloadTokensMatchWhenDownloadNameDiffers() async throws {
        let turbo = "openai_whisper-large-v3_turbo"
        try await withSink { sink in
            let store = try makeStore()
            let registry = EngineRegistry()
            await registry.register(
                engineID: .whisperKit,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() },
                downloader: { name, store, _ in
                    let url = store.installedURL(for: name)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data("weights".utf8).write(to: url.appendingPathComponent("model.bin"))
                    return url
                }
            )
            _ = try await store.download(variant: turbo, registry: registry)

            #expect(modelRecords(sink, message: "download starting for \(turbo)").count == 1)
            #expect(modelRecords(sink, message: "download finished for \(turbo)").count == 1)
        }
    }

    @Test("a registry downloader that throws is reported with its engine and model")
    func registryDownloadFailure() async throws {
        try await withSink { sink in
            let store = try makeStore()
            let registry = EngineRegistry()
            await registry.register(
                engineID: .whisperKit,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() },
                downloader: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
            )

            await #expect(throws: (any Error).self) {
                _ = try await store.download(variant: Self.tiny, registry: registry)
            }

            let record = try #require(modelRecords(sink, message: "download failed").first)
            #expect(record.level == .error)
            #expect(record.fields[.model]?.text == Self.tiny)
            #expect(record.fields[.engine]?.text == "whisperkit")
            #expect(record.fields[.elapsed] != nil)
            #expect(record.fields[.error]?.text == "NSCocoaErrorDomain.513")
        }
    }

    @Test("a cancelled registry download is not filed as a failure")
    func registryDownloadCancellation() async throws {
        try await withSink { sink in
            let store = try makeStore()
            let registry = EngineRegistry()
            await registry.register(
                engineID: .whisperKit,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() },
                downloader: { _, _, _ in throw CancellationError() }
            )

            await #expect(throws: CancellationError.self) {
                _ = try await store.download(variant: Self.tiny, registry: registry)
            }

            #expect(modelRecords(sink, message: "download failed").isEmpty)
        }
    }

    @Test("an engine with no downloader is reported instead of taking the generic snapshot")
    func missingDownloader() async throws {
        try await withSink { sink in
            let store = try makeStore()
            let registry = EngineRegistry()
            await registry.register(
                engineID: .whisperKit,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() }
            )
            await #expect(throws: ParolaError.self) {
                _ = try await store.download(variant: Self.parakeet, registry: registry)
            }
            let record = try #require(
                modelRecords(sink, message: "no downloader registered for parakeet").first
            )
            #expect(record.level == .error)
        }
    }

    @Test("a delete that cannot remove the directory is reported")
    func deleteFailure() async throws {
        try await withSink { sink in
            let store = try makeStore()
            try store.seedInstalledModel(Self.tiny)
            let parent = store.installedURL(for: Self.tiny).deletingLastPathComponent()
            try withReadOnly(parent) {
                #expect(throws: ParolaError.self) { try store.delete(variant: Self.tiny) }
            }
            let record = try #require(
                modelRecords(sink, message: "delete failed for \(Self.tiny)").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.error]?.text == "NSCocoaErrorDomain.513")
        }
    }

    @Test("a directory outside the catalog is reported under the fallback token")
    func orphanDeleteFailure() async throws {
        try await withSink { sink in
            let store = try makeStore()
            let root = store.directory
                .appendingPathComponent("models/openai", isDirectory: true)
            let orphan = root.appendingPathComponent("whisper-tiny-leftovers", isDirectory: true)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: orphan.appendingPathComponent("model.bin"))

            try withReadOnly(root) {
                #expect(throws: ParolaError.self) {
                    try store.deleteAny(idOrPath: "whisper-tiny-leftovers")
                }
            }
            let record = try #require(
                modelRecords(sink, message: "delete failed for unrecognized").first
            )
            #expect(record.level == .error)
            #expect(record.formattedLine.contains("whisper-tiny-leftovers") == false)
        }
    }

    @Test("an empty repo listing is reported")
    func emptyRepoListing() async throws {
        try await withSink { sink in
            let session = MockTransport.makeSession(
                handler: MockTransport.Handler { _ in .ok(body: "[]") }
            )
            let destination = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }
            await #expect(throws: ParolaError.self) {
                try await HuggingFaceDownloader.snapshot(
                    repo: "argmaxinc/whisperkit-coreml",
                    subpath: Self.tiny,
                    destination: destination,
                    urlSession: session,
                    progress: nil
                )
            }
            let record = try #require(modelRecords(sink, message: "repo listing was empty").first)
            #expect(record.level == .error)
        }
    }

    @Test("a non-2xx file response is reported with the files already done")
    func fileDownloadHTTPFailure() async throws {
        try await withSink { sink in
            let session = Self.session(tree: Self.tree(size: 7), fileStatus: 503)
            let destination = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }
            await #expect(throws: ParolaError.self) {
                try await HuggingFaceDownloader.snapshot(
                    repo: "argmaxinc/whisperkit-coreml",
                    subpath: Self.tiny,
                    destination: destination,
                    urlSession: session,
                    progress: nil
                )
            }
            let record = try #require(
                modelRecords(sink, message: "file download returned HTTP 503").first
            )
            #expect(record.level == .error)
            #expect(record.fields[.count]?.text == "0")
        }
    }

    @Test("a checksum mismatch is reported as a fault")
    func checksumMismatch() async throws {
        try await withSink { sink in
            let session = Self.session(tree: Self.tree(size: 7, sha256: String(repeating: "0", count: 64)))
            let destination = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }
            await #expect(throws: ParolaError.self) {
                try await HuggingFaceDownloader.snapshot(
                    repo: "argmaxinc/whisperkit-coreml",
                    subpath: Self.tiny,
                    destination: destination,
                    urlSession: session,
                    progress: nil
                )
            }
            let record = try #require(
                modelRecords(sink, message: "checksum mismatch, file discarded").first
            )
            #expect(record.level == .fault)
            #expect(record.fields[.bytes]?.text == "7")
        }
    }

    @Test("a truncated non-LFS file is reported with the bytes that landed")
    func shortFileRejected() async throws {
        try await withSink { sink in
            let session = Self.session(tree: Self.tree(size: 999))
            let destination = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }
            await #expect(throws: ParolaError.self) {
                try await HuggingFaceDownloader.snapshot(
                    repo: "argmaxinc/whisperkit-coreml",
                    subpath: Self.tiny,
                    destination: destination,
                    urlSession: session,
                    progress: nil
                )
            }
            let record = try #require(modelRecords(sink, message: "short file rejected").first)
            #expect(record.level == .error)
            #expect(record.fields[.bytes]?.text == "7")
        }
    }

    @Test("the store reports a failed snapshot with the model and the error kind")
    func snapshotFailure() async throws {
        try await withSink { sink in
            let store = try makeStore()
            // A registered engine keeps downloadNow from bootstrapping the built-in downloaders.
            let registry = EngineRegistry()
            await registry.register(
                engineID: .parakeet,
                capabilities: .whisperKitDefaults,
                factory: { _ in StubTranscriber() }
            )
            await #expect(throws: ParolaError.self) {
                _ = try await store.download(
                    variant: Self.tiny,
                    registry: registry,
                    urlSession: Self.session(tree: "[]")
                )
            }
            let record = try #require(modelRecords(sink, message: "download failed").first)
            #expect(record.level == .error)
            #expect(record.fields[.model]?.text == Self.tiny)
            #expect(record.fields[.elapsed] != nil)
            #expect(record.fields[.error]?.text == "ParolaError.modelDownloadFailed(unrecognized)")
            #expect(record.formattedLine.contains("huggingface") == false)
        }
    }

    private static func tree(size: Int64, sha256: String? = nil) -> String {
        let lfs = sha256.map { #", "lfs": {"oid": "\#($0)"}"# } ?? ""
        return #"[{"type": "file", "path": "\#(Self.tiny)/model.bin", "size": \#(size)\#(lfs)}]"#
    }

    private static func session(tree: String, fileStatus: Int = 200) -> URLSession {
        MockTransport.makeSession(
            handler: MockTransport.Handler { request in
                if request.url?.path.contains("/api/models/") == true {
                    return .ok(body: tree)
                }
                return fileStatus == 200
                    ? .ok(body: "weights")
                    : .status(fileStatus, body: "")
            }
        )
    }

    private actor StubTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        func load(model: String) async throws {}
        func unload() async {}
        func loadedModelName() async -> String? { nil }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            Transcript(segments: [], language: "en", modelName: "stub", sourceURL: url, durationSeconds: 0)
        }
    }
}
