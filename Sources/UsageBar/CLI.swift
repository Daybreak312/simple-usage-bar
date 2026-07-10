import Foundation

/// Headless commands so the whole pipeline is testable without the GUI:
///   usagebar check                     — fetch all accounts, print a table
///   usagebar list                      — list registered accounts
///   usagebar add-claude                — token from stdin (claude setup-token)
///   usagebar add-claude --from-local-cli — piggyback on local Claude Code login
///   usagebar add-codex <auth.json path | -> — import a codex auth.json
///   usagebar remove <uuid-prefix>      — remove an account
enum CLI {
    static func shouldRun(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        return ["check", "list", "add-claude", "add-codex", "remove", "update", "webhook", "help", "--help"]
            .contains(args[1])
    }

    static func run(_ args: [String]) async -> Int32 {
        let store = AccountStore.shared
        switch args[1] {
        case "help", "--help":
            print(usage)
            return 0

        case "list":
            for a in store.loadAccounts() {
                print("\(a.id.uuidString.prefix(8))  \(a.provider.displayName.padding(toLength: 7, withPad: " ", startingAt: 0))  \(a.kind.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0))  \(a.label)")
            }
            return 0

        case "add-claude":
            do {
                if args.contains("--from-local-cli") {
                    let token = try ClaudeProvider.readLocalCLIToken()
                    let email = try await ClaudeProvider()
                        .resolveLabel(secrets: AccountSecrets(accessToken: token))
                    let account = Account(provider: .claude, kind: .localClaudeCLI, label: "\(email) (로컬)")
                    try store.add(account, secrets: AccountSecrets())
                    print("추가됨: Claude \(account.label) [로컬 keychain 연동]")
                } else if args.contains("--oauth") {
                    let session = ClaudeOAuth.begin()
                    print("아래 URL을 브라우저에서 열어 등록할 계정으로 승인 (다른 계정은 시크릿 창):")
                    print(session.url.absoluteString)
                    FileHandle.standardError.write(Data("\n승인 코드 (code#state): ".utf8))
                    guard let code = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !code.isEmpty else {
                        print("코드가 비어 있음"); return 1
                    }
                    let (initial, email) = try await ClaudeOAuth.exchange(pasted: code, session: session)
                    let (_, secrets) = try await ClaudeProvider().probe(secrets: initial)
                    var label = value(of: "--label", in: args) ?? email
                    if label == nil {
                        label = try? await ClaudeProvider().resolveLabel(secrets: secrets)
                    }
                    let account = Account(
                        provider: .claude, kind: .storedToken, label: label ?? "claude")
                    try store.add(account, secrets: secrets)
                    print("추가됨: Claude \(account.label)")
                } else {
                    FileHandle.standardError.write(Data("sk-ant-oat01-… 토큰 입력 후 엔터: ".utf8))
                    guard let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !token.isEmpty else {
                        print("토큰이 비어 있음"); return 1
                    }
                    let secrets = AccountSecrets(accessToken: token)
                    // usage 스코프 검증이 먼저 — setup-token은 profile 스코프가 없을 수 있음.
                    _ = try await ClaudeProvider().probe(secrets: secrets)
                    var label = value(of: "--label", in: args)
                    if label == nil {
                        label = try? await ClaudeProvider().resolveLabel(secrets: secrets)
                    }
                    if label == nil {
                        print("usage 조회 성공. 프로필 권한이 없는 토큰이라 이메일 자동 조회 불가 — --label <이메일>로 다시 실행해줘")
                        return 1
                    }
                    let account = Account(provider: .claude, kind: .storedToken, label: label!)
                    try store.add(account, secrets: secrets)
                    print("추가됨: Claude \(label!)")
                }
                return 0
            } catch {
                print("실패: \(error.localizedDescription)"); return 1
            }

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
                try store.remove(id: matches[0].id)
                print("제거됨: \(matches[0].label)")
                return 0
            } catch {
                print("실패: \(error.localizedDescription)"); return 1
            }

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

        case "check":
            let (board, failed) = await fetchBoard(store)
            guard !board.isEmpty else {
                print("등록된 계정 없음 — usagebar add-claude / add-codex 먼저")
                return 1
            }
            print(TUIFormat.board(board))
            return failed ? 2 : 0

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
                    header: "[!] 웹훅 테스트 - UsageBar", states: board)
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

    /// Fetch every account's usage into displayable states (CLI check / webhook test).
    private static func fetchBoard(_ store: AccountStore) async -> ([AccountState], Bool) {
        var board: [AccountState] = []
        var failed = false
        for account in store.loadAccounts() {
            var state = AccountState(account: account)
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
    usagebar — Claude/Codex 사용량 메뉴바 앱

    GUI:  usagebar                (메뉴바 아이콘으로 실행)
    CLI:  usagebar check          현재 등록된 모든 계정의 사용량 출력
          usagebar list           계정 목록
          usagebar add-claude [--oauth | --from-local-cli] [--label <이메일>]
          usagebar add-codex <auth.json | ->
          usagebar remove <uuid-prefix>
          usagebar update          깃허브 pull → 재빌드 → 재설치 → 재시작
          usagebar webhook slack|discord <url> | clear | show | test
    """
}
