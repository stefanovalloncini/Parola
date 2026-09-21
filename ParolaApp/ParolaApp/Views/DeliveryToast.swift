import AppKit
import SwiftUI
import ParolaCore

/// The strip that appears under the transcript after a send. It never blocks the window and it
/// takes itself away after a few seconds.
struct DeliveryToast: View {
    @Environment(AppModel.self) private var model
    let notice: DeliveryNotice

    static let dismissAfter: Duration = .seconds(6)

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.regular) {
            Image(systemName: symbol)
                .font(DS.Font.bodyStrong)
                .foregroundStyle(tint)
            messageText
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.small)
            actions
            Button {
                model.dismissDeliveryNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .axLeaf("Delivery.Button.Dismiss")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .fill(DS.Color.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .padding(DS.Spacing.regular)
        .task(id: notice) {
            try? await Task.sleep(for: Self.dismissAfter)
            guard !Task.isCancelled, model.deliveryNotice == notice else { return }
            model.dismissDeliveryNotice()
        }
        .axBranch("DeliveryToast")
    }

    @ViewBuilder
    private var actions: some View {
        switch notice.state {
        case .sent(let location):
            if let location {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .axLeaf("Delivery.Button.Reveal")
                if Self.obsidianIsInstalled,
                   let url = ObsidianVaultFolderDestination.openInObsidianURL(for: location) {
                    Button("Open in Obsidian") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Delivery.Button.OpenInObsidian")
                }
            }
        case .queued, .failed:
            Button("Retry") {
                Task { await model.retryDelivery() }
            }
            .buttonStyle(DSPillButtonStyle(kind: .primary, size: .compact))
            .axLeaf("Delivery.Button.Retry")
        }
    }

    private var messageText: Text {
        switch notice.state {
        case .sent:
            return Text("Sent to \(notice.destinationName)")
        case .queued(let nextAt):
            return Text("Couldn't send to \(notice.destinationName), retrying \(Self.retryText(for: nextAt))")
        case .failed(let message):
            // The reason comes from the failure, not the catalog, and a path in it must not be read as markdown.
            return Text(verbatim: message)
        }
    }

    private var symbol: String {
        switch notice.state {
        case .sent: return "checkmark.circle.fill"
        case .queued: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.state {
        case .sent: return DS.Palette.success
        case .queued: return DS.Palette.warning
        case .failed: return DS.Color.danger
        }
    }

    static func retryText(for date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }

    /// Obsidian answers the `obsidian://` scheme; without it the Open button would land nowhere.
    static var obsidianIsInstalled: Bool {
        guard let scheme = URL(string: "obsidian://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: scheme) != nil
    }
}
