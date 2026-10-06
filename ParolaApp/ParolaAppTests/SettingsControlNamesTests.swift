import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation
import ParolaTestSupport

@MainActor
@Suite("Settings control names", .serialized)
struct SettingsControlNamesTests {
    private static let controlRoles: Set<String> = [
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.radioGroup.rawValue,
        NSAccessibility.Role.slider.rawValue,
    ]

    /// The panes left out open the microphone, start the updater or run yt-dlp as they appear.
    private static let walkedRoutes = SettingsRoute.allCases.filter {
        ![.microphone, .updates, .integrations, .localModels, .about].contains($0)
    }

    @ViewBuilder
    private func pane(_ route: SettingsRoute) -> some View {
        switch route {
        case .general: GeneralPane()
        case .customization: CustomizationPane()
        case .watchedFolders: WatchedFoldersPane()
        case .recordMeetings: RecordMeetingsPane()
        case .shortcuts: ShortcutsPane()
        case .liveCaptions: LiveCaptionsPane()
        case .dictation: DictationPane()
        case .snippets: SnippetsPane()
        case .corrections: CorrectionsPane()
        case .transcriptionDefaults: TranscriptionDefaultsPane()
        case .translation: TranslationPane()
        case .people: PeoplePane()
        case .ignoredSegments: IgnoredSegmentsPane()
        case .findReplace: FindReplacePane()
        case .exportFormats: ExportFormatsPane()
        case .batchExport: BatchExportSettingsPane()
        case .autoExport: AutoExportPane()
        case .sendTo: SendToPane()
        case .aiServices: AIServicesPane()
        case .prompts: PromptsPane()
        case .automation: AutomationPane()
        case .advanced: AdvancedPane()
        case .microphone, .updates, .integrations, .localModels, .about: EmptyView()
        }
    }

    @Test("every switch, pop-up and slider on a Settings pane has a VoiceOver name")
    func everyControlIsNamed() {
        let model = AppModel(bootstrap: AppBootstrap(
            mode: .test, library: makeTempLibraryURL("settings-names"), defaultsOverride: temporaryDefaults(),
            sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
        ))
        model.ignoredSegmentRules = [IgnoredSegmentRule(pattern: "uh")]
        model.findReplaceRules = [FindReplaceRule(find: "magazzino", replace: "deposito")]
        model.correctionRules = [CorrectionRule(from: "github", to: "GitHub")]
        model.snippets = [Snippet(trigger: "brb", replacement: "be right back")]
        model.setDestinations([.obsidianFolder(ObsidianVaultFolderDestination(
            name: "Vault", autoSend: false, vaultBookmark: Data([0x01]), vaultPath: "/tmp/parola-settings-names/Vault"
        ))])
        let captions = LiveCaptionsController(showsPanel: false)
        var walked = 0
        for route in Self.walkedRoutes {
            let hosted = HostedWindow(
                ScrollView { pane(route).padding() }
                    .environment(model)
                    .environment(captions),
                width: 900, height: 2400
            )
            defer { hosted.close() }
            let controls = HostedAccessibility.elements(in: hosted.host).filter { Self.controlRoles.contains($0.role ?? "") }
            walked += controls.count
            for control in controls where control.name == nil {
                Issue.record("\(route.rawValue): unnamed \(control.role ?? "control") \(control.identifier ?? "")")
            }
        }
        #expect(walked > 60, "the walk found \(walked) controls; the panes didn't render")
    }

    /// Local Models stays out of the walk above (its `.task` scans the model store), so its Sort
    /// chip is named directly instead.
    @Test("the Local Models sort chip is named for VoiceOver on its own")
    func localModelsSortChipIsNamed() {
        let pane = ModelsSettingsPane()
        let hosted = HostedWindow(pane.sortMenu, width: 80, height: 80)
        defer { hosted.close() }
        let controls = HostedAccessibility.elements(in: hosted.host).filter { Self.controlRoles.contains($0.role ?? "") }
        #expect(controls.isEmpty == false, "the sort chip didn't render")
        for control in controls {
            #expect(control.name != nil, "unnamed \(control.role ?? "control")")
        }
    }
}
