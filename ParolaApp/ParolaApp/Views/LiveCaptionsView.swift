import SwiftUI
import ParolaCore

struct LiveCaptionsView: View {
    @Bindable var controller: LiveCaptionsController
    @AppStorage("liveCaptions.opacity", store: DefaultsStore.current) private var opacity: Double = 1.0
    // Fixed pt by design: the caption overlay has its own user size control (context menu → Caption size).
    @AppStorage("liveCaptions.fontSize", store: DefaultsStore.current) private var fontSize: Double = 22

    private static let horizontalInset: CGFloat = 22
    private static let verticalInset: CGFloat = 18
    private static let chipRowTopInset: CGFloat = 10

    var body: some View {
        VStack(spacing: DS.Spacing.small) {
            HStack {
                Spacer(minLength: 0)
                LiveCaptionsChip(controller: controller)
            }
            content
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.top, Self.chipRowTopInset)
        .padding(.bottom, Self.verticalInset)
        .frame(minWidth: 560, maxWidth: .infinity, alignment: .center)
        .background(background)
        .overlay(border)
        .opacity(opacity)
        .contextMenu { settingsMenu }
        .axBranch("LiveCaptions")
    }

    @ViewBuilder
    private var content: some View {
        if let error = controller.state.error {
            VStack(spacing: DS.Spacing.small) {
                Text(error)
                    .font(DS.Font.secondary)
                    // This overlay paints its own dark scrim, so surface-derived colours read too dark here.
                    .foregroundStyle(DS.Color.dangerOnDark.opacity(0.9))
                    .multilineTextAlignment(.center)
                if !controller.state.isActive {
                    HStack(spacing: DS.Spacing.small) {
                        if let permission = controller.failurePermission {
                            Button("Open Settings") { controller.openPermission(permission) }
                                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                                .axLeaf("Button.OpenSettings")
                        }
                        Button("Retry") { Task { await controller.tryAgain() } }
                            .buttonStyle(DSPillButtonStyle(kind: controller.failurePermission == nil ? .primary : .secondary, size: .compact))
                            .axLeaf("Button.Retry")
                        Button("Close") { controller.closeFailure() }
                            .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                            .axLeaf("Button.Close")
                    }
                }
            }
        } else if caption.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: controller.state.isLoading ? "arrow.down.circle" : "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: controller.state.isActive)
                Text(statusText)
            }
            .font(.system(size: fontSize - 6, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        } else {
            Text(caption)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: captionHeight, maxHeight: captionHeight, alignment: .bottom)
                .clipped()
                .mask(rollUpFade)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.22), value: controller.state.history.count)
                .accessibilityLabel(caption)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var statusText: LocalizedStringKey {
        guard controller.state.isLoading else { return "Listening" }
        guard let fraction = controller.state.downloadFraction else { return "Loading model" }
        return "Downloading model \(Int((fraction * 100).rounded())) %"
    }

    /// Two lines tall, newest words at the bottom: older ones scroll off the top.
    private var captionHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        return (NSLayoutManager().defaultLineHeight(for: font) * 2).rounded(.up)
    }

    private var rollUpFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)], startPoint: .top, endPoint: .bottom)
    }

    private var background: some View {
        ZStack {
            Color.black.opacity(0.6)
            Rectangle().fill(.regularMaterial).opacity(0.55)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu("Style") {
            Button("Cinema") { apply(.cinema) }
                .axLeaf("ContextMenu.MenuItem.StyleCinema")
            Button("Compact") { apply(.compact) }
                .axLeaf("ContextMenu.MenuItem.StyleCompact")
            Button("Subtle") { apply(.subtle) }
                .axLeaf("ContextMenu.MenuItem.StyleSubtle")
        }
        .axLeaf("ContextMenu.Menu.Style")
        Menu("Opacity") {
            Button("100%") { opacity = 1.0 }
                .axLeaf("ContextMenu.MenuItem.Opacity100")
            Button("85%") { opacity = 0.85 }
                .axLeaf("ContextMenu.MenuItem.Opacity85")
            Button("70%") { opacity = 0.7 }
                .axLeaf("ContextMenu.MenuItem.Opacity70")
            Button("50%") { opacity = 0.5 }
                .axLeaf("ContextMenu.MenuItem.Opacity50")
        }
        .axLeaf("ContextMenu.Menu.Opacity")
        Menu("Caption Size") {
            Button("Small") { fontSize = 18 }
                .axLeaf("ContextMenu.MenuItem.SizeSmall")
            Button("Medium") { fontSize = 22 }
                .axLeaf("ContextMenu.MenuItem.SizeMedium")
            Button("Large") { fontSize = 28 }
                .axLeaf("ContextMenu.MenuItem.SizeLarge")
            Button("Huge") { fontSize = 36 }
                .axLeaf("ContextMenu.MenuItem.SizeHuge")
        }
        .axLeaf("ContextMenu.Menu.CaptionSize")
    }

    private func apply(_ preset: LiveCaptionStylePreset) {
        opacity = preset.opacity
        fontSize = preset.fontSize
    }

    private var caption: String { controller.state.captionText }
}

enum LiveCaptionStylePreset {
    case cinema
    case compact
    case subtle

    var opacity: Double {
        switch self {
        case .cinema: return 1.0
        case .compact: return 0.95
        case .subtle: return 0.7
        }
    }

    var fontSize: Double {
        switch self {
        case .cinema: return 32
        case .compact: return 20
        case .subtle: return 22
        }
    }
}

/// The source and translate chip; the panel gives it a row of its own so it never sits over the caption text.
struct LiveCaptionsChip: View {
    @Bindable var controller: LiveCaptionsController
    private static let inset: CGFloat = 9

    var body: some View {
        let translating = controller.translateToEnglish
        HStack(spacing: 6) {
            Image(systemName: translating ? "character.bubble" : Self.symbol(for: controller.source))
                .font(DS.Font.caption)
            Group {
                if translating {
                    Text("Translate")
                } else {
                    sourceName
                }
            }
            .font(DS.Font.mono.weight(.semibold))
            .textCase(.uppercase)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 150)
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(translating ? DS.Color.onAccent : Color.white.opacity(0.7))
        .padding(.horizontal, Self.inset)
        .frame(height: 20)
        .background(Capsule().fill(chipFill(translating: translating)))
    }

    @ViewBuilder
    private var sourceName: some View {
        switch controller.source {
        case .microphone: Text("Mic")
        case .systemAudio: Text("System")
        case .app(let bundleID): Text(verbatim: controller.appName(bundleID))
        }
    }

    private static func symbol(for source: CaptionSource) -> String {
        switch source {
        case .microphone: "mic.fill"
        case .systemAudio: "speaker.wave.2.fill"
        case .app: "macwindow"
        }
    }

    private func chipFill(translating: Bool) -> Color {
        translating ? DS.Color.accentFill : Color.white.opacity(0.12)
    }
}
