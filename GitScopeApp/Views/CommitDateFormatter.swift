import Foundation

@MainActor
enum CommitDateFormatter {
    private static let calendar = Calendar.autoupdatingCurrent

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        return formatter
    }()

    /// "오늘/어제/올해" 판정 경계. 행마다 `isDateInToday` 류의 Calendar 연산을 반복하지
    /// 않도록 경계 시각만 붙잡아 두고, 현재 시각이 캐시된 오늘 범위를 벗어나면(날짜가
    /// 넘어가면) 다시 계산한다.
    private static var todayStart = Date.distantPast
    private static var tomorrowStart = Date.distantPast
    private static var yesterdayStart = Date.distantPast
    private static var yearStart = Date.distantPast
    private static var nextYearStart = Date.distantPast

    static func string(from date: Date, now: Date = .now) -> String {
        refreshBoundariesIfNeeded(now: now)
        if date >= todayStart, date < tomorrowStart {
            return "오늘 \(timeFormatter.string(from: date))"
        }
        if date >= yesterdayStart, date < todayStart {
            return "어제 \(timeFormatter.string(from: date))"
        }
        if date >= yearStart, date < nextYearStart {
            return dateFormatter.string(from: date)
        }
        return date.formatted(.dateTime.year().month().day())
    }

    private static func refreshBoundariesIfNeeded(now: Date) {
        guard now < todayStart || now >= tomorrowStart else { return }
        let start = calendar.startOfDay(for: now)
        todayStart = start
        tomorrowStart = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        yesterdayStart = calendar.date(byAdding: .day, value: -1, to: start)
            ?? start.addingTimeInterval(-86_400)
        let year = calendar.component(.year, from: now)
        yearStart = calendar.date(from: DateComponents(year: year)) ?? start
        nextYearStart = calendar.date(from: DateComponents(year: year + 1)) ?? tomorrowStart
    }
}
