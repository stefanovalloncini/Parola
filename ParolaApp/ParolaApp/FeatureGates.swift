import ParolaCore

extension FeatureSet {
    /// Test mode never drops the automation bridge: the harness drives gated builds through it.
    func excludedSideEffects(mode: AppBootstrap.Mode) -> Set<BootstrapSideEffect> {
        var excluded: Set<BootstrapSideEffect> = []
        if !isEnabled(.dictation) { excluded.insert(.dictationHotkey) }
        if !isEnabled(.micRecording) { excluded.insert(.micHotkey) }
        if !isEnabled(.meetings) { excluded.insert(.meetingDetector) }
        if !isEnabled(.watchedFolders) { excluded.insert(.watchedFolders) }
        if !isEnabled(.youtube) { excluded.insert(.refreshYtDlp) }
        if !isEnabled(.liveCaptions) { excluded.insert(.liveCaptionsTranslateRestore) }
        if !isEnabled(.automation), mode == .normal { excluded.insert(.automationBridge) }
        return excluded
    }
}
