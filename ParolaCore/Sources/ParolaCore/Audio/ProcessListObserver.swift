#if os(macOS)
import Foundation
import CoreAudio
import os

/// Calls back when Core Audio's list of audio processes changes, until the returned closure is called.
public enum ProcessListObserver {
    private struct Registration: Sendable {
        var queue: DispatchQueue
        var notify: @Sendable () -> Void
    }

    private struct Registry {
        var next: UInt = 1
        var live: [UInt: Registration] = [:]
    }

    // The HAL gets a token, not a pointer, so a callback still in flight when the listener is removed finds nothing instead of freed memory.
    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    static var activeCount: Int { registry.withLock { $0.live.count } }

    public static func observe(on queue: DispatchQueue, _ notify: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let token = registry.withLock { registry -> UInt in
            defer { registry.next += 1 }
            registry.live[registry.next] = Registration(queue: queue, notify: notify)
            return registry.next
        }
        var address = listAddress()
        let context = UnsafeMutableRawPointer(bitPattern: token)
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, processListChanged, context
        )
        guard status == noErr else {
            ParolaLog.error(.audioCapture, "could not listen for audio process changes", [.count: .int(Int(status))])
            _ = registry.withLock { $0.live.removeValue(forKey: token) }
            return {}
        }
        return {
            var address = listAddress()
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject), &address, processListChanged, UnsafeMutableRawPointer(bitPattern: token)
            )
            _ = registry.withLock { $0.live.removeValue(forKey: token) }
        }
    }

    fileprivate static func deliver(token: UInt) {
        guard let registration = registry.withLock({ $0.live[token] }) else { return }
        registration.queue.async { registration.notify() }
    }

    private static func listAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private func processListChanged(
    _: AudioObjectID, _: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>, context: UnsafeMutableRawPointer?
) -> OSStatus {
    ProcessListObserver.deliver(token: UInt(bitPattern: context))
    return noErr
}

#endif
