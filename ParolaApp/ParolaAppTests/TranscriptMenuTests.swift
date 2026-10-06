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

    @Test("Jump to Time… and Show Outline open the header's popovers from the menu, with keys")
    func headerPopoversHaveMenuCommands() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Jump to Time…") { model.jumpToTimeRequests &+= 1 } .keyboardShortcut("j", modifiers: [.command])"#))
        #expect(commands.contains(#"Button("Show Outline") { model.outlineRequests &+= 1 } .keyboardShortcut("o", modifiers: [.command, .shift])"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains(".onChange(of: model.jumpToTimeRequests) { _, _ in jumpOpen = true }"))
        #expect(header.contains(".onChange(of: model.outlineRequests) { _, _ in outlineOpen = true }"))
    }

    @Test("Rename… sits in the Transcript menu and on the header title, and both raise the header's rename alert")
    func renameHasMenuAndTitleDoors() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Button("Rename…") { model.renameRequests &+= 1 } .disabled(!model.canRenameOpenTranscript)"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains(".onChange(of: model.renameRequests) { _, _ in beginRename() }"))
        #expect(header.contains(#".contextMenu { Button("Rename…") { beginRename() }"#))
        #expect(header.contains("model.renameOpenTranscript(to: renameDraft)"))
    }

    @Test("Transcribe Again runs the same settings from the Transcript menu and the Info tab, through one alert")
    func transcribeAgainHasMenuAndInfoDoors() throws {
        let menu = try source("Views/Transcript/TranscribeAgainMenus")
        let same = try #require(menu.range(of: #"Menu("Transcribe Again") { Button("Same Model and Language") { model.askToTranscribeAgain() }"#))
        let models = try #require(menu.range(of: "TranscribeAgainModelChoices(model: model, variants: variants)"))
        let languages = try #require(menu.range(of: #"Menu("Language") { TranscribeAgainLanguageChoices("#))
        #expect(same.lowerBound < models.lowerBound && models.lowerBound < languages.lowerBound)
        let info = try source("Views/Transcript/InfoInspector")
        #expect(info.contains(#"Button("Transcribe Again") { model.askToTranscribeAgain() }"#))
        #expect(info.contains("TranscribeAgainModelChoices(model: model, variants: variants)"))
        #expect(info.contains("TranscribeAgainLanguageChoices(model: model, variants: variants)"))
        #expect(!info.contains(".alert("), "the alert lives with the window, so the menu reaches it with the inspector hidden")
        let sheets = try source("Views/ContentSheets")
        #expect(sheets.contains(#"Button("Transcribe Again") { model.confirmTranscribeAgain() }"#))
        let speakers = try source("Views/SpeakersSheet")
        #expect(speakers.contains("Transcript ▸ Transcribe Again"))
    }

    @Test("the layouts are a checked pair in the View menu, with keys, named as the inspector names them")
    func layoutsAreViewCommands() throws {
        let commands = try source("Views/AppCommands")
        #expect(commands.contains(#"Toggle("Paragraphs", isOn: layoutBinding(.transcript)) .keyboardShortcut("1", modifiers: [.command, .control])"#))
        #expect(commands.contains(#"Toggle("Segments", isOn: layoutBinding(.segments)) .keyboardShortcut("2", modifiers: [.command, .control])"#))
        let inspector = try source("Views/Transcript/FormatInspector")
        #expect(inspector.contains(#"DisplayModeCard( title: "Paragraphs", icon: "text.alignleft""#))
        #expect(!inspector.contains(#"title: "Transcript""#))
    }

    @Test("a segment has one speaker menu wherever it shows, and No Speaker names the empty choice everywhere")
    func oneSpeakerMenuPerSegment() throws {
        let card = try source("Views/Transcript/SegmentCard")
        #expect(card.components(separatedBy: "Menu(\"").count == 2, "one titled submenu: the speaker menu")
        #expect(card.contains(#"return Menu("Assign This Segment to")"#))
        #expect(card.components(separatedBy: "assignSegmentMenu").count == 6)
        #expect(card.contains(#"Button("New Person…")"#))
        #expect(card.contains(#"Button("No Speaker") { model.assignSpeaker(nil, toSegmentID: segment.id) }"#))
        let inspector = try source("Views/Transcript/FormatInspector")
        #expect(inspector.contains(#"Button("No Speaker") { Task { await model.clearSpeaker(label: label) } }"#))
        let popover = try source("Views/People/AssignSpeakerPopover")
        #expect(popover.contains(#"footerButton("No Speaker")"#))
    }

    @Test("the inspector's field adds a person, as the People sheet's does; only the speaker popover adds a speaker")
    func addAPersonMeansOneThing() throws {
        let inspector = try source("Views/Transcript/FormatInspector")
        #expect(inspector.contains(#"TextField("Add a person…", text: $newPerson)"#))
        #expect(!inspector.contains("Add a speaker…"))
        let sheet = try source("Views/People/ManagePeopleSheet")
        #expect(sheet.contains(#"TextField("Add a person…""#))
    }

    @Test("both people menus go past ten, and the inspector's can name someone new")
    func peopleMenusHaveMore() throws {
        let card = try source("Views/Transcript/SegmentCard")
        #expect(card.contains("MorePeopleMenu(people: choices.people.more)"))
        let inspector = try source("Views/Transcript/FormatInspector")
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
            [#"Button("Back")"#, #"Button("Jump to Next Speaker")"#, #"Button("Jump to Time…")"#, #"Button("Show Outline")"#],
            [
                #"Button("Rename…")"#, "TranscribeAgainMenu(model: model)", #"Button("Edit Segment") { model.editFocusedSegment() }"#,
                #"Button("Add Note…") { model.noteFocusedSegment() }"#, #"Button("Favorite Segment")"#,
                #"Button("Delete Segment") { model.deleteFocusedSegment() }"#, #"Button("Manage People…")"#,
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

    @Test("Copy has one name, and the menu copies what the header's Copy button copies")
    func copyHasOneName() throws {
        let menu = try transcriptMenu()
        #expect(!menu.contains("Copy Plain Text"))
        #expect(menu.contains(#"Button("Copy Transcript") { Task { await model.copyTranscript() } }"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains(#".help(copied ? "Copied" : "Copy Transcript")"#))
        #expect(header.contains("await model.copyTranscript()"))
    }

    @Test("the Playback menu holds speed and Skip Silences, and names the keys the player owns")
    func playbackMenuHasEveryControl() throws {
        let commands = try source("Views/AppCommands")
        let start = try #require(commands.range(of: "struct PlaybackCommands: View"))
        let end = try #require(commands.range(of: "struct CaptionsCommands: View"))
        let menu = String(commands[start.lowerBound..<end.lowerBound])
        #expect(menu.contains(#"Picker("Playback Speed", selection: rate)"#))
        #expect(menu.contains("ForEach(PlaybackSpeed.all, id: \\.self)"))
        #expect(menu.contains(#"Toggle("Skip Silences", isOn: $model.skipSilences)"#))
        #expect(menu.contains(#".help(Self.keyHelp(String(localized: "Space")))"#))
        #expect(menu.contains(#".help(Self.keyHelp("⌘←"))"#))
        #expect(menu.contains(#".help(Self.keyHelp("⌘→"))"#))
    }

    @Test("next and previous segment have menu keys and one glyph pair in the header and the mini player")
    func segmentStepsShareOneGlyph() throws {
        let menu = try transcriptMenu()
        #expect(menu.contains(#"Button("Next Segment") { model.stepSegment(forward: true) } .keyboardShortcut(.downArrow, modifiers: [.command, .option])"#))
        #expect(menu.contains(#"Button("Previous Segment") { model.stepSegment(forward: false) } .keyboardShortcut(.upArrow, modifiers: [.command, .option])"#))
        let header = try source("Views/Transcript/TranscriptHeaderBar")
        #expect(header.contains("Image(systemName: SegmentStep.next.symbol)"))
        #expect(!header.contains("chevron.right.2"))
        let mini = try source("Views/MiniPlayerWindow")
        #expect(mini.contains("Image(systemName: SegmentStep.previous.symbol)"))
        #expect(mini.contains("Image(systemName: SegmentStep.next.symbol)"))
    }
}
