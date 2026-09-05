import ArgumentParser
import Foundation

/// Failures the Companion CLI reports, with the exit code each one uses.
///
/// `1` means Argus refused the request, `3` means Argus could not be reached.
/// Argument-parsing failures keep ArgumentParser's own codes.
enum ArgusCLIError: Error, CustomStringConvertible {
    case applicationUnavailable(String)
    case transport(String)
    case rejected(code: String, message: String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .applicationUnavailable(let detail):
            "\(detail). Start Argus and try again."
        case .transport(let detail):
            detail
        case .rejected(let code, let message):
            "\(message) [\(code)]"
        case .malformedResponse(let detail):
            detail
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .rejected, .malformedResponse:
            ExitCode(1)
        case .applicationUnavailable, .transport:
            ExitCode(3)
        }
    }
}
