import Foundation
import ParolaCore

extension AppModel {
    /// Queues the AI card for an entry that just landed. Cards run one at a time, since the on-device
    /// model is one resource, and each one's timeout starts when it runs rather than when it was queued.
    @discardableResult
    func enqueueCardMetadata(for id: LibraryEntry.ID, transcript: Transcript) -> Task<Void, Never> {
        guard generatesCardMetadata, features.isEnabled(.ai) else { return Task {} }
        return queueCardJob(id: id, transcript: transcript, isRetry: false)
    }

    /// Waits for every card queued so far, retries included.
    func awaitCardMetadataQueue() async {
        while cardJobsPending > 0 || cardRetryTask != nil {
            await cardMetadataTail?.value
            await cardRetryTask?.value
        }
    }

    private func queueCardJob(id: LibraryEntry.ID, transcript: Transcript?, isRetry: Bool) -> Task<Void, Never> {
        let previous = cardMetadataTail
        let timeout = cardMetadataTimeout
        let clock = clock
        cardJobsPending += 1
        let job = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var outcome: CardMetadataOutcome = .failed
            if let source = await self.cardSource(transcript, for: id) {
                outcome = await AsyncTimeout.run(timeout, clock: clock) { [weak self] in
                    await self?.writeCardMetadata(for: id, transcript: source) ?? .skipped
                } ?? .failed
            }
            if case .failed = outcome, !isRetry {
                self.cardRetryIDs.append(id)
            }
            self.cardJobsPending -= 1
            if self.cardJobsPending == 0 { self.scheduleCardRetries() }
        }
        cardMetadataTail = job
        return job
    }

    /// A retry reads the transcript back from the library rather than keeping every failed one in memory.
    private func cardSource(_ transcript: Transcript?, for id: LibraryEntry.ID) async -> Transcript? {
        if let transcript { return transcript }
        return try? await library.load(id).document.transcript
    }

    /// Once the queue drains, each card that failed or timed out gets one more try after a pause.
    private func scheduleCardRetries() {
        guard !cardRetryIDs.isEmpty, cardRetryTask == nil else { return }
        let delay = cardRetryDelay
        let clock = clock
        cardRetryTask = Task { [weak self] in
            try? await clock.sleep(for: delay, tolerance: nil)
            guard let self else { return }
            self.cardRetryTask = nil
            let ids = self.cardRetryIDs
            self.cardRetryIDs = []
            guard self.generatesCardMetadata, self.features.isEnabled(.ai) else { return }
            for id in ids {
                self.queueCardJob(id: id, transcript: nil, isRetry: true)
            }
        }
    }
}
