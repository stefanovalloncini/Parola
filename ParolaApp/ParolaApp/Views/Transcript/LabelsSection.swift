import SwiftUI
import ParolaCore

struct LabelsSection: View {
    @Environment(AppModel.self) private var model
    @State private var draftLabel: String = ""

    private var entry: LibraryEntry? {
        guard let id = model.selectedEntryID else { return nil }
        return model.libraryEntry(id: id)
    }

    private var labels: [String] { entry?.labels ?? [] }

    var body: some View {
        if entry != nil {
            InspectorSection(title: "Labels") {
                if labels.isEmpty {
                    Text("No labels yet")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.secondaryText)
                } else {
                    chipFlow
                }
                composer
            }
        }
    }

    private var chipFlow: some View {
        FlowLayout(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                chip(label)
            }
        }
    }

    private func chip(_ label: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(DS.Font.subheadlineMedium)
            Button { remove(label) } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption2Bold)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove label \(label)")
            .axLeaf("Labels.Button.RemoveChip")
        }
        .foregroundStyle(DS.Color.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(DS.Color.accent.opacity(0.12))
        )
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("Add label", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(addDraft)
                .axLeaf("Labels.TextField.AddLabel")
            if !model.allKnownLabels.isEmpty {
                Menu {
                    ForEach(model.allKnownLabels, id: \.self) { suggestion in
                        Button(suggestion) {
                            add(suggestion)
                        }
                    }
                } label: {
                    Image(systemName: "tag")
                        .font(DS.Font.subheadline)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 22)
                .accessibilityLabel("Add label")
                .axLeaf("Labels.Menu.Suggestions")
            }
        }
    }

    private func addDraft() {
        add(draftLabel)
        draftLabel = ""
    }

    private func add(_ label: String) {
        guard let entry else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = labels
        guard !next.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        next.append(trimmed)
        model.setLabels(next, for: entry.id)
    }

    private func remove(_ label: String) {
        guard let entry else { return }
        let next = labels.filter { $0 != label }
        model.setLabels(next, for: entry.id)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
