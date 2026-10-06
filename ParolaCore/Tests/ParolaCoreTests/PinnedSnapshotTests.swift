import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Pinned Hugging Face snapshot")
struct PinnedSnapshotTests {
    private static let repo = "fake/voice-pack"
    private static let pin = "512104b0229d08fab9f1e8e9e5280858231cc4fc"
    private static let otherPin = "91748676fe3c8b2eb3007b3125253bcd898202c3"

    private struct RepoFile {
        let path: String
        let body: String
    }

    private final class Readings: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: [Double]())
        func append(_ value: Double) { values.withLock { $0.append(value) } }
        var all: [Double] { values.withLock { $0 } }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-pinned-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func sidecarURL(in destination: URL) -> URL {
        destination.appendingPathComponent(HuggingFaceDownloader.sidecarFilename)
    }

    private func markerURL(in destination: URL) -> URL {
        destination.appendingPathComponent(HuggingFaceDownloader.revisionFilename)
    }

    private static func tree(_ files: [RepoFile], directories: [String] = []) -> String {
        let directoryEntries = directories.map { #"{"type":"directory","path":"\#($0)"}"# }
        let fileEntries = files.map { #"{"type":"file","path":"\#($0.path)","size":\#($0.body.utf8.count)}"# }
        return "[" + (directoryEntries + fileEntries).joined(separator: ",") + "]"
    }

    private static func isTreeRequest(_ url: URL) -> Bool {
        url.path.hasPrefix("/api/models/")
    }

    private static func resolvedPath(_ url: URL, repo: String = repo) -> String? {
        let prefix = "/\(repo)/resolve/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let afterRevision = url.path.dropFirst(prefix.count).drop { $0 != "/" }.dropFirst()
        return String(afterRevision)
    }

    private static func serving(
        _ files: [RepoFile],
        directories: [String] = [],
        repo: String = repo,
        override: @escaping @Sendable (String) -> HubStub.Reply? = { _ in nil }
    ) -> HubStub {
        let listing = tree(files, directories: directories)
        let bodies = Dictionary(files.map { ($0.path, $0.body) }, uniquingKeysWith: { first, _ in first })
        return HubStub { request in
            guard let url = request.url else { return .status(400) }
            if isTreeRequest(url) { return .ok(listing) }
            guard let path = resolvedPath(url, repo: repo) else { return .status(404) }
            if let reply = override(path) { return reply }
            return bodies[path].map { .ok($0) } ?? .status(404)
        }
    }

    private func snapshot(
        _ hub: HubStub,
        include: [String],
        into destination: URL,
        revision: String = pin,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await HuggingFaceDownloader.snapshot(
            repo: Self.repo,
            revision: revision,
            include: include,
            to: destination,
            urlSession: hub.makeSession(),
            progress: progress
        )
    }

    @Test("an include list keeps subtrees and exact files at their repo paths and skips everything else")
    func includeListKeepsRepoPaths() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("pack", isDirectory: true)
        let wanted = [
            RepoFile(path: "TextEncoder.mlmodelc/model.mil", body: "mil"),
            RepoFile(path: "TextEncoder.mlmodelc/weights/weight.bin", body: "weights"),
            RepoFile(path: "voice_styles/F1.json", body: "f1"),
            RepoFile(path: "tts.json", body: "{}"),
        ]
        let skipped = [
            RepoFile(path: "TextEncoder.mlpackage/Manifest.json", body: "manifest"),
            RepoFile(path: "TextEncoder.mlmodelc2/model.mil", body: "other"),
            RepoFile(path: "voice_styles/F2.json", body: "f2"),
            RepoFile(path: "tts.json.bak", body: "bak"),
            RepoFile(path: "infer.py", body: "print()"),
            RepoFile(path: "TextEncoder.mlmodelc/../../escape.bin", body: "escape"),
        ]
        let hub = Self.serving(wanted + skipped, directories: ["TextEncoder.mlmodelc", "voice_styles"])

        try await snapshot(
            hub,
            include: ["TextEncoder.mlmodelc/", "voice_styles/F1.json", "tts.json"],
            into: destination
        )

        for file in wanted {
            let landed = try String(contentsOf: destination.appendingPathComponent(file.path), encoding: .utf8)
            #expect(landed == file.body, "\(file.path)")
        }
        for file in skipped {
            #expect(exists(destination.appendingPathComponent(file.path)) == false, "\(file.path)")
        }
        #expect(exists(dir.appendingPathComponent("escape.bin")) == false)
        let fetched = Set(hub.requests.compactMap { Self.resolvedPath($0) })
        #expect(fetched == Set(wanted.map(\.path)))
    }

    @Test("the tree listing and every file request name the pinned revision, never main")
    func requestsCarryThePin() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = Self.serving([
            RepoFile(path: "Vocoder.mlmodelc/coremldata.bin", body: "data"),
            RepoFile(path: "unicode_indexer.json", body: "[]"),
        ])

        try await snapshot(hub, include: ["Vocoder.mlmodelc/", "unicode_indexer.json"], into: dir)

        let urls = hub.requests
        let treePaths = urls.filter(Self.isTreeRequest).map(\.path)
        let filePaths = urls.filter { !Self.isTreeRequest($0) }.map(\.path)
        #expect(treePaths == ["/api/models/\(Self.repo)/tree/\(Self.pin)"])
        #expect(filePaths.sorted() == [
            "/\(Self.repo)/resolve/\(Self.pin)/Vocoder.mlmodelc/coremldata.bin",
            "/\(Self.repo)/resolve/\(Self.pin)/unicode_indexer.json",
        ])
        let namesMain = urls.contains { $0.pathComponents.contains("main") }
        #expect(namesMain == false)
    }

    @Test("a subpath snapshot still strips the subpath, reads main and leaves no revision marker")
    func subpathSnapshotUnchanged() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("openai_whisper-tiny", isDirectory: true)
        let whisperRepo = "argmaxinc/whisperkit-coreml"
        let hub = Self.serving(
            [
                RepoFile(path: "openai_whisper-tiny/config.json", body: "{}"),
                RepoFile(path: "openai_whisper-tiny/AudioEncoder.mlmodelc/weights/weight.bin", body: "weights"),
            ],
            repo: whisperRepo
        )

        try await HuggingFaceDownloader.snapshot(
            repo: whisperRepo,
            subpath: "openai_whisper-tiny",
            destination: destination,
            urlSession: hub.makeSession(),
            progress: nil
        )

        let weights = destination.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        #expect(try String(contentsOf: weights, encoding: .utf8) == "weights")
        #expect(exists(destination.appendingPathComponent("config.json")))
        #expect(exists(destination.appendingPathComponent("openai_whisper-tiny")) == false)
        let treePaths = hub.requests.filter(Self.isTreeRequest).map(\.path)
        #expect(treePaths == ["/api/models/\(whisperRepo)/tree/main/openai_whisper-tiny"])
        let filePaths = hub.requests.filter { !Self.isTreeRequest($0) }.map(\.path)
        let prefix = "/\(whisperRepo)/resolve/main/openai_whisper-tiny/"
        let offPrefix = filePaths.filter { !$0.hasPrefix(prefix) }
        #expect(filePaths.count == 2)
        #expect(offPrefix.isEmpty)
        #expect(exists(sidecarURL(in: destination)) == false)
        #expect(exists(markerURL(in: destination)) == false)
    }

    @Test("the sidecar is on disk with the pinned revision before the listing, and a failed fetch leaves it")
    func placeholderSidecarNamesThePin() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = sidecarURL(in: dir)
        let atListing = OSAllocatedUnfairLock<DownloadSidecar?>(initialState: nil)
        let listing = Self.tree([RepoFile(path: "a.bin", body: "aaaa")])
        let hub = HubStub { request in
            guard let url = request.url, Self.isTreeRequest(url) else { return .status(500) }
            let onDisk = try? DownloadSidecar.read(at: sidecar)
            atListing.withLock { $0 = onDisk }
            return .ok(listing)
        }

        var captured: (any Error)?
        do {
            try await snapshot(hub, include: ["a.bin"], into: dir)
        } catch {
            captured = error
        }

        guard case ParolaError.modelDownloadFailed? = captured else {
            Issue.record("expected modelDownloadFailed, got \(String(describing: captured))")
            return
        }
        let placeholder = atListing.withLock { $0 }
        #expect(placeholder?.revision == Self.pin)
        #expect(placeholder?.repo == Self.repo)
        let left = try DownloadSidecar.read(at: sidecar)
        #expect(left.revision == Self.pin)
        #expect(exists(markerURL(in: dir)) == false)
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)
    }

    @Test("a sidecar from another revision is reset: its files go and every file is fetched at the pin")
    func otherRevisionSidecarResets() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("stale".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try Data("dropped".utf8).write(to: dir.appendingPathComponent("gone.bin"))
        try DownloadSidecar(
            repo: Self.repo,
            revision: Self.otherPin,
            files: [
                "a.bin": .init(size: 5, sha256: nil, complete: true),
                "gone.bin": .init(size: 7, sha256: nil, complete: true),
            ]
        ).write(to: sidecarURL(in: dir))
        let hub = Self.serving([RepoFile(path: "a.bin", body: "fresh")])

        try await snapshot(hub, include: ["a.bin"], into: dir)

        #expect(try String(contentsOf: dir.appendingPathComponent("a.bin"), encoding: .utf8) == "fresh")
        let fetched = hub.requests.compactMap { Self.resolvedPath($0) }
        #expect(fetched == ["a.bin"])
        #expect(exists(dir.appendingPathComponent("gone.bin")) == false)
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == Self.pin)
    }

    @Test("a sidecar from the pinned revision resumes without fetching its finished files again")
    func samePinSidecarResumes() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("done!".utf8).write(to: dir.appendingPathComponent("a.bin"))
        try DownloadSidecar(
            repo: Self.repo,
            revision: Self.pin,
            files: ["a.bin": .init(size: 5, sha256: nil, complete: true)]
        ).write(to: sidecarURL(in: dir))
        let hub = Self.serving([
            RepoFile(path: "a.bin", body: "done!"),
            RepoFile(path: "b.bin", body: "bbb"),
        ])

        try await snapshot(hub, include: ["a.bin", "b.bin"], into: dir)

        let fetched = hub.requests.compactMap { Self.resolvedPath($0) }
        #expect(fetched == ["b.bin"])
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == Self.pin)
    }

    @Test("the revision marker goes when a download starts and returns only once every file has landed")
    func markerFollowsSuccess() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.otherPin.utf8).write(to: markerURL(in: dir))
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == Self.otherPin)
        let files = [RepoFile(path: "a.bin", body: "aa"), RepoFile(path: "b.bin", body: "bb")]

        let failing = Self.serving(files) { $0 == "b.bin" ? .status(503) : nil }
        var captured: (any Error)?
        do {
            try await snapshot(failing, include: ["a.bin", "b.bin"], into: dir)
        } catch {
            captured = error
        }
        #expect(captured != nil)
        #expect(exists(markerURL(in: dir)) == false)
        #expect(exists(sidecarURL(in: dir)))
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)

        try await snapshot(Self.serving(files), include: ["a.bin", "b.bin"], into: dir)

        #expect(try String(contentsOf: markerURL(in: dir), encoding: .utf8) == Self.pin)
        #expect(exists(sidecarURL(in: dir)) == false)
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == Self.pin)

        try DownloadSidecar(repo: Self.repo, revision: Self.pin, files: [:]).write(to: sidecarURL(in: dir))
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)
    }

    @Test("progress is weighted by the included files' bytes, never goes back and ends at one")
    func progressIsByteWeighted() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = Self.serving([
            RepoFile(path: "big.bin", body: String(repeating: "b", count: 300)),
            RepoFile(path: "small.bin", body: String(repeating: "s", count: 100)),
            RepoFile(path: "skipped.bin", body: String(repeating: "x", count: 600)),
        ])
        let readings = Readings()

        try await snapshot(hub, include: ["big.bin", "small.bin"], into: dir) { readings.append($0) }

        let all = readings.all
        #expect(all.first == 0)
        #expect(all.contains(0.75))
        #expect(all.last == 1)
        #expect(all == all.sorted())
        #expect(Set(all).count == all.count)
    }

    @Test("cancelling mid-download throws CancellationError and leaves the sidecar")
    func cancelLeavesSidecar() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reachedSecond = TestSignal()
        let hub = Self.serving([
            RepoFile(path: "a.bin", body: "aa"),
            RepoFile(path: "b.bin", body: "bb"),
        ]) { path in
            guard path == "b.bin" else { return nil }
            reachedSecond.fire()
            return .hang
        }
        let session = hub.makeSession()

        let download = GuardedTask {
            try await HuggingFaceDownloader.snapshot(
                repo: Self.repo,
                revision: Self.pin,
                include: ["a.bin", "b.bin"],
                to: dir,
                urlSession: session,
                progress: nil
            )
        }
        guard await reachedSecond.wait("the second file request") else {
            download.cancel()
            return
        }
        download.cancel()

        do {
            _ = try await download.value("the cancelled download")
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        let sidecar = try DownloadSidecar.read(at: sidecarURL(in: dir))
        #expect(sidecar.revision == Self.pin)
        #expect(sidecar.files["a.bin"]?.complete == true)
        #expect(sidecar.files["b.bin"] == nil)
        #expect(exists(markerURL(in: dir)) == false)
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)
    }

    @Test("cancelling while the listing loads throws CancellationError and leaves the placeholder sidecar")
    func cancelDuringListingLeavesSidecar() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reachedListing = TestSignal()
        let hub = HubStub { _ in
            reachedListing.fire()
            return .hang
        }
        let session = hub.makeSession()

        let download = GuardedTask {
            try await HuggingFaceDownloader.snapshot(
                repo: Self.repo,
                revision: Self.pin,
                include: ["a.bin"],
                to: dir,
                urlSession: session,
                progress: nil
            )
        }
        guard await reachedListing.wait("the tree request") else {
            download.cancel()
            return
        }
        download.cancel()

        do {
            _ = try await download.value("the cancelled listing")
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        let sidecar = try DownloadSidecar.read(at: sidecarURL(in: dir))
        #expect(sidecar.revision == Self.pin)
        #expect(sidecar.files.isEmpty)
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)
    }

    @Test(
        "a revision that is not a full commit hash is refused before any request",
        arguments: ["main", "512104b", "v1.0.0", String(repeating: "g", count: 40)]
    )
    func refusesFloatingRevisions(revision: String) async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("pack", isDirectory: true)
        let hub = Self.serving([RepoFile(path: "a.bin", body: "aa")])

        var captured: (any Error)?
        do {
            try await snapshot(hub, include: ["a.bin"], into: destination, revision: revision)
        } catch {
            captured = error
        }

        guard case ParolaError.modelDownloadFailed? = captured else {
            Issue.record("expected modelDownloadFailed, got \(String(describing: captured))")
            return
        }
        #expect(hub.requests.isEmpty)
        #expect(exists(destination) == false)
    }

    @Test(
        "an include entry that could leave the destination is refused before any request",
        arguments: ["", "/", "../escape.bin", "/abs.bin", "voice_styles//F1.json", "voice_styles/./F1.json", "a/../"]
    )
    func refusesUnsafeIncludes(entry: String) async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = Self.serving([RepoFile(path: "a.bin", body: "aa")])

        var captured: (any Error)?
        do {
            try await snapshot(hub, include: ["a.bin", entry], into: dir)
        } catch {
            captured = error
        }

        guard case ParolaError.modelDownloadFailed? = captured else {
            Issue.record("expected modelDownloadFailed, got \(String(describing: captured))")
            return
        }
        #expect(hub.requests.isEmpty)
    }

    @Test("an include entry the listing lacks fails before any file and leaves the sidecar")
    func missingIncludeFails() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hub = Self.serving([RepoFile(path: "a.bin", body: "aa")])

        var captured: (any Error)?
        do {
            try await snapshot(hub, include: ["a.bin", "voice_styles/"], into: dir)
        } catch {
            captured = error
        }

        guard case ParolaError.modelDownloadFailed(let repo, let reason)? = captured else {
            Issue.record("expected modelDownloadFailed, got \(String(describing: captured))")
            return
        }
        #expect(repo == Self.repo)
        #expect(reason.contains("voice_styles/"))
        let fetched = hub.requests.compactMap { Self.resolvedPath($0) }
        #expect(fetched.isEmpty)
        #expect(exists(sidecarURL(in: dir)))
        #expect(HuggingFaceDownloader.installedRevision(at: dir) == nil)
    }

    @Test("a listing split across pages is followed through its cursor at the same revision")
    func listingFollowsPages() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cursor = "eyJmaWxlIjoiYS5iaW4ifQ%3D%3D"
        let firstPage = Self.tree([RepoFile(path: "a.bin", body: "aa")])
        let secondPage = Self.tree([RepoFile(path: "b.bin", body: "bb")])
        let next = "<https://huggingface.co/api/models/\(Self.repo)/tree/\(Self.pin)?recursive=true&cursor=\(cursor)>; rel=\"next\""
        let hub = HubStub { request in
            guard let url = request.url else { return .status(400) }
            guard Self.isTreeRequest(url) else {
                return Self.resolvedPath(url) == "a.bin" ? .ok("aa") : .ok("bb")
            }
            return url.absoluteString.contains("cursor=")
                ? .ok(secondPage)
                : .ok(firstPage, headers: ["Link": next])
        }

        try await snapshot(hub, include: ["a.bin", "b.bin"], into: dir)

        #expect(try String(contentsOf: dir.appendingPathComponent("a.bin"), encoding: .utf8) == "aa")
        #expect(try String(contentsOf: dir.appendingPathComponent("b.bin"), encoding: .utf8) == "bb")
        let pages = hub.requests.filter(Self.isTreeRequest).map(\.absoluteString)
        let base = "https://huggingface.co/api/models/\(Self.repo)/tree/\(Self.pin)?recursive=true"
        #expect(pages == [base, base + "&cursor=\(cursor)"])
    }
}

/// Serves canned Hugging Face replies per session; `.hang` never answers, so only a cancel ends the request.
final class HubStub: Sendable {
    enum Reply: Sendable {
        case respond(status: Int, body: Data, headers: [String: String])
        case hang

        static func ok(_ text: String, headers: [String: String] = [:]) -> Reply {
            .respond(status: 200, body: Data(text.utf8), headers: headers)
        }

        static func status(_ code: Int) -> Reply {
            .respond(status: code, body: Data(), headers: [:])
        }
    }

    fileprivate static let header = "X-Hub-Stub-ID"
    private static let registry = OSAllocatedUnfairLock(initialState: [UUID: HubStub]())

    private let route: @Sendable (URLRequest) -> Reply
    private let seen = OSAllocatedUnfairLock(initialState: [URL]())

    init(_ route: @escaping @Sendable (URLRequest) -> Reply) {
        self.route = route
    }

    var requests: [URL] { seen.withLock { $0 } }

    func makeSession() -> URLSession {
        let id = UUID()
        Self.registry.withLock { $0[id] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubStubProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id.uuidString]
        return URLSession(configuration: configuration)
    }

    fileprivate static func stub(for request: URLRequest) -> HubStub? {
        guard let raw = request.value(forHTTPHeaderField: header), let id = UUID(uuidString: raw) else { return nil }
        return registry.withLock { $0[id] }
    }

    fileprivate func reply(to request: URLRequest) -> Reply {
        if let url = request.url { seen.withLock { $0.append(url) } }
        return route(request)
    }
}

private final class HubStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: HubStub.header) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = HubStub.stub(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard case .respond(let status, let body, let headers) = stub.reply(to: request) else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
