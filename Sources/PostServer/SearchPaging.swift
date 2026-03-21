import Foundation
import NIOIMAPCore

func makeFirstPartialRange(limit: Int) -> PartialRange {
    let bounded = max(1, limit)
    let upper = UInt32(clamping: bounded)
    let range = SequenceRange(SequenceNumber(rawValue: 1)...SequenceNumber(rawValue: upper))
    return .first(range)
}
