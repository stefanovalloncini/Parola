import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            MacLibrarySidebar()
        } detail: {
            ContentRoutes()
                .toolbar { ContentToolbar() }
                .modifier(HideToolbarTitleIfAvailable())
        }
        .contentSheets()
        .overlay {
            if let count = model.recordingCountdown {
                CountInOverlay(count: count) { model.cancelRecordingCountdown() }
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
        .axBranch("App")
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
