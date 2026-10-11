import Foundation

/// How a copy that matches existing history is treated. Raw values are persisted.
public enum DuplicateHandling: String, Sendable, CaseIterable, Codable {
    /// Keep a single entry per content and move it to the top when copied again.
    case moveToTop
    /// Only ignore a copy identical to the most recent entry.
    case ignoreConsecutive
    /// Record every copy as its own entry.
    case keepAll

    public var title: String {
        switch self {
        case .moveToTop: "Move existing item to top"
        case .ignoreConsecutive: "Ignore only consecutive copies"
        case .keepAll: "Keep every copy"
        }
    }
}

public enum InsertOutcome: Sendable, Equatable {
    case inserted(ClipItem.ID)
    /// An existing entry with the same content was moved to the top.
    case updated(ClipItem.ID)
    case skipped

    public var itemID: ClipItem.ID? {
        switch self {
        case let .inserted(id), let .updated(id): id
        case .skipped: nil
        }
    }
}
