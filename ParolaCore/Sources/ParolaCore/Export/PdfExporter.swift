import CoreGraphics
import CoreText
import Foundation

struct PdfExporter: TranscriptExporter {
    let format: ExportFormat = .pdf
    let spec: ExportSpec

    init(spec: ExportSpec = .standard(for: .pdf)) {
        self.spec = spec
    }

    private static let pageWidth: CGFloat = 612    // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54        // 0.75 inch
    private static let segmentsPerChunk: Int = 64
    private static let minRemainderHeight: CGFloat = 24

    func encode(_ transcript: Transcript) throws -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw ParolaError.ioError("Could not create PDF data consumer.")
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ParolaError.ioError("Could not create PDF context.")
        }

        let textRect = mediaBox.insetBy(dx: Self.margin, dy: Self.margin)
        let fonts = Fonts.make(language: transcript.language)

        // Chunks bound framesetter memory, not pagination: each chunk continues in the
        // remaining region of the current page instead of forcing a page break.
        var pageOpen = false
        var currentTop = textRect.maxY

        var iterator = ChunkIterator(
            transcript: transcript,
            fonts: fonts,
            chunkSize: Self.segmentsPerChunk,
            speakers: options.speakers,
            translations: spec.resolvedContent == .both ? (transcript.translation?.segments ?? [:]) : [:]
        )
        while let chunk = iterator.next() {
            guard chunk.length > 0 else { continue }
            let framesetter = CTFramesetterCreateWithAttributedString(chunk)
            var startIndex = 0
            while startIndex < chunk.length {
                if !pageOpen {
                    context.beginPDFPage(nil)
                    pageOpen = true
                    currentTop = textRect.maxY
                }
                let available = CGRect(
                    x: textRect.minX,
                    y: textRect.minY,
                    width: textRect.width,
                    height: currentTop - textRect.minY
                )
                if available.height < Self.minRemainderHeight {
                    context.endPDFPage()
                    pageOpen = false
                    continue
                }
                let path = CGPath(rect: available, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(startIndex, 0), path, nil)
                CTFrameDraw(frame, context)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 {
                    context.endPDFPage()
                    pageOpen = false
                    if available.height >= textRect.height { break }
                    continue
                }
                startIndex += visible.length
                if startIndex < chunk.length {
                    context.endPDFPage()
                    pageOpen = false
                } else {
                    var fit = CFRange()
                    let used = CTFramesetterSuggestFrameSizeWithConstraints(
                        framesetter,
                        visible,
                        nil,
                        CGSize(width: available.width, height: available.height),
                        &fit
                    )
                    currentTop -= ceil(used.height)
                }
            }
        }

        if pageOpen { context.endPDFPage() }
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
        let speakers: Bool
        let translations: [Int: String]
        private var cursor: Int = 0
        private var emittedTitle: Bool = false

        init(transcript: Transcript, fonts: Fonts, chunkSize: Int, speakers: Bool, translations: [Int: String]) {
            self.transcript = transcript
            self.fonts = fonts
            self.chunkSize = max(1, chunkSize)
            self.speakers = speakers
            self.translations = translations
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
                if speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                    chunk.append(NSAttributedString(string: "\(speaker): ", attributes: [fontKey: fonts.speaker]))
                }
                let translated = translations[seg.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let translated, !translated.isEmpty {
                    chunk.append(NSAttributedString(string: "\(text)\n", attributes: [fontKey: fonts.body]))
                    chunk.append(NSAttributedString(string: "\(translated)\n\n", attributes: [fontKey: fonts.body]))
                } else {
                    chunk.append(NSAttributedString(string: "\(text)\n\n", attributes: [fontKey: fonts.body]))
                }
            }
            cursor = end
            return chunk
        }
    }

}
