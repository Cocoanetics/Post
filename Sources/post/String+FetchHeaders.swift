import Foundation
import SwiftMail

extension String {
    func normalizedFetchHeaderKey() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func decodedFetchHeaderValue() -> String {
        unfoldedFetchHeaderValue()
            .decodeMIMEHeader()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unfoldedFetchHeaderValue() -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\r?\\n[\\t ]+") else {
            return self
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: " ")
    }
}
