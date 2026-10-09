import Foundation
import SwiftMail

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

    /// The file to write for an attachment whose name a sender chose.
    ///
    /// Like ``destination(for:named:)``, except that when `output` names a
    /// directory the attachment's name may be a path: Outlook names files it
    /// attaches from a folder `docs\reference\a.md`, and that lands as
    /// `docs/reference/a.md` under the directory instead of one file with
    /// backslashes in its name. Only ``relativePath(forAttachmentNamed:)``
    /// decides what of the name is kept, so it cannot leave the directory.
    static func destination(for output: String, attachmentNamed name: String) throws -> URL {
        guard namesDirectory(output) else {
            return try destination(for: output, named: name)
        }
        let file = relativePath(forAttachmentNamed: name).reduce(URL(fileURLWithPath: output)) {
            $0.appendingPathComponent($1)
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return file
    }

    /// The folders and filename an attachment's name stands for, each safe to
    /// use as one path component.
    ///
    /// `/` and `\` both separate folders. Empty components, `.` and `..` are
    /// dropped, and so is a leading drive letter (`C:`), so the path stays
    /// relative and inside the directory it is written to. Each component is
    /// stripped of the characters file systems refuse. A name that leaves
    /// nothing is `attachment`.
    static func relativePath(forAttachmentNamed name: String) -> [String] {
        var components = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        if let first = components.first, first.count == 2, first.last == ":", first.first?.isLetter == true {
            components.removeFirst()
        }
        let kept = components
            .map { $0.sanitizedFileName().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return kept.isEmpty ? ["attachment"] : kept
    }
}
