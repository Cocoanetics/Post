import Foundation
import SwiftMail

/// How a connection to an IMAP or SMTP server is secured.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAPS, SMTPS).
    case tls
    /// Plaintext greeting, then an upgrade with STARTTLS.
    case starttls

    /// The SwiftMail transport mode for this choice.
    public var transportSecurity: MailTransportSecurity {
        switch self {
        case .tls: return .implicitTLS
        case .starttls: return .startTLS
        }
    }

    /// The mode implied by the port when none was chosen: IMAP 993 and SMTP 465 use TLS, anything else STARTTLS.
    public static func inferred(port: Int, isSMTP: Bool) -> ConnectionSecurity {
        port == (isSMTP ? 465 : 993) ? .tls : .starttls
    }
}
