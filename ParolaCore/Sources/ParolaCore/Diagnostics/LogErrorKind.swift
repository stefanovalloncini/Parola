import Foundation

public enum LogErrorKind {
    public static func describe(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let parola = error as? ParolaError { return parola.logKind }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? "cancelled" : "URLError.\(urlError.code.rawValue)"
        }
        let bridged = error as NSError
        if bridged.domain.contains("ErrorDomain") || bridged.domain.hasPrefix("kCF") {
            return "\(bridged.domain).\(bridged.code)"
        }
        return String(describing: type(of: error))
    }
}
