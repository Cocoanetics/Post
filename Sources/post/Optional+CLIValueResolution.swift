import ArgumentParser
import Foundation

extension Optional where Wrapped == String {
    func resolvedRequiredValue(fallback: String?, prompt: String) throws -> String {
        if let explicit = self?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }

        if let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }

        print("\(prompt): ", terminator: "")
        let value = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            print("\(prompt) cannot be empty.")
            throw ExitCode.failure
        }

        return value
    }
}

extension Optional where Wrapped == Int {
    func resolvedPort(fallback: Int?, prompt: String, defaultValue: Int) throws -> Int {
        if let explicit = self {
            return explicit
        }

        if let fallback {
            return fallback
        }

        print("\(prompt) [\(defaultValue)]: ", terminator: "")
        let raw = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return defaultValue
        }

        guard let value = Int(raw) else {
            throw ValidationError("Invalid \(prompt.lowercased()).")
        }

        return value
    }
}
