import SwiftUI
import ParolaCore
import AppKit

struct AboutPane: View {
    @State private var copiedVersion = false

    var body: some View {
        VStack(spacing: 16) {
            AboutInfoView()
                .padding(.top, 8)

            HStack(spacing: 10) {
                Button("Open repository") {
                    NSWorkspace.shared.open(SupportLinks.repository)
                }
                .axLeaf("About.Button.OpenRepository")
                Button(copiedVersion ? "Copied" : "Copy version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Parola \(AboutInfo.versionString)", forType: .string)
                    copiedVersion = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedVersion = false
                    }
                }
                .axLeaf("About.Button.CopyVersion")
            }
            .controlSize(.small)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
