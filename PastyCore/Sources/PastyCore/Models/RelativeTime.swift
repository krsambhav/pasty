import Foundation

/// Compact relative timestamps for list rows: "now", "4m", "2h", "Yesterday", "3d", "Mar 4".
public enum RelativeTime {
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<(3_600 * 24) where calendar.isDate(date, inSameDayAs: now):
            return "\(Int(seconds / 3_600))h"
        default: break
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days)d" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(calendar.locale ?? .current)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(style)
    }
}
