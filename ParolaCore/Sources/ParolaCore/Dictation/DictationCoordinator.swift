import Foundation

public actor DictationCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let hotkey: any HotkeyMonitor
    private let recorder: any DictationRecorder
    private let inserter: any TextInserter
    private let onStateChange: @Sendable (State) async -> Void

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        onStateChange: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.onStateChange = onStateChange
    }

    public func startMonitoring() async {
        await hotkey.start { [weak self] event in
            Task { await self?.handle(event) }
        }
    }

    public func stopMonitoring() async {
        await hotkey.stop()
        if case .listening = state {
            _ = try? await recorder.stopAndTranscribe()
        }
        await setState(.idle)
    }

    func handle(_ event: HotkeyEvent) async {
        switch event {
        case .press:
            guard state == .idle else { return }
            do {
                try await recorder.start()
                await setState(.listening)
            } catch {
                await setState(.failed(error.localizedDescription))
                await setState(.idle)
            }
        case .release:
            guard state == .listening else { return }
            await setState(.transcribing)
            do {
                let text = try await recorder.stopAndTranscribe()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    await inserter.insert(trimmed)
                }
                await setState(.idle)
            } catch {
                await setState(.failed(error.localizedDescription))
                await setState(.idle)
            }
        }
    }

    private func setState(_ new: State) async {
        state = new
        await onStateChange(new)
    }
}
