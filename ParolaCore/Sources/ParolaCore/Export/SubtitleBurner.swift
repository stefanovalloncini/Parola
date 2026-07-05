import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics
import CoreText
import QuartzCore

/// Burns transcript segments into a video as open captions. Pure AVFoundation, no `ffmpeg` dependency.
public enum SubtitleBurner {
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
    public static func burn(
        transcript: Transcript,
        video: URL,
        to output: URL,
        style: Style = Style(),
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
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
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

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(start: .zero, duration: assetDuration)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        videoComposition.animationTool = makeAnimationTool(
            transcript: transcript,
            duration: CMTimeGetSeconds(assetDuration),
            renderSize: renderSize,
            style: style
        )

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
    }

    private static func makeAnimationTool(
        transcript: Transcript,
        duration: TimeInterval,
        renderSize: CGSize,
        style: Style
    ) -> AVVideoCompositionCoreAnimationTool {
        let videoFrame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = videoFrame
        videoLayer.frame = videoFrame
        parentLayer.addSublayer(videoLayer)

        for segment in transcript.segments {
            let textLayer = makeTextLayer(
                text: segment.text,
                language: transcript.language,
                style: style,
                renderSize: renderSize
            )
            attachVisibility(
                layer: textLayer,
                segmentID: segment.id,
                start: segment.start,
                end: segment.end,
                totalDuration: duration
            )
            parentLayer.addSublayer(textLayer)
        }

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    private static func makeTextLayer(text: String, language: String, style: Style, renderSize: CGSize) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = 2

        let horizontalInset: CGFloat = 40
        let maxWidth = renderSize.width - horizontalInset * 2
        let height = max(style.fontSize * 3, 80)
        layer.frame = CGRect(
            x: horizontalInset,
            y: style.bottomInset,
            width: maxWidth,
            height: height
        )

        // CATextLayer draws no glyphs inside AVVideoCompositionCoreAnimationTool's export; rasterize via Core Text and composite as contents.
        let font = Format.cascadingFont(name: style.fontName, size: style.fontSize, language: language)
        if let image = renderTextImage(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            font: font,
            color: style.textColor,
            size: layer.bounds.size,
            scale: layer.contentsScale
        ) {
            layer.contents = image
        }

        layer.opacity = 0
        layer.shadowColor = style.strokeColor
        layer.shadowOpacity = 1
        layer.shadowRadius = style.strokeWidth
        layer.shadowOffset = .zero
        return layer
    }

    static func renderTextImage(text: String, font: CTFont, color: CGColor, size: CGSize, scale: CGFloat) -> CGImage? {
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return nil }

        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafeBytes(of: &alignment) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: raw.baseAddress!
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color,
            .init(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ])

        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
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

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fullRange = CFRangeMake(0, attributed.length)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fullRange, nil,
            CGSize(width: size.width, height: .greatestFiniteMagnitude), nil
        )
        let textHeight = min(suggested.height.rounded(.up), size.height)
        let originY = ((size.height - textHeight) / 2).rounded()
        let path = CGPath(rect: CGRect(x: 0, y: originY, width: size.width, height: textHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    private static func attachVisibility(
        layer: CALayer,
        segmentID: Int,
        start: Double,
        end: Double,
        totalDuration: TimeInterval
    ) {
        let beginAt = max(start, 0.0001)
        let endAt = max(end, beginAt + 0.05)

        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.beginTime = beginAt
        appear.duration = 0.05
        appear.fillMode = .forwards
        appear.isRemovedOnCompletion = false

        let disappear = CABasicAnimation(keyPath: "opacity")
        disappear.fromValue = 1
        disappear.toValue = 0
        disappear.beginTime = endAt
        disappear.duration = 0.05
        disappear.fillMode = .forwards
        disappear.isRemovedOnCompletion = false

        layer.add(appear, forKey: "appear-\(segmentID)")
        layer.add(disappear, forKey: "disappear-\(segmentID)")
    }

    static func renderSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let isRotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        return isRotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
    }
}
