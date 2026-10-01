import SwiftUI
import ParolaCore

/// The take's title and Note | Meeting, centred in the toolbar over the Stage.
struct TakeTitleBar: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model

    nonisolated static let fieldWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: DS.Spacing.regular) {
            TakeTitleField(take: take)
                .frame(width: Self.fieldWidth)
                .id(take.takeID)
            if model.features.isEnabled(.meetings) {
                TakeCategoryPicker(take: take)
            }
        }
        .disabled(!Self.isEditable(take))
    }

    /// The take the Stage shows from Record until its capture winds down; nil on every other page.
    static func take(on model: AppModel) -> RecordingSession? {
        guard model.route == .recording, let take = model.recording else { return nil }
        switch take.state {
        case .arming, .recording, .paused, .finishing: return take
        case .transcribing, .done, .failed: return nil
        }
    }

    /// Until Stop the name and the category are the user's to change; after it they are what the take is saved with.
    nonisolated static func isEditable(_ take: RecordingSession) -> Bool {
        take.isArming || take.isCapturing
    }
}

struct TakeTitleField: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model
    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Title", text: Binding(
            get: { draft ?? take.title },
            set: { text in
                draft = text
                Self.commit(text, to: take.takeID, model: model)
            }
        ))
        .textFieldStyle(.plain)
        .font(DS.Font.heading)
        .foregroundStyle(DS.Color.primaryText)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .focused($focused)
        .onSubmit { focused = false }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { draft = nil }
        }
        .accessibilityLabel("Title")
        .axLeaf("Stage.TextField.Title")
    }

    /// Every keystroke lands, so Stop (⌘⏎ included) saves what the field shows, and only on the take it was typed for.
    static func commit(_ text: String, to takeID: Int, model: AppModel) {
        guard model.recording?.takeID == takeID else { return }
        model.renameTake(text)
    }
}

struct TakeCategoryPicker: View {
    let take: RecordingSession
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Category", selection: Binding(
            get: { take.category },
            set: { Self.choose($0, for: take.takeID, model: model) }
        )) {
            Text("Note").tag(EntryCategory.transcription)
            Text("Meeting").tag(EntryCategory.meeting)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .axLeaf("Stage.Picker.Category")
    }

    static func choose(_ category: EntryCategory, for takeID: Int, model: AppModel) {
        guard model.recording?.takeID == takeID else { return }
        model.setTakeCategory(category)
    }
}
