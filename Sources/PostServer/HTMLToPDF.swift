import Foundation
import Logging
import SwiftTextRender

/// Renders HTML content to PDF with SwiftText's Swift layout engine.
///
/// No WebKit, so this runs on every platform Post builds for. Glyphs the
/// base-14 fonts lack fall back to installed system fonts.
///
/// Remote images are never fetched: the HTML comes from untrusted mail, so
/// loading `<img src="https://…">` would expose tracking pixels and let a
/// sender make the daemon request arbitrary hosts (SSRF). They draw as
/// placeholders; inline `data:` images still render. The renderer also reads
/// absolute paths and `file:` URLs from disk whatever the loader, so `render`
/// blanks every non-`data:` image source first: `<img src="/dev/zero">` would
/// hang the daemon and `<img src="/Users/…/passport.jpg">` would embed a local
/// file into the PDF.
enum HTMLToPDF {

    /// Converts an HTML string to PDF data, logging renderer warnings (such as
    /// images that could not be drawn) instead of writing them to stderr.
    static func render(html: String, logger: Logger) async throws -> Data {
        try await HTMLRenderer.renderPDF(html: removingNonInlineImageSources(from: html), options: RenderOptions(imageLoader: nil)) { warning in
            logger.warning("PDF export: \(warning)")
        }
    }

    private static let imageTag = try! NSRegularExpression(
        pattern: #"<img\b(?:"[^"]*"|'[^']*'|[^'">])*>"#, options: .caseInsensitive)
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"(?<![\w-])src\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .caseInsensitive)

    /// Empties the `src` of every `<img>` that is not an inline `data:` URI, so
    /// the renderer draws a placeholder instead of fetching or reading it.
    static func removingNonInlineImageSources(from html: String) -> String {
        replacing(imageTag, in: html) { tag in
            replacing(srcAttribute, in: tag) { attribute in
                let value = attribute.drop { $0 != "=" }.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.hasPrefix("data:") ? attribute : "src=\"\""
            }
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
