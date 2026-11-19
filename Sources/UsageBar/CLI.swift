import Foundation

/// Headless commands so the whole pipeline is testable without the GUI:
///   usagebar check                     — fetch all accounts, print a table
///   usagebar list                      — list registered accounts
///   usagebar add-claude-token --label <email> — 1-year token from stdin
///   usagebar add-codex <auth.json path | -> — import a codex auth.json
///   usagebar remove <uuid-prefix>      — remove an account
enum CLI {
    static func shouldRun(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        return ["check", "list", "add-claude", "add-claude-token", "add-codex", "remove", "roll", "priority", "update", "webhook", "notify", "parse-codex", "help", "--help"]
            .contains(args[1])
    }

    static func run(_ args: [String]) async -> Int32 {
        let store = AccountStore.shared
        switch args[1] {
        case "help", "--help":
            print(usage)
            return 0

        case "list":
            let active = ActiveAccountStore.shared.read()?.accountId
            for a in store.loadAccounts() {
                let prio = a.priority == 1 ? "" : "  [P\(a.priority)]"
                let mark = a.id == active ? "  * 사용 중"
                    : a.needsReregistration ? "  (\(Account.reregistrationNotice))" : ""
                print("\(a.id.uuidString.prefix(8))  \(a.provider.displayName.padding(toLength: 7, withPad: " ", startingAt: 0))  \(a.kind.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0))  \(a.label)\(prio)\(mark)")
            }
            return 0

        case "priority":
            // usagebar priority <email|uuid접두어> <1-9> — 낮을수록 우선, 1이 기본.
            guard args.count > 3, let p = Int(args[3]), (1...9).contains(p) else {
                print("사용법: usagebar priority <email|uuid접두어> <1-9>")
                return 1
            }
            let key = args[2].lowercased()
            var matches = store.loadAccounts().filter {
                $0.id.uuidString.lowercased().hasPrefix(key)
                    || $0.email.lowercased() == key
            }
            // 같은 이메일의 레거시 행 + 1년 토큰 행이 함께 걸리면 1년 토큰 행이 대상.
            if matches.count > 1 {
                let tokens = matches.filter(\.isClaudeToken)
                if tokens.count == 1 { matches = tokens }
            }
            guard matches.count == 1 else {
                print(matches.isEmpty ? "일치하는 계정 없음" : "대상이 모호함 (\(matches.count)개 일치)")
                return 1
            }
            do {
                try store.updatePriority(for: matches[0].id, p == 1 ? nil : p)
                print("우선순위 변경: \(matches[0].label) → \(p)")
                return 0
            } catch {
                print("실패: \(error.localizedDescription)")
                return 1
            }

        case "add-claude":
            print("""
            'add-claude'(OAuth·로컬 CLI 등록)는 제거되었습니다. 1년 토큰으로 등록해 주세요:
              claude setup-token                                   # 1년 유효 토큰 발급
              usagebar add-claude-token --label <이메일> < 토큰파일   # 또는 실행 후 붙여넣기
            """)
            return 1

        case "add-claude-token":
            return await addClaudeToken(args, store: store)

        case "add-codex":
            do {
                guard args.count > 2 else { print("auth.json 경로 필요 (또는 - 로 stdin)"); return 1 }
                let text: String
                if args[2] == "-" {
                    text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
                } else {
                    text = try String(contentsOfFile: args[2], encoding: .utf8)
                }
                let secrets = try CodexProvider.secretsFromAuthJSON(text)
                let email = try await CodexProvider().resolveLabel(secrets: secrets)
                let account = Account(provider: .codex, kind: .storedToken, label: email)
                try store.add(account, secrets: secrets)
                print("추가됨: Codex \(email)")
                return 0
            } catch {
                print("실패: \(error.localizedDescription)"); return 1
            }

        case "remove":
            guard args.count > 2 else { print("uuid 접두어 필요"); return 1 }
            let prefix = args[2].lowercased()
            let matches = store.loadAccounts().filter {
                $0.id.uuidString.lowercased().hasPrefix(prefix)
            }
            guard matches.count == 1 else {
                print(matches.isEmpty ? "일치하는 계정 없음" : "접두어가 모호함 (\(matches.count)개 일치)")
                return 1
            }
            do {
                // 활성 계정을 지우면 그 토큰이 active 파일에 남지 않게.
                ActiveAccountStore.shared.clear(ifActive: matches[0].id)
                try store.remove(id: matches[0].id)
                print("제거됨: \(matches[0].label)")
                return 0
            } catch {
                print("실패: \(error.localizedDescription)"); return 1
            }

        case "notify":
            // update.sh 등 외부에서 앱 명의로 네이티브 알림을 쏘는 통로.
            let title = args.count > 2 ? args[2] : "SimpleUsageBar"
            let body = args.count > 3 ? args[3] : ""
            LocalNotifier.send(title: title, body: body)
            // UN 전달이 비동기라 프로세스가 바로 죽으면 유실됨 — 잠깐 대기.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return 0

        case "update":
            guard let repo = UpdateChecker.repoPath() else {
                print("레포 경로를 못 찾음 — defaults write dev.daybreak.usagebar repoPath <경로>")
                return 1
            }
            print("업데이트 실행 (로그: /tmp/usagebar-update.log)")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["\(repo)/scripts/update.sh"]
            try? proc.run()
            proc.waitUntilExit()
            let ok = proc.terminationStatus == 0
            print(ok ? "완료 — 앱이 재시작됨" : "실패 — 로그 확인: tail /tmp/usagebar-update.log")
            return ok ? 0 : 1

        case "parse-codex":
            // wham/usage 응답 JSON(stdin)을 실제 파서에 통과시켜 창 배치를 확인.
            // 표시가 이상할 때 원본 응답만 받아오면 매핑을 재현해볼 수 있다.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            do {
                let snap = try CodexProvider.parseUsage(data)
                let fmt = DateFormatter()
                fmt.dateFormat = "MM-dd HH:mm"
                func line(_ name: String, _ w: WindowUsage?) {
                    guard let w else { print("\(name)  —"); return }
                    let reset = w.resetsAt.map { "  (리셋 \(fmt.string(from: $0)))" } ?? ""
                    print("\(name)  \(Int(w.percent.rounded()))% 사용\(reset)")
                }
                line("5h", snap.fiveHour)
                line("7d", snap.sevenDay)
                if !snap.details.isEmpty { print(snap.details.joined(separator: " · ")) }
                return 0
            } catch {
                print("파싱 실패: \(error.localizedDescription)")
                return 1
            }

        case "check":
            let (board, failed) = await fetchBoard(store)
            guard !board.isEmpty else {
                print("등록된 계정 없음 — usagebar add-claude-token / add-codex로 먼저 등록해 주세요")
                return 1
            }
            print(TUIFormat.board(board))
            return failed ? 2 : 0

        case "roll":
            // 활성 계정 파일(usagebar-claude가 쓰는 토큰)을 다른 1년 토큰 계정으로 교체.
            //   usagebar roll [--to <email>] [--dry-run]
            // --to 없이 실행하면 자동 롤링과 같은 후보 선정 로직을 따른다.
            let (board, _) = await fetchBoard(store)
            let activeId = ActiveAccountStore.shared.read()?.accountId
            let current = board.first { $0.account.id == activeId && $0.account.isClaudeToken }
            let target: AccountState?
            if let to = value(of: "--to", in: args) {
                let found = board.filter {
                    $0.account.isClaudeToken
                        && $0.account.email.caseInsensitiveCompare(to) == .orderedSame
                }
                guard let first = found.first else {
                    print("'\(to)' 1년 토큰 계정이 등록돼 있지 않음 (usagebar list로 확인)")
                    return 1
                }
                if first.account.id == current?.account.id {
                    print("'\(to)'는 이미 활성 계정")
                    return 1
                }
                if let error = first.lastError {
                    print("'\(to)' 조회 실패 상태라 전환하지 않음: \(error)")
                    return 1
                }
                target = first
            } else {
                target = RollingPolicy.candidates(states: board, activeId: current?.account.id).first
            }
            guard let target else {
                print("교체할 후보 없음 — 다른 1년 토큰 계정이 없거나 전부 지표 \(Int(RollingPolicy.threshold))% 이상·조회 실패")
                return 1
            }
            let currentTrip = RollingPolicy.tripName(current?.snapshot)
            let targetTrip = RollingPolicy.tripName(target.snapshot)
            print("활성: \(current?.account.email ?? "(없음)") [\(currentTrip)] → 대상: \(target.account.email) [\(targetTrip)]")
            if args.contains("--dry-run") {
                print("(dry-run — 변경 없음)")
                return 0
            }
            do {
                try await RollingEngine.roll(
                    to: target.account, from: current?.account, states: board, store: store,
                    reason: "수동 (\(currentTrip))")
                print("교체 완료 — 활성 계정: \(target.account.email) (다음 usagebar-claude 실행부터 적용)")
                return 0
            } catch {
                print("실패: \(error.localizedDescription)")
                return 1
            }

        case "webhook":
            guard args.count > 2 else {
                print("usagebar webhook slack|discord <url> | clear | show | test")
                return 1
            }
            var settings = SettingsStore.shared.load()
            switch args[2] {
            case "slack", "discord":
                guard args.count > 3 else { print("URL 필요"); return 1 }
                if args[2] == "slack" { settings.slackURL = args[3] }
                else { settings.discordURL = args[3] }
                do {
                    try SettingsStore.shared.save(settings)
                    print("저장됨 (\(args[2]))")
                    return 0
                } catch {
                    print("저장 실패: \(error.localizedDescription)"); return 1
                }
            case "clear":
                try? SettingsStore.shared.save(AppSettings())
                print("웹훅 설정 비움")
                return 0
            case "show":
                print("discord: \(mask(settings.discordURL))")
                print("slack:   \(mask(settings.slackURL))")
                return 0
            case "test":
                guard !settings.isEmpty else { print("웹훅 URL 미등록"); return 1 }
                let (board, _) = await fetchBoard(store)
                let results = await AlertSender.send(
                    header: "[!] 웹훅 테스트 - SimpleUsageBar", states: board)
                var ok = true
                for (target, code) in results {
                    let good = (200...299).contains(code)
                    ok = ok && good
                    print("\(target): \(good ? "전송 성공" : "실패 (HTTP \(code))")")
                }
                return ok ? 0 : 1
            default:
                print("usagebar webhook slack|discord <url> | clear | show | test")
                return 1
            }

        default:
            print(usage)
            return 1
        }
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.count > idx + 1 else { return nil }
        return args[idx + 1]
    }

    private static func mask(_ url: String) -> String {
        url.isEmpty ? "(없음)" : "\(url.prefix(45))…"
    }

    /// `usagebar add-claude-token --label <email> [--allow-duplicate]` — the
    /// token comes from stdin (argv is visible in `ps`). Probe-validated
    /// before saving; never echoed.
    static func addClaudeToken(_ args: [String], store: AccountStore) async -> Int32 {
        guard let label = value(of: "--label", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            print("사용법: usagebar add-claude-token --label <이메일>   (토큰은 stdin — `claude setup-token`으로 발급)")
            return 1
        }
        let raw: String
        if isatty(fileno(stdin)) != 0 {
            FileHandle.standardError.write(Data("claude setup-token 토큰(sk-ant-oat01-…) 붙여넣고 엔터: ".utf8))
            raw = readLine() ?? ""
        } else {
            raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        guard let token = ClaudeProvider.normalizeToken(raw) else {
            print("토큰이 비었거나 형식이 아님 (공백·줄바꿈 없는 한 줄)")
            return 1
        }
        let existing = store.loadAccounts()
        if let dup = ClaudeRegistration.duplicateToken(token, in: existing, store: store) {
            print("이미 등록된 토큰: \(dup.label)")
            return 1
        }
        do {
            let secrets = AccountSecrets(accessToken: token)
            let (snapshot, _) = try await ClaudeProvider().probe(secrets: secrets)
            let dups = ClaudeRegistration.sameOrganization(snapshot.organizationId, in: existing)
            if !dups.isEmpty, !args.contains("--allow-duplicate") {
                print("같은 조직(계정)의 토큰이 이미 등록됨: \(dups.map(\.label).joined(separator: ", ")) — 그래도 추가하려면 --allow-duplicate")
                return 1
            }
            let account = Account(
                provider: .claude, kind: .setupToken, label: label,
                organizationId: snapshot.organizationId)
            try store.add(account, secrets: secrets)
            var state = AccountState(account: account)
            state.snapshot = snapshot
            print("추가됨: Claude \(label)")
            print(TUIFormat.board([state]))
            return 0
        } catch {
            print("실패: \(error.localizedDescription)")
            return 1
        }
    }

    /// Fetch every account's usage into displayable states (CLI check / webhook test).
    /// Legacy Claude rows are listed without fetching.
    private static func fetchBoard(_ store: AccountStore) async -> ([AccountState], Bool) {
        var board: [AccountState] = []
        var failed = false
        for account in store.loadAccounts() {
            var state = AccountState(account: account)
            if account.needsReregistration {
                board.append(state)
                continue
            }
            do {
                state.snapshot = try await provider(for: account.provider)
                    .fetchUsage(account: account, store: store)
            } catch {
                state.lastError = error.localizedDescription
                failed = true
            }
            board.append(state)
        }
        return (board, failed)
    }

    private static let usage = """
    SimpleUsageBar — Claude/Codex 사용량 메뉴바 앱

    GUI:  usagebar                (메뉴바 아이콘으로 실행)
    CLI:  usagebar check          현재 등록된 모든 계정의 사용량 출력
          usagebar list           계정 목록
          usagebar add-claude-token --label <이메일> [--allow-duplicate]
                                  1년 토큰(claude setup-token) 등록 — 토큰은 stdin
          usagebar add-codex <auth.json | ->
          usagebar remove <uuid-prefix>
          usagebar roll [--to <email>] [--dry-run]   활성 Claude 계정(usagebar-claude 토큰) 교체
          usagebar priority <email|uuid접두어> <1-9>  롤링 우선순위 (낮을수록 우선)
          usagebar update          깃허브 pull → 재빌드 → 재설치 → 재시작
          usagebar webhook slack|discord <url> | clear | show | test
          usagebar parse-codex     wham/usage JSON(stdin) 파싱 결과 확인 (디버그)
          usagebar observe-claude --launch <id> --dir <경로>
                                  usagebar-claude 내부용 — claude stdout 통과·이벤트 기록
    """
}
