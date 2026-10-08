import Foundation

/// How every `--output` option decides whether it was given a directory or a
/// filename.
///
/// The extension is not a usable signal in either direction: `exports.v1`
/// is a plausible directory name and `README` a plausible filename, and
/// keying on `pathExtension` got both wrong — writing into the first
/// failed outright, and the second silently became a directory holding a
/// generated child. The rule instead is:
///
/// - an existing directory is a directory;
/// - a trailing slash means a directory, created if missing;
/// - anything else is the file to write, with its parent created.
enum OutputPath {

    /// Whether `output` names a directory under the rule above.
    ///
    /// Touches nothing on disk, so a command can reject a filename (say,
    /// when it is about to write several files) before any directory exists.
    static func namesDirectory(_ output: String) -> Bool {
        let url = URL(fileURLWithPath: output)
        let isExistingDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return isExistingDirectory || output.hasSuffix("/")
    }

    /// The file to write for `output`, with whatever directory it needs created.
    ///
    /// `filename` is used only when `output` names a directory.
    static func destination(for output: String, named filename: String) throws -> URL {
        let url = URL(fileURLWithPath: output)
        let wantsDirectory = namesDirectory(output)

        let directory = wantsDirectory ? url : url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return wantsDirectory ? directory.appendingPathComponent(filename) : url
    }
}
