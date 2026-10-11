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
