import Foundation

enum PostError: Error, LocalizedError {
    case notImplemented(String)
    case validationError(String)
    
    var errorDescription: String? {
        switch self {
        case .notImplemented(let message):
            return "Not implemented: \(message)"
        case .validationError(let message):
            return "Validation error: \(message)"
        }
    }
}
