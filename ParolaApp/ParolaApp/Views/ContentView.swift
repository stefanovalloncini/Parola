import SwiftUI
import ParolaCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var windowUndoManager

    var body: some View {
        Group {
            if model.introduction.isPresented {
                IntroductionView()
                    .transition(.opacity)
            } else {
                home
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.introduction.isPresented)
        .background(MainWindowReporter(model: model))
        .background(LinkPasteInstaller(model: model))
        .onReceive(NotificationCenter.default.publisher(for: .parolaSummarizeLast)) { _ in
            model.summarizeLatestEntry()
        }
        .axBranch("App")
    }

    private var home: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            LibrarySidebar()
        } detail: {
            ContentRoutes()
                .toolbar { ContentToolbar() }
                .modifier(HideToolbarTitleIfAvailable())
        }
        .modifier(TakeSidebarRelease())
        .contentSheets()
        .background { TranslationHostView() }
        .modifier(SplitDropZone())
        .overlay {
            // The Stage counts in on its own clock; the overlay covers whoever left it during the count.
            if let count = model.recordingCountdown, model.route != .recording {
                CountInOverlay(count: count) { model.cancelRecordingCountdown() }
            }
        }
        .overlay(alignment: .bottom) {
            if model.savingTakesBeforeQuit {
                SavingBeforeQuitNotice()
            }
        }
        .alert(
            "Couldn't save to your library",
            isPresented: Binding(
                get: { model.nonFatalWarning != nil },
                set: { if !$0 { model.nonFatalWarning = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.nonFatalWarning = nil }
        } message: {
            if let warning = model.nonFatalWarning { Text(warning) }
        }
        .alert(
            "Add \(model.pendingLargeDrop?.count ?? 0) files?",
            isPresented: Binding(
                get: { model.pendingLargeDrop != nil },
                set: { if !$0 { model.cancelLargeDrop() } }
            )
        ) {
            Button("Cancel", role: .cancel) { model.cancelLargeDrop() }
                .axLeaf("Alert.Button.CancelLargeDrop")
            Button("Add Files") { model.confirmLargeDrop() }
                .axLeaf("Alert.Button.AddLargeDrop")
        } message: {
            Text("They go into the queue and are transcribed one at a time.")
        }
        .onAppear { model.undoManager = windowUndoManager }
        .onChange(of: windowUndoManager) { _, newValue in model.undoManager = newValue }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { model.mainSidebar.visibility }, set: { model.mainSidebar.userSet($0) })
    }
}

/// What a quit is waiting for, so a window that hasn't closed yet doesn't look stuck.
private struct SavingBeforeQuitNotice: View {
    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text("Saving your recording before Parola quits…")
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.primaryText)
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .background(Capsule().fill(DS.Color.surfaceElevated))
        .overlay(Capsule().strokeBorder(DS.Color.separator, lineWidth: 1))
        .padding(.bottom, DS.Spacing.large)
        .accessibilityElement(children: .combine)
        .axLeaf("App.Text.SavingBeforeQuit")
    }
}

private struct CountInOverlay: View {
    let count: Int
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 140

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("\(count)")
                    .font(.system(size: numeralSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.large)
                    .tint(.white)
                    .axLeaf("CountIn.Button.Cancel")
            }
        }
        .transition(.opacity)
    }
}
