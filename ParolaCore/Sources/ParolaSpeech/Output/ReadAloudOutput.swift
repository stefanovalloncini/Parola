import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ParolaCore

/// The sink on a real output: player → time-pitch (the reading speed) → peak limiter → main mixer, Float32
/// mono 48 kHz. A stop or a new subscription leaves it idle, holding what is scheduled next until
/// `resume()`, which binds the engine to the current default output first. A change of output pauses it
/// without a fade, ends the current stream and calls `onOutputChanged`. The offline variant opens no
/// device and renders only when pumped with `renderOffline(frames:)`.
@MainActor
public final class ReadAloudOutput: ReadAloudOutputSink {
    public enum State: Sendable, Equatable {
        case idle
        case playing
        case paused
    }

    public enum Failure: Error, Equatable {
        case formatUnavailable
        case notOffline
        case renderFailed
    }

    public static let sampleRate: Double = 48_000
    public static let speedRange: ClosedRange<Double> = 0.75...2.0

    static let maximumFrameCount: AVAudioFrameCount = 4096
    // The mixer ramps a volume change over ~27 ms from its next I/O cycle; this also covers a Bluetooth-sized cycle.
    static let fadeOutDuration: Duration = .milliseconds(60)

    private static let peakLimiter = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    public private(set) var speed: Double = 1
    public private(set) var state: State = .idle
    public var onOutputChanged: (@MainActor () -> Void)?
    var onCompletion: (@MainActor () -> Void)?

    private(set) var generation = 0
    private(set) var level = SpeechLevel()
    private(set) var fadeTask: Task<Void, Never>?

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: ReadAloudOutput.peakLimiter)
    private let format: AVAudioFormat
    private let isOffline: Bool
    private let completionType: AVAudioPlayerNodeCompletionCallbackType
    private let monitor: (any OutputDeviceMonitoring)?
    private let clock: any Clock<Duration>
    private var listener: AsyncStream<UnitFinished>.Continuation?
    private var openUnit: UnitResampler?
    private var inFlight: [ScheduledBuffer] = []
    private var nextSequence = 0
    private var holdsStaleAudio = false
    private var isHoldingEngine = true
    private var isFadedOut = false
    private var boundDevice: AudioDeviceID?
    private var configurationObserver: EngineConfigurationObserver?

    public convenience init() throws {
        #if os(macOS)
        try self.init(offline: false, monitor: OutputDeviceMonitor())
        #else
        try self.init(offline: false, monitor: nil)
        #endif
    }

    public init(
        offline: Bool,
        monitor: (any OutputDeviceMonitoring)?,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            throw Failure.formatUnavailable
        }
        let engine = AVAudioEngine()
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.maximumFrameCount)
        }
        self.engine = engine
        self.format = format
        self.isOffline = offline
        self.completionType = offline ? .dataRendered : .dataPlayedBack
        self.monitor = monitor
        self.clock = clock

        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(limiter)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        if offline {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        } else {
            configurationObserver = EngineConfigurationObserver(engine: engine) { @Sendable [weak self] in
                Task { @MainActor in self?.engineConfigurationChanged() }
            }
        }
        monitor?.onChange = { [weak self] in self?.outputChanged() }
    }

    deinit {
        listener?.finish()
        fadeTask?.cancel()
    }

    public func setSpeed(_ speed: Double) {
        let clamped = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        self.speed = clamped
        timePitch.rate = Float(clamped)
    }

    public func unitFinishedEvents() -> AsyncStream<UnitFinished> {
        level = SpeechLevel()
        clear()
        listener?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: UnitFinished.self)
        listener = continuation
        return stream
    }

    public func schedule(_ chunk: PCMChunk, epoch: Int, gainDB: Double) {
        guard !chunk.samples.isEmpty else { return }
        if let open = openUnit, open.unitID != chunk.unitID || open.sourceRate != chunk.sampleRate {
            enqueue(open.flush(), finishing: nil)
            openUnit = nil
        }
        if openUnit == nil {
            openUnit = UnitResampler(unitID: chunk.unitID, sourceRate: chunk.sampleRate, outputFormat: format)
        }
        guard let open = openUnit else {
            ParolaLog.error(.readAloud, "a reading unit's audio has a rate the output can't convert")
            return
        }
        enqueue(open.convert(chunk.samples, gain: Float(pow(10, gainDB / 20))), finishing: nil)
    }

    public func finishUnit(_ unitID: Int, epoch: Int, pauseAfter: Double) {
        var tail: [Float] = []
        if let open = openUnit, open.unitID == unitID {
            tail = open.flush()
            openUnit = nil
        }
        let pauseFrames = pauseAfter.isFinite && pauseAfter > 0 ? Int((pauseAfter * Self.sampleRate).rounded()) : 0
        tail.append(contentsOf: repeatElement(0, count: max(pauseFrames, tail.isEmpty ? 1 : 0)))
        enqueue(tail, finishing: UnitFinished(epoch: epoch, unitID: unitID))
    }

    public func pause(fade: Bool) {
        switch state {
        case .idle:
            return
        case .paused:
            if !fade, fadeTask != nil { halt() }
        case .playing:
            state = .paused
            if fade { fadeOut() } else { halt() }
        }
    }

    public func resume() throws {
        if holdsStaleAudio { clear() }
        cancelFade()
        isFadedOut = false
        applyVolume()
        if !engine.isRunning {
            bindOutputDevice()
            do {
                try engine.start()
            } catch {
                ParolaLog.error(.readAloud, "the read-aloud output could not start", [.error: .error(error)])
                throw error
            }
            monitor?.start(boundDevice: boundDevice)
        }
        player.play()
        state = .playing
        isHoldingEngine = false
        retirePlayed()
    }

    public func stop() {
        clear()
    }

    public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard isOffline else { throw Failure.notOffline }
        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames),
              let slice = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.maximumFrameCount),
              let target = rendered.floatChannelData?[0],
              let source = slice.floatChannelData?[0]
        else { throw Failure.renderFailed }
        while rendered.frameLength < frames {
            let count = min(Self.maximumFrameCount, frames - rendered.frameLength)
            guard try engine.renderOffline(count, to: slice) == .success else { throw Failure.renderFailed }
            (target + Int(rendered.frameLength)).update(from: source, count: Int(slice.frameLength))
            rendered.frameLength += slice.frameLength
        }
        return rendered
    }

    func outputChanged() {
        guard state != .idle, !holdsStaleAudio else { return }
        generation += 1
        cancelFade()
        player.pause()
        engine.pause()
        isHoldingEngine = true
        holdsStaleAudio = true
        state = .paused
        monitor?.stop()
        listener?.finish()
        listener = nil
        ParolaLog.notice(.readAloud, "the audio output changed; reading paused")
        onOutputChanged?()
    }

    func engineConfigurationChanged() {
        guard state != .idle else { return }
        if engine.isRunning, isBoundToDefaultOutput { return }
        outputChanged()
    }

    private var isBoundToDefaultOutput: Bool {
        #if os(macOS)
        guard !isOffline, let boundDevice else { return false }
        return OutputDevices.defaultOutput() == boundDevice
        #else
        return false
        #endif
    }

    private func enqueue(_ samples: [Float], finishing unit: UnitFinished?) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        nextSequence += 1
        let sequence = nextSequence
        let generation = generation
        inFlight.append(ScheduledBuffer(
            sequence: sequence,
            finishing: unit,
            measure: SpeechMeasure(samples, sampleRate: Self.sampleRate)
        ))
        player.scheduleBuffer(buffer, completionCallbackType: completionType) { @Sendable [weak self] _ in
            // Runs on an audio thread, or inside player.stop(): only hop to the main actor from here.
            Task { @MainActor in self?.bufferPlayed(sequence: sequence, generation: generation) }
        }
    }

    func stopEngineAsTheSystemWould() {
        engine.stop()
    }

    private func bufferPlayed(sequence: Int, generation: Int) {
        defer { onCompletion?() }
        guard generation == self.generation,
              let index = inFlight.firstIndex(where: { $0.sequence == sequence })
        else { return }
        guard engine.isRunning || isHoldingEngine else {
            // The engine stopped on its own and flushed the queue: nothing after this point played.
            ParolaLog.notice(.readAloud, "the audio engine stopped on its own")
            outputChanged()
            return
        }
        inFlight[index].played = true
        if !isHoldingEngine { retirePlayed() }
    }

    private func retirePlayed() {
        while let head = inFlight.first, head.played {
            inFlight.removeFirst()
            level.absorb(head.measure)
            if let unit = head.finishing {
                listener?.yield(unit)
            }
        }
        applyVolume()
    }

    private func clear() {
        // Bump first: player.stop() fires every pending completion at once.
        generation += 1
        cancelFade()
        player.stop()
        engine.stop()
        timePitch.auAudioUnit.reset()
        limiter.auAudioUnit.reset()
        isHoldingEngine = true
        openUnit = nil
        inFlight.removeAll()
        holdsStaleAudio = false
        isFadedOut = false
        applyVolume()
        monitor?.stop()
        state = .idle
    }

    private func fadeOut() {
        isFadedOut = true
        applyVolume()
        fadeTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.fadeOutDuration)
            guard !Task.isCancelled else { return }
            self?.halt()
        }
    }

    private func halt() {
        cancelFade()
        // Not player.pause(): after it, play() makes the time-pitch unit replay the current buffer from its start.
        engine.pause()
        isHoldingEngine = true
    }

    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = isFadedOut ? 0 : Float(level.gain)
    }

    private func bindOutputDevice() {
        #if os(macOS)
        guard !isOffline, let unit = engine.outputNode.audioUnit else { return }
        if let target = OutputDevices.defaultOutput(), OutputDevices.current(of: unit) != target {
            let status = OutputDevices.bind(unit, to: target)
            if status != noErr {
                ParolaLog.error(.readAloud, "the read-aloud output could not move to the default output", [.error: .int(Int(status))])
            }
        }
        boundDevice = OutputDevices.current(of: unit)
        #endif
    }
}

private struct ScheduledBuffer {
    let sequence: Int
    let finishing: UnitFinished?
    let measure: SpeechMeasure
    var played = false
}

private final class EngineConfigurationObserver {
    private let token: any NSObjectProtocol

    init(engine: AVAudioEngine, onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in onChange() }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
