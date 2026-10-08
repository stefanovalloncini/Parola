import Foundation
import Testing
@testable import Parola

@Suite("Transcript and View menus")
struct TranscriptMenuTests {
    private func source(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/TranscriptMenuTests.swift",
            with: "ParolaApp/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("Jump to Time… and Show Chapters are Transcript menu commands, with keys")
    func pagePopoversHaveMenuCommands() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Jump to Time…") { model.jumpToTimeRequests &+= 1 } .keyboardShortcut("j", modifiers: [.command])"#))
        #expect(commands.contains(#"Button("Show Chapters") { model.revealInInspector(.chapters) } .keyboardShortcut("o", modifiers: [.command, .shift])"#))
        #expect(!commands.contains("Show Outline"))
    }

    @Test("Rename… sits in the Transcript menu and asks for the page's one rename")
    func renameIsATranscriptCommand() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Rename…") { model.renameRequests &+= 1 } .disabled(!model.canRenameOpenTranscript)"#))
    }

    @Test("Transcribe Again runs the same settings from the Transcript menu and the inspector's Details, through one alert")
    func transcribeAgainHasMenuAndInfoDoors() throws {
        let menu = try source("Views/Transcript/TranscribeAgainMenus")
        let same = try #require(menu.range(of: #"Menu("Transcribe Again") { Button("Same Model and Language") { model.askToTranscribeAgain() }"#))
        let models = try #require(menu.range(of: "TranscribeAgainModelChoices(model: model, variants: variants)"))
        let languages = try #require(menu.range(of: #"Menu("Language") { TranscribeAgainLanguageChoices("#))
        #expect(same.lowerBound < models.lowerBound && models.lowerBound < languages.lowerBound)
        let info = try source("Views/Transcript/TranscriptDetails")
        #expect(info.contains(#"Button("Transcribe Again") { model.askToTranscribeAgain() }"#))
        #expect(info.contains("TranscribeAgainModelChoices(model: model, variants: variants)"))
        #expect(info.contains("TranscribeAgainLanguageChoices(model: model, variants: variants)"))
        #expect(!info.contains(".alert("), "the alert lives with the window, so the menu reaches it with the inspector hidden")
        let sheets = try source("Views/ContentSheets")
        #expect(sheets.contains(#"Button("Transcribe Again") { model.confirmTranscribeAgain() }"#))
        let speakers = try source("Views/SpeakersSheet")
        #expect(speakers.contains("Transcript ▸ Transcribe Again"))
    }

    @Test("the layouts are a checked pair in the View menu, with keys, named as the toolbar's Aa names them")
    func layoutsAreViewCommands() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Toggle("Paragraphs", isOn: layoutBinding(.transcript)) .keyboardShortcut("1", modifiers: [.command, .control])"#))
        #expect(commands.contains(#"Toggle("Segments", isOn: layoutBinding(.segments)) .keyboardShortcut("2", modifiers: [.command, .control])"#))
        let format = try source("Views/Transcript/TranscriptToolbar")
        #expect(format.contains(#"Text("Paragraphs").tag(TranscriptDisplayMode.transcript)"#))
        #expect(format.contains(#"Text("Segments").tag(TranscriptDisplayMode.segments)"#))
    }

    @Test("a segment has one speaker menu wherever it shows, and No Speaker names the empty choice everywhere")
    func oneSpeakerMenuPerSegment() throws {
        let card = try source("Views/Transcript/SegmentCard")
        #expect(card.components(separatedBy: "Menu(\"").count == 2, "one titled submenu: the speaker menu")
        #expect(card.contains(#"return Menu("Assign This Segment to")"#))
        #expect(card.components(separatedBy: "assignSegmentMenu").count == 6)
        #expect(card.contains(#"Button("New Person…")"#))
        #expect(card.contains(#"Button("No Speaker") { model.assignSpeaker(nil, toSegmentID: segment.id) }"#))
        let inspector = try source("Views/Transcript/OverviewPeople")
        #expect(inspector.contains(#"Button("No Speaker") { Task { await model.clearSpeaker(label: label) } }"#))
        let popover = try source("Views/People/AssignSpeakerPopover")
        #expect(popover.contains(#"footerButton("No Speaker")"#))
    }

    @Test("the People sheet's field adds a person; the inspector names someone new only through a row's New Person…")
    func addAPersonMeansOneThing() throws {
        let inspector = try source("Views/Transcript/OverviewPeople")
        #expect(!inspector.contains("TextField(\"Add"))
        #expect(!inspector.contains("Add a speaker…"))
        #expect(inspector.contains("model.assignSpeaker(label: label, toNewPersonNamed: draftName)"))
        let sheet = try source("Views/People/ManagePeopleSheet")
        #expect(sheet.contains(#"TextField("Add a person…""#))
    }

    @Test("both people menus go past ten, and the inspector's can name someone new")
    func peopleMenusHaveMore() throws {
        let card = try source("Views/Transcript/SegmentCard")
        #expect(card.contains("MorePeopleMenu(people: choices.people.more)"))
        let inspector = try source("Views/Transcript/OverviewPeople")
        #expect(inspector.contains("MorePeopleMenu(people: choices.more)"))
        #expect(inspector.contains(#"Button("New Person…")"#))
        #expect(inspector.contains("model.assignSpeaker(label: label, toNewPersonNamed: draftName)"))
    }

    @Test("the display options are checked View menu items")
    func displayOptionsAreViewToggles() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Toggle("Compact Text", isOn: $model.transcriptCompact) .disabled(!model.mainTranscriptCommandsEnabled || !model.compactTextApplies)"#))
        #expect(commands.contains(#"Toggle("Show Favorites Only", isOn: $model.favoritesOnly)"#))
        #expect(commands.contains(#"Toggle("Subtitle Warnings", isOn: $model.showSubtitleQC)"#))
    }

    /// The Transcript menu's body, from its first item to the end of the file.
    private func transcriptMenu() throws -> String {
        let commands = try source("Views/AppCommands")
        let start = try #require(commands.range(of: "struct TranscriptCommands: View"))
        return String(commands[start.lowerBound...])
    }

    @Test("the Transcript menu reads in groups: go, edit, copy, share, then windows")
    func transcriptMenuIsGrouped() throws {
        let menu = try transcriptMenu()
        let groups = [
            [#"Button("Back")"#, #"Button("Jump to Next Speaker")"#, #"Button("Jump to Time…")"#, #"Button("Show Chapters")"#],
            [
                #"Button("Rename…")"#, "TranscribeAgainMenu(model: model)", "TranslateMenu(model: model)",
                #"Button("Edit Segment") { model.editFocusedSegment() }"#,
                #"Button("Add Note…") { model.noteFocusedSegment() }"#, #"Button("Favorite Segment")"#,
                #"Button("Split Segment") { model.splitFocusedSegment() }"#, "MergeSegmentMenuItem(model: model",
                #"Button("Delete Segment") { model.deleteFocusedSegment() }"#, #"Button("Rename Speakers…")"#,
            ],
            [
                #"Button("Copy Transcript")"#, #"Button("Copy with Timestamps")"#, #"Button("Copy as Markdown")"#,
                #"Button("Copy as SRT")"#, #"Button("Copy Favorites")"#,
            ],
            [
                #"Button("Export…")"#, #"Menu("Export As")"#, #"Button("Export Segment Notes…")"#,
                #"Button("Send via Mail…")"#, #"Button("Share…")"#, "SendToMenu(", #"Button("Print Transcript…")"#,
                #"Button("Burn Subtitles into Video…")"#,
            ],
            [#"Button("Open in New Window")"#],
        ]
        var offsets: [[Int]] = []
        for group in groups {
            var groupOffsets: [Int] = []
            for title in group {
                let range = try #require(menu.range(of: title), "missing \(title)")
                groupOffsets.append(menu.distance(from: menu.startIndex, to: range.lowerBound))
            }
            offsets.append(groupOffsets)
        }
        let flat = offsets.flatMap { $0 }
        #expect(flat == flat.sorted(), "items out of order")
        for (earlier, later) in zip(offsets, offsets.dropFirst()) {
            let lo = menu.index(menu.startIndex, offsetBy: earlier.max() ?? 0)
            let hi = menu.index(menu.startIndex, offsetBy: later.min() ?? 0)
            #expect(menu[lo..<hi].contains("Divider()"), "no divider before \(later)")
        }
        for group in offsets {
            let lo = menu.index(menu.startIndex, offsetBy: group.min() ?? 0)
            let hi = menu.index(menu.startIndex, offsetBy: group.max() ?? 0)
            #expect(!menu[lo..<hi].contains("Divider()"))
        }
    }

    @Test("Copy has one name in the Transcript menu, Copy Transcript, as in Share")
    func copyHasOneName() throws {
        let menu = try transcriptMenu()
        #expect(!menu.contains("Copy Plain Text"))
        #expect(menu.contains(#"Button("Copy Transcript") { Task { await model.copyTranscript() } }"#))
    }

    @Test("Rename Speakers… sits with the transcript, and Chat ends with Manage Prompts…")
    func renameSpeakersSitsWithTheTranscript() throws {
        let commands = try transcriptMenu()
        #expect(commands.contains(#"Button("Rename Speakers…") { model.showingSpeakersSheet = true }"#))
        let inspector = try source("Views/Transcript/OverviewPeople")
        #expect(inspector.contains(#"Button("Rename Speakers…") { model.showingSpeakersSheet = true }"#))
        let chat = try source("Views/Chat/ChatPane")
        #expect(chat.contains(#"Button("Manage Prompts…") { model.openSettings(route: .prompts) }"#))
    }

    @Test("translating has a menu path, and the strip and the Details row offer the same targets")
    func translationHasAMenuPath() throws {
        let menu = try source("Views/Transcript/TranslateMenu")
        #expect(menu.contains(#"Menu("Translate To") { ForEach(targets, id: \.code) { target in Button(target.name) { Task { await model.translateTranscript(to: target.code) } }"#))
        #expect(menu.contains(#"Button("Remove Translation") { Task { await model.removeTranslation() } }"#))
        #expect(menu.contains("TranslationTargets.named( from: model.translationCoordinator.knownTargets ?? SupportedLanguages.codes"))
        let strip = try source("Views/Transcript/TranslationStrip")
        #expect(!strip.contains("characters"))
        #expect(strip.contains("TranslationTargets.named(from: targets, excluding: model.transcript?.language)"))
        let details = try source("Views/Transcript/TranscriptDetails")
        #expect(details.contains("TranslationTargets.named( from: model.translationCoordinator.knownTargets ?? SupportedLanguages.codes"))
        #expect(details.contains(#"Button("Remove Translation") { Task { await model.removeTranslation() } }"#))
    }

    @Test("the translation targets leave out the transcript's own language and read in name order")
    @MainActor
    func translationTargetsSkipTheSource() {
        let targets = TranslationTargets.named(from: ["it", "en", "fr"], excluding: "EN")
        #expect(targets.map(\.code) == ["fr", "it"])
        #expect(TranslationTargets.named(from: ["it", "en"], excluding: "auto").count == 2)
    }

    @Test("the transcript view says things in plain words: no QC, no Re-Extract, no Engine, no chars")
    func plainWordsForJargon() throws {
        let format = try source("Views/Transcript/TranscriptToolbar")
        #expect(format.contains(#"Toggle("Subtitle Warnings", isOn: $model.showSubtitleQC)"#))
        #expect(!format.contains("Subtitle QC"))
        let info = try source("Views/Transcript/TranscriptDetails")
        #expect(!info.contains(#"label: "Engine""#))
        let items = try source("Views/Transcript/OverviewActionItems")
        #expect(!items.contains("Re-Extract"))
        let summary = try source("Views/Summary/SummaryPane")
        #expect(!summary.contains("chars"))
    }

    @Test("the Playback menu holds speed and Skip Silences")
    func playbackMenuHasEveryControl() throws {
        let commands = try source("Views/AppCommands")
        let start = try #require(commands.range(of: "struct PlaybackCommands: View"))
        let end = try #require(commands.range(of: "struct DictationCommands: View"))
        let menu = String(commands[start.lowerBound..<end.lowerBound])
        #expect(menu.contains(#"Picker("Playback Speed", selection: rate)"#))
        #expect(menu.contains("ForEach(PlaybackSpeed.all, id: \\.self)"))
        #expect(menu.contains(#"Toggle("Skip Silences", isOn: $model.skipSilences)"#))
    }

    @Test("next and previous segment have menu keys and one glyph pair in the mini player")
    func segmentStepsShareOneGlyph() throws {
        let menu = try transcriptMenu()
        #expect(menu.contains(#"Button("Next Segment") { model.stepSegment(forward: true) } .keyboardShortcut(.downArrow, modifiers: [.command, .option])"#))
        #expect(menu.contains(#"Button("Previous Segment") { model.stepSegment(forward: false) } .keyboardShortcut(.upArrow, modifiers: [.command, .option])"#))
        let mini = try source("Views/MiniPlayerWindow")
        #expect(mini.contains("Image(systemName: SegmentStep.previous.symbol)"))
        #expect(mini.contains("Image(systemName: SegmentStep.next.symbol)"))
    }
}
