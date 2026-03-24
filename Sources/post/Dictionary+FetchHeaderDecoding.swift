import Foundation
import SwiftMail

extension Dictionary where Key == String, Value == String {
    func decodedFetchHeaders() -> [String: String] {
        var decoded: [String: String] = [:]
        decoded.reserveCapacity(count)

        for (rawKey, rawValue) in self {
            let key = rawKey.normalizedFetchHeaderKey()
            let value = rawValue.decodedFetchHeaderValue()
            guard !key.isEmpty, !value.isEmpty else {
                continue
            }

            decoded[key] = value
        }

        return decoded
    }
}
