import Foundation
import ParolaCore

extension RecoveryCheckpoint.Kind: LogSafe {
    var logToken: String { rawValue }
}
