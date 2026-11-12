import Foundation
import Logging
import SwiftTextRender

/// Renders HTML content to PDF with SwiftText's Swift layout engine.
///
/// No WebKit, so this runs on every platform Post builds for. Glyphs the
/// base-14 fonts lack fall back to installed system fonts.
///
/// The HTML comes from untrusted mail, so its images are held in on two fronts.
/// Remote `http(s)` images load from the public internet only: `PublicImageLoader`
/// refuses any host on this machine or a private network, redirects included,
/// that a sender could otherwise make the daemon request (SSRF). Like a mail
/// client that shows images, fetching them lets the sender see that the mail was
/// exported. And the renderer reads absolute paths and `file:` URLs from disk
/// whatever the loader, so `render` first blanks every image source that is
/// neither `data:` nor `http(s)`: `<img src="/dev/zero">` would hang the daemon
/// and `<img src="/Users/…/passport.jpg">` would embed a local file into the PDF.
/// Fonts likewise: the renderer reads an `@font-face` `src` from disk and never
/// from the network, so `render` also disables every `@font-face` rule.
enum HTMLToPDF {

    /// Converts an HTML string to PDF data, logging renderer warnings (such as
    /// images that could not be drawn) instead of writing them to stderr.
    static func render(html: String, logger: Logger) async throws -> Data {
        let options = RenderOptions(imageLoader: PublicImageLoader.load)
        let html = removingFontFaces(from: removingLocalImageSources(from: html))
        return try await HTMLRenderer.renderPDF(html: html, options: options) { warning in
            logger.warning("PDF export: \(warning)")
        }
    }

    private static let imageTag = try! NSRegularExpression(
        pattern: #"<img\b(?:"[^"]*"|'[^']*'|[^'">])*>"#, options: .caseInsensitive)
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"(?<![\w-])src\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .caseInsensitive)

    /// Empties the `src` of every `<img>` that is neither an inline `data:` URI nor
    /// an `http`/`https` URL, so the renderer draws a placeholder instead of
    /// reading it from disk. A protocol-relative `//host/…` source goes too: the
    /// renderer would take it for an absolute path were it not fetched.
    static func removingLocalImageSources(from html: String) -> String {
        replacing(imageTag, in: html) { tag in
            replacing(srcAttribute, in: tag) { attribute in
                let value = attribute.drop { $0 != "=" }.dropFirst()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isKept = ["data:", "http://", "https://"].contains { value.hasPrefix($0) }
                return isKept ? attribute : "src=\"\""
            }
        }
    }

    /// A CSS at-keyword, escapes included: `@\66 ont-face` is `@font-face` too.
    private static let atKeyword = try! NSRegularExpression(
        pattern: #"@((?:[-\w]|[^\x00-\x7F]|\\(?:[0-9a-fA-F]{1,6}(?:\r\n|[ \t\r\n\f])?|[^\r\n\f0-9a-fA-F]))+)"#)
    private static let cssEscape = try! NSRegularExpression(
        pattern: #"\\(?:([0-9a-fA-F]{1,6})(?:\r\n|[ \t\r\n\f])?|([^\r\n\f0-9a-fA-F]))"#)

    /// Renames every `@font-face` to `@x-font-face`, an at-rule the renderer
    /// ignores, so it reads no font file a sender names. That runs over the whole
    /// document rather than only its `<style>` elements, so no disagreement with
    /// the HTML parser about where a style sheet ends can let one through.
    static func removingFontFaces(from html: String) -> String {
        replacing(atKeyword, in: html) { keyword in
            let name = replacing(cssEscape, in: String(keyword.dropFirst())) { escape in
                let escaped = escape.dropFirst()
                let hex = escaped.prefix { $0.isHexDigit }
                guard !hex.isEmpty else { return String(escaped) }
                return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? "\u{FFFD}"
            }
            return name.lowercased() == "font-face" ? "@x-" + keyword.dropFirst() : keyword
        }
    }

    private static func replacing(_ regex: NSRegularExpression, in string: String,
                                  with transform: (String) -> String) -> String {
        let source = string as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: string, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
