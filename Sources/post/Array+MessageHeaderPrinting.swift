import PostServer

extension Array where Element == MessageHeader {
    func printHeaders() {
        guard !isEmpty else {
            print("No messages found.")
            return
        }

        for message in self {
            let dateText = message.date.isEmpty ? "Unknown Date" : message.date
            let fromText = message.from.isEmpty ? "Unknown" : message.from
            let sanitizedSubject = message.sanitizedSubject().text
            let subjectText = sanitizedSubject.isEmpty ? "(No Subject)" : sanitizedSubject

            print("[\(message.uid)] \(dateText) - \(fromText)")
            print("   \(subjectText)")
        }
    }
}
