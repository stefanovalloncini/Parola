import AppKit
import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("Transcript inspector", .serialized)
struct TranscriptInspectorTests {
    private static let width: CGFloat = 1180

    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-transcript-inspector-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func makeModel(_ defaults: UserDefaults, features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: defaults,
            libraryURL: makeTempLibraryURL("transcript-inspector"),
            features: features
        )
        model.libraryLoaded = true
        return model
    }

    private static func meeting() -> Transcript {
        var transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 20, text: "We start with the launch plan for the spring release.", speaker: "SPEAKER_00"),
                TranscriptSegment(id: 1, start: 20, end: 40, text: "The first screen still needs its final render.", speaker: "SPEAKER_01"),
                TranscriptSegment(id: 2, start: 40, end: 70, text: "Then the budget for the next quarter goes to review.", speaker: "SPEAKER_00"),
            ],
            language: "en",
            modelName: "stub",
            durationSeconds: 70
        )
        transcript.summary = Summary(
            text: "The team agreed on the spring launch plan and moved the budget review to next week.",
            chapters: [
                Chapter(title: "Launch plan", start: 0),
                Chapter(title: "First screen", start: 20),
                Chapter(title: "Budget", start: 40),
            ],
            actionItems: ["Sam: render the first screen", "Book the room for the review"]
        )
        return transcript
    }

    private static func dictation() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 9, text: "Thanks Anna, Friday works for me.")],
            language: "en",
            modelName: "stub",
            durationSeconds: 9
        )
    }

    /// Ten turns between two speakers and no AI chapters: the outline the speaker turns give.
    private static func longTalk() -> Transcript {
        Transcript(
            segments: (0..<10).map { index in
                TranscriptSegment(
                    id: index,
                    start: Double(index * 10),
                    end: Double(index * 10 + 9),
                    text: "Turn number \(index) about the plan",
                    speaker: index.isMultiple(of: 2) ? "SPEAKER_00" : "SPEAKER_01"
                )
            },
            language: "en",
            modelName: "stub",
            durationSeconds: 100
        )
    }

    private func open(_ transcript: Transcript, in model: AppModel) async throws -> LibraryEntry {
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await store.add(transcript: transcript, audioSource: nil, category: .transcription)
        await model.library.dropCaches()
        await model.refreshLibraryAndWait()
        try await awaitGuarded("opening \(entry.id)") { _ = try await model.openEntry(entry.id) }
        await awaitGuarded("the open's library refresh") { await model.libraryRefreshTask?.value }
        model.phase = .ready
        return entry
    }

    private func host(_ model: AppModel, height: CGFloat = 1600) -> HostedWindow {
        HostedWindow(ContentView().environment(model), width: Self.width, height: height)
    }

    /// What VoiceOver finds in the inspector column, top to bottom, each element once.
    private func inspector(_ hosted: HostedWindow) -> [HostedAccessibility.Element] {
        hosted.host.layoutSubtreeIfNeeded()
        let left = hosted.window.frame.maxX - MainWindowLayout.inspectorWidth
        var seen: Set<String> = []
        return HostedAccessibility.elements(in: hosted.host)
            .filter { $0.frame.midX >= left && $0.frame.width > 0 }
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .filter { seen.insert("\($0.role ?? "")|\($0.name ?? "")|\($0.identifier ?? "")|\($0.frame)").inserted }
    }

    private func headings(_ hosted: HostedWindow) -> [String] {
        inspector(hosted).filter { $0.role == "AXHeading" }.compactMap(\.name).map { $0.lowercased() }
    }

    private func element(_ leaf: String, in hosted: HostedWindow) -> HostedAccessibility.Element? {
        inspector(hosted).first { $0.identifier?.hasSuffix(leaf) == true }
    }

    private func count(_ leaf: String, in hosted: HostedWindow) -> Int {
        inspector(hosted).filter { $0.identifier?.hasSuffix(leaf) == true }.count
    }

    /// What VoiceOver reads for an element; a menu button carries its name as an attributed title.
    private func spoken(_ element: HostedAccessibility.Element?) -> String? {
        guard let element else { return nil }
        if let name = element.name { return name }
        guard element.object.responds(to: NSSelectorFromString("accessibilityTitle")) else { return nil }
        let title = element.object.value(forKey: "accessibilityTitle")
        return (title as? NSAttributedString)?.string ?? title as? String
    }

    private func dump(_ hosted: HostedWindow) -> String {
        inspector(hosted).map { "\($0.role ?? "-") \(spoken($0) ?? "-") \($0.identifier ?? "-")" }.joined(separator: "\n")
    }

    @Test("a meeting's inspector reads in the order you open it for, with the reference rows closed under it")
    func overviewReadsByPurpose() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.meeting(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { headings(hosted).contains("insights") }
            #expect(drawn, "\(dump(hosted))")
            let expected = ["summary", "chapters · 3", "action items · 2", "people", "labels", "details", "insights"]
            #expect(headings(hosted) == expected, "\(dump(hosted))")
            let words = inspector(hosted).flatMap(\.words)
            let excerpt = words.contains { $0.contains("spring launch plan") }
            let item = words.contains { $0.contains("render the first screen") }
            let chapter = words.contains { $0.contains("Launch plan") }
            #expect(excerpt)
            #expect(chapter)
            #expect(item)
            #expect(element("Info.Button.TranscribeAgain", in: hosted) == nil, "Details starts closed")
            #expect(element("Inspector.Button.DisplayModetextalignleft", in: hosted) == nil)
        }
    }

    @Test("a short dictation asks for one summary and lists nothing it doesn't have")
    func dictationAsksForOneSummary() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.dictation(), in: model)
            let hosted = host(model, height: 760)
            defer { hosted.close() }

            let drawn = await waitUntil { headings(hosted).contains("labels") }
            #expect(drawn, "\(dump(hosted))")
            let shown = headings(hosted)
            #expect(Array(shown.prefix(3)) == ["summary", "labels", "details"], "\(shown)")
            let extra = shown.filter { $0.hasPrefix("chapters") || $0.hasPrefix("action items") || $0 == "people" || $0 == "outline" }
            #expect(extra.isEmpty)
            let summarize = element("Overview.Button.Summarize", in: hosted)
            #expect(summarize?.name == "Summarize")
            #expect(!inspector(hosted).flatMap(\.words).contains("No labels yet"))
        }
    }

    @Test("with the AI feature off there is no Summary to ask for, and chapters only show when the transcript has them")
    func aiOffLeavesTheSummaryOut() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults, features: Set(ParolaFeature.allCases).subtracting([.ai]))
            _ = try await open(Self.meeting(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { headings(hosted).contains("labels") }
            #expect(drawn, "\(dump(hosted))")
            let shown = headings(hosted)
            #expect(!shown.contains("summary"), "\(shown)")
            #expect(shown.contains("chapters · 3"), "\(shown)")
            #expect(element("Chapters.Button.Generate", in: hosted) == nil)
        }
    }

    @Test("with no AI chapters the speaker turns make the outline, eight at first and the rest on Show All")
    func chaptersFallBackToTheOutline() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.longTalk(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { headings(hosted).contains("outline") }
            #expect(drawn, "\(dump(hosted))")
            #expect(count("Chapters.Button.Jump", in: hosted) == 8)
            #expect(element("Chapters.Button.Generate", in: hosted)?.name == "Generate Chapters")
            #expect(HostedAccessibility.press(endingWith: "Chapters.Button.ShowAll", in: hosted.host))
            let all = await waitUntil { count("Chapters.Button.Jump", in: hosted) == 10 }
            #expect(all)
            #expect(element("Chapters.Button.ShowAll", in: hosted)?.name == "Show Less")
        }
    }

    @Test("the outline is stored by the open inspector, follows a timing nudge and goes with the transcript")
    func outlineIsStoredOffTheBody() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.longTalk(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let filled = await waitUntil { model.inspectorOutline.count == 10 }
            #expect(filled)
            let fourth = model.inspectorOutline.first { $0.id == "seg-4" }
            let before = try #require(fourth)
            #expect(before.start == 40)

            model.nudgeSegmentStart(id: 4, frames: 12)
            let moved = await waitUntil { model.inspectorOutline.first { $0.id == "seg-4" }?.start != 40 }
            #expect(moved)
            let expected = TranscriptOutline.entries(for: try #require(model.transcript), chapters: [])
            #expect(model.inspectorOutline == expected)

            model.closeTranscript()
            await model.awaitTranscriptClose()
            #expect(model.inspectorOutline.isEmpty)
        }
    }

    @Test("opening another entry leaves none of the last entry's outline behind")
    func outlineDoesNotSurviveAnEntrySwitch() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.longTalk(), in: model)
            let hosted = host(model)
            defer { hosted.close() }
            let filled = await waitUntil { model.inspectorOutline.count == 10 }
            #expect(filled)

            var other = Self.longTalk()
            other.segments = other.segments.prefix(3).map { segment in
                var moved = segment
                moved.id += 100
                return moved
            }
            model.installStoredTranscript(other)

            let stale = model.inspectorOutline.filter { entry in Int(entry.id.dropFirst(4)).map { $0 < 100 } ?? false }
            #expect(stale.isEmpty, "\(model.inspectorOutline.map(\.id))")
            let settled = await waitUntil { model.inspectorOutline.map(\.id) == ["seg-100", "seg-101", "seg-102"] }
            #expect(settled)
        }
    }

    @Test("a speaker who isn't anyone yet is the only row that asks, and every count reads as segments")
    func peopleAskOnlyWhereNeeded() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.meeting(), in: model)
            await model.assignSpeaker(label: "SPEAKER_00", toNewPersonNamed: "Ada")
            await model.awaitSpeakerAssignmentWrites()
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { element("Inspector.People.Row.SPEAKER_01", in: hosted) != nil }
            #expect(drawn, "\(dump(hosted))")
            #expect(count("Inspector.Menu.Assign", in: hosted) == 1, "\(dump(hosted))")
            let assign = try #require(element("Inspector.Menu.Assign", in: hosted))
            let row = try #require(element("Inspector.People.Row.SPEAKER_01", in: hosted))
            #expect(row.frame.insetBy(dx: -0.5, dy: -0.5).contains(assign.frame), "Assign… sits outside the unassigned row")
            #expect(spoken(assign) == "Assign SPEAKER_01…")
            let person = try #require(element("Inspector.Menu.Person", in: hosted))
            #expect(spoken(person) == "Ada, 2 segments")
            let words = inspector(hosted).flatMap(\.words)
            #expect(!words.contains("Assigned") && !words.contains("Unassigned"))
            #expect(words.contains("1 segment"), "the count reads in words")
            #expect(!words.contains("1"), "no bare count")
        }
    }

    @Test("each section's menu names its section for VoiceOver")
    func sectionMenusNameTheirSection() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.meeting(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { element("Inspector.Menu.People", in: hosted) != nil }
            #expect(drawn, "\(dump(hosted))")
            #expect(spoken(element("Inspector.Menu.Chapters", in: hosted)) == "Chapter Options")
            #expect(spoken(element("Inspector.Menu.ActionItems", in: hosted)) == "Action Item Options")
            #expect(spoken(element("Inspector.Menu.People", in: hosted)) == "People Options")
        }
    }

    private func scrollToBottom(_ hosted: HostedWindow) {
        let left = hosted.window.frame.maxX - MainWindowLayout.inspectorWidth - 0.5
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
        }
        let column = scrollViews(in: hosted.host).first {
            guard let window = $0.window else { return false }
            return window.convertToScreen($0.convert($0.bounds, to: nil)).minX >= left
        }
        guard let scroll = column, let document = scroll.documentView, document.isFlipped else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func chaptersCaption(_ hosted: HostedWindow) -> CGRect? {
        inspector(hosted).first { $0.role == "AXHeading" && $0.name?.lowercased() == "chapters · 3" }?.frame
    }

    private func chaptersOnScreen(_ hosted: HostedWindow) -> Bool {
        guard let caption = chaptersCaption(hosted) else { return false }
        return caption.minY >= hosted.window.frame.minY && caption.maxY <= hosted.window.frame.maxY
    }

    /// The caption sits at the top of the column, above where Summary would start.
    private func chaptersAtTop(_ hosted: HostedWindow) -> Bool {
        guard let caption = chaptersCaption(hosted) else { return false }
        return caption.maxY <= hosted.window.frame.maxY && caption.maxY >= hosted.window.frame.maxY - 2 * DS.Spacing.large
    }

    @Test("Transcript ▸ Show Chapters opens a hidden inspector and scrolls it back to Chapters")
    func showChaptersRevealsThem() async throws {
        try await withIsolatedDefaults { defaults in
            defaults.set(false, forKey: InspectorVisibility.preferenceKey)
            defaults.set(true, forKey: "inspectorDetailsExpanded")
            defaults.set(true, forKey: "inspectorInsightsExpanded")
            let model = makeModel(defaults)
            _ = try await open(Self.meeting(), in: model)
            let hosted = host(model, height: 760)
            let menu = HostedWindow(VStack(alignment: .leading) { TranscriptCommands(model: model) }.environment(model), width: 420, height: 900)
            defer {
                hosted.close()
                menu.close()
            }
            let pressedWhileHidden = HostedAccessibility.press(endingWith: "Menu.Transcript.ShowChapters", in: menu.host)
            #expect(pressedWhileHidden)
            let shown = await waitUntil { chaptersAtTop(hosted) }
            #expect(shown, "\(dump(hosted))")
            #expect(InspectorVisibility.preference(in: defaults))
            #expect(model.inspectorReveal == nil, "the request clears once the column has scrolled")

            scrollToBottom(hosted)
            let scrolledAway = await waitUntil { !chaptersOnScreen(hosted) }
            #expect(scrolledAway)
            #expect(HostedAccessibility.press(endingWith: "Menu.Transcript.ShowChapters", in: menu.host))
            let back = await waitUntil { chaptersAtTop(hosted) }
            #expect(back)
        }
    }

    private func pressShowChapters(_ model: AppModel) -> Bool {
        let menu = HostedWindow(VStack(alignment: .leading) { TranscriptCommands(model: model) }.environment(model), width: 420, height: 900)
        defer { menu.close() }
        return HostedAccessibility.press(endingWith: "Menu.Transcript.ShowChapters", in: menu.host)
    }

    @Test("Show Chapters on a dictation with no chapters shows the section with Generate Chapters, and it stays")
    func showChaptersOnADictationOffersToGenerate() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.dictation(), in: model)
            let hosted = host(model, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { headings(hosted).contains("labels") }
            #expect(drawn, "\(dump(hosted))")
            #expect(!headings(hosted).contains("chapters"))

            #expect(pressShowChapters(model))
            let shown = await waitUntil { headings(hosted).contains("chapters") && model.inspectorReveal == nil }
            #expect(shown, "\(dump(hosted))")
            #expect(element("Chapters.Button.Generate", in: hosted)?.name == "Generate Chapters", "\(dump(hosted))")
            await settle()
            #expect(headings(hosted).contains("chapters"), "the section stays once the request has cleared")

            _ = try await open(Self.dictation(), in: model)
            let next = await waitUntil { !headings(hosted).contains("chapters") && headings(hosted).contains("labels") }
            #expect(next, "another transcript starts without it: \(dump(hosted))")
        }
    }

    @Test("Show Chapters with AI off and nothing to list says there are no chapters")
    func showChaptersWithNothingToListSaysSo() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults, features: Set(ParolaFeature.allCases).subtracting([.ai]))
            _ = try await open(Self.dictation(), in: model)
            let hosted = host(model, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { headings(hosted).contains("labels") }
            #expect(drawn, "\(dump(hosted))")

            #expect(pressShowChapters(model))
            let shown = await waitUntil { headings(hosted).contains("chapters") }
            #expect(shown, "\(dump(hosted))")
            let words = inspector(hosted).flatMap(\.words)
            #expect(words.contains("This transcript has no chapters."), "\(dump(hosted))")
            #expect(element("Chapters.Button.Generate", in: hosted) == nil)
        }
    }

    @Test("Details and Insights open in place and stay open")
    func referenceRowsOpenInPlace() async throws {
        try await withIsolatedDefaults { defaults in
            let model = makeModel(defaults)
            _ = try await open(Self.meeting(), in: model)
            let hosted = host(model)
            defer { hosted.close() }

            let drawn = await waitUntil { element("Inspector.Disclosure.Insights", in: hosted) != nil }
            #expect(drawn, "\(dump(hosted))")
            #expect(element("Info.Button.TranscribeAgain", in: hosted) == nil)
            #expect(HostedAccessibility.press(endingWith: "Inspector.Disclosure.Details", in: hosted.host))
            let opened = await waitUntil { element("Info.Button.TranscribeAgain", in: hosted) != nil }
            #expect(opened)
            #expect(defaults.bool(forKey: "inspectorDetailsExpanded"))
            #expect(inspector(hosted).flatMap(\.words).contains("Transcription Details") == false, "one list, no second caption")

            let statsBefore = headings(hosted).contains { $0.hasPrefix("speakers ·") }
            #expect(!statsBefore)
            #expect(HostedAccessibility.press(endingWith: "Inspector.Disclosure.Insights", in: hosted.host))
            let insights = await waitUntil { headings(hosted).contains { $0.hasPrefix("speakers ·") } }
            #expect(insights, "\(dump(hosted))")
            #expect(defaults.bool(forKey: "inspectorInsightsExpanded"))
        }
    }

    @Test("a favorite count and the translation's language are Details rows")
    func favoritesAndTranslationAreDetails() async throws {
        try await withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "inspectorDetailsExpanded")
            let model = makeModel(defaults)
            var meeting = Self.meeting()
            meeting.translation = TranscriptTranslation(
                targetLanguage: "es", segments: [0: "Empezamos"], createdAt: Date(), provider: "mock"
            )
            _ = try await open(meeting, in: model)
            model.toggleSegmentFavorite(0)
            model.toggleSegmentFavorite(2)
            let favorited = await waitUntil { model.favoriteSegmentIDs.count == 2 }
            #expect(favorited)
            let hosted = host(model)
            defer { hosted.close() }

            let spanish = try #require(LanguageDisplay.name(for: "es"))
            let drawn = await waitUntil { inspector(hosted).flatMap(\.words).contains("Translated to") }
            #expect(drawn, "\(dump(hosted))")
            let words = inspector(hosted).flatMap(\.words)
            #expect(spoken(element("Info.Menu.Translation", in: hosted)) == spanish, "\(dump(hosted))")
            #expect(words.contains("Favorites"))
            #expect(!headings(hosted).contains("translation"))
        }
    }
}

/// Holds a translation run open until the test lets it go.
private actor InspectorTranslationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct GatedInspectorTranslator: TranscriptTranslating {
    let providerName = "stub"
    let gate: InspectorTranslationGate

    func translate(_ texts: [(id: Int, text: String)], from source: String?, to target: String) async throws -> [Int: String] {
        await gate.wait()
        return Dictionary(uniqueKeysWithValues: texts.map { ($0.id, "T\($0.id)") })
    }
}

private struct FailingInspectorTranslator: TranscriptTranslating {
    let providerName = "stub"
    var reason = "translator went down"

    func translate(_ texts: [(id: Int, text: String)], from source: String?, to target: String) async throws -> [Int: String] {
        throw ParolaError.ioError(reason)
    }
}

@MainActor
@Suite("Translation strip", .serialized)
struct TranslationStripTests {
    private static let strip = "Transcript.Strip.Translation"

    private func withIsolatedDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-translation-strip-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try await body(suite)
    }

    private func openItalian(_ defaults: UserDefaults) async throws -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("translation-strip"))
        model.libraryLoaded = true
        let store = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await store.add(
            transcript: Transcript(
                segments: [
                    TranscriptSegment(id: 0, start: 0, end: 1, text: "ciao mondo"),
                    TranscriptSegment(id: 1, start: 1, end: 2, text: "come stai"),
                ],
                language: "it",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        await model.library.dropCaches()
        await model.refreshLibraryAndWait()
        try await awaitGuarded("opening \(entry.id)") { _ = try await model.openEntry(entry.id) }
        await awaitGuarded("the open's library refresh") { await model.libraryRefreshTask?.value }
        model.phase = .ready
        return model
    }

    private func ids(_ hosted: HostedWindow) -> [String] {
        hosted.host.layoutSubtreeIfNeeded()
        return HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
    }

    private func has(_ leaf: String, _ hosted: HostedWindow) -> Bool {
        ids(hosted).contains { $0.hasSuffix(leaf) }
    }

    @Test("at the narrowest window with the inspector open, a failed translation's note keeps its width and every control shows")
    func failedStripFitsTheNarrowestWindow() async throws {
        try await withIsolatedDefaults { defaults in
            defaults.set(true, forKey: InspectorVisibility.forcedAtNarrowWidthKey)
            let model = try await openItalian(defaults)
            model.transcript?.translation = TranscriptTranslation(targetLanguage: "fr", segments: [0: "bonjour"], createdAt: Date(), provider: "mock")
            model.translationCoordinator.translatorOverride = FailingInspectorTranslator(reason: "The system translator stopped.")
            let hosted = HostedWindow(ContentView().environment(model), width: MainWindowLayout.minimumWidth, height: 760)
            defer { hosted.close() }

            await model.translateTranscript(to: "en")
            let failed = await waitUntil { has("Translation.Button.Dismiss", hosted) }
            #expect(failed)
            guard case .failed(let message) = model.translationState else {
                Issue.record("expected a failed run, got \(model.translationState)")
                return
            }
            hosted.host.layoutSubtreeIfNeeded()
            let elements = HostedAccessibility.elements(in: hosted.host)
            func frame(_ leaf: String) -> CGRect? { elements.first { $0.identifier?.hasSuffix(leaf) == true }?.frame }
            let inspectorLeft = hosted.window.frame.maxX - MainWindowLayout.inspectorWidth
            let inspectorShows = elements.contains { $0.role == "AXHeading" && $0.frame.minX >= inspectorLeft }
            #expect(inspectorShows, "the inspector is forced open beside the strip")

            let strip = try #require(frame(Self.strip))
            let noteElement = elements.first { $0.words.contains(message) }
            let note = try #require(noteElement?.frame, "\(elements.map(\.words))")
            let retry = try #require(frame("Translation.Button.Retry"))
            #expect(note.width >= strip.width / 2, "note \(note) in strip \(strip)")
            #expect(note.height <= 2 * retry.height, "note \(note), Retry \(retry)")
            for leaf in ["Translation.Button.Retry", "Translation.Button.Remove", "Translation.Menu.TranslateTo", "Translation.Button.Dismiss"] {
                let control = try #require(frame(leaf), "\(leaf)")
                #expect(strip.insetBy(dx: -0.5, dy: -0.5).contains(control), "\(leaf) \(control) outside the strip \(strip)")
                #expect(control.maxX <= inspectorLeft, "\(leaf) \(control) under the inspector")
            }
        }
    }

    private func translateMenu(_ model: AppModel) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: TranslateMenu(model: model))
        menu.update()
        return menu.items
    }

    private func translateToItems(_ model: AppModel) -> [String] {
        translateMenu(model).first { $0.title == "Translate To" }?.submenu?.items.map(\.title) ?? []
    }

    @Test("Transcript ▸ Translate To offers every language the system translator has, not just the app's own table")
    func translateToOffersTheSystemsLanguages() async throws {
        try await withIsolatedDefaults { defaults in
            let model = try await openItalian(defaults)
            model.translationCoordinator.systemLanguagesOverride = SupportedLanguages.codes + ["pl", "uk"]
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { has("Transcript.Heading.Title", hosted) }
            #expect(drawn)

            let polish = SupportedLanguages.displayName(for: "pl")
            #expect(!SupportedLanguages.codes.contains("pl"))
            let offered = await waitUntil { translateToItems(model).contains(polish) }
            #expect(offered, "\(translateToItems(model))")
            #expect(!translateToItems(model).contains(SupportedLanguages.displayName(for: "it")), "not the transcript's own language")
            #expect(translateMenu(model).map(\.title) == ["Translate To", "Remove Translation"])
        }
    }

    @Test("a running translation shows above the text with Cancel, and goes once it lands")
    func runningTranslationShowsAboveTheText() async throws {
        try await withIsolatedDefaults { defaults in
            let model = try await openItalian(defaults)
            let gate = InspectorTranslationGate()
            model.translationCoordinator.translatorOverride = GatedInspectorTranslator(gate: gate)
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer { hosted.close() }
            let drawn = await waitUntil { has("Transcript.Heading.Title", hosted) }
            #expect(drawn)
            #expect(!has(Self.strip, hosted))

            let run = Task { await model.translateTranscript(to: "en") }
            let running = await waitUntil { has(Self.strip, hosted) && has("Translation.Button.Cancel", hosted) }
            #expect(running)
            let strip = HostedAccessibility.elements(in: hosted.host).first { $0.identifier?.hasSuffix("Translation.Button.Cancel") == true }
            let inspectorLeft = hosted.window.frame.maxX - MainWindowLayout.inspectorWidth
            #expect((strip?.frame.maxX ?? .infinity) <= inspectorLeft, "the strip belongs to the text column")

            await gate.open()
            await run.value
            let gone = await waitUntil { !has(Self.strip, hosted) }
            #expect(gone)
            #expect(model.transcript?.translation?.targetLanguage == "en")
        }
    }

    @Test("a failed translation stays above the text with Retry until it is retried or dismissed, and Dismiss keeps the stored one")
    func failedTranslationOffersRetry() async throws {
        try await withIsolatedDefaults { defaults in
            let model = try await openItalian(defaults)
            let kept = TranscriptTranslation(targetLanguage: "fr", segments: [0: "bonjour"], createdAt: Date(), provider: "mock")
            model.transcript?.translation = kept
            model.translationCoordinator.translatorOverride = FailingInspectorTranslator()
            let hosted = HostedWindow(ContentView().environment(model), width: 1180, height: 760)
            defer { hosted.close() }

            await model.translateTranscript(to: "en")
            let failed = await waitUntil { has("Translation.Button.Retry", hosted) && has(Self.strip, hosted) }
            #expect(failed)
            #expect(has("Translation.Menu.TranslateTo", hosted))
            #expect(has("Translation.Button.Dismiss", hosted))
            let elements = HostedAccessibility.elements(in: hosted.host)
            let retryFrame = elements.first { $0.identifier?.hasSuffix("Translation.Button.Retry") == true }?.frame
            let dismissFrame = elements.first { $0.identifier?.hasSuffix("Translation.Button.Dismiss") == true }?.frame
            let retry = try #require(retryFrame)
            let dismiss = try #require(dismissFrame)
            #expect(abs(retry.midY - dismiss.midY) < 1, "a wide column keeps the strip on one row")

            #expect(HostedAccessibility.press(endingWith: "Translation.Button.Dismiss", in: hosted.host))
            let dismissed = await waitUntil { !has(Self.strip, hosted) }
            #expect(dismissed)
            #expect(model.translationState == .idle)
            #expect(model.transcript?.translation == kept)
        }
    }
}

@MainActor
@Suite("Overview section rules")
struct OverviewSectionRulesTests {
    private func makeModel(features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("overview-rules"),
            features: features
        )
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub"
        )
        return model
    }

    @Test("a leading name of up to three words is who does it; anything longer is part of the task")
    func summaryItemsSplitOffTheirAssignee() {
        let sam = OverviewActionItems.split("Sam: render the first screen")
        #expect(sam.assignee == "Sam")
        #expect(sam.task == "render the first screen")
        let team = OverviewActionItems.split("Design team lead: book the room")
        #expect(team.assignee == "Design team lead")
        let sentence = OverviewActionItems.split("Remember what we said about this: ship it")
        #expect(sentence.assignee == nil)
        #expect(sentence.task == "Remember what we said about this: ship it")
        #expect(OverviewActionItems.split("Book the room").assignee == nil)
        #expect(OverviewActionItems.split("Sam:").assignee == nil)
        #expect(OverviewActionItems.split("Ana María: send the notes").assignee == "Ana María")
        #expect(OverviewActionItems.split("Jean-Luc: book the room").assignee == "Jean-Luc")
    }

    @Test("a name the summary gives in lowercase is still who does it")
    func lowercaseNamesAreAssignees() {
        for (line, name) in [("sam: ship the feature", "sam"), ("maria: send the notes", "maria"), ("иван: book the room", "иван")] {
            let split = OverviewActionItems.split(line)
            #expect(split.assignee == name, "\(line)")
            #expect(split.task == String(line.dropFirst(name.count + 2)))
        }
    }

    @Test("a time or a link before the first colon is part of the task, not someone's name")
    func timesAndLinksAreNotAssignees() {
        for line in [
            "10:30 standup with design",
            "Standup at 10:30 with design",
            "https://example.com/notes has the deck",
            "See https://example.com/notes for the deck",
            "Q3: close the budget",
        ] {
            let split = OverviewActionItems.split(line)
            #expect(split.assignee == nil, "\(line)")
            #expect(split.task == line)
        }
    }

    @Test("with nothing extracted, Action Items shows and copies the summary's; extracted items win once there are any")
    func extractedItemsWinOverTheSummarys() {
        let model = makeModel()
        model.transcript?.summary = Summary(text: "Short.", actionItems: ["Sam: render the first screen", "  "])
        #expect(OverviewActionItems.summaryItems(model) == ["Sam: render the first screen"])
        #expect(OverviewActionItems.shows(model))
        #expect(OverviewActionItems.copyText(model) == "- Sam: render the first screen")

        model.actionItems = [ActionItem(assignee: "Ada", task: "Ship the patch", dueDate: "Friday")]
        #expect(OverviewActionItems.copyText(model) == "- [Ada] Ship the patch [by Friday]")
    }

    @Test("Chapters and Action Items wait for an AI run, unless the transcript already has something to list")
    func sectionsWaitForAnAIRun() {
        let model = makeModel()
        #expect(!OverviewChapters.shows(model))
        #expect(!OverviewActionItems.shows(model))

        model.transcript?.summary = Summary(text: "We ship on Friday.")
        #expect(OverviewChapters.shows(model), "after Summarize, Generate Chapters is one click away")
        #expect(OverviewActionItems.shows(model))

        let off = makeModel(features: Set(ParolaFeature.allCases).subtracting([.ai]))
        off.transcript?.summary = Summary(text: "We ship on Friday.")
        #expect(!OverviewChapters.shows(off))
        #expect(!OverviewActionItems.shows(off))
        off.smartChapters = [Chapter(title: "Friday", start: 0)]
        #expect(OverviewChapters.shows(off))
    }

    @Test("the strip shows only while a translation runs or after one failed")
    func stripShowsOnlyWhileRunningOrFailed() {
        #expect(!TranslationStrip.shows(.idle))
        #expect(TranslationStrip.shows(.preparing))
        #expect(TranslationStrip.shows(.translating(completed: 3, total: 10)))
        #expect(TranslationStrip.shows(.failed("The translator stopped.")))
    }
}
