import Foundation
import NIOIMAPCore
import SwiftMail

// NIOIMAPCore also declares IMAPServer, MessageIdentifier and MessageIdentifierSet, so the
// SwiftMail types are qualified here.

/// The commands searches and raw downloads need. Both the shared primary connection
/// (`IMAPServer`) and an extra connection (`IMAPNamedConnection`) provide them, so the
/// same code runs on an extra connection or, as a fallback, on the primary one.
protocol MailboxCommandRunning: Actor {
    func selectMailbox(_ mailboxName: String) async throws -> SwiftMail.Mailbox.Selection

    func extendedSearch<T: SwiftMail.MessageIdentifier>(
        identifierSet: SwiftMail.MessageIdentifierSet<T>?,
        criteria: [SwiftMail.SearchCriteria],
        sortCriteria: [SortCriterion],
        sortCharset: String,
        calendar: Calendar,
        partialRange: PartialRange?
    ) async throws -> SwiftMail.ExtendedSearchResult<T>

    func fetchMessageInfosBulk<T: SwiftMail.MessageIdentifier>(
        using identifierSet: SwiftMail.MessageIdentifierSet<T>,
        options: SwiftMail.FetchMessageInfoOptions,
        headerFields: [String]?
    ) async throws -> [SwiftMail.MessageInfo]

    func fetchRawMessage<T: SwiftMail.MessageIdentifier>(identifier: T) async throws -> Data
}

extension SwiftMail.IMAPServer: MailboxCommandRunning {}
extension SwiftMail.IMAPNamedConnection: MailboxCommandRunning {}

extension MailboxCommandRunning {
    /// Unsorted extended search; named apart from `extendedSearch` so calls on a concrete
    /// `IMAPServer` stay unambiguous.
    func searchUIDs<T: SwiftMail.MessageIdentifier>(
        identifierSet: SwiftMail.MessageIdentifierSet<T>?,
        criteria: [SwiftMail.SearchCriteria],
        partialRange: PartialRange?
    ) async throws -> SwiftMail.ExtendedSearchResult<T> {
        try await extendedSearch(
            identifierSet: identifierSet,
            criteria: criteria,
            sortCriteria: [],
            sortCharset: "UTF-8",
            calendar: Calendar(identifier: .gregorian),
            partialRange: partialRange
        )
    }

    /// Header data without any message body: SwiftMail's default info set, which is envelope,
    /// internal date, flags, body structure and the full header section (so
    /// `MessageInfo.additionalFields` is filled, as `fetchMessages(using:)` filled it).
    func fetchHeaderInfos<T: SwiftMail.MessageIdentifier>(
        using identifierSet: SwiftMail.MessageIdentifierSet<T>
    ) async throws -> [SwiftMail.MessageInfo] {
        try await fetchMessageInfosBulk(using: identifierSet, options: .default, headerFields: nil)
    }
}
