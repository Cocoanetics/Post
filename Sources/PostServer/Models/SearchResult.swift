import Foundation
import SwiftMCP

/// Pagination cursor for next page
@Schema
public struct SearchResultNext: Codable, Sendable {
    public let afterUid: Int
    
    public init(afterUid: Int) {
        self.afterUid = afterUid
    }
}

/// Pagination metadata
@Schema
public struct SearchResultPage: Codable, Sendable {
    public let returned: Int
    public let hasMore: Bool
    public let next: SearchResultNext?
    
    public init(returned: Int, hasMore: Bool, next: SearchResultNext?) {
        self.returned = returned
        self.hasMore = hasMore
        self.next = next
    }
}

/// Result of a search operation with pagination metadata
@Schema
public struct SearchResult: Codable, Sendable {
    /// Total number of messages matching the search criteria
    public let total: Int?
    
    /// The actual message headers
    public let messages: [MessageHeader]
    
    /// Pagination metadata
    public let page: SearchResultPage
    
    public init(
        total: Int?,
        messages: [MessageHeader],
        page: SearchResultPage
    ) {
        self.total = total
        self.messages = messages
        self.page = page
    }
}
