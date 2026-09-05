import AVFoundation
import Foundation
import ParolaCore

/// The three answers a permission check can give, in a form safe to log. Apple's own
/// `AVAuthorizationStatus` must not conform to `LogSafe`, so it maps in here.
enum PermissionState: String, LogSafe {
    case granted
    case denied
    case undetermined

    var logToken: String { rawValue }

    init(granted: Bool) {
        self = granted ? .granted : .denied
    }

    init(granted: Bool, undetermined: Bool) {
        if granted {
            self = .granted
        } else {
            self = undetermined ? .undetermined : .denied
        }
    }

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .undetermined
        default: self = .denied
        }
    }
}

extension RecoveryCheckpoint.Kind: LogSafe {
    var logToken: String { rawValue }
}
