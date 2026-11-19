import AppKit
import DooraySync
import SwiftUI

/// Lays out `PanelModel.make(state, now)`. Every string, count and partition comes from the model.
struct PanelView: View {
    let model: AppModel
    let perform: (PanelAction) -> Void

    static let width: CGFloat = 344
    /// Transparent room around the glass for its own shadow. A window edge that touches the
    /// glass clips that shadow to a square, which shows as lines past the rounded corners.
    static let shadowMargin: CGFloat = 24

    var body: some View {
        let content = PanelModel.make(state: model.state, now: model.now, calendar: .current)
        VStack(spacing: 10) {
            HeaderCard(header: content.header)
            BodyCard(content: content.body, footer: content.footer, perform: perform)
            BottomBar(perform: perform)
        }
        .padding(12)
        .frame(width: Self.width)
        .modifier(GlassBackground(cornerRadius: 30))
        .padding(Self.shadowMargin)
    }
}

/// Liquid Glass on macOS 26 and later, a behind-window material before that. Both draw
/// their own shadow because the panel window has none.
private struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                MaterialBackground()
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            )
        }
    }
}

private struct MaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: .rect(cornerRadius: 22))
    }
}

private struct HeaderCard: View {
    let header: PanelModel.Header

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(red: 0.91, green: 0.42, blue: 0.36), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(header.weekday).font(.system(size: 15, weight: .semibold))
                Text(header.date).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if let openCount = header.openCount {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(openCount)").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(Copy.openCountCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .modifier(Card())
    }
}

private struct BodyCard: View {
    let content: PanelModel.Body
    let footer: String?
    let perform: (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch content {
            case .tasks(let today, let next):
                Text(Copy.todaySection).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if today.isEmpty {
                    Text(Copy.nothingToday).font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    TaskList(rows: today, perform: perform)
                }
                if let next {
                    Divider()
                    NextLine(next: next) { perform(.openTask(next.task)) }
                }
            case .allDone:
                Notice(symbol: "checkmark.circle", message: Copy.allDone)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.loading).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Notice(symbol: "exclamationmark.triangle", message: message)
            case .needsSetup:
                SetupNotice(message: Copy.needsSetup, perform: perform)
            case .authFailed:
                SetupNotice(message: Copy.authFailed, perform: perform)
            }
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .modifier(Card())
    }
}

private struct TaskList: View {
    let rows: [PanelModel.Row]
    let perform: (PanelAction) -> Void

    private static let maxVisibleRows = 8
    /// A one-line subject, its detail line and the row's insets.
    private static let rowHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 4

    var body: some View {
        if rows.count > Self.maxVisibleRows {
            let visible = CGFloat(Self.maxVisibleRows)
            ScrollView {
                stack
            }
            .frame(height: visible * Self.rowHeight + (visible - 1) * Self.rowSpacing)
            .padding(.horizontal, -TaskRow.horizontalInset)
        } else {
            stack
                .padding(.horizontal, -TaskRow.horizontalInset)
                .padding(.vertical, -TaskRow.verticalInset)
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(rows) { row in
                TaskRow(row: row) { perform(.openTask(row.task)) }
            }
        }
    }
}

private struct TaskRow: View {
    let row: PanelModel.Row
    let open: () -> Void

    /// Room for the hover highlight around the row. The list takes it back at its edges.
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 4

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(row.urgency.color).frame(width: 3.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.subject)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(row.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(row.urgency == .overdue ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Self.verticalInset)
            .padding(.horizontal, Self.horizontalInset)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct NextLine: View {
    let next: PanelModel.Next
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(Copy.nextLabel).foregroundStyle(.secondary)
                Text(next.subject).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(next.when).foregroundStyle(.secondary).fixedSize()
                if next.moreCount > 0 {
                    Text(Copy.more(next.moreCount)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .font(.system(size: 12.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct Notice: View {
    let symbol: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(message).font(.system(size: 13))
        }
    }
}

private struct SetupNotice: View {
    let message: String
    let perform: (PanelAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Notice(symbol: "key", message: message)
            Button(Copy.openSettings) { perform(.openSettings) }
        }
    }
}

private struct BottomBar: View {
    let perform: (PanelAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button { perform(.openDooray) } label: {
                Label(Copy.openDooray, systemImage: "arrow.up.right.square")
            }
            Spacer()
            Button { perform(.openSettings) } label: {
                Image(systemName: "gearshape")
            }
            .help(Copy.settings)
            Button { perform(.quit) } label: {
                Image(systemName: "power")
            }
            .help(Copy.quit)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

private extension Urgency {
    var color: Color {
        switch self {
        case .overdue: .red
        case .dueToday: .blue
        case .upcoming: .orange
        case .noDue: .gray
        }
    }
}
