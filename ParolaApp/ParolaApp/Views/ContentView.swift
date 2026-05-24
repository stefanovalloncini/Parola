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
        .axBranch("App")
    }
}

private struct CountInOverlay: View {
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("\(count)")
                    .font(.system(size: 140, weight: .bold, design: .rounded))
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
