import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreGraphics
import CoreText
import QuartzCore

/// Burns transcript segments into a video as open captions using AVFoundation.
///
/// Native rendering — no `ffmpeg`. Each segment becomes a `CATextLayer` whose opacity
/// is keyframed to its `start`/`end` time. The composed asset is exported to H.264 + AAC
/// via `AVAssetExportSession`.
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

    public static func burn(
        transcript: Transcript,
        video: URL,
        to output: URL,
        style: Style = Style()
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
            try? compAudioTrack.insertTimeRange(
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
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true

        await export.export()

        if export.status != .completed {
            let detail = export.error?.localizedDescription ?? "status=\(export.status.rawValue)"
            throw ParolaError.ioError("Export failed: \(detail)")
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
            let textLayer = makeTextLayer(text: segment.text, style: style, renderSize: renderSize)
            attachVisibility(
                layer: textLayer,
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

    private static func makeTextLayer(text: String, style: Style, renderSize: CGSize) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        layer.font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        layer.fontSize = style.fontSize
        layer.foregroundColor = style.textColor
        layer.alignmentMode = .center
        layer.isWrapped = true
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
        layer.opacity = 0
        layer.shadowColor = style.strokeColor
        layer.shadowOpacity = 1
        layer.shadowRadius = style.strokeWidth
        layer.shadowOffset = .zero
        return layer
    }

    private static func attachVisibility(
        layer: CALayer,
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

        layer.add(appear, forKey: "appear-\(start)")
        layer.add(disappear, forKey: "disappear-\(end)")
    }

    static func renderSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let isRotated = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
        return isRotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize
    }
}
