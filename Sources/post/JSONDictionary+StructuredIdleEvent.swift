import SwiftMCP

extension JSONDictionary {
    var structuredIdleEvent: (server: String, mailbox: String, event: String)? {
        guard let server = self["server"]?.stringValue,
              let mailbox = self["mailbox"]?.stringValue,
              let event = self["event"]?.stringValue else {
            return nil
        }

        return (server, mailbox, event)
    }
}
