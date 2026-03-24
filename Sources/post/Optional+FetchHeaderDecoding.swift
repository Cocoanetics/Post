extension Optional where Wrapped == [String: String] {
    func decodedFetchHeaders() -> [String: String] {
        self?.decodedFetchHeaders() ?? [:]
    }
}
