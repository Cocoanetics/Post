import Foundation
import SwiftTextCore

public struct SanitizedText: Equatable, Sendable {
    public let text: String
    public let unicodeAbuse: String?

    public init(text: String, unicodeAbuse: String? = nil) {
        self.text = text
        self.unicodeAbuse = unicodeAbuse
    }
}

public enum UnicodeAbuseSummary {
    public static func sanitize(_ text: String, field: String) -> SanitizedText {
        let result = UnicodeAbuseSanitizer.sanitize(text)
        return SanitizedText(
            text: result.text,
            unicodeAbuse: description(for: result.report, field: field)
        )
    }

    public static func combine(_ descriptions: [String?]) -> String? {
        let parts = descriptions.compactMap { $0 }.filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }

    public static func description(for report: UnicodeAbuseReport, field: String) -> String? {
        guard report.containsAbuse else { return nil }

        var parts: [String] = []

        if report.hasBidiOverrides {
            parts.append("Removed bidirectional control characters")
        }

        if report.excessiveCombiningMarks > 0 {
            parts.append("Trimmed excessive combining marks")
        }

        if report.zwjChainLength > 11 {
            parts.append("Trimmed suspiciously long ZWJ sequence")
        }

        if report.hasTagAbuse {
            parts.append("Removed abusive Unicode tag sequence")
        }

        if parts.isEmpty {
            parts.append("Removed suspicious Unicode content")
        }

        return "\(field): \(parts.joined(separator: ", "))"
    }
}
