import Foundation

extension Array where Element == String {
    func value(forOptionNamed option: String) -> String? {
        for (index, argument) in enumerated() {
            if argument == option, indices.contains(index + 1) {
                return self[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let prefix = "\(option)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }
}
