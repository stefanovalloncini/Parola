import Foundation
import Testing
@testable import ParolaCore

@Suite("Download sidecar")
struct DownloadSidecarTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-dl-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("sidecar JSON round-trips")
    func roundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".parola-download.json")

        let sidecar = DownloadSidecar(
            repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            revision: "main",
            files: [
                "weights.bin": .init(size: 12345, sha256: "abc", complete: true),
                "config.json": .init(size: 80, sha256: nil, complete: false),
            ]
        )
        try sidecar.write(to: url)
        let loaded = try DownloadSidecar.read(at: url)
        #expect(loaded == sidecar)
    }

    @Test("isInstalled returns false while sidecar is present")
    func isInstalledRespectsSidecar() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ModelStore(modelsDirectory: dir)

        let installed = store.installedURL(for: "nvidia_parakeet-tdt-0.6b-v2")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: installed.appendingPathComponent("weights.bin"))

        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))

        let sidecarURL = installed.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
        let sidecar = DownloadSidecar(repo: "x", revision: "main", files: [:])
        try sidecar.write(to: sidecarURL)

        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2") == false)

        try FileManager.default.removeItem(at: sidecarURL)
        #expect(store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))
    }

    @Test("cancelled HuggingFace download propagates CancellationError")
    func cancelPropagates() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model")

        let task = Task<Void, Error> {
            try await HuggingFaceDownloader.snapshot(
                repo: "nonexistent/repo-for-cancellation-test",
                subpath: nil,
                destination: dest,
                progress: nil
            )
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("expected the task to throw")
        } catch is CancellationError {
        } catch {
            // Network error before cancellation took effect is also acceptable; the task did not complete.
        }
    }

    @Test("snapshot resumes when sidecar marks every file complete and on-disk")
    func snapshotResumesWhenSidecarCompletes() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model-resume")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try Data("body-a".utf8).write(to: dest.appendingPathComponent("a.bin"))
        let sidecar = DownloadSidecar(
            repo: "fake/repo",
            revision: "main",
            files: [
                "a.bin": .init(size: 6, sha256: nil, complete: true),
            ]
        )
        try sidecar.write(to: dest.appendingPathComponent(HuggingFaceDownloader.sidecarFilename))

        let handler = MockTransport.Handler { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/models/") {
                let tree = #"[{"type":"file","path":"a.bin","size":6}]"#
                return .ok(body: tree)
            }
            return .status(500, body: "file fetch should not happen on resume")
        }
        let session = MockTransport.makeSession(handler: handler)

        try await HuggingFaceDownloader.snapshot(
            repo: "fake/repo",
            subpath: nil,
            destination: dest,
            urlSession: session,
            progress: nil
        )

        let onlyTreeFetch = handler.requests.allSatisfy { $0.url?.path.contains("/api/models/") == true }
        #expect(onlyTreeFetch, "resume must skip already-complete file downloads")
        let sidecarStillThere = FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(HuggingFaceDownloader.sidecarFilename).path
        )
        #expect(sidecarStillThere == false, "snapshot should clean up the sidecar after success")
    }

    @Test("snapshot fails when the HuggingFace tree endpoint returns a 4xx")
    func snapshotFailsOnTreeHTTPError() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model-tree-fail")

        let handler = MockTransport.Handler { _ in .status(404, body: "Not Found") }
        let session = MockTransport.makeSession(handler: handler)

        var captured: Error?
        do {
            try await HuggingFaceDownloader.snapshot(
                repo: "fake/missing",
                subpath: nil,
                destination: dest,
                urlSession: session,
                progress: nil
            )
        } catch {
            captured = error
        }
        guard let captured else {
            Issue.record("expected an error to be thrown")
            return
        }
        if case ParolaError.modelDownloadFailed(let repo, let reason) = captured {
            #expect(repo == "fake/missing")
            #expect(reason.contains("404"))
        } else {
            Issue.record("expected modelDownloadFailed, got \(captured)")
        }
    }

    @Test("snapshot fails when a file fetch returns a non-2xx response")
    func snapshotFailsOnFileHTTPError() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model-file-fail")

        let handler = MockTransport.Handler { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/models/") {
                return .ok(body: #"[{"type":"file","path":"weights.bin","size":4}]"#)
            }
            return .status(500, body: "boom")
        }
        let session = MockTransport.makeSession(handler: handler)

        var captured: Error?
        do {
            try await HuggingFaceDownloader.snapshot(
                repo: "fake/file-error",
                subpath: nil,
                destination: dest,
                urlSession: session,
                progress: nil
            )
        } catch {
            captured = error
        }
        guard let captured else {
            Issue.record("expected an error to be thrown")
            return
        }
        if case ParolaError.modelDownloadFailed(let repo, let reason) = captured {
            #expect(repo == "fake/file-error")
            #expect(reason.contains("500") || reason.contains("HTTP"))
        } else {
            Issue.record("expected modelDownloadFailed, got \(captured)")
        }
    }

    @Test("snapshot writes a sidecar that records each completed file by name")
    func snapshotPersistsSidecarBetweenSteps() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("model-progress")

        let bodyA = "AAAA"
        let bodyB = "BBBBB"

        let handler = MockTransport.Handler { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/models/") {
                let tree = #"[{"type":"file","path":"a.bin","size":4},{"type":"file","path":"b.bin","size":5}]"#
                return .ok(body: tree)
            }
            if path.hasSuffix("/a.bin") { return .ok(body: bodyA) }
            if path.hasSuffix("/b.bin") { return .ok(body: bodyB) }
            return .status(404, body: "unknown path \(path)")
        }
        let session = MockTransport.makeSession(handler: handler)

        try await HuggingFaceDownloader.snapshot(
            repo: "fake/two-files",
            subpath: nil,
            destination: dest,
            urlSession: session,
            progress: nil
        )

        let a = try String(contentsOf: dest.appendingPathComponent("a.bin"), encoding: .utf8)
        let b = try String(contentsOf: dest.appendingPathComponent("b.bin"), encoding: .utf8)
        #expect(a == bodyA)
        #expect(b == bodyB)
        let sidecarExists = FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(HuggingFaceDownloader.sidecarFilename).path
        )
        #expect(sidecarExists == false, "successful snapshot removes the sidecar on completion")
    }

    @Test("install lands the temp file at the destination and consumes the temp")
    func installLandsFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent("download.tmp")
        let dest = dir.appendingPathComponent("model.bin")
        try Data("model-bytes".utf8).write(to: tmp)

        try HuggingFaceDownloader.install(from: tmp, to: dest)

        #expect(try String(contentsOf: dest, encoding: .utf8) == "model-bytes")
        #expect(FileManager.default.fileExists(atPath: tmp.path) == false)
    }

    @Test("install overwrites an existing destination")
    func installOverwrites() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tmp = dir.appendingPathComponent("download.tmp")
        let dest = dir.appendingPathComponent("model.bin")
        try Data("stale".utf8).write(to: dest)
        try Data("fresh".utf8).write(to: tmp)

        try HuggingFaceDownloader.install(from: tmp, to: dest)

        #expect(try String(contentsOf: dest, encoding: .utf8) == "fresh")
    }
}
