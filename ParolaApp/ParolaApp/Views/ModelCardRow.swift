import SwiftUI
import ParolaCore

struct ModelCardRow: View {
    enum Kind {
        case active
        case installed
        case available
        case downloading(progress: Double)
    }

    let variant: ModelVariant
    let kind: Kind
    var actualSizeBytes: Int64? = nil
    var isDeleting: Bool = false
    var downloadDisabled: Bool = false
    let primaryAction: () -> Void
    var deleteAction: (() -> Void)? = nil
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 6) {
                Text(variant.displayName)
                    .font(DS.Font.heading)
                Text(meta)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            ModelTagChip(label: chip.label, fill: chip.fill, text: chip.text)
                        }
                    }
                    .padding(.top, DS.Spacing.hair)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(DS.Spacing.regular)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .contextMenu {
            if canDelete, let deleteAction {
                Button(role: .destructive, action: deleteAction) {
                    Label("Delete from Disk", systemImage: "trash")
                }
                .axLeaf("Card.ContextMenuItem.Delete")
            }
        }
    }

    private var canDelete: Bool {
        switch kind {
        case .installed: return !isDeleting
        case .active, .available, .downloading: return false
        }
    }

    private var iconTile: some View {
        ModelEngineIcon(engineID: variant.engineID)
    }

    @ViewBuilder
    private var trailing: some View {
        if isDeleting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Deleting…")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        } else {
            switch kind {
            case .active:
                Image(systemName: "checkmark.circle.fill")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Active model")
            case .installed:
                HStack(spacing: 6) {
                    if let deleteAction {
                        Button(action: deleteAction) {
                            Image(systemName: "trash")
                                .font(DS.Font.bodyStrong)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Color.secondaryText)
                        .help("Delete this model from disk")
                        .accessibilityLabel("Delete \(variant.displayName)")
                        .accessibilityIdentifier("model.\(variant.id).delete")
                        .axLeaf("Card.Button.Delete")
                    }
                    Button(action: primaryAction) {
                        Text("Activate")
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                    .accessibilityIdentifier("model.\(variant.id).activate")
                    .axLeaf("Card.Button.Activate")
                }
            case .available:
                Button(action: primaryAction) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down")
                        Text("Download")
                    }
                }
                .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
                .disabled(downloadDisabled)
                .help(downloadDisabled ? "Another model is downloading. Wait or cancel it first." : "")
                .accessibilityIdentifier("model.\(variant.id).download")
                .axLeaf("Card.Button.Download")
            case .downloading(let progress):
                HStack(spacing: 8) {
                    DSProgressBar(value: progress)
                        .frame(width: 80)
                    Text(progressPercent(progress))
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                    if let cancelAction {
                        Button(action: cancelAction) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Color.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel this download")
                        .accessibilityLabel("Cancel download of \(variant.displayName)")
                        .axLeaf("Card.Button.CancelDownload")
                    }
                }
            }
        }
    }

    private var meta: String {
        let sizeBytes = actualSizeBytes.map { Int($0) } ?? Int(variant.sizeBytes)
        guard sizeBytes > 0 else { return engineLabel }
        return "\(engineLabel) · \(AppFormat.byteSize(sizeBytes))"
    }

    private var engineLabel: String {
        variant.engineID.displayName
    }

    private var chips: [ModelTagChip.Chip] {
        var result: [ModelTagChip.Chip] = []
        if variant.qualityTier == .best {
            result.append(.init(label: "High accuracy", tokens: DS.Color.warningChip))
        }
        if variant.speedTier == .fastest {
            result.append(.init(label: "Fast", tokens: DS.Color.successChip))
        }
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] {
            result.append(.init(label: "English-only", tokens: DS.Color.neutralChip))
        }
        return result
    }

    private var borderColor: Color {
        if case .active = kind { return DS.Color.accent.opacity(0.55) }
        return DS.Color.separator.opacity(0.6)
    }

    private var borderWidth: CGFloat {
        if case .active = kind { return 1.5 }
        return 0.5
    }

    private func progressPercent(_ value: Double) -> String {
        let clamped = max(0, min(1, value))
        return AppFormat.percent(clamped)
    }
}

/// The tile a model wears wherever it is shown: one glyph and one tint per engine.
struct ModelEngineIcon: View {
    let engineID: EngineID

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(Self.tint(for: engineID).opacity(0.15))
            Image(systemName: Self.symbol(for: engineID))
                .font(DS.Font.heading)
                .foregroundStyle(Self.tint(for: engineID))
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    static func symbol(for engineID: EngineID) -> String {
        switch engineID {
        case .parakeet: return "bird"
        case .whisperKit: return "waveform"
        default: return "cpu"
        }
    }

    static func tint(for engineID: EngineID) -> Color {
        switch engineID {
        case .parakeet: return .green
        case .whisperKit: return DS.Color.accent
        default: return .secondary
        }
    }
}

struct ModelTagChip: View {
    struct Chip: Identifiable {
        let label: String
        let fill: Color
        let text: Color
        var id: String { label }

        init(label: String, tokens: (fill: Color, text: Color)) {
            self.label = label
            self.fill = tokens.fill
            self.text = tokens.text
        }
    }

    let label: String
    let fill: Color
    let text: Color

    var body: some View {
        Text(label)
            .font(DS.Font.caption)
            .foregroundStyle(text)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.hair)
            .background(fill, in: Capsule())
    }
}

