import SwiftUI

struct PresenterCaptionsView: View {
    @Bindable var controller: LiveCaptionsController
    let onClose: () -> Void

    @AppStorage("presenter.fontSize") private var fontSize: Double = 96
    @State private var hovering = false

    private var caption: String {
        if !controller.state.partial.isEmpty { return controller.state.partial }
        return controller.state.confirmedLines.last ?? ""
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            content
                .padding(.horizontal, 120)
                .padding(.vertical, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if hovering {
                closeButton
                    .padding(28)
                    .transition(.opacity)
            }
        }
        .background(KeyEventCatcher(onEscape: onClose))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .axBranch("Presenter")
    }

    @ViewBuilder
    private var content: some View {
        if let error = controller.state.error {
            Text(error)
                .font(.system(size: fontSize / 2, weight: .semibold))
                .foregroundStyle(.red.opacity(0.85))
                .multilineTextAlignment(.center)
        } else if caption.isEmpty {
            VStack(spacing: 24) {
                Image(systemName: controller.state.isLoading ? "arrow.down.circle" : "waveform")
                    .font(.system(size: fontSize / 2))
                    .foregroundStyle(.white.opacity(0.4))
                    .symbolEffect(.variableColor.iterative, isActive: controller.state.isActive)
                Text(controller.state.isLoading ? "Loading model…" : "Waiting for speech…")
                    .font(.system(size: fontSize / 2.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        } else {
            Text(caption)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.8))
                .padding(8)
                .background(Circle().fill(.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help("Exit Presenter (Esc)")
    }
}

private struct KeyEventCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onEscape = onEscape
    }

    final class KeyView: NSView {
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Escape
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
