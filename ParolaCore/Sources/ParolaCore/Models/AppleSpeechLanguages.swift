import Foundation
#if canImport(Speech)
import Speech
#endif

/// The languages Apple Speech can transcribe on this system, read from the Speech framework once.
/// Empty when the framework can't say.
public actor AppleSpeechLanguages {
    public static let shared = AppleSpeechLanguages()

    private var read: Task<Set<String>, Never>?

    public func codes() async -> Set<String> {
        if let read { return await read.value }
        let task = Task { await Self.readFromSystem() }
        read = task
        return await task.value
    }

    private static func readFromSystem() async -> Set<String> {
        #if canImport(Speech)
        if #available(macOS 26.0, iOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            // "mul" names a multilingual locale, not a language anyone picks.
            return Set(locales.compactMap { $0.language.languageCode?.identifier }).subtracting(["mul", "und"])
        }
        #endif
        return []
    }
}
