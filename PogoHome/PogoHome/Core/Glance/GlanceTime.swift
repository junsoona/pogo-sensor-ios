import Foundation

/// A confirmation time: "14:02" today, "9월 22일 14:02" on another day.
nonisolated enum GlanceTime {
    static func string(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// For the tiny Lock Screen shapes: the time today, only the date on another day.
    static func compactString(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "14:02 확인" for a recent confirmation, "마지막 확인 14:02" once it's old or unconfirmed,
    /// "확인 기록 없음" if there never was one.
    static func confirmation(_ date: Date?, now: Date, isCurrent: Bool) -> String {
        guard let date else {
            return String(localized: "확인 기록 없음", comment: "Widget: this was never confirmed by the app")
        }
        let time = string(date, now: now)
        return isCurrent
            ? String(localized: "\(time) 확인", comment: "Widget: when the app confirmed this, e.g. '14:02 확인'")
            : String(localized: "마지막 확인 \(time)", comment: "Widget: when the app last confirmed old or unverified data")
    }
}
