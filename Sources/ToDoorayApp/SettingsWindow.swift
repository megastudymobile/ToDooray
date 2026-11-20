import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func show() {
        model.reloadMilestones()
        let window = self.window ?? makeWindow()
        self.window = window
        // An accessory app's text fields get key focus only once the app is active.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.title = "ToDooray 설정"
        window.isReleasedWhenClosed = false
        // SwiftUI sizes the window a moment after it appears, which is too late to center it.
        window.setContentSize(content.view.fittingSize)
        window.center()
        return window
    }
}

struct SettingsView: View {
    let model: AppModel

    @State private var draft = SettingsDraft()
    @State private var saveMessage: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField(
                    "개인 API 토큰",
                    text: $draft.token,
                    prompt: Text(model.settings.token == nil ? "Dooray에서 발급한 토큰" : "저장됨")
                )
                TextField("Dooray 웹 주소", text: $draft.webAddress, prompt: Text("회사이름.dooray.com"))
                TextField("API 주소", text: $draft.apiBase, prompt: Text(Settings.defaultAPIBase.absoluteString))
            } footer: {
                Text("토큰은 이 Mac의 키체인에만 저장합니다.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("로그인 시 실행", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginItemMessage {
                    HStack {
                        Text(loginItemMessage).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("로그인 항목 열기") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Section {
                HStack {
                    Text(saveMessage ?? status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("저장", action: save).keyboardShortcut(.defaultAction)
                }
            }

            FilterSection(model: model)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: showStoredSettings)
    }

    private var status: String {
        switch model.state {
        case .needsSetup: "토큰과 웹 주소를 입력해 주세요"
        case .loading: "확인 중…"
        case .loaded(let snapshot) where model.filter.isActive:
            "연결됨 · 업무 \(snapshot.tasks.count)건 중 \(model.filter.apply(snapshot.tasks).visible.count)건 표시"
        case .loaded(let snapshot): "연결됨 · 업무 \(snapshot.tasks.count)건"
        case .stale(_, let error), .failed(let error): Copy.failure(error)
        case .authFailed: Copy.authFailed
        }
    }

    private func showStoredSettings() {
        draft = SettingsDraft(
            token: "",
            webAddress: model.settings.webBase?.absoluteString ?? "",
            apiBase: model.settings.apiBase.absoluteString
        )
        loginItemMessage = LaunchAtLogin.needsApproval ? "시스템 설정에서 허용해 주세요" : nil
    }

    private func save() {
        do throws(AppModel.SaveError) {
            try model.save(draft)
            saveMessage = nil
            showStoredSettings()
        } catch {
            saveMessage = switch error {
            case .invalid(.tokenMissing): "토큰을 입력해 주세요"
            case .invalid(.tokenMalformed): "토큰에 공백이나 줄바꿈이 들어 있어요"
            case .invalid(.webAddressInvalid): "웹 주소를 확인해 주세요. 예: 회사이름.dooray.com"
            case .invalid(.apiBaseInvalid): "API 주소는 https로 시작해야 해요"
            case .keychain(let status): "키체인에 저장하지 못했어요 (\(status))"
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            loginItemMessage = LaunchAtLogin.needsApproval ? "시스템 설정에서 허용해 주세요" : nil
        } catch {
            loginItemMessage = "로그인 항목을 바꾸지 못했어요"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

private struct FilterSection: View {
    let model: AppModel

    private static let listHeight: CGFloat = 300

    var body: some View {
        let choices = model.filterChoices
        Section {
            Toggle("모든 업무 보기", isOn: Binding(
                get: { !model.filter.isActive },
                set: { model.setFilter($0 ? .showAll : TaskFilter.showAll.pickingEvery(choices)) }
            ))
            Group {
                if choices.isEmpty {
                    Text("업무를 불러오면 프로젝트가 여기에 보여요")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        // With no filter on, the list shows what "모든 업무 보기" means: everything checked.
                        FilterList(
                            choices: choices,
                            filter: model.filter.isActive ? model.filter : model.filter.pickingEvery(choices),
                            milestoneLoads: model.milestoneLoads,
                            update: model.setFilter,
                            loadMilestones: { model.loadMilestones(of: $0) }
                        )
                        .disabled(!model.filter.isActive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: Self.listHeight)
        } header: {
            Text("표시할 업무")
        } footer: {
            Text("체크한 프로젝트와 단계의 업무만 메뉴 막대와 패널에 보여요. 바로 적용돼요.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FilterList: View {
    let choices: [ProjectChoice]
    let filter: TaskFilter
    let milestoneLoads: [String: AppModel.MilestoneLoad]
    let update: (TaskFilter) -> Void
    let loadMilestones: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choices) { project in
                let selection = filter.projects?[project.id]
                Toggle(isOn: binding(selection != nil) { $0.setProject(project, picked: $1) }) {
                    counted(project.code, project.taskCount)
                }
                if let selection {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("모든 단계", isOn: binding(selection.milestones == nil) {
                            $0.setEveryMilestone(of: project, picked: $1)
                            if !$1 { loadMilestones(project.id) }
                        })
                        if let milestones = selection.milestones {
                            Group {
                                ForEach(project.milestones, id: \.self) { item in
                                    Toggle(isOn: binding(milestones.admits(item.milestone)) {
                                        $0.setMilestone(item.milestone, of: project, picked: $1)
                                    }) {
                                        counted(item.name, item.taskCount)
                                    }
                                }
                                loadStatus(of: project)
                            }
                            .padding(.leading, 20)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private func loadStatus(of project: ProjectChoice) -> some View {
        switch milestoneLoads[project.id] {
        case .loading:
            Text("단계 불러오는 중…").font(.callout).foregroundStyle(.secondary)
        case .failed:
            HStack {
                Text("단계를 불러오지 못했어요").font(.callout).foregroundStyle(.secondary)
                Button("다시 시도") { loadMilestones(project.id) }.controlSize(.small)
            }
        case .loaded, nil:
            EmptyView()
        }
    }

    private func counted(_ name: String, _ count: Int) -> Text {
        count == 0 ? Text(name) : Text(name) + Text("  \(count)건").foregroundStyle(.secondary)
    }

    private func binding(_ isOn: Bool, _ change: @escaping (inout TaskFilter, Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                var next = filter
                change(&next, on)
                update(next)
            }
        )
    }
}

/// Read from the system every time and never copied into UserDefaults, so a change made in
/// System Settings shows up here.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
