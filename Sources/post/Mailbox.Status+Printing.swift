import SwiftMail

extension Mailbox.Status {
    func printDetails() {
        if let messageCount {
            print("Messages: \(messageCount)")
        }
        if let recentCount {
            print("Recent: \(recentCount)")
        }
        if let unseenCount {
            print("Unseen: \(unseenCount)")
        }
        if let uidNext {
            print("UID Next: \(uidNext)")
        }
        if let uidValidity {
            print("UID Validity: \(uidValidity)")
        }
    }
}
