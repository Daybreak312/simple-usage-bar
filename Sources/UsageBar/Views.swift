import SwiftUI

// MARK: - Popover root (single window, in-place navigation)

/// The MenuBarExtra popover closes whenever it loses key status, so any
/// separate window (.sheet/.popover) fights it. All navigation happens
/// in-place by swapping the popover's content.
struct MenuView: View {
    @EnvironmentObject var poller: Poller
    @State private var adding = false

    var body: some View {
        Group {
            if adding {
                AddAccountView(onDone: { adding = false })
            } else {
                accountList
            }
        }
        .padding(12)
        .frame(width: 480)
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if poller.states.isEmpty {
                VStack(spacing: 6) {
                    Text("등록된 계정이 없어").font(.callout)
                    Text("아래 + 버튼으로 시작").font(.caption).foregroundStyle(.secondary)
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
                Spacer()
                Button {
                    Task { await poller.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("지금 새로고침")

                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("계정 추가")

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

                Spacer()

                if hovering {
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
        .onHover { hovering = $0 }
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

            Group {
                if providerChoice == .claude {
                    Text("`claude setup-token`으로 발급한 sk-ant-oat01-… 토큰을 붙여넣어. 다른 계정은 시크릿 창에서 로그인해 발급하면 돼.")
                } else {
                    Text("그 계정으로 로그인된 ~/.codex/auth.json 내용 전체를 붙여넣어. 원본 머신에서 codex를 계속 쓸 거면 `CODEX_HOME=/tmp/cx codex login`으로 새 세션을 만들어 그걸 쓸 것 (토큰 계보 충돌 방지).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pasted)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: providerChoice == .claude ? 54 : 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))

            TextField("라벨 (선택 — 이메일 자동 조회 실패 시 여기 입력한 값 사용)", text: $manualLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if providerChoice == .claude {
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
                .disabled(busy || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// Validation order matters: usage first (the thing we actually need),
    /// then profile only to prettify the label. setup-token tokens can lack
    /// the profile scope while usage works fine.
    private func add() async {
        busy = true
        defer { busy = false }
        errorText = nil
        infoText = nil
        do {
            var secrets: AccountSecrets
            switch providerChoice {
            case .claude:
                secrets = AccountSecrets(
                    accessToken: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            case .codex:
                secrets = try CodexProvider.secretsFromAuthJSON(pasted)
            }

            let p = provider(for: providerChoice)
            let (_, updatedSecrets) = try await p.probe(secrets: secrets)
            secrets = updatedSecrets

            var label = manualLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                if let resolved = try? await p.resolveLabel(secrets: secrets) {
                    label = resolved
                } else {
                    infoText = "usage 조회는 성공! 다만 이 토큰엔 프로필 권한이 없어서 이메일을 못 가져와 — 라벨을 직접 입력하고 다시 ‘추가’를 눌러줘."
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

// MARK: - Menu bar label

struct MenuBarLabel: View {
    @ObservedObject var poller: Poller

    var body: some View {
        if let worst = poller.worstPercent {
            Image(systemName: symbol(for: worst))
            Text("\(Int(worst))%")
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
