import ArgumentParser
import Foundation
import ParolaCore

struct Burn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "burn",
        abstract: "Burn an SRT subtitle track into a video via ffmpeg."
    )

    @Argument(help: "Path to the source video.")
    var video: String

    @Option(name: .long, help: "Path to the SRT file to burn in. Required if --parola isn't given.")
    var srt: String?

    @Option(name: .long, help: "Path to a .parola bundle. Its transcript is rendered to SRT on the fly.")
    var parola: String?

    @Option(name: .shortAndLong, help: "Output video path.")
    var output: String

    @Option(name: .long, help: "Subtitle font (default: Helvetica-Bold).")
    var font: String = "Helvetica-Bold"

    @Option(name: .long, help: "Subtitle font size (default: 28).")
    var fontSize: Double = 28

    func run() async throws {
        CLIDiagnostics.installIfWanted(alwaysOn: false)
        let videoURL = URL(fileURLWithPath: video).resolvingSymlinksInPath()
        let outputURL = URL(fileURLWithPath: output)
        let style = SubtitleBurner.Style(fontName: font, fontSize: CGFloat(fontSize))

        let transcript: Transcript
        switch (srt, parola) {
        case (let srtPath?, nil):
            transcript = try SrtImporter.parse(contentsOf: URL(fileURLWithPath: srtPath))
        case (nil, let parolaPath?):
            transcript = try ParolaDocument.read(at: URL(fileURLWithPath: parolaPath)).transcript
        case (nil, nil):
            throw ValidationError("Pass either --srt <path> or --parola <bundle>.")
        case (_?, _?):
            throw ValidationError("Pass --srt OR --parola, not both.")
        }

        try await SubtitleBurner.burn(transcript: transcript, video: videoURL, to: outputURL, style: style)
        stderr("Wrote \(outputURL.path)")
    }
}
