import SwiftUI
import ParolaCore

struct TranscriptDetailView: View {
    let entryID: LibraryEntry.ID
    @EnvironmentObject var model: AppModel
    @State private var loaded: LoadedEntry?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loaded {
                List {
                    Section {
                        Text(loaded.entry.title).font(.title2.weight(.semibold))
                        Text(loaded.entry.createdAt, style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Transcript") {
                        ForEach(loaded.document.transcript.segments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(timestamp(segment.start))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(segment.text.trimmingCharacters(in: .whitespaces))
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: loaded.document.transcript.text)
                    }
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .task(id: entryID) {
            do {
                loaded = try await model.library.load(entryID)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let m = (total % 3600) / 60
        let sec = total % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
