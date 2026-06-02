import SwiftUI
import ParolaCore
import AppKit

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            AboutInfoView()
                .padding(.top, 8)

            HStack(spacing: 10) {
                Button("Open repository") {
                    if let url = URL(string: "https://github.com/stefanovalloncini/Parola") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .axLeaf("About.Button.OpenRepository")
                Button("Copy version") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Parola \(AboutInfo.versionString)", forType: .string)
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
