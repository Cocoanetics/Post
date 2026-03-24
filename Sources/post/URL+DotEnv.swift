import Foundation

extension URL {
    static var currentDirectory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    func dotEnvValue(named key: String) -> String? {
        let envURL = appendingPathComponent(".env")
        guard let raw = try? String(contentsOf: envURL, encoding: .utf8) else {
            return nil
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let withoutExport: String
            if trimmed.hasPrefix("export ") {
                withoutExport = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                withoutExport = trimmed
            }

            guard let separatorIndex = withoutExport.firstIndex(of: "=") else {
                continue
            }

            let name = withoutExport[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == key else {
                continue
            }

            var value = withoutExport[withoutExport.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            return value
        }

        return nil
    }
}
