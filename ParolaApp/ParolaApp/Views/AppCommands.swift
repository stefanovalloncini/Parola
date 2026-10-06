import SwiftUI
import AppKit
import ParolaCore

// One view per menu: a predicate read inline in `.commands` makes the whole App scene depend on it.

struct HelpCommands: View {
    let model: AppModel
    let showShortcuts: () -> Void

    var body: some View {
        Button("Show Introduction") { model.restartIntroduction() }
            .disabled(model.introduction.isPresented || model.downloadBlockedReason != nil)
        Divider()
        Button("Keyboard Shortcuts…", action: showShortcuts)
            .keyboardShortcut("/", modifiers: [.command])
        Button("Copy Model Details") { model.copyModelDetails() }
            .axLeaf("Menu.Help.CopyModelDetails")
        Button("Send Feedback") {
            if let url = SupportLinks.feedbackMailto {
                NSWorkspace.shared.open(url)
            }
        }
        Button("Export Diagnostics…") {
            Task {
                do {
                    try await model.exportDiagnostics()
                } catch {
                    model.phase = .failed(
                        message: AppModel.diagnosticsExportFailureMessage(for: error)
                    )
                }
            }
        }
    }
}

struct FileCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.features.isEnabled(.micRecording) {
            Button("New Recording") { record(.microphone) }
                .keyboardShortcut("n")
                .disabled(!model.canStartTake(.microphone) || model.introduction.isPresented)
                .axLeaf("Menu.File.NewRecording")
        }
        if model.features.isEnabled(.meetings) {
            Button("New System Audio Recording") { record(.systemAudio) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!model.canStartTake(.systemAudio) || model.introduction.isPresented)
                .axLeaf("Menu.File.NewSystemAudioRecording")
        }
        Button("Open…") { model.presentOpenPanel() }
            .keyboardShortcut("o")
            .disabled(model.introduction.isPresented)
        Menu("Open Recent") {
            let recents = model.recentFiles
            if recents.isEmpty {
                Text("No Recent Files")
            } else {
                ForEach(recents, id: \.self) { url in
                    Button(url.lastPathComponent) { model.openRecentFile(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecentFiles() }
            }
        }
        .disabled(model.introduction.isPresented)
        Button("Save As Parola Document…") { model.saveProjectDocument() }
            .keyboardShortcut("s")
            .disabled(!model.hasTranscript)
    }

    /// From a viewer, Settings or with no window open, the take's Stop still has to be on screen.
    private func record(_ source: AppModel.RecordSource) {
        model.showMainWindow { openWindow(id: MainWindowScene.id) }
        model.startRecording(source: source)
    }
}

/// ⌘⏎ stops a take that can still stop, except in the chat composer, where it sends: one key, one owner at a time.
enum CommandReturn {
    static let shortcut = KeyboardShortcut(.return, modifiers: .command)

    nonisolated static func stops(takeCanStop: Bool, composerFocused: Bool) -> Bool {
        takeCanStop && !composerFocused
    }
}

/// What the Recording menu offers for the take as it stands.
struct RecordingMenuState: Equatable {
    var canEnd: Bool
    /// The take is still starting, so ending it cancels it and the item says so.
    var cancels: Bool
    var canCapture: Bool
    var canDiscard: Bool
    var resumes: Bool
    var canShow: Bool
    var stopOwnsCommandReturn: Bool

    init(take: RecordingSession?, showsRecording: Bool, composerFocused: Bool) {
        canEnd = TakeRemote.canEnd(take)
        cancels = take?.isArming ?? false
        canCapture = take?.isCapturing ?? false
        canDiscard = TakeRemote.canDiscard(take)
        resumes = take?.isPaused ?? false
        canShow = showsRecording
        stopOwnsCommandReturn = CommandReturn.stops(takeCanStop: canEnd, composerFocused: composerFocused)
    }
}

/// The take's controls from any page: the calls the Stage, the menu bar item and the pill make.
struct RecordingCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let menu = RecordingMenuState(
            take: model.recording, showsRecording: model.stageHoldsTake, composerFocused: model.chatComposerHasFocus
        )
        let _ = RecordingMenuRefresher.shared.menuDrew()
        Button(menu.cancels ? "Cancel Recording" : "Stop Recording") { TakeRemote.stopOrCancel(model, cancels: menu.cancels) }
            .keyboardShortcut(menu.stopOwnsCommandReturn ? CommandReturn.shortcut : nil)
            .disabled(!menu.canEnd)
            .axLeaf("Menu.Recording.Stop")
        Button(menu.resumes ? "Resume" : "Pause") { TakeRemote.togglePause(model) }
            .disabled(!menu.canCapture)
            .axLeaf("Menu.Recording.Pause")
        Button("Add Marker") { TakeRemote.addMarker(model) }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(!menu.canCapture)
            .axLeaf("Menu.Recording.AddMarker")
        Button("Discard…") {
            Task { await TakeRemote.discard(model, confirm: TakeRemote.askToDiscard) }
        }
        .disabled(!menu.canDiscard)
        .axLeaf("Menu.Recording.Discard")
        Divider()
        Button("Show Recording") {
            TakeRemote.showParola(model) { model.showMainWindow { openWindow(id: MainWindowScene.id) } }
        }
        .disabled(!menu.canShow)
        .axLeaf("Menu.Recording.ShowRecording")
    }
}

struct ViewCommands: View {
    @Bindable var model: AppModel
    @AppStorage(InspectorVisibility.preferenceKey, store: DefaultsStore.current) private var inspectorPreference = true
    @AppStorage(InspectorVisibility.forcedAtNarrowWidthKey, store: DefaultsStore.current)
    private var inspectorForcedAtNarrowWidth = false

    private var inspectorShows: Bool {
        InspectorVisibility.isVisible(
            preference: inspectorPreference,
            forcedAtNarrowWidth: inspectorForcedAtNarrowWidth,
            isNarrow: model.transcriptPaneIsNarrow
        )
    }

    var body: some View {
        Button("Show Transcript") { model.setTranscriptPaneMode(.transcript) }
            .keyboardShortcut("1", modifiers: [.command])
            .disabled(!model.canShow(.transcript) || model.keyWindowIsViewer)
        Button("Show Summary") { model.setTranscriptPaneMode(.summary) }
            .keyboardShortcut("2", modifiers: [.command])
            .disabled(!model.canShow(.summary) || model.keyWindowIsViewer)
        Button("Show Chat") { model.setTranscriptPaneMode(.chat) }
            .keyboardShortcut("3", modifiers: [.command])
            .disabled(!model.canShow(.chat) || model.keyWindowIsViewer)
        Divider()
        Toggle("Paragraphs", isOn: layoutBinding(.transcript))
            .keyboardShortcut("1", modifiers: [.command, .control])
            .disabled(!model.mainTranscriptCommandsEnabled)
            .axLeaf("Menu.View.Paragraphs")
        Toggle("Segments", isOn: layoutBinding(.segments))
            .keyboardShortcut("2", modifiers: [.command, .control])
            .disabled(!model.mainTranscriptCommandsEnabled)
            .axLeaf("Menu.View.Segments")
        Divider()
        Toggle("Show Translations Side by Side", isOn: $model.translationSideBySide)
            .disabled(!model.hasTranslation)
            .axLeaf("Menu.View.TranslationSideBySide")
        Toggle("Compact Text", isOn: $model.transcriptCompact)
            .disabled(!model.mainTranscriptCommandsEnabled || !model.compactTextApplies)
            .axLeaf("Menu.View.CompactText")
        Toggle("Show Favorites Only", isOn: $model.favoritesOnly)
            .disabled(!model.mainTranscriptCommandsEnabled || (!model.favoritesOnly && !model.selectedEntryHasFavorites))
            .axLeaf("Menu.View.FavoritesOnly")
        Toggle("Subtitle Warnings", isOn: $model.showSubtitleQC)
            .disabled(!model.mainTranscriptCommandsEnabled || model.transcriptDisplayMode != .segments)
            .axLeaf("Menu.View.SubtitleWarnings")
        Divider()
        Button(InspectorVisibility.commandTitle(showing: inspectorShows)) {
            InspectorVisibility.toggle(in: DefaultsStore.current, isNarrow: model.transcriptPaneIsNarrow)
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!model.mainTranscriptCommandsEnabled)
        .axLeaf("Menu.View.Inspector")
        Toggle("Always on Top", isOn: $model.mainWindowAlwaysOnTop)
        MiniPlayerCommand()
        Divider()
        Button("Statistics") { model.openStatistics() }
            .disabled(model.introduction.isPresented)
            .axLeaf("Menu.View.Statistics")
    }

    private func layoutBinding(_ layout: TranscriptDisplayMode) -> Binding<Bool> {
        Binding(
            get: { model.transcriptDisplayMode == layout },
            set: { _ in model.showTranscriptLayout(layout) }
        )
    }
}

struct EditCommands: View {
    let model: AppModel

    var body: some View {
        Button("Find…") { model.beginFind() }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(!model.findCommandEnabled)
        Button("Find Next") { model.goToNextMatchInKeyWindow() }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(!model.keyWindowFindIsOpen || !model.keyWindowHasMatches)
        Button("Find Previous") { model.goToPreviousMatchInKeyWindow() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!model.keyWindowFindIsOpen || !model.keyWindowHasMatches)
        Button("Replace All") { model.replaceAllMatches() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!model.transcriptFindBarShows || !model.hasMatches || model.keyWindowIsViewer)
        Divider()
        let searchTitle = model.route.searchTitle()
        Button(searchTitle ?? String(localized: "Search Library")) { model.focusLibrarySearch() }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(model.introduction.isPresented || searchTitle == nil)
            .axLeaf("Menu.Edit.SearchLibrary")
        Divider()
        Button("Auto-Detect Language") { model.selectedLanguage = nil }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        FocusChatComposerCommand()
    }
}

struct PlaybackCommands: View {
    @Bindable var model: AppModel
    @AppStorage("playbackRate", store: DefaultsStore.current) private var mainRate: Double = 1.0

    var body: some View {
        Button(model.keyWindowIsPlaying ? "Pause" : "Play") { model.togglePlayPauseInKeyWindow() }
            .disabled(!model.keyWindowHasPlayer)
            .help(Self.keyHelp(String(localized: "Space")))
        Button("Skip Back 5 Seconds") { model.skipInKeyWindow(by: PlaybackSkip.back.seconds) }
            .disabled(!model.keyWindowHasPlayer)
            .help(Self.keyHelp("⌘←"))
        Button("Skip Forward 5 Seconds") { model.skipInKeyWindow(by: PlaybackSkip.forward.seconds) }
            .disabled(!model.keyWindowHasPlayer)
            .help(Self.keyHelp("⌘→"))
        Divider()
        Picker("Playback Speed", selection: rate) {
            ForEach(PlaybackSpeed.all, id: \.self) { speed in
                Text(verbatim: PlaybackSpeed.label(speed)).tag(speed)
            }
        }
        .disabled(!model.keyWindowHasPlayer)
        .axLeaf("Menu.Playback.Speed")
        Toggle("Skip Silences", isOn: $model.skipSilences)
            .disabled(!model.keyWindowHasPlayer || model.keyWindowIsViewer)
            .axLeaf("Menu.Playback.SkipSilences")
    }

    /// A key monitor owns Space and ⌘←/⌘→ so text fields keep them; a menu key equivalent would take them first.
    static func keyHelp(_ keys: String) -> String {
        String(localized: "Shortcut: \(keys)")
    }

    private var rate: Binding<Double> {
        Binding(
            get: { model.keyViewerSession?.rate ?? mainRate },
            set: { speed in
                if let session = model.keyViewerSession {
                    session.rate = speed
                } else {
                    mainRate = speed
                    model.applyPlaybackRate(speed)
                }
            }
        )
    }
}

struct CaptionsCommands: View {
    let model: AppModel
    let scratchpad: ScratchpadController
    let liveCaptions: LiveCaptionsController

    var body: some View {
        if model.features.isEnabled(.dictation) {
            Button(scratchpad.isOpen ? "Hide Scratchpad" : "Show Scratchpad") {
                scratchpad.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model.introduction.isPresented)
            let dictationItem = MenuBarController.dictationMenuItem(for: model.dictationState)
            Button(dictationItem.title) {
                dictationItem.stops ? model.stopDictationFromIntent() : model.startDictationFromIntent()
            }
            .disabled(model.introduction.isPresented)
        }
        if model.features.isEnabled(.liveCaptions) {
            Divider()
            Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                model.toggleLiveCaptions()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(
                !liveCaptions.isActive
                    && (model.introduction.isPresented || model.liveCaptionsUnavailableReason != nil)
            )
            Toggle("Translate to English", isOn: translateBinding)
            Divider()
            Button(liveCaptions.isPresenterOpen ? "Exit Presenter" : "Enter Presenter Mode") {
                liveCaptions.togglePresenter()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Save Captions…") { liveCaptions.saveCaptionsHistory() }
                .disabled(!liveCaptions.hasHistory)
        }
    }

    private var translateBinding: Binding<Bool> {
        Binding(
            get: { model.liveCaptionsTranslate },
            set: { model.liveCaptionsTranslate = $0 }
        )
    }
}

struct TranscriptCommands: View {
    let model: AppModel

    private var favoriteSegmentHelp: LocalizedStringKey {
        if model.selectedEntryID == nil { return "Save the transcript to the library first" }
        return segmentHelp
    }

    private var segmentHelp: LocalizedStringKey {
        model.hasCurrentSegment ? "" : "Click a segment or play the audio first"
    }

    private var segmentCommandsDisabled: Bool {
        !model.mainTranscriptCommandsEnabled || !model.hasCurrentSegment
    }

    var body: some View {
        Button("Back") { model.returnToOrigin() }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!model.canReturnToOrigin)
        Button("Next Segment") { model.stepSegment(forward: true) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!model.mainTranscriptCommandsEnabled || !model.keyWindowHasPlayer)
            .axLeaf("Menu.Transcript.NextSegment")
        Button("Previous Segment") { model.stepSegment(forward: false) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!model.mainTranscriptCommandsEnabled || !model.keyWindowHasPlayer)
            .axLeaf("Menu.Transcript.PreviousSegment")
        Button("Jump to Next Speaker") { model.jumpToNextSpeaker() }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Jump to Time…") { model.jumpToTimeRequests &+= 1 }
            .keyboardShortcut("j", modifiers: [.command])
            .disabled(!model.mainTranscriptCommandsEnabled)
            .axLeaf("Menu.Transcript.JumpToTime")
        Button("Show Outline") { model.outlineRequests &+= 1 }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!model.mainTranscriptCommandsEnabled)
            .axLeaf("Menu.Transcript.ShowOutline")
        Divider()
        Button("Rename…") { model.renameRequests &+= 1 }
            .disabled(!model.canRenameOpenTranscript)
            .axLeaf("Menu.Transcript.Rename")
        Button("Edit Segment") { model.editFocusedSegment() }
            .disabled(segmentCommandsDisabled)
            .help(segmentHelp)
            .axLeaf("Menu.Transcript.EditSegment")
        Button("Add Note…") { model.noteFocusedSegment() }
            .disabled(segmentCommandsDisabled || model.selectedEntryID == nil)
            .help(favoriteSegmentHelp)
            .axLeaf("Menu.Transcript.AddNote")
        Button("Favorite Segment") {
            guard let id = model.focusedSegmentIDForCommands else { return }
            model.toggleSegmentFavorite(id)
        }
        .keyboardShortcut("d", modifiers: [.command])
        .disabled(segmentCommandsDisabled || model.selectedEntryID == nil)
        .help(favoriteSegmentHelp)
        Button("Delete Segment") { model.deleteFocusedSegment() }
            .disabled(segmentCommandsDisabled)
            .help(segmentHelp)
            .axLeaf("Menu.Transcript.DeleteSegment")
        Button("Manage People…") { model.showingPeopleSheet = true }
        Divider()
        Button("Copy Transcript") { Task { await model.copyTranscript() } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Copy with Timestamps") { model.copyTranscriptToPasteboard(withTimestamps: true, pasteboard: .general) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Copy as Markdown") { model.copyTranscriptAsFormat(.md) }
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Copy as SRT") { model.copyTranscriptAsFormat(.srt) }
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Copy Favorites") { model.copyTranscriptToPasteboard(withTimestamps: true, favoritesOnly: true, pasteboard: .general) }
            .disabled(!model.selectedEntryHasFavorites || model.keyWindowIsViewer)
        Divider()
        Button("Export…") { model.openExportSheet() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Menu("Export As") {
            ForEach(Array(model.exportPresets.enumerated()), id: \.element.id) { position, preset in
                Button {
                    model.exportWithPreset(preset.id)
                } label: {
                    ExportPresetChecks.label(preset)
                }
                // ⌘E has always been the one-key export; it follows whichever preset is on top.
                .keyboardShortcut(position == 0 ? KeyboardShortcut("e", modifiers: .command) : nil)
            }
        }
        .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Export Segment Notes…") { model.exportSegmentNotesAsMarkdown() }
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Send via Mail…") { model.shareTranscriptViaMail() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Share…") { model.shareTranscriptAsTextFile() }
            .disabled(!model.mainTranscriptCommandsEnabled)
        if model.destinationsEnabled {
            SendToMenu(model: model, entryID: model.selectedEntryID)
        }
        Button("Print Transcript…") { model.printTranscript() }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(!model.mainTranscriptCommandsEnabled)
        Button("Burn Subtitles into Video…") { model.requestBurnSubtitles() }
            .disabled(!model.mainTranscriptCommandsEnabled || model.burnIsRunning)
        Divider()
        Button("Open in New Window") {
            guard let id = model.selectedEntryID else { return }
            model.openEntryWindow(id)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(model.selectedEntryID == nil || model.keyWindowIsViewer)
        .help(model.selectedEntryID == nil ? "Save the transcript to the library first" : "")
    }
}
