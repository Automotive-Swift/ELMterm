import Foundation

/// Transport failures in one-shot mode must produce a failing process status.
enum BatchError: LocalizedError {
    case responseTimeout(String)
    case interrupted(String)

    var errorDescription: String? {
        switch self {
            case .responseTimeout(let command):
                return "Timed out waiting for the adapter prompt after '\(command)'. Use --response-timeout for slow adapters."
            case .interrupted(let reason):
                return "Batch interrupted: \(reason)"
        }
    }
}
