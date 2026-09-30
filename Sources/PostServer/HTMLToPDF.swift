import Foundation
import Logging
import SwiftTextRender

/// Renders HTML content to PDF with SwiftText's Swift layout engine.
///
/// No WebKit, so this runs on every platform Post builds for. Glyphs the
/// base-14 fonts lack fall back to installed system fonts.
enum HTMLToPDF {

    /// Converts an HTML string to PDF data, logging renderer warnings (such as
    /// images that could not be drawn) instead of writing them to stderr.
    static func render(html: String, logger: Logger) async throws -> Data {
        try await HTMLRenderer.renderPDF(html: html) { warning in
            logger.warning("PDF export: \(warning)")
        }
    }
}
