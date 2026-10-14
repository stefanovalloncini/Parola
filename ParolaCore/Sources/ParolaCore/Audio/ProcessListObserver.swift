#if os(macOS)
import Foundation
import CoreAudio
import os

/// Calls back when Core Audio's list of audio processes changes, until the returned closure is called; none starts after it.
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

    /// The two Core Audio calls, so a test can see them made.
    struct Hardware: Sendable {
        var add: @Sendable (_ token: UInt) -> OSStatus
        var remove: @Sendable (_ token: UInt) -> OSStatus

        static let live = Hardware(
            add: { token in
                var address = listAddress()
                return AudioObjectAddPropertyListener(
                    AudioObjectID(kAudioObjectSystemObject), &address, processListChanged, UnsafeMutableRawPointer(bitPattern: token)
                )
            },
            remove: { token in
                var address = listAddress()
                return AudioObjectRemovePropertyListener(
                    AudioObjectID(kAudioObjectSystemObject), &address, processListChanged, UnsafeMutableRawPointer(bitPattern: token)
                )
            }
        )
    }

    public static func observe(on queue: DispatchQueue, _ notify: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        observe(on: queue, hardware: .live, notify)
    }

    static func observe(
        on queue: DispatchQueue, hardware: Hardware, _ notify: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let token = registry.withLock { registry -> UInt in
            defer { registry.next += 1 }
            registry.live[registry.next] = Registration(queue: queue, notify: notify)
            return registry.next
        }
        let status = hardware.add(token)
        guard status == noErr else {
            ParolaLog.error(.audioCapture, "could not listen for audio process changes", [.status: .int(Int(status))])
            _ = registry.withLock { $0.live.removeValue(forKey: token) }
            return {}
        }
        return {
            guard registry.withLock({ $0.live.removeValue(forKey: token) }) != nil else { return }
            _ = hardware.remove(token)
        }
    }

    /// A delivery already handed to its queue is dropped there if the observer was removed meanwhile.
    static func deliver(token: UInt) {
        guard let registration = registry.withLock({ $0.live[token] }) else { return }
        registration.queue.async {
            guard registry.withLock({ $0.live[token] != nil }) else { return }
            registration.notify()
        }
    }

    fileprivate static func listAddress() -> AudioObjectPropertyAddress {
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
