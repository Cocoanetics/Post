import ArgumentParser
import Foundation

extension String {
    func resolvedDraftBodyInputForCLI() throws -> String {
        let expandedPath = NSString(string: self).expandingTildeInPath
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw ValidationError("--body path '\(self)' is a directory.")
            }

            let url = URL(fileURLWithPath: expandedPath)
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                guard let data = try? Data(contentsOf: url),
                      let fallback = String(data: data, encoding: .isoLatin1) else {
                    throw ValidationError("Failed to read --body file '\(self)': \(error.localizedDescription)")
                }

                return fallback
            }
        }

        return decodeBodyEscapesForCLI()
    }

    func detectedDraftBodyInputFormat() -> DraftBodyInputFormat {
        if looksLikeHTML {
            return .html
        }
        if looksLikeMarkdown {
            return .markdown
        }
        return .plainText
    }

    private var looksLikeHTML: Bool {
        guard !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let pattern = #"(?is)<!DOCTYPE\s+html|<\s*/?\s*(html|head|body|div|span|p|br|h[1-6]|ul|ol|li|table|tr|td|th|a|img|strong|em|b|i|blockquote|pre|code)\b[^>]*>"#
        return matches(pattern: pattern)
    }

    private var looksLikeMarkdown: Bool {
        guard !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let patterns = [
            #"(?m)^\s{0,3}#{1,6}\s+\S"#,
            #"(?m)^\s{0,3}[-*+]\s+\S"#,
            #"(?m)^\s{0,3}\d+\.\s+\S"#,
            #"(?m)^>\s+\S"#,
            #"(?m)^(```|~~~)"#,
            #"(?m)^([-*_])\1{2,}\s*$"#,
            #"(?m)^\|.*\|$"#,
            #"\[[^\]]+\]\([^)]+\)"#,
            #"!\[[^\]]*\]\([^)]+\)"#,
            #"`[^`\n]+`"#,
            #"\*\*[^*\n]+\*\*|__[^_\n]+__"#
        ]

        return patterns.contains { matches(pattern: $0) }
    }

    private func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.firstMatch(in: self, range: range) != nil
    }

    private func decodeBodyEscapesForCLI() -> String {
        guard contains("\\") else {
            return self
        }

        var decoded = String()
        decoded.reserveCapacity(count)
        var index = startIndex

        while index < endIndex {
            let character = self[index]
            guard character == "\\" else {
                decoded.append(character)
                formIndex(after: &index)
                continue
            }

            let nextIndex = self.index(after: index)
            guard nextIndex < endIndex else {
                decoded.append("\\")
                index = nextIndex
                continue
            }

            let next = self[nextIndex]
            switch next {
            case "n":
                decoded.append("\n")
            case "r":
                decoded.append("\r")
            case "t":
                decoded.append("\t")
            case "\\":
                decoded.append("\\")
            case "\"":
                decoded.append("\"")
            case "'":
                decoded.append("'")
            default:
                decoded.append("\\")
                decoded.append(next)
            }

            index = self.index(after: nextIndex)
        }

        return decoded
    }
}
