import Foundation

/// A titled run of consecutive history entries, e.g. "Today".
public struct HistorySection: Identifiable, Sendable, Equatable {
    public var title: String
    public var items: [ClipItem]
    public var id: String { title }

    public init(title: String, items: [ClipItem]) {
        self.title = title
        self.items = items
    }
}

public enum HistorySections {
    /// Groups newest-first entries by recency. Order is preserved; empty groups are omitted.
    public static func byDate(_ items: [ClipItem], now: Date = Date(), calendar: Calendar = .current) -> [HistorySection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        var sections: [HistorySection] = []
        for item in items {
            let title: String
            switch item.updatedAt {
            case today...: title = "Today"
            case yesterday..<today: title = "Yesterday"
            case weekAgo..<yesterday: title = "Previous 7 Days"
            default: title = "Earlier"
            }
            if sections.last?.title == title {
                sections[sections.count - 1].items.append(item)
            } else if let index = sections.firstIndex(where: { $0.title == title }) {
                // Out-of-order dates (e.g. a clock change) still land in their group.
                sections[index].items.append(item)
            } else {
                sections.append(HistorySection(title: title, items: [item]))
            }
        }
        return sections
    }
}

/// A titled run of rows in a list whose entries are loaded on demand: entries
/// `start ..< start + count` (in display order) belong to this section.
public struct ListSection: Sendable, Equatable {
    public var title: String
    public var start: Int
    public var count: Int
    public var range: Range<Int> { start..<(start + count) }

    public init(title: String, start: Int, count: Int) {
        self.title = title
        self.start = start
        self.count = count
    }
}

extension HistorySections {
    /// Section titles with the earliest `updatedAt` each one covers, newest first. "Earlier" has
    /// no lower bound.
    public static func boundaries(now: Date = Date(), calendar: Calendar = .current) -> [(title: String, since: Date?)] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        return [("Today", today), ("Yesterday", yesterday), ("Previous 7 Days", weekAgo), ("Earlier", nil)]
    }

    /// Lays out sections from how many entries are at least as new as each boundary
    /// (`cumulative[i]` for `boundaries()[i]`; the last is the total). Empty sections are omitted.
    public static func sections(cumulativeCounts cumulative: [Int], titles: [String]) -> [ListSection] {
        var sections: [ListSection] = []
        var start = 0
        for (title, upTo) in zip(titles, cumulative) {
            let count = max(0, upTo - start)
            if count > 0 { sections.append(ListSection(title: title, start: start, count: count)) }
            start = max(start, upTo)
        }
        return sections
    }
}
