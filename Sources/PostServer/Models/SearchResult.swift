import Foundation
import SwiftMCP

/// Result of a search operation with pagination metadata
@Schema
public struct SearchResult: Codable, Sendable {
    /// Total number of messages matching the search criteria
    public let count: Int?
    
    /// Lowest UID in the full result set
    public let min: Int?
    
    /// Highest UID in the full result set
    public let max: Int?
    
    /// Number of messages returned in this response
    public let returned: Int
    
    /// Lowest UID in the returned subset
    public let returnedMin: Int?
    
    /// Highest UID in the returned subset
    public let returnedMax: Int?
    
    /// Whether there are more results available
    public let hasMore: Bool
    
    /// The actual message headers
    public let messages: [MessageHeader]
    
    public init(
        count: Int?,
        min: Int?,
        max: Int?,
        returned: Int,
        returnedMin: Int?,
        returnedMax: Int?,
        hasMore: Bool,
        messages: [MessageHeader]
    ) {
        self.count = count
        self.min = min
        self.max = max
        self.returned = returned
        self.returnedMin = returnedMin
        self.returnedMax = returnedMax
        self.hasMore = hasMore
        self.messages = messages
    }
}
