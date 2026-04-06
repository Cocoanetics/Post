import Foundation

public extension MessageHeader {
    func sanitizedSubject() -> SanitizedText {
        UnicodeAbuseSummary.sanitize(subject, field: "Subject")
    }
}
