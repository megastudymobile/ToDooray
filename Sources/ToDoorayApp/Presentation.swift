import DooraySync
import Foundation

// Everything the user reads is computed here from (AppState, now, calendar). Views and the
// status item only lay these values out, and the debug console prints the same values.

// MARK: - Menu bar

enum StatusSymbol: String, Equatable {
    case normal
    case allDone
    case attention
}

struct StatusTitle: Equatable {
    var symbol: StatusSymbol
    /// Preferred text, already capped. Empty means the icon alone.
    var full: String
    /// Shown when `full` gets the status item hidden: the open count, or empty.
    var compact: String

    /// With a list, the title follows the next deadline today. An overdue task is not the
    /// title: the oldest one sorts first and would stay pinned to the menu bar for weeks.
    /// A stale list renders like a fresh one, since it is still the best answer available.
    static func make(state: AppState, filter: TaskFilter, now: Date, calendar: Calendar) -> StatusTitle {
        guard let snapshot = state.snapshot else {
            switch state {
            case .needsSetup: return StatusTitle(symbol: .attention, full: Copy.titleNeedsSetup, compact: "")
            case .authFailed: return StatusTitle(symbol: .attention, full: Copy.titleAuthFailed, compact: "")
            case .failed: return StatusTitle(symbol: .attention, full: "", compact: "")
            case .loading, .loaded, .stale: return StatusTitle(symbol: .normal, full: "", compact: "")
            }
        }

        let items = Agenda.items(filter.apply(snapshot.tasks).visible, now: now, calendar: calendar)
        guard !items.isEmpty else {
            return StatusTitle(symbol: .allDone, full: Copy.titleNothingOpen, compact: "")
        }
        let count = String(items.count)
        if let next = items.first(where: { $0.urgency == .dueToday }), let due = next.task.dueDate {
            let full = "\(TitleText.capped(next.task.subject)) · \(Format.time(due, calendar))"
            return StatusTitle(symbol: .normal, full: full, compact: count)
        }
        let overdue = items.count { $0.urgency == .overdue }
        let full = overdue > 0 ? Copy.titleOverdue(overdue) : Copy.titleOpen(items.count)
        return StatusTitle(symbol: .normal, full: full, compact: count)
    }
}

enum TitleText {
    /// Hangul, CJK and fullwidth characters count 2 and everything else 1. Eighteen units is
    /// about nine Hangul syllables, which keeps the whole item under roughly 190 pt.
    static let maxUnits = 18

    static func capped(_ text: String, maxUnits: Int = maxUnits) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.reduce(0, { $0 + units(of: $1) }) > maxUnits else { return collapsed }

        var kept = ""
        var used = 1
        for character in collapsed {
            let width = units(of: character)
            if used + width > maxUnits { break }
            kept.append(character)
            used += width
        }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func units(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF:
            return 2
        default:
            return 1
        }
    }
}

// MARK: - Panel

struct PanelModel: Equatable {
    struct Header: Equatable, Encodable {
        var weekday: String
        var date: String
        /// The tasks the filter shows. nil when there is no list to count.
        var openCount: Int?
    }

    struct Row: Equatable, Identifiable {
        var task: DoorayTask
        var urgency: Urgency
        var subject: String
        var detail: String
        var id: String { task.id }
    }

    /// The earliest upcoming task and how many more upcoming tasks follow it.
    struct Next: Equatable {
        var task: DoorayTask
        var subject: String
        var when: String
        var moreCount: Int
    }

    enum Body: Equatable {
        case needsSetup
        case loading
        case authFailed
        case failed(message: String)
        case allDone
        /// `today` holds overdue, due-today and no-due tasks in contract order.
        /// Upcoming tasks fold into `next`.
        case tasks(today: [Row], next: Next?)
    }

    var header: Header
    var body: Body
    var footer: String?
    /// Tasks the filter hides. nil when no filter is on or there is no list.
    var hiddenCount: Int?

    /// The panel never hides work silently: with a filter on, this line says how much it hides.
    var filterNote: String? { hiddenCount.map(Copy.filterNote) }

    static func make(state: AppState, filter: TaskFilter, now: Date, calendar: Calendar) -> PanelModel {
        let filtered = state.snapshot.map { filter.apply($0.tasks) }
        let header = Header(
            weekday: Format.weekday(now, calendar),
            date: Format.longDate(now, calendar),
            openCount: filtered?.visible.count
        )
        guard let snapshot = state.snapshot, let filtered else {
            let body: Body = switch state {
            case .needsSetup: .needsSetup
            case .authFailed: .authFailed
            case .failed(let error): .failed(message: Copy.failure(error))
            case .loading, .loaded, .stale: .loading
            }
            return PanelModel(header: header, body: body, footer: nil, hiddenCount: nil)
        }
        let hiddenCount = filter.isActive ? filtered.hiddenCount : nil

        let footer: String = if case .stale(_, let error) = state {
            Copy.staleFooter(reason: Copy.failure(error), fetchedAt: Format.time(snapshot.fetchedAt, calendar))
        } else {
            Copy.updated(Format.ago(snapshot.fetchedAt, now: now))
        }

        let items = Agenda.items(filtered.visible, now: now, calendar: calendar)
        guard !items.isEmpty else {
            return PanelModel(header: header, body: .allDone, footer: footer, hiddenCount: hiddenCount)
        }
        // Work already in progress belongs to today even when its deadline is later.
        let belongsToday = { (item: AgendaItem) in item.urgency != .upcoming || item.task.state == .working }
        let upcoming = items.filter { !belongsToday($0) }
        let today = items.filter(belongsToday).map { item in
            Row(
                task: item.task,
                urgency: item.urgency,
                subject: item.task.subject,
                detail: Format.detail(item, now: now, calendar: calendar)
            )
        }
        let next = upcoming.first.flatMap { first in
            first.task.dueDate.map { due in
                Next(
                    task: first.task,
                    subject: first.task.subject,
                    when: Format.when(due, now: now, calendar: calendar),
                    moreCount: upcoming.count - 1
                )
            }
        }
        return PanelModel(header: header, body: .tasks(today: today, next: next), footer: footer, hiddenCount: hiddenCount)
    }
}

// MARK: - Copy and formatting

enum Copy {
    static let titleNeedsSetup = "설정 필요"
    static let titleAuthFailed = "토큰 확인"
    static let titleNothingOpen = "할 일 없음"
    static func titleOverdue(_ count: Int) -> String { "마감 지남 \(count)건" }
    static func titleOpen(_ count: Int) -> String { "할 일 \(count)건" }

    static let openCountCaption = "남은 업무"
    static let todaySection = "오늘"
    static let nextLabel = "다음"
    static func more(_ count: Int) -> String { "외 \(count)건" }
    static let overdue = "마감 지남"
    static let noDue = "마감 없음"
    static let needsSetup = "Dooray 연결이 필요해요"
    static let authFailed = "토큰이 맞지 않아요"
    static let openSettings = "설정 열기"
    static let loading = "불러오는 중"
    static let allDone = "남은 업무가 없어요"
    static let nothingToday = "오늘 할 일은 없어요"
    static let openDooray = "Dooray"
    static let settings = "설정"
    static let refresh = "새로고침 (⌘R)"
    static let quit = "종료"
    static func update(_ version: AppVersion) -> String { "업데이트 \(version)" }
    static let updateHelp = "새 버전 내려받기"

    static func filterNote(hidden: Int) -> String { "필터 적용 중 · 숨긴 업무 \(hidden)건" }
    static let noMilestone = "단계 없음"

    static func updated(_ ago: String) -> String { "\(ago) 업데이트" }
    static func staleFooter(reason: String, fetchedAt: String) -> String {
        "업데이트 실패 · \(reason) · \(fetchedAt) 기준"
    }

    static func failure(_ error: DoorayError) -> String {
        switch error {
        case .unauthorized: authFailed
        case .rateLimited: "요청이 많아 잠시 쉬는 중"
        case .network: "네트워크 연결 없음"
        case .http(let status): "Dooray 서버 오류 (\(status))"
        case .api(_, let message): message.isEmpty ? "Dooray 오류" : "Dooray 오류: \(message)"
        case .invalidResponse: "응답 형식이 달라요"
        case .cancelled: ""
        }
    }
}

/// Strings are built from calendar components, not a formatter, so they do not depend on the
/// machine's locale or 12-hour setting.
enum Format {
    private static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]

    static func weekday(_ date: Date, _ calendar: Calendar) -> String {
        weekdays[calendar.component(.weekday, from: date) - 1] + "요일"
    }

    static func longDate(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)년 \(parts.month ?? 0)월 \(parts.day ?? 0)일"
    }

    static func time(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func detail(_ item: AgendaItem, now: Date, calendar: Calendar) -> String {
        let key = item.task.key
        guard let due = item.task.dueDate else { return "\(key) · \(Copy.noDue)" }
        switch item.urgency {
        case .overdue:
            return "\(key) · \(Copy.overdue) · \(day(due, now: now, calendar: calendar, withWeekday: false)) \(time(due, calendar))"
        case .dueToday:
            return "\(key) · 오늘 \(time(due, calendar)) · \(remaining(until: due, now: now))"
        case .upcoming, .noDue:
            return "\(key) · \(when(due, now: now, calendar: calendar))"
        }
    }

    static func when(_ due: Date, now: Date, calendar: Calendar) -> String {
        "\(day(due, now: now, calendar: calendar, withWeekday: true)) \(time(due, calendar))"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(seconds / 60)분 전"
        case ..<86400: return "\(seconds / 3600)시간 전"
        default: return "\(seconds / 86400)일 전"
        }
    }

    private static func remaining(until due: Date, now: Date) -> String {
        let minutes = Int(due.timeIntervalSince(now)) / 60
        return minutes < 60 ? "\(max(minutes, 1))분 남음" : "\(minutes / 60)시간 남음"
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar, withWeekday: Bool) -> String {
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day
        switch offset {
        case 0: return "오늘"
        case -1: return "어제"
        case 1: return "내일"
        default: break
        }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        var text = "\(parts.month ?? 0)월 \(parts.day ?? 0)일"
        if parts.year != calendar.component(.year, from: now) {
            text = "\(parts.year ?? 0)년 " + text
        }
        if withWeekday, let weekday = parts.weekday {
            text += " (\(weekdays[weekday - 1]))"
        }
        return text
    }
}
