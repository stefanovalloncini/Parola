import AppKit
import SwiftUI

enum MainWindowScene {
    static let id = "main"
}

/// Hands the scene's `openWindow` to the model, so AppKit surfaces can open the main window again after it closed.
private struct OpenMainWindowBinder: ViewModifier {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            model.bindOpenMainWindow { open(id: MainWindowScene.id) }
        }
    }
}

extension View {
    func bindsMainWindowOpening(to model: AppModel) -> some View {
        modifier(OpenMainWindowBinder(model: model))
    }
}

/// The main window's title for the Window menu, Mission Control and VoiceOver: a running take's, else the open transcript's, else the app's.
enum MainWindowTitle {
    nonisolated static let resting = "Parola"

    nonisolated static func title(takeRunning: Bool, transcriptTitle: String? = nil, bundle: Bundle = .main) -> String {
        if takeRunning { return String(localized: "Recording — Parola", bundle: bundle) }
        return transcriptTitle ?? resting
    }
}

/// Keeps `AppModel.mainWindow` on the window this content sits in, and lets go of it as that window closes; the title follows the take and the open transcript, and closing it mid-take asks first.
struct MainWindowReporter: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        ReportingView(model: model)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        private weak var model: AppModel?
        private var observer: (any NSObjectProtocol)?
        private var followsTake = false

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // Every main window shares one model, so a tab would be a second copy of the same pages.
            window.tabbingMode = .disallowed
            model?.mainWindow = window
            if let model { MainWindowCloseGuard.install(on: window, model: model) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak model, weak window] _ in
                MainActor.assumeIsolated {
                    if let model, model.mainWindow === window { model.mainWindow = nil }
                }
            }
            followTake()
        }

        /// One observation at a time, however often the view joins a window.
        private func followTake() {
            guard !followsTake, let model else {
                nameWindow()
                floatWindow()
                return
            }
            followsTake = true
            withObservationTracking {
                _ = model.takeIsRunning
                nameWindow()
                floatWindow()
                guardClose()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.followsTake = false
                    self?.followTake()
                }
            }
        }

        private func nameWindow() {
            guard let model, let window else { return }
            let title = MainWindowTitle.title(takeRunning: model.takeIsRunning, transcriptTitle: model.shownTranscriptTitle)
            if window.title != title { window.title = title }
        }

        private func floatWindow() {
            guard let model, let window else { return }
            let level: NSWindow.Level = model.mainWindowAlwaysOnTop ? .floating : .normal
            if window.level != level { window.level = level }
        }

        /// Again as each take starts, in case the window's delegate changed since the window opened.
        private func guardClose() {
            guard let model, let window, model.takeIsRunning else { return }
            MainWindowCloseGuard.install(on: window, model: model)
        }
    }
}
