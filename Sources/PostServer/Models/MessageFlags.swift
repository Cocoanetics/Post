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
    
    /// Access flags as an array of human-readable strings (matches JSON encoding)
    public var array: [String] {
        var flags = raw.compactMap { flag -> String? in
            let str = Self.flagToHumanString(flag)
            // Skip color bit patterns
            if str.hasPrefix("$MailFlagBit") {
                return nil
            }
            return str
        }
        
        // If flagged with a color, replace "Flagged" with "Flagged:Color"
        if let color = color, let flaggedIndex = flags.firstIndex(of: "Flagged") {
            flags[flaggedIndex] = "Flagged:\(color.rawValue.capitalized)"
        }
        
        // Deduplicate while preserving order
        var seen = Set<String>()
        return flags.filter { seen.insert($0).inserted }
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
        var flags: [Flag] = []
        
        for str in strings {
            // Handle "Flagged:Color" format
            if str.hasPrefix("Flagged:") {
                flags.append(.flagged)
                let colorName = str.dropFirst("Flagged:".count).lowercased()
                // Add color bit flags based on color
                flags.append(contentsOf: Self.colorBitFlags(for: colorName))
            } else {
                flags.append(Self.stringToFlag(str))
            }
        }
        
        self.raw = flags
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var flags = raw.compactMap { flag -> String? in
            let str = Self.flagToHumanString(flag)
            // Skip color bit patterns (they're represented via the flagged+color combo)
            if str.hasPrefix("$MailFlagBit") {
                return nil
            }
            return str
        }
        
        // If flagged with a color, replace "Flagged" with "Flagged:Color"
        if let color = color, let flaggedIndex = flags.firstIndex(of: "Flagged") {
            flags[flaggedIndex] = "Flagged:\(color.rawValue.capitalized)"
        }
        
        // Deduplicate while preserving order
        var seen = Set<String>()
        let deduplicated = flags.filter { seen.insert($0).inserted }
        
        try container.encode(deduplicated)
    }
    
    // MARK: - Flag Conversion
    
    /// Convert flag to human-readable string for JSON output
    private static func flagToHumanString(_ flag: Flag) -> String {
        switch flag {
        case .seen: return "Seen"
        case .answered: return "Answered"
        case .flagged: return "Flagged"
        case .deleted: return "Deleted"
        case .draft: return "Draft"
        case .custom(let value):
            // Check if it's a color bit pattern
            if value.hasPrefix("$MailFlagBit") {
                // These are encoded in the color property, skip them
                return value  // Will be filtered later
            }
            
            // Normalize junk-related flags
            switch value {
            case "$Junk": return "Junk"
            case "$NotJunk", "NotJunk": return "NotJunk"
            case "JunkRecorded": return "JunkRecorded"  // Server metadata
            default:
                // Strip dollar sign from other custom flags
                return value.hasPrefix("$") ? String(value.dropFirst()) : value
            }
        }
    }
    
    /// Convert flag to raw IMAP string for internal use
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
    
    /// Get the $MailFlagBit* flags for a given color name
    private static func colorBitFlags(for colorName: String) -> [Flag] {
        switch colorName {
        case "red": return []  // No bits for red
        case "orange": return [.custom("$MailFlagBit1")]
        case "yellow": return [.custom("$MailFlagBit2")]
        case "green": return [.custom("$MailFlagBit0"), .custom("$MailFlagBit1")]
        case "blue": return [.custom("$MailFlagBit0"), .custom("$MailFlagBit2")]
        case "purple": return [.custom("$MailFlagBit1"), .custom("$MailFlagBit2")]
        case "gray": return [.custom("$MailFlagBit0"), .custom("$MailFlagBit1"), .custom("$MailFlagBit2")]
        default: return []
        }
    }
    
    private static func stringToFlag(_ string: String) -> Flag {
        switch string {
        // IMAP protocol format
        case "\\Seen": return .seen
        case "\\Answered": return .answered
        case "\\Flagged": return .flagged
        case "\\Deleted": return .deleted
        case "\\Draft": return .draft
        // Human-readable format
        case "Seen": return .seen
        case "Answered": return .answered
        case "Flagged": return .flagged
        case "Deleted": return .deleted
        case "Draft": return .draft
        case "Junk": return .custom("$Junk")
        case "NotJunk": return .custom("$NotJunk")
        default:
            // Add dollar sign prefix for custom flags if missing
            if string.starts(with: "$") {
                return .custom(string)
            } else {
                return .custom("$\(string)")
            }
        }
    }
}
