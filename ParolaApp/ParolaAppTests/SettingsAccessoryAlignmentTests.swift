import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Settings accessory alignment", .serialized)
struct SettingsAccessoryAlignmentTests {
    private static let controlRoles: Set<String> = [
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
    ]

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-settings-alignment-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("settings-alignment"))
    }

    /// The trailing edge of each row's last switch or pop-up, in window points.
    private func accessoryEdges(of pane: some View) -> [CGFloat] {
        let hosted = HostedWindow(pane, width: 760, height: 2400)
        defer { hosted.close() }
        let controls = HostedAccessibility.elements(in: hosted.host)
            .filter { Self.controlRoles.contains($0.role ?? "") && $0.identifier != nil }
        let rows = Dictionary(grouping: controls) { ($0.frame.midY / 8).rounded() }
        return rows.values.compactMap { row in row.map(\.frame.maxX).max() }
    }

    private func expectFlush(_ pane: some View, count: Int, _ label: String) {
        let edges = accessoryEdges(of: pane)
        #expect(edges.count >= count, "\(label): found \(edges.count) accessories")
        guard let trailing = edges.max() else { return }
        for edge in edges {
            #expect(abs(edge - trailing) <= 2, "\(label): an accessory ends at \(edge), the row at \(trailing)")
        }
    }

    @Test("transcription defaults accessories share one trailing edge")
    func transcriptionDefaults() {
        withIsolatedDefaults { defaults in
            expectFlush(TranscriptionDefaultsPane().environment(makeModel(defaults)), count: 2, "transcription defaults")
        }
    }

    @Test("dictation accessories share one trailing edge")
    func dictation() {
        withIsolatedDefaults { defaults in
            expectFlush(DictationPane().environment(makeModel(defaults)), count: 2, "dictation")
        }
    }

    @Test("microphone accessories share one trailing edge")
    func microphone() {
        withIsolatedDefaults { defaults in
            expectFlush(MicrophonePane().environment(makeModel(defaults)), count: 2, "microphone")
        }
    }

    @Test("People: each person's menu ends on the form's trailing edge, not inside a card of its own")
    func people() async {
        let model = PeopleTestSupport.makeModel("people-pane-alignment")
        await model.addPerson(named: "Ada")
        await model.addPerson(named: "Grace")
        expectFlush(PeoplePane().environment(model), count: 3, "people")
    }

    @Test("the Microphone pane's level preview opens the real microphone in the app, never in the test host")
    func microphonePreviewStaysShutInTheTestHost() {
        #expect(MicrophonePane.opensPreview(environment: [:]))
        #expect(!MicrophonePane.opensPreview(environment: ["XCTestConfigurationFilePath": ""]))
        #expect(!MicrophonePane.opensPreview(), "this process is a test host")
    }
}
