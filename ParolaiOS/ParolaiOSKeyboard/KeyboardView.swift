import SwiftUI

struct KeyboardView: View {
    let onDictate: () -> Void
    let onSwitchKeyboard: () -> Void
    let onDeleteBackward: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Button(action: onDictate) {
                VStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                    Text("Tap to dictate")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("Full Access is required for transcription. Coming soon.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            HStack {
                Button(action: onSwitchKeyboard) {
                    Image(systemName: "globe")
                        .font(.title2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Spacer()
                Button(action: onDeleteBackward) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }
}
