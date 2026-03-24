import Foundation

extension Encodable {
    func printAsJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(AnyEncodable(self)),
              let string = String(data: data, encoding: .utf8) else {
            print("Error: Failed to encode JSON.")
            return
        }

        print(string)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
