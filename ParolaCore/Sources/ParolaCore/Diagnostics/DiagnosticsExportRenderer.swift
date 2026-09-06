import Foundation

extension DiagnosticsExport {
    private static let unknown = "unknown"
    private static let labelWidth = 11

    static func render(
        reading: DiagnosticsReading,
        environment: DiagnosticsEnvironment,
        generatedAt: Date
    ) -> String {
        var lines = [
            "Parola Diagnostics — generated \(Date.ISO8601FormatStyle().format(generatedAt))",
            "No transcript text, file names, or paths are included.",
            "",
        ]
        lines += header(environment)
        lines.append("")
        if reading.records.isEmpty {
            lines.append("No diagnostics recorded.")
        } else {
            for record in reading.records { lines += recordLines(record) }
        }
        let footer = footerLines(reading)
        if !footer.isEmpty {
            lines.append("")
            lines += footer
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func header(_ environment: DiagnosticsEnvironment) -> [String] {
        [
            [
                "App \(appVersionText(environment))",
                "macOS \(environment.osVersion)",
                environment.arch,
                byteText(environment.physicalMemoryBytes),
                environment.localeIdentifier,
            ].joined(separator: "  "),
            row("Permissions", permissionsText(environment)),
            row("Engines", enginesText(environment.engines)),
            row("Models", modelsText(environment.models)),
            row("Library", libraryText(environment)),
            row("Features", featuresText(environment.features)),
        ]
    }

    private static func row(_ label: String, _ value: String) -> String {
        let padding = String(repeating: " ", count: max(0, labelWidth - label.count))
        return "\(label)\(padding)  \(value)"
    }

    private static func appVersionText(_ environment: DiagnosticsEnvironment) -> String {
        guard let version = environment.appVersion else { return unknown }
        guard let build = environment.appBuild else { return version }
        return "\(version) (\(build))"
    }

    private static func permissionsText(_ environment: DiagnosticsEnvironment) -> String {
        let items: [(String, DiagnosticsEnvironment.Permission?)] = [
            ("microphone", environment.microphone),
            ("screenRecording", environment.screenRecording),
            ("systemAudio", environment.systemAudio),
            ("accessibility", environment.accessibility),
        ]
        let rendered = items.compactMap { name, state in state.map { "\(name)=\($0.rawValue)" } }
        return rendered.isEmpty ? "unknown" : rendered.joined(separator: " ")
    }

    private static func enginesText(_ engines: [EngineID: Bool]) -> String {
        guard !engines.isEmpty else { return unknown }
        return engines
            .map { "\($0.key.logToken)=\($0.value ? "ok" : "unavailable")" }
            .sorted()
            .joined(separator: " ")
    }

    private static func modelsText(_ models: [DiagnosticsEnvironment.InstalledModel]) -> String {
        guard !models.isEmpty else { return "none installed" }
        return models
            .map { "\($0.token.logToken) (\($0.bytes.map(byteText) ?? "size \(unknown)"))" }
            .joined(separator: ", ")
    }

    private static func libraryText(_ environment: DiagnosticsEnvironment) -> String {
        let entries = environment.libraryEntryCount.map { "\($0) entries" } ?? "\(unknown) entries"
        let bytes = environment.libraryBytes.map(byteText) ?? "not measured"
        return "\(entries), \(bytes)"
    }

    private static func featuresText(_ features: FeatureSet) -> String {
        if features == .all { return "all enabled" }
        if features.enabled.isEmpty { return "none enabled" }
        return features.enabled.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private static func recordLines(_ record: ExportedRecord) -> [String] {
        var lines = [
            "\(record.timestampText)  \(record.level)"
                + "  \(shortSubsystem(record.subsystem))/\(record.category)  \(record.message)",
        ]
        if !record.fields.isEmpty {
            let fields = record.fields.keys.sorted()
                .map { "\($0)=\(record.fields[$0] ?? "")" }
                .joined(separator: " ")
            lines.append("    \(fields)")
        }
        return lines
    }

    private static func shortSubsystem(_ subsystem: String) -> String {
        guard let last = subsystem.split(separator: ".").last else { return unknown }
        return String(last)
    }

    private static func footerLines(_ reading: DiagnosticsReading) -> [String] {
        var footer: [String] = []
        if reading.skippedLines > 0 {
            let noun = reading.skippedLines == 1 ? "line" : "lines"
            footer.append(
                "\(reading.skippedLines) \(noun) skipped: unreadable or written by a newer version of Parola."
            )
        }
        if reading.skippedFiles > 0 {
            let noun = reading.skippedFiles == 1 ? "file" : "files"
            footer.append("\(reading.skippedFiles) \(noun) skipped: could not be read.")
        }
        if reading.truncated {
            footer.append(
                "Oldest records dropped: the store is over the export's \(maxReadBytes / 1_000_000) MB cap."
            )
        }
        return footer
    }

    /// 1024-based, one decimal, so 34,359,738,368 bytes reads as the 32 GB the machine advertises.
    static func byteText(_ bytes: UInt64) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        guard bytes >= 1024 else { return "\(bytes) bytes" }
        var value = Double(bytes) / 1024
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
        return "\(text) \(units[index])"
    }
}
