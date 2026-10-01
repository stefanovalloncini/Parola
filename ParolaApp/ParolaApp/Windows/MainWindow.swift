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

/// Keeps `AppModel.mainWindow` on the window this content sits in, and lets go of it as that window closes.
struct MainWindowReporter: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        ReportingView(model: model)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        private weak var model: AppModel?
        private var observer: (any NSObjectProtocol)?

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
            model?.mainWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak model, weak window] _ in
                MainActor.assumeIsolated {
                    if let model, model.mainWindow === window { model.mainWindow = nil }
                }
            }
        }
    }
}
