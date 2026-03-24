import Foundation

extension Data {
    func parsedAdditionalHeaders() -> [String: String] {
        guard let content = String(data: self, encoding: .utf8)
                ?? String(data: self, encoding: .isoLatin1) else {
            return [:]
        }

        let headerBlock: Substring
        if let split = content.range(of: "\r\n\r\n") {
            headerBlock = content[..<split.lowerBound]
        } else if let split = content.range(of: "\n\n") {
            headerBlock = content[..<split.lowerBound]
        } else {
            headerBlock = content[content.startIndex..<content.endIndex]
        }

        var parsed: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""

        for line in headerBlock.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if line.isEmpty {
                continue
            }

            if let first = line.first, first == " " || first == "\t" {
                currentValue += "\r\n" + line
                continue
            }

            if let currentKey {
                parsed[currentKey] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                currentKey = nil
                currentValue = ""
                continue
            }

            currentKey = String(line[..<colonIndex]).normalizedFetchHeaderKey()
            currentValue = String(line[line.index(after: colonIndex)...])
        }

        if let currentKey {
            parsed[currentKey] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let standardKeys: Set<String> = [
            "from", "to", "cc", "bcc", "subject", "date", "message-id",
            "content-type", "content-transfer-encoding", "mime-version"
        ]
        return parsed.filter { !standardKeys.contains($0.key) }
    }
}
