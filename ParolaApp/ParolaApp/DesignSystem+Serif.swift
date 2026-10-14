import SwiftUI

private struct SerifTranscriptKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var serifTranscript: Bool {
        get { self[SerifTranscriptKey.self] }
        set { self[SerifTranscriptKey.self] = newValue }
    }
}

extension View {
    func serifTranscript(_ serif: Bool) -> some View {
        environment(\.serifTranscript, serif)
    }
}
