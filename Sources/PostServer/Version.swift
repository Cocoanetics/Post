import Foundation

/// Returns the version from the main bundle's Info.plist (CFBundleShortVersionString),
/// falling back to "unknown" if not embedded.
public var postVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
}
