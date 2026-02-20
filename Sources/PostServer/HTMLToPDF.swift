#if os(macOS)
import Foundation
import SwiftTextHTML

/// Renders HTML content to PDF using WebKit.
enum HTMLToPDF {

    /// Converts an HTML string to PDF data.
    /// Must be called from an async context; internally dispatches to `@MainActor`.
    @available(macOS 12.0, *)
    static func render(html: String) async throws -> Data {
        await MainActor.run {
            // WebKit needs a RunLoop tick — ensure one is scheduled
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        let browser = await WebKitBrowser(htmlString: html)
        return try await browser.exportPDFData()
    }
}
#endif
