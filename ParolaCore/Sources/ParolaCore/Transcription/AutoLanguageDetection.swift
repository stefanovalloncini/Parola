import Foundation

struct AudioProbeWindow: Hashable, Sendable {
    var start: Double
    var duration: Double

    var end: Double { start + duration }
}

struct ProbeWindowEnergy: Hashable, Sendable {
    var window: AudioProbeWindow
    var energy: Double
}

enum LanguageCandidates {
    static let limit = 4

    static func autoDetect(preferred: [String], current: Locale, limit: Int = limit) -> [Locale] {
        var locales: [Locale] = []
        var seen: Set<String> = []
        func append(_ identifier: String?) {
            guard let identifier, locales.count < limit else { return }
            let language = Locale.Language(identifier: identifier)
            guard let code = language.languageCode?.identifier, seen.insert(code).inserted else { return }
            guard let region = language.region?.identifier else {
                locales.append(AppleSpeechTranscriber.pickLocale(language: code))
                return
            }
            locales.append(Locale(identifier: "\(code)_\(region)"))
        }
        for identifier in preferred { append(identifier) }
        append(current.language.languageCode?.identifier)
        append(regionLanguage(of: current))
        return locales
    }

    static func installedMatches(for candidates: [Locale], installed: [Locale]) -> [Locale] {
        candidates.compactMap { candidate in
            let code = candidate.language.languageCode?.identifier
            let sameLanguage = installed.filter { $0.language.languageCode?.identifier == code }
            return sameLanguage.first { $0.region == candidate.region } ?? sameLanguage.first
        }
    }

    /// A Mac set to English with the region set to Italy reports `en_US@rg=itzzzz`, and its owner
    /// very likely records Italian; ICU's likely-subtags turn that region back into a language.
    private static func regionLanguage(of locale: Locale) -> String? {
        guard let region = locale.region?.identifier else { return nil }
        return Locale.Language(identifier: "und-\(region)").maximalIdentifier
    }
}

enum ProbeWindowPlanner {
    static let windowSeconds: Double = 20
    static let windowLimit = 6
    static let candidateLimit = 24
    static let silenceFloor = 0.1

    static func candidates(
        duration: Double,
        windowSeconds: Double = windowSeconds,
        limit: Int = candidateLimit
    ) -> [AudioProbeWindow] {
        guard duration > 0, limit > 0 else { return [] }
        // Under two windows long, the whole file costs no more than two windows and reaches the tail.
        guard duration > 2 * windowSeconds else {
            return [AudioProbeWindow(start: 0, duration: duration)]
        }
        let span = duration - windowSeconds
        let count = min(limit, Int(span / windowSeconds) + 1)
        guard count > 1 else { return [AudioProbeWindow(start: 0, duration: windowSeconds)] }
        let step = span / Double(count - 1)
        return (0..<count).map {
            AudioProbeWindow(start: Double($0) * step, duration: windowSeconds)
        }
    }

    static func pick(from measured: [ProbeWindowEnergy], limit: Int = windowLimit) -> [AudioProbeWindow] {
        ranked(from: measured, limit: limit).sorted { $0.start < $1.start }
    }

    /// `pick`, loudest first.
    static func ranked(from measured: [ProbeWindowEnergy], limit: Int = windowLimit) -> [AudioProbeWindow] {
        guard let loudest = measured.map(\.energy).max(), loudest > 0 else {
            return measured.prefix(limit).map(\.window)
        }
        let floor = loudest * silenceFloor
        return measured
            .filter { $0.energy >= floor }
            .sorted { lhs, rhs in
                lhs.energy == rhs.energy
                    ? lhs.window.start < rhs.window.start
                    : lhs.energy > rhs.energy
            }
            .prefix(limit)
            .map(\.window)
    }
}

struct LanguageProbeOutcome: Hashable, Sendable {
    var text: String
    var confidence: Double?
    /// How much text the confidence averages over, so outcomes from several windows can be pooled.
    var confidenceWeight: Double

    init(text: String, confidence: Double? = nil, confidenceWeight: Double? = nil) {
        self.text = text
        self.confidence = confidence
        self.confidenceWeight = confidenceWeight ?? Double(text.count)
    }

    /// One outcome for several windows of the same language, as if they had been probed back to back.
    static func pooled(_ outcomes: [LanguageProbeOutcome]) -> LanguageProbeOutcome {
        let scored = outcomes.compactMap { outcome in
            outcome.confidence.map { (confidence: $0, weight: outcome.confidenceWeight) }
        }.filter { $0.weight > 0 }
        let weight = scored.reduce(0) { $0 + $1.weight }
        return LanguageProbeOutcome(
            text: outcomes.map(\.text).filter { !$0.isEmpty }.joined(separator: " "),
            confidence: weight > 0 ? scored.reduce(0) { $0 + $1.confidence * $1.weight } / weight : nil,
            confidenceWeight: weight
        )
    }
}

struct LanguageProbe: Hashable, Sendable {
    var locale: Locale
    var outcome: LanguageProbeOutcome

    var wordCount: Int { outcome.text.split(whereSeparator: \.isWhitespace).count }
    var confidence: Double? { outcome.confidence }
}

struct LanguagePick: Hashable, Sendable {
    var locale: Locale
    var detection: LanguageDetection
}

/// How a run arrived at its locale. `unverified` is the case where auto-detection could not run at
/// all — one installed language leaves nothing to compare against — so the run's own confidence
/// stands in for a probe.
enum LocaleResolution: Hashable, Sendable {
    case specified(Locale)
    case probed(LanguagePick)
    case unverified(Locale)

    var locale: Locale {
        switch self {
        case .specified(let locale), .unverified(let locale): locale
        case .probed(let pick): pick.locale
        }
    }

    var needsRunConfidence: Bool {
        if case .unverified = self { return true }
        return false
    }

    func detection(afterRun confidence: Double?, isEmpty: Bool) -> LanguageDetection? {
        switch self {
        case .specified:
            nil
        case .probed(let pick):
            pick.detection
        case .unverified(let locale):
            AutoLanguage.verdict(forUnprobedRun: confidence, isEmpty: isEmpty, locale: locale)
        }
    }
}

/// Scores one probe transcription per candidate language. A recognizer handed the wrong language
/// still emits a plausible word count — it spells the sounds out phonetically — so confidence is
/// the discriminator, with word yield as the fallback where the engine reports no confidence.
/// The best probe is always the one transcribed with, even when the margin is too thin to call it
/// detected: a thin lead still beats the system locale, and `assumed` tells the user to check.
enum AutoLanguage {
    static let minimumEvidenceWords = 8
    static let strongConfidence = 0.8
    static let minimumConfidence = 0.6
    static let confidenceMargin = 0.15
    static let yieldMargin = 1.6

    static func decide(probes: [LanguageProbe], fallback: Locale) -> LanguagePick {
        let ranked = rank(probes.filter { $0.wordCount > 0 })
        guard let best = ranked.first else {
            return LanguagePick(locale: fallback, detection: .assumed(code(of: fallback)))
        }
        return pick(best.locale, detected: isTrustworthy(best, over: ranked.dropFirst().first))
    }

    static func code(of locale: Locale) -> String {
        locale.language.languageCode?.identifier ?? locale.identifier
    }

    /// Verdict for a run nothing could be compared against. A clean transcript says nothing rather
    /// than crying wolf on every English file on an English Mac; a weak or empty one is flagged,
    /// since that is what a recognizer handed the wrong language produces.
    static func verdict(forUnprobedRun confidence: Double?, isEmpty: Bool, locale: Locale) -> LanguageDetection? {
        if isEmpty { return .assumed(code(of: locale)) }
        guard let confidence, confidence < strongConfidence else { return nil }
        return .assumed(code(of: locale))
    }

    private static func pick(_ locale: Locale, detected: Bool) -> LanguagePick {
        LanguagePick(locale: locale, detection: detected ? .detected(code(of: locale)) : .assumed(code(of: locale)))
    }

    private static func rank(_ probes: [LanguageProbe]) -> [LanguageProbe] {
        let byConfidence = probes.allSatisfy { $0.confidence != nil }
        return probes.sorted { lhs, rhs in
            let left = byConfidence ? lhs.confidence ?? 0 : Double(lhs.wordCount)
            let right = byConfidence ? rhs.confidence ?? 0 : Double(rhs.wordCount)
            return left == right ? lhs.locale.identifier < rhs.locale.identifier : left > right
        }
    }

    private static func isTrustworthy(_ best: LanguageProbe, over runnerUp: LanguageProbe?) -> Bool {
        guard best.wordCount >= minimumEvidenceWords else { return false }
        guard let confidence = best.confidence else {
            return (runnerUp.map { Double($0.wordCount) * yieldMargin } ?? 0) < Double(best.wordCount)
        }
        if confidence >= strongConfidence { return true }
        guard confidence >= minimumConfidence else { return false }
        return confidence - (runnerUp?.confidence ?? 0) >= confidenceMargin
    }
}

/// Probes every candidate language on every window, a few at once, and decides on the pooled outcomes.
struct AutoLanguagePicker: Sendable {
    static let concurrentProbes = 4

    let windowCount: Int
    let concurrentProbes: Int
    let runProbe: @Sendable (Locale, Int) async throws -> LanguageProbeOutcome

    init(
        windowCount: Int,
        concurrentProbes: Int = AutoLanguagePicker.concurrentProbes,
        runProbe: @escaping @Sendable (_ locale: Locale, _ window: Int) async throws -> LanguageProbeOutcome
    ) {
        self.windowCount = windowCount
        self.concurrentProbes = max(1, concurrentProbes)
        self.runProbe = runProbe
    }

    func pick(candidates: [Locale], fallback: Locale) async throws -> LanguagePick {
        try Task.checkCancellation()
        guard candidates.count > 1, windowCount > 0 else {
            return LanguagePick(locale: fallback, detection: .assumed(AutoLanguage.code(of: fallback)))
        }
        var heard = Array(repeating: [Int: LanguageProbeOutcome](), count: candidates.count)
        try await withThrowingTaskGroup(of: (candidate: Int, window: Int, outcome: LanguageProbeOutcome?).self) { group in
            var jobs = (0..<windowCount).flatMap { window in candidates.indices.map { (window, $0) } }.makeIterator()
            func launchNext() {
                guard let job = jobs.next() else { return }
                let (window, candidate) = job
                let locale = candidates[candidate]
                group.addTask { [runProbe] in
                    do {
                        return (candidate, window, try await runProbe(locale, window))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (candidate, window, nil)
                    }
                }
            }
            for _ in 0..<concurrentProbes { launchNext() }
            while let result = try await group.next() {
                heard[result.candidate][result.window] = result.outcome
                launchNext()
            }
        }
        try Task.checkCancellation()
        let pooled = candidates.indices.map { candidate in
            LanguageProbe(
                locale: candidates[candidate],
                outcome: .pooled(heard[candidate].sorted { $0.key < $1.key }.map(\.value))
            )
        }
        return AutoLanguage.decide(probes: pooled, fallback: fallback)
    }
}
