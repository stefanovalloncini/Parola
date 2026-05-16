import SwiftUI
import ParolaCore

struct LiveCaptionsView: View {
    @ObservedObject var controller: LiveCaptionsController
    @AppStorage("liveCaptions.opacity") private var opacity: Double = 1.0
    @AppStorage("liveCaptions.fontSize") private var fontSize: Double = 22

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minWidth: 560, maxWidth: .infinity, alignment: .center)
            .background(background)
            .overlay(border)
            .overlay(alignment: .topTrailing) {
                modeChip.padding(.top, 10).padding(.trailing, 12)
            }
            .opacity(opacity)
            .contextMenu { settingsMenu }
            .animation(.easeOut(duration: 0.22), value: caption)
    }

    @ViewBuilder
    private var content: some View {
        if let error = controller.state.error {
            Text(error)
                .font(.callout)
                .foregroundStyle(DS.Color.danger.opacity(0.9))
                .multilineTextAlignment(.center)
        } else if caption.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: controller.state.isActive)
                Text("Listening")
            }
            .font(.system(size: fontSize - 6, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        } else {
            Text(caption)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .id(caption)
                .transition(.opacity)
        }
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
    private var modeChip: some View {
        let translating = controller.translateToEnglish
        HStack(spacing: 6) {
            Image(systemName: translating ? "character.bubble" : "mic.fill")
                .font(.system(size: 9, weight: .bold))
            Text(translating ? "Translate" : "Mic")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
        }
        .foregroundStyle(translating ? Color.white : Color.white.opacity(0.7))
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(Capsule().fill(chipFill(translating: translating)))
    }

    private func chipFill(translating: Bool) -> some ShapeStyle {
        translating ? AnyShapeStyle(DS.Color.accent) : AnyShapeStyle(Color.white.opacity(0.12))
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu("Opacity") {
            Button("100%") { opacity = 1.0 }
            Button("85%") { opacity = 0.85 }
            Button("70%") { opacity = 0.7 }
            Button("50%") { opacity = 0.5 }
        }
        Menu("Caption size") {
            Button("Small") { fontSize = 18 }
            Button("Medium") { fontSize = 22 }
            Button("Large") { fontSize = 28 }
            Button("Huge") { fontSize = 36 }
        }
    }

    private var caption: String {
        let last = controller.state.confirmedLines.last
        let partial = controller.state.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return [last, partial.isEmpty ? nil : partial]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
