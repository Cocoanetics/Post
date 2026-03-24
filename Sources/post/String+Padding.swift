extension String {
    func padded(to width: Int) -> String {
        guard count < width else {
            return self
        }

        return self + String(repeating: " ", count: width - count)
    }
}
