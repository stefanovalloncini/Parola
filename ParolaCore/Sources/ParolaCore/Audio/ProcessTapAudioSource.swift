#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio
import os

/// Captures the audio of specific processes via a Core Audio process tap and writes
/// 16 kHz mono Float32 WAV. Unlike ScreenCaptureKit's content filter, tap process
/// objects carry their own bundle IDs — helper processes of multi-process apps
/// (browsers, Electron) are matched and captured too.
///
/// Requires the System Audio Recording permission; the first tap triggers the TCC prompt.
@available(macOS 14.2, *)
public actor ProcessTapAudioSource: LiveAudioSource, TargetsGoneReporting {
    private let processObjects: [AudioObjectID]
    private let outputURL: URL?
    private let outputFormat: AVAudioFormat
    private let callbackQueue = DispatchQueue(label: "com.parola.process-tap")
    public nonisolated let levelMeter = LevelMeter()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var handler: TapHandler?
    private var captureFailure: String?
    private let sink: (@Sendable ([Float]) -> Void)?
    private var cancelled = false
    private let processList: @Sendable () -> [AudioObjectID]
    private let subscribeToProcessList: @Sendable (@escaping @Sendable () -> Void) -> ProcessEndWatch.Unsubscribe
    private var endWatch: ProcessEndWatch?

    /// Audio process objects whose bundle ID matches a target (or a helper under it).
    /// Only processes currently registered with the audio system appear; an app that
    /// starts playing after the take begins is not picked up.
    public static func audioProcessObjects(matching targets: Set<String>) -> [AudioObjectID] {
        guard !targets.isEmpty else { return [] }
        return allAudioProcessObjects().filter { object in
            guard let bundleID = bundleID(of: object) else { return false }
            return matchesTarget(bundleID: bundleID, targets: targets)
        }
    }

    /// The bundle IDs of every process currently registered with the audio system.
    public static func audioProcessBundleIDs() -> [String] {
        allAudioProcessObjects().compactMap(bundleID(of:))
    }

    private static func allAudioProcessObjects() -> [AudioObjectID] {
        AudioProcessObjectList.current()
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
        self.init(processObjects: processObjects, sink: nil)
    }

    /// Hands the converted samples to `sink` instead of writing a file, and sets the tap up off the cooperative pool.
    public init(processObjects: [AudioObjectID], samples sink: @escaping @Sendable ([Float]) -> Void) {
        self.init(processObjects: processObjects, sink: sink)
    }

    init(
        processObjects: [AudioObjectID],
        samples sink: @escaping @Sendable ([Float]) -> Void,
        processList: @escaping @Sendable () -> [AudioObjectID],
        subscribeToProcessList: @escaping @Sendable (@escaping @Sendable () -> Void) -> ProcessEndWatch.Unsubscribe
    ) {
        self.init(
            processObjects: processObjects, sink: sink, processList: processList, subscribeToProcessList: subscribeToProcessList
        )
    }

    private init(
        processObjects: [AudioObjectID],
        sink: (@Sendable ([Float]) -> Void)?,
        processList: @escaping @Sendable () -> [AudioObjectID] = { ProcessTapAudioSource.allAudioProcessObjects() },
        subscribeToProcessList: @escaping @Sendable (@escaping @Sendable () -> Void) -> ProcessEndWatch.Unsubscribe = ProcessEndWatch.listenToHardware
    ) {
        self.processList = processList
        self.subscribeToProcessList = subscribeToProcessList
        self.sink = sink
        self.processObjects = processObjects
        self.outputURL = sink == nil ? RecordingScratch.fileURL(prefix: "parola-system") : nil
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
        let objects = processObjects
        let output = outputFormat
        let url = outputURL
        let queue = callbackQueue
        let sink = sink
        let meter = levelMeter
        let build: @Sendable () throws -> TapParts = {
            try Self.installTap(processObjects: objects, outputFormat: output, outputURL: url, sink: sink, queue: queue, levelMeter: meter)
        }
        // A consent prompt parks AudioDeviceCreateIOProcIDWithBlock, which must not hold a cooperative thread.
        let parts = sink == nil ? try build() : try await Self.offCooperativePool(build)
        guard !cancelled else {
            Self.tearDown(parts)
            throw CancellationError()
        }
        tapID = parts.tapID
        aggregateID = parts.aggregateID
        ioProcID = parts.ioProcID
        handler = parts.handler
    }

    // Unchecked Sendable: the parts move once from the setup thread to this actor, then only the IO queue touches the handler.
    private struct TapParts: @unchecked Sendable {
        var tapID: AudioObjectID
        var aggregateID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID
        var handler: TapHandler
    }

    private static func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func installTap(
        processObjects: [AudioObjectID],
        outputFormat: AVAudioFormat,
        outputURL: URL?,
        sink: (@Sendable ([Float]) -> Void)?,
        queue: DispatchQueue,
        levelMeter: LevelMeter
    ) throws -> TapParts {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else {
            ParolaLog.error(
                .audioCapture,
                "could not create the audio process tap",
                [.count: .int(processObjects.count)]
            )
            throw ParolaError.captureUnavailable("could not create the audio process tap")
        }

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
            AudioHardwareDestroyProcessTap(tap)
            throw ParolaError.captureUnavailable("could not create the tap aggregate device")
        }

        func cleanUp() {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tap)
        }
        func fail(_ message: String) -> ParolaError {
            cleanUp()
            return ParolaError.captureUnavailable(message)
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &asbdSize, &asbd) == noErr,
              let srcFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw fail("could not read the tap stream format")
        }
        guard let converter = AVAudioConverter(from: srcFormat, to: outputFormat) else {
            throw fail("could not create audio converter")
        }
        let writer: CaptureFileWriter
        if let sink {
            writer = .forwarding(to: sink)
        } else if let outputURL {
            do {
                writer = CaptureFileWriter(file: try AVAudioFile(
                    forWriting: outputURL,
                    settings: outputFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                ))
            } catch {
                cleanUp()
                throw error
            }
        } else {
            throw fail("no file to record to")
        }

        let handler = TapHandler(
            converter: converter,
            writer: writer,
            outputFormat: outputFormat,
            srcFormat: srcFormat,
            onLevel: { levelMeter.record($0) }
        )

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            handler.process(bufferList: inInputData)
        }
        guard status == noErr, let procID else {
            throw fail("could not install the tap IO proc")
        }
        guard AudioDeviceStart(aggregateID, procID) == noErr else {
            ParolaLog.error(.audioCapture, "tap aggregate device failed to start")
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            throw fail("could not start the tap aggregate device")
        }
        return TapParts(tapID: tap, aggregateID: aggregateID, ioProcID: procID, handler: handler)
    }

    private static func tearDown(_ parts: TapParts) {
        AudioDeviceStop(parts.aggregateID, parts.ioProcID)
        AudioDeviceDestroyIOProcID(parts.aggregateID, parts.ioProcID)
        AudioHardwareDestroyAggregateDevice(parts.aggregateID)
        AudioHardwareDestroyProcessTap(parts.tapID)
    }

    public func prepare() async throws -> URL {
        await stop()
        guard let outputURL else { throw ParolaError.captureUnavailable("a sample capture keeps no file") }
        if let captureFailure {
            ParolaLog.error(.audioRecording, "app audio take cut short by a write failure")
            throw CaptureInterrupted(url: outputURL, reason: captureFailure)
        }
        return outputURL
    }

    public func inFlightURL() async -> URL? { outputURL }

    public func setPaused(_ paused: Bool) async {
        handler?.setPaused(paused)
    }

    public func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async {
        endWatch?.cancel()
        guard !cancelled else { return }
        endWatch = ProcessEndWatch(
            objects: processObjects, currentObjects: processList, subscribe: subscribeToProcessList, onGone: handler
        )
    }

    public func cancel() async {
        await stop()
        guard let outputURL else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func stop() async {
        cancelled = true
        endWatch?.cancel()
        endWatch = nil
        defer { levelMeter.reset() }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        teardownAll()
        // Hand the handler off before the drain await: a second stop that interleaves there must not
        // clear the failure this one is about to latch.
        let stopping = handler
        handler = nil
        guard let stopping else { return }
        await callbackQueue.drain()
        captureFailure = stopping.failure
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

/// Calls `onGone` once, when any watched process object has left the process list; a running but silent process keeps its object.
final class ProcessEndWatch: Sendable {
    typealias Unsubscribe = @Sendable () -> Void

    private struct State {
        var finished = false
        var unsubscribe: Unsubscribe = {}
    }

    private let objects: Set<AudioObjectID>
    private let currentObjects: @Sendable () -> [AudioObjectID]
    private let onGone: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        objects: [AudioObjectID],
        currentObjects: @escaping @Sendable () -> [AudioObjectID],
        subscribe: @Sendable (@escaping @Sendable () -> Void) -> Unsubscribe,
        onGone: @escaping @Sendable () -> Void
    ) {
        self.objects = Set(objects)
        self.currentObjects = currentObjects
        self.onGone = onGone
        let unsubscribe = subscribe { [weak self] in self?.check() }
        let cancelledAlready = state.withLock { state -> Bool in
            state.unsubscribe = unsubscribe
            return state.finished
        }
        if cancelledAlready { unsubscribe() }
        check()
    }

    func check() {
        guard !state.withLock({ $0.finished }), !objects.isSubset(of: currentObjects()) else { return }
        guard let unsubscribe = finish() else { return }
        unsubscribe()
        onGone()
    }

    func cancel() {
        finish()?()
    }

    private func finish() -> Unsubscribe? {
        state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            return state.unsubscribe
        }
    }

    static let listenToHardware: @Sendable (@escaping @Sendable () -> Void) -> Unsubscribe = { notify in
        ProcessListObserver.observe(on: DispatchQueue(label: "com.parola.process-end-watch"), notify)
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
    private var sampleScratch: AVAudioPCMBuffer?
    private var outputScratch: AVAudioPCMBuffer?

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

    func setPaused(_ paused: Bool) {
        writer.setPaused(paused)
    }

    func process(bufferList: UnsafePointer<AudioBufferList>) {
        guard !writer.isPaused, let copy = ProcessTapSampleCopy.copy(
            bufferList: bufferList,
            srcFormat: srcFormat,
            reusing: &sampleScratch
        ) else { return }

        guard let outBuffer = StreamChunkConverter.convert(
            chunk: copy,
            with: converter,
            to: outputFormat,
            reusing: &outputScratch
        ) else { return }
        writer.write(outBuffer)
        onLevel(AudioLevel.normalised(of: copy))
    }
}

/// Copies samples out of an IO proc's buffer list into a PCM buffer. The list belongs to
/// Core Audio for the length of the callback only.
enum ProcessTapSampleCopy {
    /// Copies into `scratch`, growing it when a callback delivers more frames. The returned buffer
    /// is the scratch itself, so the caller must be done with it before the next callback.
    static func copy(
        bufferList: UnsafePointer<AudioBufferList>,
        srcFormat: AVAudioFormat,
        reusing scratch: inout AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        let bytesPerFrame = srcFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = bufferList.pointee.mBuffers.mDataByteSize / bytesPerFrame
        guard frameCount > 0 else { return nil }
        if (scratch?.frameCapacity ?? 0) < frameCount || scratch?.format != srcFormat {
            scratch = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        }
        guard let copy = scratch else { return nil }
        copy.frameLength = frameCount

        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (index, buffer) in src.enumerated() where index < dst.count {
            guard let from = buffer.mData, let to = dst[index].mData else { continue }
            let bytes = min(buffer.mDataByteSize, dst[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
        }
        return copy
    }
}

/// Raw enumeration of `kAudioHardwarePropertyProcessObjectList`, shared by callers matching by bundle ID or by PID.
enum AudioProcessObjectList {
    static func current() -> [AudioObjectID] {
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
        return Array(objects.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))
    }
}

#endif
