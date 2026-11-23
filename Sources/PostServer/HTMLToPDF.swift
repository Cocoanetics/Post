import Foundation
import Logging
import SwiftTextRender

/// Renders HTML content to PDF with SwiftText's Swift layout engine.
///
/// No WebKit, so this runs on every platform Post builds for. Glyphs the
/// base-14 fonts lack fall back to installed system fonts.
///
/// The HTML comes from untrusted mail, so what it can make the daemon fetch is
/// held in on two fronts. Remote `http(s)` images load from the public internet
/// only: `PublicImageLoader` refuses any host on this machine or a private
/// network, redirects included, that a sender could otherwise make the daemon
/// request (SSRF). Like a mail client that shows images, fetching them lets the
/// sender see that the mail was exported. And nothing the mail names is read from
/// disk: with `allowsLocalFiles` off the renderer refuses `<img>` paths and
/// `file:` URLs and the `@font-face` sources in the mail's own `<style>`, where
/// `/dev/zero` would hang the daemon and `/Users/…/passport.jpg` would be
/// embedded into the PDF. As a second line, `render` first blanks every image
/// source that is neither `data:` nor `http(s)` and disables every `@font-face`
/// rule.
///
/// Images the mail carries itself (`<img src="cid:…">`) are the exception to
/// "nothing but `data:` and `http(s)`": `render` is handed the bytes of those
/// parts and writes them into the HTML as `data:` URIs before anything is
/// blanked, so they come from the message and never from disk or the network.
enum HTMLToPDF {

    /// An image part of the message, addressed from its HTML by Content-ID.
    struct InlineImage: Sendable, Equatable {
        let contentType: String
        let data: Data
    }

    /// The largest image part embedded into a PDF; a bigger one keeps its
    /// placeholder rather than being downloaded.
    static let maximumInlineImageBytes = 20 * 1024 * 1024

    /// Converts an HTML string to PDF data, logging renderer warnings (such as
    /// images that could not be drawn) instead of writing them to stderr.
    ///
    /// `inlineImages` holds the message's own image parts by normalized
    /// Content-ID (see `PostServer.normalizedContentID`), for its `cid:` image sources.
    static func render(html: String, inlineImages: [String: InlineImage] = [:], logger: Logger) async throws -> Data {
        var options = RenderOptions(imageLoader: PublicImageLoader.load)
        options.allowsLocalFiles = false
        let html = removingFontFaces(from: removingLocalImageSources(
            from: embeddingInlineImages(inlineImages, in: html)))
        return try await HTMLRenderer.renderPDF(html: html, options: options) { warning in
            logger.warning("PDF export: \(warning)")
        }
    }

    private static let imageTag = try! NSRegularExpression(
        pattern: #"<img\b(?:"[^"]*"|'[^']*'|[^'">])*>"#, options: .caseInsensitive)
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"(?<![\w-])src\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .caseInsensitive)

    /// The value of a `src` attribute as matched by `srcAttribute`: unquoted and trimmed.
    private static func sourceValue(of attribute: String) -> String {
        attribute.drop { $0 != "=" }.dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The normalized Content-IDs that the `<img>` elements of `html` refer to.
    static func inlineImageContentIDs(in html: String) -> Set<String> {
        var contentIDs: Set<String> = []
        let source = html as NSString
        for tag in imageTag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let tagText = source.substring(with: tag.range) as NSString
            for attribute in srcAttribute.matches(
                in: tagText as String, range: NSRange(location: 0, length: tagText.length)) {
                let value = sourceValue(of: tagText.substring(with: attribute.range))
                if value.lowercased().hasPrefix("cid:") {
                    contentIDs.insert(PostServer.normalizedContentID(value))
                }
            }
        }
        return contentIDs
    }

    /// The media type to put into a `data:` URI for an image part, or nil when the
    /// part is not an image. Only the `image/subtype` token is kept, so nothing a
    /// sender writes into the Content-Type can leave the attribute.
    static func inlineImageMediaType(_ contentType: String) -> String? {
        let mediaType = contentType.prefix { $0 != ";" }
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let subtype = mediaType.dropFirst("image/".count)
        guard mediaType.hasPrefix("image/"), !subtype.isEmpty,
              subtype.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return mediaType
    }

    /// Replaces every `<img>` source of the form `cid:…` that names one of
    /// `images` with that image as a `data:` URI. A `cid:` source without a
    /// matching image is left as it is, for `removingLocalImageSources` to blank.
    static func embeddingInlineImages(_ images: [String: InlineImage], in html: String) -> String {
        guard !images.isEmpty else { return html }
        return replacing(imageTag, in: html) { tag in
            replacing(srcAttribute, in: tag) { attribute in
                let value = sourceValue(of: attribute)
                guard value.lowercased().hasPrefix("cid:"),
                      let image = images[PostServer.normalizedContentID(value)],
                      let mediaType = inlineImageMediaType(image.contentType)
                else { return attribute }
                return "src=\"data:\(mediaType);base64,\(image.data.base64EncodedString())\""
            }
        }
    }

    /// Empties the `src` of every `<img>` that is neither an inline `data:` URI nor
    /// an `http`/`https` URL, so the renderer draws a placeholder instead of
    /// reading it from disk. A protocol-relative `//host/…` source goes too: the
    /// renderer would take it for an absolute path were it not fetched.
    static func removingLocalImageSources(from html: String) -> String {
        replacing(imageTag, in: html) { tag in
            replacing(srcAttribute, in: tag) { attribute in
                let value = sourceValue(of: attribute).lowercased()
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
