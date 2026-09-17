import Foundation

/// Narrows the list to when something was copied.
///
/// Separate from the category filter rather than folded into it: "images" and
/// "this week" are two independent questions, and a user asking both at once is
/// the ordinary case - the whole point of a time filter is to cut a busy tab
/// down before looking for a type inside it.
enum TimeFilter: Equatable, Codable {
    case any
    case lastDay
    case lastWeek
    case lastMonth
    /// A range the user picked, inclusive of both days.
    case range(from: Date, to: Date)

    static let presets: [TimeFilter] = [.any, .lastDay, .lastWeek, .lastMonth]

    var title: String {
        switch self {
        case .any:       return "Any time"
        case .lastDay:   return "Last 24 hours"
        case .lastWeek:  return "Last 7 days"
        case .lastMonth: return "Last 30 days"
        case .range(let from, let to):
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return "\(f.string(from: from)) – \(f.string(from: to))"
        }
    }

    /// The short form for the button, which sits in a crowded row.
    var shortTitle: String {
        switch self {
        case .any:       return "Any time"
        case .lastDay:   return "24 hours"
        case .lastWeek:  return "7 days"
        case .lastMonth: return "30 days"
        case .range:     return title
        }
    }

    var symbol: String {
        switch self {
        case .any:   return "clock"
        case .range: return "calendar"
        default:     return "clock.arrow.circlepath"
        }
    }

    var isCustom: Bool { if case .range = self { return true }; return false }

    /// Does an item fall inside this window?
    ///
    /// A custom range runs to the END of its last day. Comparing against the
    /// raw date would silently exclude everything copied on the final day of
    /// the range the user just chose, which reads as the filter being broken.
    func contains(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .any:       return true
        case .lastDay:   return date >= now.addingTimeInterval(-86_400)
        case .lastWeek:  return date >= now.addingTimeInterval(-7 * 86_400)
        case .lastMonth: return date >= now.addingTimeInterval(-30 * 86_400)
        case .range(let from, let to):
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1,
                                    to: calendar.startOfDay(for: max(from, to))) ?? max(from, to)
            return date >= start && date < end
        }
    }
}
