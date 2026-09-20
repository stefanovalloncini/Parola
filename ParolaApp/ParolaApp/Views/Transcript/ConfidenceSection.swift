import SwiftUI
import ParolaCore

struct ConfidenceSection: View {
    let overall: Double?
    let lows: [TranscriptSegment]

    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        if let overall {
            InspectorSection(title: "Confidence") {
                summaryRow(overall: overall)
                if !lows.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(lows) { seg in
                                lowRow(seg)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Group {
                            if lows.count == 1 {
                                Text("1 low-confidence segment")
                            } else {
                                Text("\(lows.count) low-confidence segments")
                            }
                        }
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
        }
    }

    private func summaryRow(overall: Double) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Circle()
                .fill(color(for: overall))
                .frame(width: 10, height: 10)
            Text("Overall")
                .font(DS.Font.body)
            Spacer()
            Text(percentLabel(overall))
                .font(DS.Font.body.monospacedDigit())
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    private func lowRow(_ seg: TranscriptSegment) -> some View {
        Button {
            model.seek(to: seg)
        } label: {
            HStack(spacing: DS.Spacing.tight) {
                Text(Timecode.format(seg.start))
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.accentText)
                    .frame(width: 50, alignment: .leading)
                Text(seg.text)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let value = SegmentConfidence.average(for: seg) {
                    Text(percentLabel(value))
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to \(Timecode.format(seg.start))")
    }

    private func color(for value: Double) -> Color {
        DS.confidenceColor(for: SegmentConfidence.bucket(for: value))
    }

    private func percentLabel(_ value: Double) -> String {
        AppFormat.percent(value)
    }
}
