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
                ForEach(poller.states) { state in
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
                        Label(
                            updater.pendingAutoInstall
                                ? "업데이트 (\(next)) — 곧 자동 설치"
                                : "업데이트 (\(next))",
                            systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("클릭하면 즉시 설치. '곧 자동 설치'는 연속 푸시 완충/시작 유예로 잠시 대기 중이라는 뜻")
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

                if isActive {
                    Text("사용 중")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                        .help("활성 계정 — usagebar-claude로 실행하는 claude가 이 계정의 1년 토큰을 씁니다")
                }

                if let note = state.staleNote {
                    Text("(\(note))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("마지막 성공 조회 값을 표시 중 — 다음 폴링에서 자동 회복")
                }

                if poller.pinnedAccountId == state.account.id {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("메뉴바에 이 계정 표시 중")
                }

                if !hovering, state.account.isClaudeToken, state.account.priority != 1 {
                    Text("P\(state.account.priority)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("롤링 우선순위 \(state.account.priority) (낮을수록 우선)")
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
                    if state.account.isClaudeToken {
                        Menu {
                            ForEach(1...5, id: \.self) { p in
                                Button {
                                    try? AccountStore.shared.updatePriority(
                                        for: state.account.id, p == 1 ? nil : p)
                                    poller.reloadAccounts()
                                } label: {
                                    if state.account.priority == p {
                                        Label("\(p)", systemImage: "checkmark")
                                    } else {
                                        Text("\(p)")
                                    }
                                }
                            }
                        } label: {
                            Text("P\(state.account.priority)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("롤링 우선순위 (기본 1, 낮을수록 우선)")
                    }

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
                        .help("이 계정을 활성 계정으로 전환 — 다음 claude 실행부터 적용 (자동 롤링이 켜져 있으면 한도 임박 시 다시 교체될 수 있음)")
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
                        // 활성 계정을 지우면 그 토큰이 active 파일에 남지 않게.
                        ActiveAccountStore.shared.clear(ifActive: state.account.id)
                        try? AccountStore.shared.remove(id: state.account.id)
                        poller.reloadAccounts()
                        poller.reloadActive()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("계정 제거")
                }
            }

            if state.account.needsReregistration {
                Text("\(Account.reregistrationNotice) — 계정 추가에서 `claude setup-token` 토큰으로 다시 등록한 뒤 이 행을 지워 주세요")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let snap = state.snapshot {
                HStack(spacing: 12) {
                    // Claude Ultra 플랜은 5h 한도가 없다 — 헤더가 없으면 게이지 숨김.
                    if !(state.account.provider == .claude && snap.fiveHour == nil) {
                        UsageGauge(title: "5h", usage: snap.fiveHour)
                    }
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

    private var isActive: Bool { poller.activeAccountId == state.account.id }

    /// 전환 버튼 노출 조건: 활성 아닌 1년 토큰 계정 + 마지막 조회 정상
    /// (폐기된 토큰을 활성 파일에 쓰면 모든 claude 실행이 실패한다).
    private var canSwitchTo: Bool {
        state.account.isClaudeToken && !isActive && state.lastError == nil
    }

    private func switchToThis() async {
        switching = true
        confirmingSwitch = false
        defer { switching = false }
        let from = poller.states.first { $0.account.id == poller.activeAccountId }?.account
        do {
            try await RollingEngine.roll(
                to: state.account, from: from, states: poller.states,
                store: AccountStore.shared, reason: "수동 전환")
            poller.reloadActive()
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

    @State private var providerChoice: Provider = .claude
    @State private var pasted = ""
    @State private var manualLabel = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var infoText: String?
    /// 같은 조직 id가 이미 등록돼 있다는 경고를 보여준 입력 — 같은 입력으로
    /// 한 번 더 누르면 그대로 추가한다.
    @State private var confirmedDuplicate: String?

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
                Text("1년 토큰 — 터미널에서 `claude setup-token`을 실행해 나온 토큰을 붙여넣으세요(1년 유효). 이 토큰으로는 이메일을 조회할 수 없어 라벨(이메일)을 직접 입력해야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("sk-ant-oat01-…", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                TextField("라벨 (필수 — 계정 이메일)", text: $manualLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            } else {
                Text("그 계정으로 로그인된 ~/.codex/auth.json 내용 전체를 붙여넣어 주세요. 원본 머신에서 codex를 계속 쓰려면 `CODEX_HOME=/tmp/cx codex login`으로 만든 새 세션을 사용해 주세요 (토큰 계보 충돌 방지).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $pasted)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

                TextField("라벨 (선택 — 이메일 자동 조회 실패 시 여기 입력한 값 사용)", text: $manualLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
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
        .onChange(of: providerChoice) {
            pasted = ""
            errorText = nil
            infoText = nil
            confirmedDuplicate = nil
        }
    }

    private var primaryInputEmpty: Bool {
        let input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerChoice == .claude {
            return input.isEmpty || manualLabel.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return input.isEmpty
    }

    private func add() async {
        busy = true
        defer { busy = false }
        errorText = nil
        infoText = nil
        do {
            switch providerChoice {
            case .claude: try await addClaude()
            case .codex: try await addCodex()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 탐침으로 검증(200 또는 한도 거절 429) → 조직 id 중복 경고 → 저장.
    private func addClaude() async throws {
        guard let token = ClaudeProvider.normalizeToken(pasted) else {
            errorText = "토큰 형식이 아닙니다 (공백·줄바꿈 없이 한 줄로 붙여넣어 주세요)"
            return
        }
        let label = manualLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = AccountStore.shared.loadAccounts()
        if let dup = ClaudeRegistration.duplicateToken(token, in: existing, store: .shared) {
            errorText = "이미 등록된 토큰입니다 (\(dup.label))"
            return
        }
        let secrets = AccountSecrets(accessToken: token)
        let (snapshot, _) = try await ClaudeProvider().probe(secrets: secrets)
        let dups = ClaudeRegistration.sameOrganization(snapshot.organizationId, in: existing)
        if !dups.isEmpty, confirmedDuplicate != token {
            confirmedDuplicate = token
            infoText = "같은 조직(계정)의 토큰이 이미 등록돼 있습니다: \(dups.map(\.label).joined(separator: ", ")). 같은 계정을 두 번 등록하면 롤링이 의미가 없습니다 — 그래도 추가하려면 ‘추가’를 한 번 더 눌러 주세요."
            return
        }
        let account = Account(
            provider: .claude, kind: .setupToken, label: label,
            organizationId: snapshot.organizationId)
        try AccountStore.shared.add(account, secrets: secrets)
        poller.reloadAccounts()
        onDone()
        await poller.refreshAll()
    }

    private func addCodex() async throws {
        var secrets = try CodexProvider.secretsFromAuthJSON(pasted)
        let p = CodexProvider()
        let (_, updatedSecrets) = try await p.probe(secrets: secrets)
        secrets = updatedSecrets
        var label = manualLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            if let resolved = try? await p.resolveLabel(secrets: secrets) {
                label = resolved
            } else {
                infoText = "usage 조회는 성공했습니다. 다만 이메일을 가져오지 못했습니다 — 라벨을 직접 입력하고 다시 ‘추가’를 눌러 주세요."
                return
            }
        }
        let account = Account(provider: .codex, kind: .storedToken, label: label)
        try AccountStore.shared.add(account, secrets: secrets)
        poller.reloadAccounts()
        onDone()
        await poller.refreshAll()
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
                Text("새 버전 자동 설치 (1시간마다 + 시작 시 확인)")
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
                Text("Claude 계정 자동 롤링 — 활성 계정의 7d(5h 한도가 있으면 5h 포함)가 95% 이상이면 다음 계정으로 교체")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)
            Text("활성 계정 파일만 바꿉니다 — usagebar-claude를 거치는 claude 실행에 다음 실행부터 적용되며, 키체인 로그인은 건드리지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text(updateStatusLine)
                .font(.caption2)
                .foregroundStyle(updater.lastRun?.state == "failed"
                    ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
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

    /// 업데이트 파이프라인 상태 한 줄 — 알림 권한이 없어도 여기서 보인다.
    private var updateStatusLine: String {
        var parts: [String] = []
        if let checked = updater.lastCheckAt {
            parts.append("확인 \(Self.hhmm(checked))")
        }
        if let run = updater.lastRun {
            let label = switch run.state {
            case "success": "성공"
            case "failed": "실패"
            default: "진행 중"
            }
            let detail = run.detail.isEmpty ? "" : " — \(run.detail)"
            parts.append("마지막 실행 \(label)(\(run.commit))\(detail) \(Self.hhmm(run.at))")
        }
        return parts.isEmpty ? "업데이트: 아직 확인 전" : "업데이트: " + parts.joined(separator: " · ")
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
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
