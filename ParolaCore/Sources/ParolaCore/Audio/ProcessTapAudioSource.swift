#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio

/// Captures the audio of specific processes via a Core Audio process tap and writes
/// 16 kHz mono Float32 WAV. Unlike ScreenCaptureKit's content filter, tap process
/// objects carry their own bundle IDs — helper processes of multi-process apps
/// (browsers, Electron) are matched and captured too.
///
/// Requires the System Audio Recording permission; the first tap triggers the TCC prompt.
@available(macOS 14.2, *)
public actor ProcessTapAudioSource: LiveAudioSource {
    private let processObjects: [AudioObjectID]
    private let outputURL: URL
    private let outputFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.parola.process-tap")
    private var levelContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var handler: TapHandler?
    private var captureFailure: String?

    /// Audio process objects whose bundle ID matches a target (or a helper under it).
    /// Only processes currently registered with the audio system appear; an app that
    /// starts playing after the take begins is not picked up.
    public static func audioProcessObjects(matching targets: Set<String>) -> [AudioObjectID] {
        guard !targets.isEmpty else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objects) == noErr else {
            return []
        }
        return objects.filter { object in
            guard let bundleID = bundleID(of: object) else { return false }
            return matchesTarget(bundleID: bundleID, targets: targets)
        }
    }

    /// A target bundle ID matches the app itself and its helper bundles (`id` or `id.*`),
    /// so multi-process vendors whose audio comes from a helper are still captured.
    public static func matchesTarget(bundleID: String, targets: Set<String>) -> Bool {
        targets.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    private static func bundleID(of processObject: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(processObject, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    public init(processObjects: [AudioObjectID]) {
        self.processObjects = processObjects
        self.outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-system-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("unreachable: failed to build target audio format")
        }
        self.outputFormat = format
    }

    public func start() async throws {
        guard ioProcID == nil else { return }
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            throw ParolaError.captureUnavailable("could not create the audio process tap")
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Parola Process Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            teardownTap()
            throw ParolaError.captureUnavailable("could not create the tap aggregate device")
        }
        self.aggregateID = aggregateID

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &asbd) == noErr,
              let srcFormat = AVAudioFormat(streamDescription: &asbd) else {
            teardownAll()
            throw ParolaError.captureUnavailable("could not read the tap stream format")
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: outputFormat) else {
            teardownAll()
            throw ParolaError.captureUnavailable("could not create audio converter")
        }
        let writeFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let levelSink: @Sendable (Float) -> Void = { [weak self] level in
            guard let self else { return }
            Task { await self.emitLevel(level) }
        }
        let handler = TapHandler(
            converter: converter,
            writer: CaptureFileWriter(file: writeFile),
            outputFormat: outputFormat,
            srcFormat: srcFormat,
            onLevel: levelSink
        )
        self.handler = handler

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, callbackQueue) { _, inInputData, _, _, _ in
            handler.process(bufferList: inInputData)
        }
        guard status == noErr, let procID else {
            teardownAll()
            throw ParolaError.captureUnavailable("could not install the tap IO proc")
        }
        ioProcID = procID
        guard AudioDeviceStart(aggregateID, procID) == noErr else {
            teardownAll()
            throw ParolaError.captureUnavailable("could not start the tap aggregate device")
        }
    }

    public func prepare() async throws -> URL {
        await stop()
        if let captureFailure {
            try? FileManager.default.removeItem(at: outputURL)
            throw ParolaError.captureUnavailable(captureFailure)
        }
        return outputURL
    }

    public func cancel() async {
        await stop()
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// Emits a normalised 0...1 amplitude per captured buffer. Multiple subscribers are supported.
    public func levels() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            levelContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeLevelContinuation(id) }
            }
        }
    }

    private func removeLevelContinuation(_ id: UUID) {
        levelContinuations.removeValue(forKey: id)
    }

    private func emitLevel(_ level: Float) {
        for continuation in levelContinuations.values {
            continuation.yield(level)
        }
    }

    private func stop() async {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        teardownAll()
        await callbackQueue.drain()
        captureFailure = handler?.failure
        handler = nil
        for continuation in levelContinuations.values {
            continuation.finish()
        }
        levelContinuations.removeAll()
    }

    private func teardownAll() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        teardownTap()
    }

    private func teardownTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// Unchecked Sendable: mutated only on the serial IO queue passed to
// AudioDeviceCreateIOProcIDWithBlock; `stop()` synchronises with that queue before release.
@available(macOS 14.2, *)
private final class TapHandler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let writer: CaptureFileWriter
    private let outputFormat: AVAudioFormat
    private let srcFormat: AVAudioFormat
    private let onLevel: @Sendable (Float) -> Void

    var failure: String? { writer.failure }

    init(
        converter: AVAudioConverter,
        writer: CaptureFileWriter,
        outputFormat: AVAudioFormat,
        srcFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.converter = converter
        self.writer = writer
        self.outputFormat = outputFormat
        self.srcFormat = srcFormat
        self.onLevel = onLevel
    }

    func process(bufferList: UnsafePointer<AudioBufferList>) {
        let firstBuffer = bufferList.pointee.mBuffers
        let bytesPerFrame = srcFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return }
        let frameCount = firstBuffer.mDataByteSize / bytesPerFrame
        guard frameCount > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        copy.frameLength = frameCount

        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (index, buffer) in src.enumerated() where index < dst.count {
            guard let from = buffer.mData, let to = dst[index].mData else { continue }
            let bytes = min(buffer.mDataByteSize, dst[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
        }

        guard let outBuffer = StreamChunkConverter.convert(
            chunk: copy,
            with: converter,
            to: outputFormat
        ) else { return }
        writer.write(outBuffer)
        onLevel(AudioLevel.normalised(of: copy))
    }
}

#endif
