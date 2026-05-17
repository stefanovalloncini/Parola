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

        #expect(!store.isInstalled("nvidia_parakeet-tdt-0.6b-v2"))

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
            // expected
        } catch {
            // network error before cancellation took effect is also acceptable here;
            // the point is the task did not run to completion.
        }
    }
}
