import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Scoped log sink")
struct ParolaLogScopeTests {
    private func messages(_ sink: CapturingDiagnosticsSink) -> [String] {
        sink.records.map(\.message.rendered)
    }

    @Test("a child task logs into the scope that started it")
    func childTasksInheritTheScope() async {
        let sink = CapturingDiagnosticsSink()
        await ParolaLog.withSink(sink) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { ParolaLog.info(.cli, "scope probe: group child") }
                await group.waitForAll()
            }
            await Task { ParolaLog.info(.cli, "scope probe: unstructured child") }.value
        }
        #expect(messages(sink).sorted() == ["scope probe: group child", "scope probe: unstructured child"])
    }

    @Test("a detached task logs outside the scope that started it")
    func detachedTasksLeaveTheScope() async {
        let sink = CapturingDiagnosticsSink()
        await ParolaLog.withSink(sink) {
            await Task.detached { ParolaLog.info(.cli, "scope probe: detached") }.value
        }
        #expect(sink.records.isEmpty)
    }

    @Test("a detached task that re-enters the scope is captured again")
    func detachedTasksCanReenterTheScope() async {
        let sink = CapturingDiagnosticsSink()
        await ParolaLog.withSink(sink) {
            await Task.detached {
                ParolaLog.withSink(sink) { ParolaLog.info(.cli, "scope probe: forwarded") }
            }.value
        }
        #expect(messages(sink) == ["scope probe: forwarded"])
    }

    @Test("the innermost scope takes the record, and the outer one takes it back")
    func nestedScopesNestProperly() async {
        let outer = CapturingDiagnosticsSink()
        let inner = CapturingDiagnosticsSink()
        await ParolaLog.withSink(outer) {
            ParolaLog.withSink(inner) { ParolaLog.info(.cli, "scope probe: inner") }
            ParolaLog.info(.cli, "scope probe: outer again")
        }
        #expect(messages(inner) == ["scope probe: inner"])
        #expect(messages(outer) == ["scope probe: outer again"])
    }

    @Test("two scopes running at once keep their records apart")
    func concurrentScopesStayApart() async {
        let first = CapturingDiagnosticsSink()
        let second = CapturingDiagnosticsSink()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await ParolaLog.withSink(first) {
                    for _ in 0..<200 {
                        ParolaLog.info(.cli, "scope probe: first")
                        await Task.yield()
                    }
                }
            }
            group.addTask {
                await ParolaLog.withSink(second) {
                    for _ in 0..<200 {
                        ParolaLog.info(.cli, "scope probe: second")
                        await Task.yield()
                    }
                }
            }
            await group.waitForAll()
        }
        #expect(Set(messages(first)) == ["scope probe: first"])
        #expect(Set(messages(second)) == ["scope probe: second"])
    }

    @Test("a synchronous scope routes the records it wraps")
    func synchronousScopeRoutes() {
        let sink = CapturingDiagnosticsSink()
        ParolaLog.withSink(sink) { ParolaLog.info(.cli, "scope probe: synchronous") }
        ParolaLog.info(.cli, "scope probe: after the synchronous scope")
        #expect(messages(sink) == ["scope probe: synchronous"])
    }
}

@Suite("Scoped log sink and the installed sink", .serialized, .logFacade)
struct ParolaLogScopeAndInstallTests {
    private final class FlushCountingSink: DiagnosticsSink {
        private let state = OSAllocatedUnfairLock(initialState: 0)

        var flushes: Int { state.withLock { $0 } }

        func enqueue(_ record: LogRecord) {}

        func flush() async { state.withLock { $0 += 1 } }
    }

    private func probes(_ sink: CapturingDiagnosticsSink) -> [String] {
        sink.records.map(\.message.rendered).filter { $0.hasPrefix("install probe:") }
    }

    @Test("a scoped record never reaches the installed sink")
    func theScopeKeepsRecordsToItself() {
        let installed = CapturingDiagnosticsSink()
        let scoped = CapturingDiagnosticsSink()
        ParolaLog.install(installed)
        defer { ParolaLog.uninstall() }

        ParolaLog.withSink(scoped) { ParolaLog.info(.cli, "install probe: scoped") }

        #expect(probes(scoped) == ["install probe: scoped"])
        #expect(probes(installed).isEmpty)
    }

    @Test("the installed sink takes the records again once the scope ends")
    func theInstalledSinkResumes() {
        let installed = CapturingDiagnosticsSink()
        let scoped = CapturingDiagnosticsSink()
        ParolaLog.install(installed)
        defer { ParolaLog.uninstall() }

        ParolaLog.withSink(scoped) { ParolaLog.info(.cli, "install probe: inside") }
        ParolaLog.info(.cli, "install probe: after")

        #expect(probes(scoped) == ["install probe: inside"])
        #expect(probes(installed) == ["install probe: after"])
    }

    @Test("a record from a detached task lands on the installed sink, not the scope")
    func detachedRecordsFollowTheInstalledSink() async {
        let installed = CapturingDiagnosticsSink()
        let scoped = CapturingDiagnosticsSink()
        ParolaLog.install(installed)
        defer { ParolaLog.uninstall() }

        await ParolaLog.withSink(scoped) {
            await Task.detached { ParolaLog.info(.cli, "install probe: detached") }.value
        }

        #expect(probes(scoped).isEmpty)
        #expect(probes(installed) == ["install probe: detached"])
    }

    @Test("a flush inside a scope drains the scope's sink")
    func flushFollowsTheScope() async {
        let installed = FlushCountingSink()
        let scoped = FlushCountingSink()
        ParolaLog.install(installed)
        defer { ParolaLog.uninstall() }

        await ParolaLog.withSink(scoped) { await ParolaLog.flush() }
        await ParolaLog.flush()

        #expect(scoped.flushes == 1)
        #expect(installed.flushes == 1)
    }
}
