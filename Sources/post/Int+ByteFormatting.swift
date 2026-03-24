import Foundation

extension Int {
    func formattedAsBytes() -> String {
        if self < 1024 {
            return "\(self) B"
        }

        let kilobytes = Double(self) / 1024
        if kilobytes < 1024 {
            return String(format: "%.1f KB", kilobytes)
        }

        return String(format: "%.1f MB", kilobytes / 1024)
    }
}
