import PostServer

struct JSONMessageHeader: Codable {
    let uid: Int
    let from: String
    let subject: String
    let date: String
    let flags: [String]

    init(_ message: MessageHeader) {
        uid = message.uid
        from = message.from
        subject = message.subject
        date = message.date
        flags = message.flags.array
    }
}
