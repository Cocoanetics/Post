import PostServer

struct JSONMessageHeader: Codable {
    let uid: Int
    let from: String
    let subject: String
    let date: String
    let flags: [String]
    let unicodeAbuse: String?

    init(_ message: MessageHeader) {
        let subject = message.sanitizedSubject()
        uid = message.uid
        from = message.from
        self.subject = subject.text
        date = message.date
        flags = message.flags.array
        unicodeAbuse = subject.unicodeAbuse
    }
}
