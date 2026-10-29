import Foundation

enum WidgetCalendar {
    static func nextDay(after date: Date, calendar: Calendar = .current) -> Date? {
        calendar.dateInterval(of: .day, for: date)?.end
    }
}
