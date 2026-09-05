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
                    .font(.headline)
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips) { chip in
                            ModelTagChip(label: chip.label, color: chip.color)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .contextMenu {
            if canDelete, let deleteAction {
                Button(role: .destructive, action: deleteAction) {
                    Label("Delete from disk", systemImage: "trash")
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
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(iconTint.opacity(0.15))
            Image(systemName: iconName)
                .font(DS.Font.title3)
                .foregroundStyle(iconTint)
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var trailing: some View {
        if isDeleting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Deleting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch kind {
            case .active:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Active model")
            case .installed:
                HStack(spacing: 6) {
                    if let deleteAction {
                        Button(action: deleteAction) {
                            Image(systemName: "trash")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
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
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text(progressPercent(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let cancelAction {
                        Button(action: cancelAction) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
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
            result.append(.init(label: "High accuracy", color: DS.Palette.warning))
        }
        if variant.speedTier == .fastest {
            result.append(.init(label: "Fast", color: DS.Palette.success))
        }
        if case .some(.only(let codes)) = variant.languageScope, codes == ["en"] {
            result.append(.init(label: "English-only", color: DS.Color.secondaryText))
        }
        return result
    }

    private var iconName: String {
        switch variant.engineID {
        case .parakeet: return "bird"
        case .whisperKit: return "waveform"
        default: return "cpu"
        }
    }

    private var iconTint: Color {
        switch variant.engineID {
        case .parakeet: return .green
        case .whisperKit: return DS.Color.accent
        default: return .secondary
        }
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
        return "\(Int(clamped * 100))%"
    }
}

struct ModelTagChip: View {
    struct Chip: Identifiable {
        let label: String
        let color: Color
        var id: String { label }
    }

    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

