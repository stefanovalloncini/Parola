import AVFoundation
import Foundation
import Testing
import ParolaTestSupport
@testable import ParolaCore

// .logFacade: RecordingScratchTests reads the same process-wide scratch directory this suite redirects.
@Suite("Capture logging", .serialized, .logFacade)
struct CaptureLoggingTests {
    private func withSink(_ body: (CapturingDiagnosticsSink) throws -> Void) rethrows {
        let sink = CapturingDiagnosticsSink()
        try ParolaLog.withSink(sink) { try body(sink) }
    }

    private func records(
        _ sink: CapturingDiagnosticsSink, message: String
    ) -> [LogRecord] {
        sink.records.filter { $0.message.rendered == message }
    }

    @Test("a latched write failure is reported once, with the drops so far")
    func writeFailureIsReportedOnce() throws {
        try withSink { sink in
            let writer = CaptureFileWriter { _ in throw CocoaError(.fileWriteOutOfSpace) }
            writer.noteDrop()
            writer.noteDrop()
            writer.write(Self.buffer())
            writer.write(Self.buffer())
            writer.write(Self.buffer())

            let latched = records(sink, message: "capture write failed, take latched")
            #expect(latched.count == 1)
            let record = try #require(latched.first)
            #expect(record.category == .audioRecording)
            #expect(record.level == .error)
            #expect(record.fields[.error]?.text == "NSCocoaErrorDomain.640")
            #expect(record.fields[.count]?.text == "2")
        }
    }

    @Test("a clean take reports nothing")
    func cleanTakeIsSilent() {
        withSink { sink in
            let writer = CaptureFileWriter { _ in }
            writer.noteDrop()
            for _ in 0..<32 { writer.write(Self.buffer()) }

            #expect(sink.records.filter { $0.category == .audioRecording }.isEmpty)
        }
    }

    @Test("a scratch directory that cannot be created is reported")
    func scratchDirectoryFailure() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-capture-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let scratch = parent.appendingPathComponent("inflight", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: parent.path
        )
        RecordingScratch.setDirectory(scratch)
        defer {
            RecordingScratch.setDirectory(nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: parent.path
            )
            try? FileManager.default.removeItem(at: parent)
        }

        try withSink { sink in
            let url = RecordingScratch.fileURL(prefix: "parola-mic")
            #expect(url.deletingLastPathComponent().path == scratch.path)

            let record = try #require(
                records(sink, message: "could not create the recording scratch directory").first
            )
            #expect(record.category == .audioRecording)
            #expect(record.level == .error)
            #expect(record.fields[.error] != nil)
            #expect(record.formattedLine.contains("inflight") == false)
        }
    }

    // The live sources need real hardware to fail, so their sites are pinned in source instead.
    private func audioSource(_ name: String) throws -> String {
        let path = #filePath.replacingOccurrences(
            of: "Tests/ParolaCoreTests/CaptureLoggingTests.swift",
            with: "Sources/ParolaCore/Audio/\(name).swift"
        )
        return try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func expectCalls(
        _ calls: [String], in source: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for call in calls {
            #expect(source.contains(call), "missing log site: \(call)", sourceLocation: sourceLocation)
        }
    }

    @Test("the microphone source logs format, converter, engine and cut-short failures")
    func micSites() throws {
        let source = try audioSource("MicAudioSource")
        expectCalls([
            #"ParolaLog.error(.audioCapture, "microphone input format is invalid")"#,
            #"ParolaLog.fault(.audioCapture, "could not build the capture format")"#,
            #"ParolaLog.fault(.audioCapture, "could not create the audio converter")"#,
            #"ParolaLog.error(.audioCapture, "audio engine failed to start", [.error: .error(error)])"#,
            #"ParolaLog.error( .audioRecording, "take cut short by a write failure", [.count: .int(writer.droppedChunks)] )"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 5)
    }

    @Test("the system audio source logs availability, start and cut-short failures")
    func systemAudioSites() throws {
        let source = try audioSource("SystemAudioSource")
        expectCalls([
            #"ParolaLog.error(.audioCapture, "screencapturekit unavailable", [.error: .error(error)])"#,
            #"ParolaLog.error(.audioCapture, "no display available for system audio")"#,
            #"ParolaLog.error( .audioCapture, "system audio capture failed to start", [.error: .error(error)] )"#,
            #"ParolaLog.error(.audioRecording, "system audio take cut short by a write failure")"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 4)
    }

    @Test("the process tap source logs the tap, the aggregate device and a cut-short take")
    func processTapSites() throws {
        let source = try audioSource("ProcessTapAudioSource")
        expectCalls([
            #"ParolaLog.error( .audioCapture, "could not create the audio process tap", [.count: .int(processObjects.count)] )"#,
            #"ParolaLog.error(.audioCapture, "tap aggregate device failed to start")"#,
            #"ParolaLog.error(.audioRecording, "app audio take cut short by a write failure")"#,
        ], in: source)
        #expect(source.components(separatedBy: "ParolaLog.").count - 1 == 3)
    }

    // The pinned counts are also what rules out a per-buffer record appearing later.
    @Test("the writer and the scratch directory log once each")
    func writerAndScratchSites() throws {
        let writer = try audioSource("CaptureFileWriter")
        expectCalls([
            #"ParolaLog.error( .audioRecording, "capture write failed, take latched", [.error: .error(error), .count: .int(droppedChunks)] )"#,
        ], in: writer)
        #expect(writer.components(separatedBy: "ParolaLog.").count - 1 == 1)

        let scratch = try audioSource("RecordingScratch")
        expectCalls([
            #"ParolaLog.error( .audioRecording, "could not create the recording scratch directory", [.error: .error(error)] )"#,
        ], in: scratch)
        #expect(scratch.components(separatedBy: "ParolaLog.").count - 1 == 1)
    }

    @Test("no capture path hands the log an error's localized description")
    func neverLogsLocalizedDescriptions() throws {
        let files = [
            "CaptureFileWriter", "MicAudioSource", "SystemAudioSource",
            "ProcessTapAudioSource", "RecordingScratch",
        ]
        for name in files {
            let source = try audioSource(name)
            for chunk in source.components(separatedBy: "ParolaLog.").dropFirst() {
                #expect(
                    Self.call(startingAt: chunk).contains("localizedDescription") == false,
                    "\(name) logs an error's localized description"
                )
            }
        }
    }

    private static func call(startingAt text: String) -> String {
        var depth = 0
        var call = ""
        for character in text {
            call.append(character)
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
        }
        return call
    }

    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private static func buffer(frames: AVAudioFrameCount = 8) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}
