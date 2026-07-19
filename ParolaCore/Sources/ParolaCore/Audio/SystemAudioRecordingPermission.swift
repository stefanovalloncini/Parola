import Foundation

#if canImport(Darwin) && os(macOS)
import Darwin
import CoreAudio
#endif

/// Consent state for the System Audio Recording privacy control that gates
/// process taps. macOS has no public status API, so `current()` reads it via SPI.
public enum SystemAudioRecordingPermission: Sendable, Equatable {
    case granted
    case undetermined
    case denied

    public static func status(fromPreflight raw: Int32) -> Self {
        switch raw {
        case 0: return .granted
        case 2: return .denied
        default: return .undetermined
        }
    }

    #if canImport(Darwin) && os(macOS)
    public static func current() -> Self {
        TCCPreflightBridge.shared.audioCaptureStatus()
    }

    /// Installs and immediately removes a global-tap IO proc so macOS raises the
    /// System Audio Recording consent dialog. The IO proc hookup blocks until the
    /// user answers a pending prompt, so completion means the prompt was resolved.
    @available(macOS 14.2, *)
    public static func triggerConsentPrompt() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                runConsentProbe()
                continuation.resume()
            }
        }
    }

    @available(macOS 14.2, *)
    private static func runConsentProbe() {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Parola Permission Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, { _, _, _, _, _ in }) == noErr,
              let procID else { return }
        AudioDeviceDestroyIOProcID(aggregateID, procID)
    }
    #endif
}

#if canImport(Darwin) && os(macOS)

/// Unchecked Sendable: `dlopen` handle and function pointer are loaded once at init and read-only after.
private final class TCCPreflightBridge: @unchecked Sendable {
    static let shared = TCCPreflightBridge()

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private let preflight: PreflightFn?

    private init() {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/TCC"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            preflight = nil
            return
        }
        // TCC SPI; acceptable for direct distribution, not Mac App Store.
        preflight = dlsym(handle, "TCCAccessPreflight").map {
            unsafeBitCast($0, to: PreflightFn.self)
        }
    }

    func audioCaptureStatus() -> SystemAudioRecordingPermission {
        guard let preflight else { return .undetermined }
        return .status(fromPreflight: preflight("kTCCServiceAudioCapture" as CFString, nil))
    }
}

#endif
