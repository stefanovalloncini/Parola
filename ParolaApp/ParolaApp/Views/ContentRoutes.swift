import SwiftUI
import ParolaCore

struct ContentRoutes: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        routedContent
            .onChange(of: model.pendingExport) { _, spec in
                if let spec {
                    model.performExport(spec)
                    model.pendingExport = nil
                }
            }
    }

    private var routedContent: some View {
        ZStack {
            content
                .id(model.route)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : DS.Motion.route, value: routeID)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let notice = model.exportNotice {
                    ExportNoticeStrip(notice: notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let job = model.burnJob {
                    BurnJobStrip(job: job)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let notice = model.arrivalNotice ?? model.runningArrivalNotice {
                    ArrivalToast(notice: notice)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.mode == .test, model.settingsRoutePreview {
            SettingsView()
        } else {
            switch model.route {
            case .batch:
                BatchView()
            case .queue:
                QueueView()
            case .statistics:
                StatisticsView()
            case .recentlyDeleted:
                MacRecentlyDeletedView()
            case .recording:
                StageRoute(library: libraryPage(browses: true), transcription: phaseContent)
            case .transcript:
                transcriptPage
            }
        }
    }

    /// Outside the identity the list and the panes take turns under: results replacing a transcript mid-query must not rebuild the field.
    private var transcriptPage: some View {
        ZStack {
            transcriptContent
                .id(routeID)
                .transition(.opacity)
        }
        .toolbarSearch(text: librarySearch, for: .transcript)
    }

    private var librarySearch: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.search($0) })
    }

    private var routeID: RouteID { Self.routeID(for: model) }

    /// Coarse on purpose: one case per library filter keeps the list's identity across a category switch.
    static func routeID(for model: AppModel) -> RouteID {
        if model.mode == .test, model.settingsRoutePreview { return .settingsPreview }
        switch model.route {
        case .batch: return .batch
        case .queue: return .queue
        case .statistics: return .statistics
        case .recentlyDeleted: return .recentlyDeleted
        case .recording: return .stage
        case .transcript:
            return model.isBrowsingLibrary ? .library : .phase
        }
    }

    enum RouteID: Hashable {
        case settingsPreview
        case batch
        case queue
        case statistics
        case recentlyDeleted
        case stage
        case library
        case phase
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if showsLibraryBrowse {
            libraryBrowseList
        } else {
            phaseContent
        }
    }

    private var phaseContent: some View {
        ZStack {
            phaseView
                .id(phaseViewID)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.3), value: phaseViewID)
    }

    @ViewBuilder
    private var phaseView: some View {
        switch model.transcriptRoutePhase {
        case .idle:
            libraryPage(browses: true)
        case .downloadingModel(let name, let progress):
            ProgressPane(title: "Downloading \(AppModel.modelLabel(name))", progress: progress)
        case .loadingModel(let name):
            ProgressPane(title: "Loading \(AppModel.modelLabel(name))…", progress: nil)
        case .fetchingLink(let title, let progress):
            ProgressPane(title: Self.fetchingTitle(title), progress: progress)
        case .transcribing(let file):
            LiveTranscribingPane(file: file)
        case .ready:
            if model.transcript != nil {
                TranscriptPane()
            } else {
                libraryPage(browses: true)
            }
        case .failed:
            libraryPage(browses: true)
        }
    }

    private static func fetchingTitle(_ videoTitle: String?) -> LocalizedStringKey {
        guard let videoTitle else { return "Downloading audio…" }
        return "Downloading \(videoTitle)"
    }

    private var phaseViewID: Int { Self.phaseViewID(for: model) }

    static func phaseViewID(for model: AppModel) -> Int {
        switch model.transcriptRoutePhase {
        case .idle: 0
        case .downloadingModel: 1
        case .loadingModel: 2
        case .transcribing: 3
        case .ready: 5
        case .failed: 6
        case .fetchingLink: 8
        }
    }

    private var showsLibraryBrowse: Bool {
        model.isBrowsingLibrary
    }

    /// One call site on purpose: an `if` per case would give each branch its own identity and tear the List down on every sidebar move.
    private var libraryBrowseList: some View {
        libraryPage(browses: LibraryListContent.showsBrowseList(hasTranscript: model.hasTranscript))
    }

    private func libraryPage(browses: Bool) -> some View {
        LibraryListView(category: model.libraryFilter, browses: browses, searchRanking: model.searchRanking)
    }

}

/// The take's page, read here rather than in `ContentRoutes`, which a title typed or a marker set would otherwise redraw whole.
private struct StageRoute<Library: View, Transcription: View>: View {
    @Environment(AppModel.self) private var model
    let library: Library
    /// What the phase shows while the take transcribes: its progress pane, or the library once Stop Transcribing lets go.
    let transcription: Transcription

    var body: some View {
        if let take = model.recording {
            switch take.state {
            case .arming, .recording, .paused, .finishing:
                RecordingPane(source: take.source)
            case .transcribing:
                transcription
            case .failed(let message):
                ErrorPane(message: message, take: take)
            case .done:
                library
            }
        } else {
            library
        }
    }
}

/// Owns the route's only reads of the per-partial properties, which arrive several times a second.
/// Reading them from `ContentRoutes` instead would invalidate the whole detail column each time.
private struct LiveTranscribingPane: View {
    @Environment(AppModel.self) private var model
    let file: URL

    var body: some View {
        TranscribingPane(
            file: file,
            name: model.linkRunTitle.flatMap { $0.file == file ? $0.title : nil },
            partial: model.filePartialText,
            progress: model.fileTranscribeFraction,
            expectsPartials: model.activeEngineStreamsPartials,
            stage: model.fileTranscribeStage
        )
    }
}

struct HideToolbarTitleIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
