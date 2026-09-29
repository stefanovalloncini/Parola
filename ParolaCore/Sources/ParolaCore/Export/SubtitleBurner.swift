import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreGraphics
import CoreText
import os

/// Burns transcript segments into a video as open captions. Pure AVFoundation, no `ffmpeg` dependency.
public enum SubtitleBurner {
    /// Sizes are pixels on a frame whose short side is 1080; other frames get them in proportion.
    public struct Style: Sendable {
        public var fontName: String
        public var fontSize: CGFloat
        public var bottomInset: CGFloat
        public var textColor: CGColor
        public var strokeColor: CGColor
        public var strokeWidth: CGFloat

        public init(
            fontName: String = "Helvetica-Bold",
            fontSize: CGFloat = 28,
            bottomInset: CGFloat = 60,
            textColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            strokeColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            strokeWidth: CGFloat = 4
        ) {
            self.fontName = fontName
            self.fontSize = fontSize
            self.bottomInset = bottomInset
            self.textColor = textColor
            self.strokeColor = strokeColor
            self.strokeWidth = strokeWidth
        }
    }

    /// Burns the transcript into a copy of the video, reporting export progress (0–1) roughly twice a second.
    /// The captions are the cues an SRT export with `options` would write, fitted to the frame.
    public static func burn(
        transcript: Transcript,
        video: URL,
        to output: URL,
        style: Style = Style(),
        options: ExportOptions = ExportSpec.standard(for: .srt).options,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard FileManager.default.fileExists(atPath: video.path) else {
            throw ParolaError.audioLoadFailed(video, underlying: "video file does not exist")
        }

        let asset = AVURLAsset(url: video)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ParolaError.ioError("Video file has no video track: \(video.path)")
        }
        let assetDuration = try await asset.load(.duration)
        let (naturalSize, preferredTransform, minFrameDuration, nominalFrameRate) = try await sourceVideoTrack.load(
            .naturalSize, .preferredTransform, .minFrameDuration, .nominalFrameRate
        )
        let renderSize = renderSize(naturalSize: naturalSize, transform: preferredTransform)

        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ParolaError.ioError("Could not add video track to composition")
        }
        try compVideoTrack.insertTimeRange(
            CMTimeRangeMake(start: .zero, duration: assetDuration),
            of: sourceVideoTrack,
            at: .zero
        )
        compVideoTrack.preferredTransform = preferredTransform

        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudioTrack.insertTimeRange(
                CMTimeRangeMake(start: .zero, duration: assetDuration),
                of: sourceAudioTrack,
                at: .zero
            )
        }

        let metrics = CaptionMetrics(style: style, renderSize: renderSize)
        let captions = BurnCaptionTrack(
            cues: try cues(from: transcript, options: options, metrics: metrics, renderSize: renderSize),
            language: captionLanguage(of: transcript, options: options),
            metrics: metrics,
            renderSize: renderSize
        )
        // One caption drawn over each frame as it is composed; no layer tree holds every cue for the whole export.
        let videoComposition = try await AVMutableVideoComposition.videoComposition(
            with: composition,
            applyingCIFiltersWithHandler: { request in
                let frame = request.sourceImage
                guard let caption = captions.image(at: request.compositionTime.seconds) else {
                    request.finish(with: frame, context: nil)
                    return
                }
                request.finish(with: caption.composited(over: frame).cropped(to: frame.extent), context: nil)
            }
        )
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(minFrameDuration: minFrameDuration, nominalFrameRate: nominalFrameRate)

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ParolaError.ioError("Could not create AVAssetExportSession")
        }
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true

        var progressTask: Task<Void, Never>?
        if let progress, #available(macOS 15, iOS 18, *) {
            let states = export.states(updateInterval: 0.5)
            progressTask = Task {
                for await state in states {
                    if case .exporting(let exportProgress) = state {
                        progress(exportProgress.fractionCompleted)
                    }
                }
            }
        }
        defer { progressTask?.cancel() }

        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw ParolaError.ioError("Export failed: \(error.localizedDescription)")
        }
        OutputMarker.mark(output)
    }

    /// The frame rate the source plays at: its shortest frame, else its nominal rate, else 30 fps. A
    /// shortest frame under 1/240 s is a timing glitch, not a rate.
    static func frameDuration(minFrameDuration: CMTime, nominalFrameRate: Float) -> CMTime {
        if minFrameDuration.isNumeric, minFrameDuration.seconds >= 1.0 / 240 {
            return minFrameDuration
        }
        if nominalFrameRate > 0 {
            return CMTime(value: CMTimeValue((60_000 / Double(nominalFrameRate)).rounded()), timescale: 60_000)
        }
        return CMTime(value: 1, timescale: 30)
    }

    /// A style's sizes scaled to one frame.
    struct CaptionMetrics: Sendable {
        let fontName: String
        let fontSize: CGFloat
        let bottomInset: CGFloat
        let horizontalInset: CGFloat
        let strokeWidth: CGFloat
        let textColor: CGColor
        let strokeColor: CGColor

        init(style: Style, renderSize: CGSize) {
            let scale = min(renderSize.width, renderSize.height) / 1080
            fontName = style.fontName
            fontSize = style.fontSize * scale
            bottomInset = style.bottomInset * scale
            horizontalInset = 40 * scale
            strokeWidth = style.strokeWidth * scale
            textColor = style.textColor
            strokeColor = style.strokeColor
        }
    }

    static func measureCaption(_ text: String, font: CTFont, maxWidth: CGFloat) -> CGSize {
        guard !text.isEmpty, maxWidth > 0 else { return .zero }
        let attributed = captionText(text, font: font, color: CGColor(gray: 1, alpha: 1))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, attributed.length), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil
        )
        return CGSize(width: suggested.width.rounded(.up), height: suggested.height.rounded(.up))
    }

    static func captionText(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: raw.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        return NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
            .init(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ])
    }

    /// The dark halo that keeps a caption readable on a bright frame.
    struct Outline {
        let color: CGColor
        let blur: CGFloat

        /// How far the halo reaches past the text, and so the margin the bitmap needs around it.
        var padding: CGFloat { (blur * 1.5).rounded(.up) }
    }

    /// The text laid out in a `size` box, with `outline.padding` of margin on every side when there is a halo.
    static func renderTextImage(
        text: String, font: CTFont, color: CGColor, size: CGSize, scale: CGFloat, outline: Outline? = nil
    ) -> CGImage? {
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return nil }

        let attributed = captionText(text, font: font, color: color)
        let padding = outline.map(\.padding) ?? 0

        let pixelWidth = Int(((size.width + padding * 2) * scale).rounded())
        let pixelHeight = Int(((size.height + padding * 2) * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if let outline, outline.blur > 0 {
            ctx.setShadow(offset: .zero, blur: outline.blur, color: outline.color)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fullRange = CFRangeMake(0, attributed.length)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fullRange, nil,
            CGSize(width: size.width, height: .greatestFiniteMagnitude), nil
        )
        let textHeight = min(suggested.height.rounded(.up), size.height)
        let originY = padding + ((size.height - textHeight) / 2).rounded()
        let path = CGPath(rect: CGRect(x: padding, y: originY, width: size.width, height: textHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    static func renderSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let isRotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        return isRotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
    }
}

/// A burn's captions, looked up per frame. Only a cue that reaches the screen is rasterised, and only the
/// last two stay, so memory holds flat however long the transcript runs.
final class BurnCaptionTrack: Sendable {
    private struct Rendered {
        let index: Int
        let image: CIImage?
    }

    private struct Recent {
        var entries: [Rendered] = []
    }

    private let cues: [BurnCue]
    private let starts: [Double]
    private let metrics: SubtitleBurner.CaptionMetrics
    private let renderSize: CGSize
    private let language: String
    private let recent = OSAllocatedUnfairLock(initialState: Recent())

    init(cues: [BurnCue], language: String, metrics: SubtitleBurner.CaptionMetrics, renderSize: CGSize) {
        self.cues = cues
        starts = cues.map(\.start)
        self.metrics = metrics
        self.renderSize = renderSize
        self.language = language
    }

    /// The caption on screen at `seconds`, placed in frame coordinates, or nil between cues.
    func image(at seconds: Double) -> CIImage? {
        guard let index = cueIndex(at: seconds) else { return nil }
        return recent.withLock { recent in
            if let hit = recent.entries.first(where: { $0.index == index }) { return hit.image }
            let image = rasterize(cues[index])
            recent.entries.append(Rendered(index: index, image: image))
            if recent.entries.count > 2 { recent.entries.removeFirst() }
            return image
        }
    }

    var cachedCueCount: Int { recent.withLock { $0.entries.count } }

    /// The cue that started last at or before `seconds`, if it hasn't ended.
    func cueIndex(at seconds: Double) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= seconds { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0, seconds < cues[index].end else { return nil }
        return index
    }

    private func rasterize(_ cue: BurnCue) -> CIImage? {
        let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = Format.cascadingFont(name: metrics.fontName, size: metrics.fontSize, language: language)
        let maxWidth = renderSize.width - metrics.horizontalInset * 2
        let measured = SubtitleBurner.measureCaption(text, font: font, maxWidth: maxWidth)
        let box = CGSize(width: min(maxWidth, measured.width + 4), height: measured.height + 2)
        let outline = metrics.strokeWidth > 0
            ? SubtitleBurner.Outline(color: metrics.strokeColor, blur: metrics.strokeWidth * 2)
            : nil
        guard let bitmap = SubtitleBurner.renderTextImage(
            text: text, font: font, color: metrics.textColor, size: box, scale: 1, outline: outline
        ) else { return nil }
        let padding = outline?.padding ?? 0
        let x = ((renderSize.width - CGFloat(bitmap.width)) / 2).rounded()
        let y = (metrics.bottomInset - padding).rounded()
        return CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(translationX: x, y: y))
    }
}
