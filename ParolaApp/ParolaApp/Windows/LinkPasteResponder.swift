import AppKit
import SwiftUI

/// ⌘V in the main window when nothing focused takes the paste itself: a link on the clipboard opens the link sheet.
final class LinkPasteResponder: NSResponder, NSUserInterfaceValidations {
    private weak var model: AppModel?
    private weak var window: NSWindow?
    /// Weak where AppKit's own is unowned: a controller that goes first must not leave this pointing at it.
    private weak var following: NSResponder?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var nextResponder: NSResponder? {
        get { following }
        set {
            following = newValue
            super.nextResponder = newValue
        }
    }

    /// Offered where the link sheet can open, judged by the kinds of data on offer: reading the data outside a paste can make macOS ask.
    static func offersPaste(for model: AppModel, windowIsKey: Bool, windowHasSheet: Bool) -> Bool {
        guard windowIsKey, !windowHasSheet, model.features.isEnabled(.youtube), !model.introduction.isPresented else {
            return false
        }
        switch model.phase {
        case .idle, .ready, .failed: return PastedLink.mayHoldLink(on: model.linkPasteboard)
        default: return false
        }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(paste(_:)), let model, let window else { return false }
        return Self.offersPaste(for: model, windowIsKey: window.isKeyWindow, windowHasSheet: window.attachedSheet != nil)
    }

    @objc func paste(_ sender: Any?) {
        guard let model, let link = PastedLink.url(on: model.linkPasteboard) else { return }
        model.openLinkSheet(prefill: link)
    }

    /// Right after the window, so a text field or anything else focused that pastes on its own is asked first.
    func attach(to window: NSWindow) {
        self.window = window
        var responder = window.nextResponder
        while let current = responder {
            if current === self { return }
            responder = current.nextResponder
        }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    func detach(from window: NSWindow) {
        var previous: NSResponder = window
        while let current = previous.nextResponder {
            if current === self {
                previous.nextResponder = nextResponder
                break
            }
            previous = current
        }
        nextResponder = nil
        if self.window === window { self.window = nil }
    }
}

/// Keeps a `LinkPasteResponder` in the chain of the window this content sits in, for as long as it sits there.
struct LinkPasteInstaller: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        InstallingView(responder: LinkPasteResponder(model: model))
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallingView: NSView {
        /// AppKit doesn't retain a next responder, so the view holds the one it puts in the chain.
        private let responder: LinkPasteResponder

        init(responder: LinkPasteResponder) {
            self.responder = responder
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window, window !== newWindow { responder.detach(from: window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { responder.attach(to: window) }
        }
    }
}
