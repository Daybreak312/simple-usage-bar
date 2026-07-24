import SwiftUI

// MARK: - Popover root (single window, in-place navigation)

/// The MenuBarExtra popover closes whenever it loses key status, so any
/// separate window (.sheet/.popover) fights it. All navigation happens
/// in-place by swapping the popover's content.
struct MenuView: View {
    enum Screen { case list, add, settings }

    @EnvironmentObject var poller: Poller
    @EnvironmentObject var updater: UpdateChecker
    @State private var screen: Screen = .list

    var body: some View {
        Group {
            switch screen {
            case .list: accountList
            case .add: AddAccountView(onDone: { screen = .list })
            case .settings: SettingsView(onDone: { screen = .list })
            }
        }
        .padding(12)
        .frame(width: 480)
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if poller.states.isEmpty {
                VStack(spacing: 6) {
                    Text("등록된 계정이 없습니다").font(.callout)
                    Text("아래 + 버튼으로 시작해 주세요").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(poller.visibleStates) { state in
                    AccountRow(state: state)
                }
            }

            Divider()

            HStack(spacing: 10) {
                if let last = poller.lastRefresh {
                    Text("갱신 \(last, style: .time)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let commit = updater.currentCommit {
                    Text(commit)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .help("현재 버전 — 클릭하면 업데이트 확인")
                        .onTapGesture { Task { await updater.check() } }
                }
                Spacer()

                if updater.updating {
                    Text("업데이트 중…")
                        .font(.caption2).foregroundStyle(.orange)
                } else if let next = updater.availableCommit {
                    Button {
                        updater.apply()
                    } label: {
                        Label("업데이트 (\(next))", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("git pull → 재빌드 → 재설치 → 자동 재시작")
                }

                Button {
                    Task { await poller.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("지금 새로고침")

                Button {
                    screen = .add
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("계정 추가")

                Button {
                    screen = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("웹훅 알림 설정")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("종료")
            }
        }
    }
}

// MARK: - Account row

struct AccountRow: View {
    let state: AccountState
    @EnvironmentObject var poller: Poller
    @State private var hovering = false
    @State private var confirmingSwitch = false
    @State private var switching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(state.account.provider.displayName)
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(badgeColor)

                Text(state.account.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if poller.pinnedAccountId == state.account.id {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("메뉴바에 이 계정 표시 중")
                }

                Spacer()

                if switching {
                    ProgressView()
                        .controlSize(.small)
                    Text("전환 중…")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if hovering {
                    if canSwitchTo {
                        Button {
                            if confirmingSwitch {
                                Task { await switchToThis() }
                            } else {
                                confirmingSwitch = true
                            }
                        } label: {
                            if confirmingSwitch {
                                Label("한 번 더 누르면 전환", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(confirmingSwitch ? .orange : .secondary)
                        .disabled(switching)
                        .help("이 계정으로 Claude Code 로그인 전환 (자동 롤링이 켜져 있으면 한도 임박 시 다시 교체될 수 있음)")
                    }

                    Button {
                        let isPinned = poller.pinnedAccountId == state.account.id
                        poller.setPinned(isPinned ? nil : state.account.id)
                    } label: {
                        Image(systemName: poller.pinnedAccountId == state.account.id
                            ? "pin.slash" : "pin")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help(poller.pinnedAccountId == state.account.id
                        ? "고정 해제 (메뉴바에 전체 최댓값 표시)"
                        : "메뉴바에 이 계정 퍼센트 표시")

                    Button {
                        try? AccountStore.shared.remove(id: state.account.id)
                        poller.reloadAccounts()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("계정 제거")
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let snap = state.snapshot {
                HStack(spacing: 12) {
                    UsageGauge(title: "5h", usage: snap.fiveHour)
                    UsageGauge(title: "7d", usage: snap.sevenDay)
                }
                if !snap.details.isEmpty {
                    Text(snap.details.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("불러오는 중…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onHover {
            hovering = $0
            if !$0 { confirmingSwitch = false }
        }
    }

    /// 전환 버튼 노출 조건: Claude 저장 계정 + 로컬 행(전환 추적 주체) 존재.
    /// 섀도잉 덕에 화면에 보이는 저장 행은 곧 "현재 비활성" 계정이다.
    private var canSwitchTo: Bool {
        state.account.provider == .claude
            && state.account.kind == .storedToken
            && poller.states.contains {
                $0.account.provider == .claude && $0.account.kind == .localClaudeCLI
            }
    }

    private func switchToThis() async {
        switching = true
        confirmingSwitch = false
        defer { switching = false }
        let local = poller.states.first {
            $0.account.provider == .claude && $0.account.kind == .localClaudeCLI
        }
        do {
            try await RollingEngine.roll(
                to: state.account, states: poller.visibleStates,
                store: AccountStore.shared,
                reason: "수동 전환", from: local?.account.email)
            poller.reloadAccounts()
            await poller.refreshAll()
        } catch {
            LocalNotifier.send(title: "[!] 계정 전환 실패", body: error.localizedDescription)
        }
    }

    private var badgeColor: Color {
        state.account.provider == .claude ? .orange : .teal
    }
}

struct UsageGauge: View {
    let title: String
    let usage: WindowUsage?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let pct = usage?.percent {
                        Capsule()
                            .fill(color(pct))
                            .frame(width: max(3, geo.size.width * min(pct, 100) / 100))
                    }
                }
            }
            .frame(height: 7)

            Text(usage.map { "\(Int($0.percent))%" } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 34, alignment: .trailing)

            if let resets = usage?.resetsAt {
                Text(Self.countdown(to: resets))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .leading)
            }
        }
    }

    private func color(_ pct: Double) -> Color {
        switch pct {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    static func countdown(to date: Date) -> String {
        let s = max(0, date.timeIntervalSinceNow)
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h >= 48 { return "\(h / 24)d\(h % 24)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}

// MARK: - Add account (inline, same window)

struct AddAccountView: View {
    @EnvironmentObject var poller: Poller
    let onDone: () -> Void

    enum ClaudeMode: String, CaseIterable, Identifiable {
        case oauth = "OAuth 로그인 (권장)"
        case paste = "토큰 직접 입력"
        var id: String { rawValue }
    }

    @State private var providerChoice: Provider = .claude
    @State private var claudeMode: ClaudeMode = .oauth
    @State private var oauthSession: ClaudeOAuth.Session?
    @State private var oauthCode = ""
    @State private var pasted = ""
    @State private var manualLabel = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var infoText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("계정 추가").font(.headline)
                Spacer()
            }

            Picker("프로바이더", selection: $providerChoice) {
                ForEach(Provider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if providerChoice == .claude {
                Picker("방식", selection: $claudeMode) {
                    ForEach(ClaudeMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if providerChoice == .claude && claudeMode == .oauth {
                Text("1) 아래 버튼으로 로그인 페이지를 열고 **등록할 계정으로** 승인해 주세요\n2) 다른 계정이면 ‘URL 복사’ 후 시크릿 창에서 진행해 주세요\n3) 승인 후 화면에 뜨는 코드를 아래에 붙여넣어 주세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("브라우저에서 로그인 열기") {
                        let session = ClaudeOAuth.begin()
                        oauthSession = session
                        NSWorkspace.shared.open(session.url)
                    }
                    Button("URL 복사") {
                        let session = ClaudeOAuth.begin()
                        oauthSession = session
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.url.absoluteString, forType: .string)
                    }
                }
                .disabled(busy)

                TextField("승인 코드 (code#state 형태)", text: $oauthCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            } else {
                Group {
                    if providerChoice == .claude {
                        Text("sk-ant-oat01-… 토큰을 붙여넣어 주세요. 주의: setup-token 토큰은 usage 조회 스코프(user:profile)가 없어 등록되지 않습니다 — OAuth 로그인을 사용해 주세요. (로컬 감지는 이 맥의 Claude Code 로그인을 재사용합니다)")
                    } else {
                        Text("그 계정으로 로그인된 ~/.codex/auth.json 내용 전체를 붙여넣어 주세요. 원본 머신에서 codex를 계속 쓰려면 `CODEX_HOME=/tmp/cx codex login`으로 만든 새 세션을 사용해 주세요 (토큰 계보 충돌 방지).")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $pasted)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: providerChoice == .claude ? 54 : 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }

            TextField("라벨 (선택 — 이메일 자동 조회 실패 시 여기 입력한 값 사용)", text: $manualLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if providerChoice == .claude && claudeMode == .paste {
                Button("로컬 Claude Code 계정 자동 감지") {
                    Task { await addLocalClaude() }
                }
                .font(.caption)
                .disabled(busy)
            }

            if let infoText {
                Text(infoText).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("취소") { onDone() }
                Button(busy ? "확인 중…" : "추가") {
                    Task { await add() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || primaryInputEmpty)
            }
        }
    }

    private var primaryInputEmpty: Bool {
        if providerChoice == .claude && claudeMode == .oauth {
            return oauthCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Validation order matters: usage first (the thing we actually need),
    /// then profile only to prettify the label.
    private func add() async {
        busy = true
        defer { busy = false }
        errorText = nil
        infoText = nil
        do {
            var secrets: AccountSecrets
            var oauthEmail: String?
            switch providerChoice {
            case .claude where claudeMode == .oauth:
                guard let session = oauthSession else {
                    errorText = "먼저 ‘브라우저에서 로그인 열기’ 또는 ‘URL 복사’로 로그인을 시작해 주세요 (코드는 그 세션과 짝이어야 합니다)"
                    return
                }
                (secrets, oauthEmail) = try await ClaudeOAuth.exchange(
                    pasted: oauthCode, session: session)
            case .claude:
                secrets = AccountSecrets(
                    accessToken: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            case .codex:
                secrets = try CodexProvider.secretsFromAuthJSON(pasted)
            }

            let p = provider(for: providerChoice)
            let (_, updatedSecrets) = try await p.probe(secrets: secrets)
            secrets = updatedSecrets
            if let oauthEmail, manualLabel.isEmpty { manualLabel = oauthEmail }

            var label = manualLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                if let resolved = try? await p.resolveLabel(secrets: secrets) {
                    label = resolved
                } else {
                    infoText = "usage 조회는 성공했습니다. 다만 이 토큰엔 프로필 권한이 없어 이메일을 가져오지 못했습니다 — 라벨을 직접 입력하고 다시 ‘추가’를 눌러 주세요."
                    return
                }
            }

            let account = Account(provider: providerChoice, kind: .storedToken, label: label)
            try AccountStore.shared.add(account, secrets: secrets)
            poller.reloadAccounts()
            onDone()
            await poller.refreshAll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addLocalClaude() async {
        busy = true
        defer { busy = false }
        errorText = nil
        infoText = nil
        do {
            let token = try ClaudeProvider.readLocalCLIToken()
            let label = (try? await ClaudeProvider()
                .resolveLabel(secrets: AccountSecrets(accessToken: token))) ?? "로컬 Claude Code"
            let account = Account(provider: .claude, kind: .localClaudeCLI, label: "\(label) (로컬)")
            try AccountStore.shared.add(account, secrets: AccountSecrets())
            poller.reloadAccounts()
            onDone()
            await poller.refreshAll()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Webhook settings (inline, same window)

struct SettingsView: View {
    @EnvironmentObject var poller: Poller
    @EnvironmentObject var updater: UpdateChecker
    let onDone: () -> Void

    @State private var discord = ""
    @State private var slack = ""
    @State private var status: String?
    @State private var busy = false
    @State private var autoRoll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("웹훅 알림 설정").font(.headline)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("메뉴바 표시").font(.caption)
                Picker("", selection: Binding(
                    get: { poller.menuBarWindow },
                    set: { poller.setMenuBarWindow($0) }
                )) {
                    ForEach(MenuBarWindow.allCases, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("‘둘 다’는 5h/7d 순서로 표시합니다. 계정 행의 핀으로 특정 계정만 볼 수도 있습니다 (핀이 없으면 계정 전체 최댓값).")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Toggle(isOn: Binding(
                get: { updater.autoUpdate },
                set: { updater.setAutoUpdate($0) }
            )) {
                Text("새 버전 자동 설치 (6시간마다 + 시작 시 확인)")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: Binding(
                get: { autoRoll },
                set: { on in
                    autoRoll = on
                    var s = SettingsStore.shared.load()
                    s.autoRoll = on
                    try? SettingsStore.shared.save(s)
                }
            )) {
                Text("Claude 계정 자동 롤링 — 5h/7d/모델 주간 중 하나가 95% 이상이면 다음 계정으로 교체")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            Text("주의: 이 맥의 Claude Code 로그인 자체가 바뀝니다 (claude CLI를 쓰는 모든 도구에 적용). 교체 전 기존 계정의 토큰은 앱에 자동 보존됩니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("계정별로 3분마다 조회합니다. 5h/7d 사용률이 50·70·80·90%를 상향 돌파하면 등록된 웹훅으로 알림을 보냅니다 — 첫 줄에 돌파한 계정·임계치, 아래에 전체 계정 보드.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Discord 웹훅 URL (https://discord.com/api/webhooks/…)", text: $discord)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            TextField("Slack 웹훅 URL (https://hooks.slack.com/services/…)", text: $slack)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))

            if let status {
                Text(status).font(.caption)
                    .foregroundStyle(status.contains("실패") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("테스트 전송") {
                    Task { await test() }
                }
                .disabled(busy)
                Button("저장") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            let s = SettingsStore.shared.load()
            discord = s.discordURL
            slack = s.slackURL
            autoRoll = s.autoRoll ?? false
        }
    }

    private func save() {
        do {
            // Load-modify-save: settings.json holds pin/window/autoUpdate/
            // autoRoll too — overwriting with a fresh struct wiped them.
            var s = SettingsStore.shared.load()
            s.slackURL = slack.trimmingCharacters(in: .whitespacesAndNewlines)
            s.discordURL = discord.trimmingCharacters(in: .whitespacesAndNewlines)
            try SettingsStore.shared.save(s)
            status = "저장됨"
        } catch {
            status = "저장 실패: \(error.localizedDescription)"
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        save()
        guard !SettingsStore.shared.load().isEmpty else {
            status = "웹훅 URL을 먼저 입력해 주세요"
            return
        }
        let results = await AlertSender.send(
            header: "[!] 웹훅 테스트 - SimpleUsageBar", states: poller.states)
        status = results.map { target, code in
            let ok = (200...299).contains(code)
            return "\(target): \(ok ? "전송 성공" : "실패 (HTTP \(code))")"
        }.joined(separator: " · ")
    }
}

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @ObservedObject var poller: Poller

    var body: some View {
        if let text = poller.menuBarText {
            Image(systemName: symbol(for: poller.menuBarSeverity ?? 0))
            Text(text)
        } else {
            Image(systemName: "gauge.with.needle")
        }
    }

    private func symbol(for pct: Double) -> String {
        switch pct {
        case ..<60: return "gauge.with.needle"
        case ..<85: return "gauge.high"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
