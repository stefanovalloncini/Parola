import CoreGraphics
import CoreText
import Foundation

struct PdfExporter: TranscriptExporter {
    let format: ExportFormat = .pdf
    init() {}

    private static let pageWidth: CGFloat = 612    // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54        // 0.75 inch
    private static let segmentsPerChunk: Int = 64

    func render(_ transcript: Transcript) throws -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw ParolaError.ioError("Could not create PDF data consumer.")
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ParolaError.ioError("Could not create PDF context.")
        }

        let textRect = mediaBox.insetBy(dx: Self.margin, dy: Self.margin)
        let path = CGPath(rect: textRect, transform: nil)
        let fonts = Fonts.make(language: transcript.language)

        var iterator = ChunkIterator(transcript: transcript, fonts: fonts, chunkSize: Self.segmentsPerChunk)
        while let chunk = iterator.next() {
            guard chunk.length > 0 else { continue }
            let framesetter = CTFramesetterCreateWithAttributedString(chunk)
            var startIndex = 0
            while startIndex < chunk.length {
                context.beginPDFPage(nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(startIndex, 0), path, nil)
                CTFrameDraw(frame, context)
                let visible = CTFrameGetVisibleStringRange(frame)
                context.endPDFPage()
                guard visible.length > 0 else { break }
                startIndex += visible.length
            }
        }

        context.closePDF()
        return pdfData as Data
    }

    private struct Fonts {
        let title: CTFont
        let body: CTFont
        let speaker: CTFont

        static func make(language: String) -> Fonts {
            Fonts(
                title: Format.cascadingFont(name: "Helvetica-Bold", size: 18, language: language),
                body: Format.cascadingFont(name: "Helvetica", size: 12, language: language),
                speaker: Format.cascadingFont(name: "Helvetica-Bold", size: 12, language: language)
            )
        }
    }

    private struct ChunkIterator {
        let transcript: Transcript
        let fonts: Fonts
        let chunkSize: Int
        private var cursor: Int = 0
        private var emittedTitle: Bool = false

        init(transcript: Transcript, fonts: Fonts, chunkSize: Int) {
            self.transcript = transcript
            self.fonts = fonts
            self.chunkSize = max(1, chunkSize)
        }

        mutating func next() -> NSAttributedString? {
            let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
            let chunk = NSMutableAttributedString()
            if !emittedTitle {
                chunk.append(NSAttributedString(string: "\(Format.documentTitle(for: transcript))\n\n", attributes: [fontKey: fonts.title]))
                emittedTitle = true
            }
            let end = min(cursor + chunkSize, transcript.segments.count)
            guard cursor < end else { return chunk.length == 0 ? nil : chunk }
            for index in cursor..<end {
                let seg = transcript.segments[index]
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let speaker = seg.speaker, !speaker.isEmpty {
                    chunk.append(NSAttributedString(string: "\(speaker): ", attributes: [fontKey: fonts.speaker]))
                }
                chunk.append(NSAttributedString(string: "\(text)\n\n", attributes: [fontKey: fonts.body]))
            }
            cursor = end
            return chunk
        }
    }

}
