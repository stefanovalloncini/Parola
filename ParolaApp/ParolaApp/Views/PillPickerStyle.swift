import SwiftUI

/// One segment of the toolbar's intake capsule: no shell of its own, just a hover fill inside the shared one.
struct IntakeSegment<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, DS.Spacing.regular)
                .frame(height: ToolbarCapsule.height)
                .background(hovering ? DS.Palette.subtleFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : DS.Opacity.disabled)
        .onHover { hovering = isEnabled && $0 }
    }
}

/// A segment borrows the toolbar capsule's chrome; a standalone pill wears its own so it can sit in a settings row.
enum PillPickerShell {
    case segment
    case standalone
}

extension EnvironmentValues {
    /// Rows call it after a pick so the popover closes the way a menu does; controls that refine the list leave it open.
    @Entry var dismissPillPopover: () -> Void = {}
}

struct PillPickerButton<MenuContent: View>: View {
    let icon: String
    let caption: String
    let value: String
    var shell: PillPickerShell = .segment
    let popoverWidth: CGFloat
    var leaf: String? = nil
    @ViewBuilder var menuContent: () -> MenuContent

    @State private var isPresented = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        control
            .accessibilityLabel("\(caption): \(value)")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                menuContent()
                    .padding(.vertical, DS.Spacing.snug)
                    .frame(width: popoverWidth)
                    .environment(\.dismissPillPopover, { isPresented = false })
            }
            .axLeaf(leaf ?? "Pill.Button.\(caption)")
    }

    @ViewBuilder
    private var control: some View {
        switch shell {
        case .segment:
            IntakeSegment {
                isPresented = true
            } label: {
                label
            }
        case .standalone:
            Button {
                isPresented = true
            } label: {
                label
                    .padding(.leading, DS.Spacing.regular)
                    .padding(.trailing, DS.Spacing.small + DS.Spacing.hair)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(hovering ? DS.Palette.pillFillHover : DS.Palette.pillFill))
                    .overlay(Capsule(style: .continuous).strokeBorder(DS.Color.separator.opacity(0.6), lineWidth: 0.5))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : DS.Opacity.disabled)
            .onHover { hovering = isEnabled && $0 }
        }
    }

    private var label: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 14)
            Text(value)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(DS.Font.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct PillToggleButton: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(DS.Font.bodyStrong)
                    .frame(width: 14)
                Text(label)
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? DS.Color.onAccent : Color.primary)
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.tight)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .axLeaf("Pill.Toggle.\(label)")
    }

    private var fillColor: Color {
        if isOn { return DS.Color.accent.opacity(hovering ? 0.95 : 0.85) }
        return Color.primary.opacity(hovering ? 0.10 : 0.06)
    }

    private var borderColor: Color {
        isOn ? DS.Color.accent.opacity(0.45) : Color.primary.opacity(0.08)
    }
}

/// Caps a popover list at a screen-friendly height; a shorter list keeps its own height so the popover hugs it.
struct PillPopoverList<Content: View>: View {
    var maxHeight: CGFloat = 440
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                content()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
        .frame(maxHeight: maxHeight)
    }
}

struct PillPopoverRow: View {
    enum Leading {
        case none
        case symbol(String, tint: Color? = nil)
        case tile(String, tint: Color)
        case monogram(String)
    }

    enum Trailing: Equatable {
        case none
        case text(String)
        case download(String)
        case progress(Double)
    }

    let title: String
    var subtitle: String? = nil
    var subtitleTint: Color? = nil
    var badge: String? = nil
    var isSelected = false
    var isDimmed = false
    var leading: Leading = .none
    var trailing: Trailing = .none
    var minHeight: CGFloat? = nil
    var dismissesOnSelect = true
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.dismissPillPopover) private var dismissPopover

    static let leadingSlot: CGFloat = 26
    /// Rows in a list with subtitles share this height, so a row without one stays as tall as its neighbours.
    static let twoLineHeight: CGFloat = 44

    var body: some View {
        Button {
            action()
            if dismissesOnSelect { dismissPopover() }
        } label: {
            HStack(spacing: DS.Spacing.small) {
                leadingView
                    .opacity(isDimmed ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Spacing.snug) {
                        Text(title)
                            .font(DS.Font.bodyStrong)
                            .foregroundStyle(isDimmed ? DS.Color.secondaryText : DS.Color.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge {
                            ModelTagChip(label: badge, fill: DS.Color.neutralChip.fill, text: DS.Color.neutralChip.text)
                                .fixedSize()
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Font.secondary)
                            .foregroundStyle(subtitleTint ?? DS.Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailingView
                    .fixedSize()
                Image(systemName: "checkmark")
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.snug)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .axLeaf("Pill.PopoverRow.\(title)")
    }

    private var fill: Color {
        if isSelected { return DS.Color.accentWash }
        return hovering ? Color.secondary.opacity(0.18) : Color.clear
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(tint ?? DS.Color.secondaryText)
                .frame(width: Self.leadingSlot, height: Self.leadingSlot)
        case .tile(let name, let tint):
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(tint.opacity(0.15))
                Image(systemName: name)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(tint)
            }
            .frame(width: Self.leadingSlot, height: Self.leadingSlot)
        case .monogram(let text):
            Text(verbatim: text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: Self.leadingSlot, height: Self.leadingSlot)
                .background(Circle().fill(DS.Palette.pillFill))
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(DS.Font.secondary)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
        case .download(let text):
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle")
                    .font(DS.Font.secondary)
                Text(text)
                    .font(DS.Font.secondary)
                    .monospacedDigit()
            }
            .foregroundStyle(DS.Color.secondaryText)
        case .progress(let value):
            HStack(spacing: 5) {
                PillProgressRing(value: value)
                Text(AppFormat.percent(max(0, min(1, value))))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }
}

struct PillProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Palette.pillFill, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(DS.Color.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.progress, value: value)
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

struct PillPopoverSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.small)
            .padding(.bottom, DS.Spacing.hair)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
