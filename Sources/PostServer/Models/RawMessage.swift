import Foundation
import SwiftMCP

@Schema
public struct RawMessage: Codable, Sendable {
    public let uid: Int
    public let rawData: Data
    public let size: Int

    public init(uid: Int, rawData: Data) {
        self.uid = uid
        self.rawData = rawData
        self.size = rawData.count
    }
}
