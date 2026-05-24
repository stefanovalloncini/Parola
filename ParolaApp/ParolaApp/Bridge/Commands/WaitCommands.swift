import Foundation

extension ParolaAutomationServer {
    func waitCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "waitForPhase",
                area: .core,
                summary: "Polls until model.phase matches `phase` or timeoutMs elapses.",
                kind: .waiter,
                args: [
                    .init(name: "phase", kind: .string(), required: true, summary: "Expected phase name"),
                    .init(name: "timeoutMs", kind: .integer, required: false, summary: "Timeout in ms", defaultValue: .int(10_000)),
                ],
                handler: { args, ctx in
                    let expected = try args.string("phase")
                    let timeoutMs = (try args.optionalInt("timeoutMs")) ?? 10_000
                    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
                    while Date() < deadline {
                        if ParolaAutomationServer.phaseName(ctx.model.phase) == expected {
                            return .object([
                                "matched": .bool(true),
                                "state": ctx.server.snapshotState(),
                            ])
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    return .object([
                        "matched": .bool(false),
                        "state": ctx.server.snapshotState(),
                    ])
                }
            ),
        ]
    }
}
