import Foundation

extension ParolaAutomationServer {
    func simulationCommands() -> [AutomationCommand] {
        [
            AutomationCommand(
                name: "simulateHotkey",
                area: .test,
                summary: "Fires the same callback a global hotkey would. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(
                        name: "name",
                        kind: .string(enum: [
                            "dictation.start",
                            "dictation.stop",
                            "dictation.toggle",
                            "mic.start",
                            "mic.stop",
                            "mic.toggle",
                        ]),
                        required: true,
                        summary: "Hotkey identifier"
                    ),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("simulateHotkey is only available in --test-mode")
                    }
                    let name = try args.string("name")
                    switch name {
                    case "dictation.start":
                        ctx.model.startDictationFromIntent()
                    case "dictation.stop":
                        ctx.model.stopDictationFromIntent()
                    case "dictation.toggle":
                        if ctx.model.dictationEnabled {
                            ctx.model.stopDictationFromIntent()
                        } else {
                            ctx.model.startDictationFromIntent()
                        }
                    case "mic.start":
                        guard case .recording(.microphone) = ctx.model.phase else {
                            ctx.model.toggleMicRecording()
                            break
                        }
                    case "mic.toggle":
                        ctx.model.toggleMicRecording()
                    case "mic.stop":
                        if case .recording(.microphone) = ctx.model.phase {
                            ctx.model.toggleMicRecording()
                        }
                    default:
                        throw AutomationError.invalidArgs(field: "name", reason: "unknown hotkey: \(name)")
                    }
                    return .object(["fired": .string(name)])
                }
            ),

            AutomationCommand(
                name: "simulateFrontmostApp",
                area: .test,
                summary: "Fires MeetingDetector as if a meeting app activated. Test-mode only.",
                kind: .mutating,
                args: [
                    .init(name: "bundleID", kind: .string(), required: true, summary: "Bundle identifier"),
                ],
                handler: { args, ctx in
                    guard ctx.model.mode == .test else {
                        throw AutomationError.precondition("simulateFrontmostApp is only available in --test-mode")
                    }
                    let bundleID = try args.string("bundleID")
                    let appName = MeetingDetector.knownMeetingApps[bundleID] ?? bundleID
                    ctx.model.meetingDetector.fire(appName: appName)
                    return .object(["bundleID": .string(bundleID), "appName": .string(appName)])
                }
            ),
        ]
    }
}
