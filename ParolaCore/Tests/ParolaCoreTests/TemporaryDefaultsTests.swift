import Foundation
import Testing
import ParolaTestSupport

@Suite("Temporary defaults sweeper")
struct TemporaryDefaultsTests {
    @Test("the sweeper removes the plists it was given and nothing else")
    func removesOnlyTheListedPlists() async throws {
        let files = FileManager.default
        // A space and an apostrophe: the sweeper reads its list line by line for exactly this.
        let root = files.temporaryDirectory
            .appending(path: "parola sweeper's plists \(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let doomed = (0..<3).map { root.appending(path: "test-\($0)-\(UUID().uuidString).plist") }
        let bystander = root.appending(path: "keep me.plist")
        for url in doomed + [bystander] { try Data("x".utf8).write(to: url) }

        let list = try #require(
            TemporarySuites.sweep(
                plists: doomed.map(\.path), listDirectory: root, interval: 0.1, passes: 50
            )
        )

        let swept = await poll { doomed.allSatisfy { !files.fileExists(atPath: $0.path) } }
        #expect(swept, "the sweeper left plists behind")
        #expect(files.fileExists(atPath: bystander.path), "the sweeper deleted a file it was not given")

        let finished = await poll { !files.fileExists(atPath: list.path) }
        #expect(finished, "the sweeper kept its list file, so it gave up with files still on disk")
    }

    private func poll(
        budget: Duration = .seconds(10), until condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
