import Foundation

extension String {
    func writeToStandardError() {
        guard let data = data(using: .utf8) else {
            return
        }

        FileHandle.standardError.write(data)
    }

    func writeToStandardOutputLine() {
        guard let data = (self + "\n").data(using: .utf8) else {
            return
        }

        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
