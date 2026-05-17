import CoreGraphics
import CoreText
import Foundation

public struct PdfExporter: TranscriptExporter {
    public let format: ExportFormat = .pdf
    public init() {}

    private static let pageWidth: CGFloat = 612    // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 54        // 0.75 inch

    public func render(_ transcript: Transcript) throws -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw ParolaError.ioError("Could not create PDF data consumer.")
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ParolaError.ioError("Could not create PDF context.")
        }

        let attributed = Self.buildAttributedString(transcript)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: Self.margin, dy: Self.margin)
        let path = CGPath(rect: textRect, transform: nil)

        var startIndex = 0
        let totalLength = attributed.length

        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(startIndex, 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            startIndex += visible.length
        } while startIndex < totalLength

        context.closePDF()
        return pdfData as Data
    }

    private static func buildAttributedString(_ transcript: Transcript) -> NSAttributedString {
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let speakerFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "Transcript\n\n",
            attributes: [fontKey: titleFont]
        ))

        for seg in transcript.segments {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            if let speaker = seg.speaker {
                result.append(NSAttributedString(
                    string: "\(speaker): ",
                    attributes: [fontKey: speakerFont]
                ))
            }
            result.append(NSAttributedString(
                string: "\(text)\n\n",
                attributes: [fontKey: bodyFont]
            ))
        }

        return result
    }
}
