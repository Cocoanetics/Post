import SwiftMail
import SwiftMCP

/// A collection of message flags that encodes as a string array but provides convenient
/// computed properties for common flags and Mail.app color decoding.
///
/// Encodes to JSON as:
/// ```json
/// ["\\Seen", "\\Flagged", "$Junk", "$MailFlagBit0", "$MailFlagBit2"]
/// ```
///
/// Provides convenient access:
/// ```swift
/// if message.flags.isSeen { ... }
/// if let color = message.flags.color { ... }
/// for flag in message.flags.array { print(flag) }
/// ```
@Schema
public struct MessageFlags: Codable, Sendable {
    private let raw: [Flag]
    
    // MARK: - Initialization
    
    public init(_ flags: [Flag]) {
        self.raw = flags
    }
    
    // MARK: - Array Access
    
    /// Access flags as an array of strings
    public var array: [String] {
        raw.map(Self.flagToString)
    }
    
    /// Access count
    public var count: Int { raw.count }
    
    /// Check if empty
    public var isEmpty: Bool { raw.isEmpty }
    
    // MARK: - Convenience Properties
    
    /// Whether the message has been read (\\Seen flag)
    public var isSeen: Bool {
        raw.contains(.seen)
    }
    
    /// Whether the message is marked as junk/spam ($Junk flag)
    public var isJunk: Bool {
        raw.contains(.custom("$Junk"))
    }
    
    /// Whether the message is flagged/starred (\\Flagged flag)
    public var isFlagged: Bool {
        raw.contains(.flagged)
    }
    
    /// Whether the message is marked for deletion (\\Deleted flag)
    public var isDeleted: Bool {
        raw.contains(.deleted)
    }
    
    /// Whether the message is a draft (\\Draft flag)
    public var isDraft: Bool {
        raw.contains(.draft)
    }
    
    /// Whether the message has been answered/replied to (\\Answered flag)
    public var isAnswered: Bool {
        raw.contains(.answered)
    }
    
    /// The Mail.app flag color decoded from $MailFlagBit* flags (if present)
    public var color: MailFlagColor? {
        MailFlagColor(flags: raw)
    }
    
    // MARK: - Codable
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let strings = try container.decode([String].self)
        self.raw = strings.map(Self.stringToFlag)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw.map(Self.flagToString))
    }
    
    // MARK: - Flag Conversion
    
    private static func flagToString(_ flag: Flag) -> String {
        switch flag {
        case .seen: return "\\Seen"
        case .answered: return "\\Answered"
        case .flagged: return "\\Flagged"
        case .deleted: return "\\Deleted"
        case .draft: return "\\Draft"
        case .custom(let value): return value
        }
    }
    
    private static func stringToFlag(_ string: String) -> Flag {
        switch string {
        case "\\Seen": return .seen
        case "\\Answered": return .answered
        case "\\Flagged": return .flagged
        case "\\Deleted": return .deleted
        case "\\Draft": return .draft
        default: return .custom(string)
        }
    }
}
