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
/// placeholders; inline `data:` images still render.
enum HTMLToPDF {

    /// Converts an HTML string to PDF data, logging renderer warnings (such as
    /// images that could not be drawn) instead of writing them to stderr.
    static func render(html: String, logger: Logger) async throws -> Data {
        try await HTMLRenderer.renderPDF(html: html, options: RenderOptions(imageLoader: nil)) { warning in
            logger.warning("PDF export: \(warning)")
        }
    }
}
