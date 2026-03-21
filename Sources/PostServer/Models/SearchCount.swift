import Foundation
import SwiftMCP

@Schema
public struct SearchCount: Codable, Sendable {
    public let count: Int?
    public let minUID: Int?
    public let maxUID: Int?
    public let all: [Int]?

    public init(count: Int?, minUID: Int?, maxUID: Int?, all: [Int]?) {
        self.count = count
        self.minUID = minUID
        self.maxUID = maxUID
        self.all = all
    }
}
