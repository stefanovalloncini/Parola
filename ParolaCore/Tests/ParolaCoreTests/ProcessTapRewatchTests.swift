import Foundation
import os
import Testing
@testable import ParolaCore

private final class CountingList: Sendable {
    private let objects = OSAllocatedUnfairLock<[UInt32]>(initialState: [])
    private let listeners = OSAllocatedUnfairLock<[Int: @Sendable () -> Void]>(initialState: [:])
    private let nextID = OSAllocatedUnfairLock(initialState: 0)

    init(_ objects: [UInt32]) { self.objects.withLock { $0 = objects } }

    var current: [UInt32] { objects.withLock { $0 } }
    var active: Int { listeners.withLock { $0.count } }

    func subscribe(_ block: @escaping @Sendable () -> Void) -> ProcessEndWatch.Unsubscribe {
        let id = nextID.withLock { id -> Int in
            id += 1
            return id
        }
        listeners.withLock { $0[id] = block }
        return { [self] in _ = listeners.withLock { $0.removeValue(forKey: id) } }
    }

    func set(_ new: [UInt32]) {
        objects.withLock { $0 = new }
        for block in listeners.withLock({ Array($0.values) }) { block() }
    }
}

@Suite("Process tap re-watch")
struct ProcessTapRewatchTests {
    @Test("a real tap re-armed on its survivors fires once per real end, holds one listener, and a stop removes it")
    @available(macOS 14.2, *)
    func rearm() async {
        let list = CountingList([1, 2])
        let tap = ProcessTapAudioSource(
            processObjects: [1, 2], samples: { _ in }, processList: { list.current }, subscribeToProcessList: list.subscribe
        )
        let fired = Awaitable(0)
        await tap.whenTargetsGone { fired.increment() }
        #expect(list.active == 1)
        list.set([1])
        #expect(fired.value == 1)
        #expect(list.active == 0)

        await tap.rewatchTargets([1]) { fired.increment() }
        #expect(await tap.watchedProcessObjects() == [1])
        #expect(fired.value == 1, "the object that already left doesn't fire the new watch")
        #expect(list.active == 1)
        list.set([1, 5])
        #expect(fired.value == 1, "a new object is not an end")
        list.set([5])
        #expect(fired.value == 2)
        #expect(list.active == 0)

        await tap.rewatchTargets([5]) { fired.increment() }
        #expect(list.active == 1)
        await tap.cancel()
        #expect(list.active == 0, "a stop removes the re-armed listener")
        list.set([])
        #expect(fired.value == 2)
        await tap.rewatchTargets([5]) { fired.increment() }
        #expect(list.active == 0, "nothing is watched again after a stop")
    }

    @Test("a re-arm whose survivor already left fires at once")
    @available(macOS 14.2, *)
    func rearmFiresAtOnce() async {
        let list = CountingList([1, 2])
        let tap = ProcessTapAudioSource(
            processObjects: [1, 2], samples: { _ in }, processList: { list.current }, subscribeToProcessList: list.subscribe
        )
        let fired = Awaitable(0)
        await tap.whenTargetsGone { fired.increment() }
        list.set([1])
        list.set([])
        await tap.rewatchTargets([1]) { fired.increment() }
        #expect(fired.value == 2)
        #expect(list.active == 0)
        await tap.cancel()
    }
}
