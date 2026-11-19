import SwiftUI

enum Urgency {
    case overdue, dueToday, upcoming, noDue

    var color: Color {
        switch self {
        case .overdue: .red
        case .dueToday: .blue
        case .upcoming: .orange
        case .noDue: .gray
        }
    }
}

struct FakeTicket: Identifiable {
    let id = UUID()
    let key: String
    let subject: String
    let detail: String
    let urgency: Urgency
}

enum FakeData {
    static let menuBarTitle = "디자인 리뷰 반영 · 18:00"
    static let openCount = 8
    static let tickets = [
        FakeTicket(key: "FE-1203", subject: "결제 모듈 오류 수정", detail: "마감 지남 · 어제 18:00", urgency: .overdue),
        FakeTicket(key: "APP-88", subject: "디자인 리뷰 반영", detail: "오늘 18:00 · 3시간 남음", urgency: .dueToday),
        FakeTicket(key: "OPS-12", subject: "주간 보고 작성", detail: "마감 없음", urgency: .noDue),
    ]
    static let next = (subject: "API 문서 정리", when: "내일 10:00")
}

enum Chrome {
    case system, custom
}

struct PanelContent: View {
    let chrome: Chrome
    var onQuit: () -> Void = { NSApp.terminate(nil) }

    var body: some View {
        let inner = VStack(spacing: 10) {
            header
            list
            bottomBar
        }
        .padding(12)
        .frame(width: 344)

        if chrome == .custom {
            inner.glassEffect(.regular, in: .rect(cornerRadius: 30))
        } else {
            inner
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(red: 0.91, green: 0.42, blue: 0.36), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("목요일").font(.system(size: 15, weight: .semibold))
                Text("2026년 11월 19일").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(FakeData.openCount)").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("남은 업무").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(cardFill, in: .rect(cornerRadius: 22))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("오늘").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(FakeData.tickets) { ticket in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(ticket.urgency.color).frame(width: 3.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.subject).font(.system(size: 14, weight: .semibold))
                        Text("\(ticket.key) · \(ticket.detail)")
                            .font(.system(size: 12))
                            .foregroundStyle(ticket.urgency == .overdue ? Color.red : Color.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("다음").foregroundStyle(.secondary)
                Text(FakeData.next.subject).fontWeight(.semibold)
                Spacer()
                Text(FakeData.next.when).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: .rect(cornerRadius: 22))
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Label("Dooray", systemImage: "arrow.up.right.square")
            Spacer()
            Image(systemName: "gearshape")
            Button(action: onQuit) { Image(systemName: "power") }.buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var cardFill: some ShapeStyle {
        Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }
}
