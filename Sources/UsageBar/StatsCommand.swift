import Foundation

/// `usagebar stats [--days N] [--account <email|uuid접두어>] [--json] [--refresh]`
/// — the usage ledger without the GUI. Reads the ledger file only; `--refresh`
/// runs one ingest scan first (same scan the app runs every minute). Prices
/// come from the cached/bundled table — no network.
enum StatsCommand {
    static let defaultDays = 7

    struct Options: Equatable {
        var days = StatsCommand.defaultDays
        var account: String?
        var json = false
        var refresh = false
    }

    enum Parsed: Equatable {
        case ok(Options)
        case bad(String)
    }

    static func parse(_ args: [String]) -> Parsed {
        var o = Options()
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--days":
                guard i + 1 < args.count, let n = Int(args[i + 1]), (1...UsageLedger.retentionDays).contains(n) else {
                    return .bad("--days는 1~\(UsageLedger.retentionDays) 사이 정수")
                }
                o.days = n
                i += 1
            case "--account":
                guard i + 1 < args.count, !args[i + 1].isEmpty else { return .bad("--account <이메일|uuid접두어>") }
                o.account = args[i + 1]
                i += 1
            case "--json": o.json = true
            case "--refresh": o.refresh = true
            default: return .bad("알 수 없는 옵션: \(args[i])")
            }
            i += 1
        }
        return .ok(o)
    }

    static let usageLine = "사용법: usagebar stats [--days N] [--account <이메일|uuid접두어>] [--json] [--refresh]"

    static func run(_ args: [String], store: AccountStore = .shared,
                    ledger: UsageLedger = .shared, prices: ModelPriceSource = .shared,
                    now: Date = Date()) -> Int32 {
        let options: Options
        switch parse(args) {
        case .ok(let o): options = o
        case .bad(let why):
            print("\(why)\n\(usageLine)")
            return 1
        }
        let accounts = store.loadAccounts()

        var accountFilter: UUID?
        if let key = options.account?.lowercased() {
            let matches = accounts.filter {
                $0.isClaudeToken && ($0.email.lowercased() == key || $0.id.uuidString.lowercased().hasPrefix(key))
            }
            guard matches.count == 1 else {
                print(matches.isEmpty ? "일치하는 Claude 1년 토큰 계정 없음: \(options.account!)"
                      : "대상이 모호함 (\(matches.count)개 일치)")
                return 1
            }
            accountFilter = matches[0].id
        }

        if options.refresh {
            do {
                let r = try ledger.ingest(hashes: tokenHashes(accounts, store: store))
                let line = "집계: 새 응답 \(r.counted)건 · 중복 \(r.duplicates)건 · 계정 미상 \(r.unattributed)건 (파일 \(r.filesRead)개 읽음)\n"
                FileHandle.standardError.write(Data(line.utf8))
            } catch {
                print("집계 실패: \(error.localizedDescription)")
                return 1
            }
        }

        let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = ledger.timeZone
            return c
        }()
        let toDay = ledger.day(now)
        let fromDay = ledger.day(calendar.date(byAdding: .day, value: -(options.days - 1), to: now) ?? now)
        let rows: [LedgerRow]
        do {
            rows = try ledger.rows(fromDay: fromDay, toDay: toDay, account: accountFilter)
        } catch {
            print("장부 읽기 실패: \(error.localizedDescription)")
            return 1
        }
        let (table, origin) = prices.current()
        let report = LedgerReport(rows: rows, table: table)
        let labels = Dictionary(accounts.map { ($0.id, $0.email) }, uniquingKeysWith: { a, _ in a })
        let started = ledger.trackingStartedAt()
        let context = Context(fromDay: fromDay, toDay: toDay, days: options.days, trackingStartedAt: started,
                              timeZone: ledger.timeZone, priceSource: origin.description, labels: labels)
        if options.json {
            print(json(report, context))
        } else {
            print(text(report, context))
        }
        return 0
    }

    static func tokenHashes(_ accounts: [Account], store: AccountStore) -> [String: UUID] {
        var out: [String: UUID] = [:]
        for a in accounts where a.isClaudeToken {
            if let token = store.secrets(for: a.id)?.accessToken, !token.isEmpty {
                out[ClaudeProvider.tokenHash(token)] = a.id
            }
        }
        return out
    }

    struct Context {
        var fromDay: String
        var toDay: String
        var days: Int
        var trackingStartedAt: Date?
        var timeZone: TimeZone
        var priceSource: String
        var labels: [UUID: String]

        func label(_ id: UUID) -> String {
            labels[id] ?? "(등록 해제된 계정 \(id.uuidString.prefix(8)))"
        }
    }

    // MARK: - Text

    static func text(_ report: LedgerReport, _ c: Context) -> String {
        let stamp = DateFormatter()
        stamp.timeZone = c.timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out: [String] = []
        out.append("Claude 사용량 장부 — \(c.fromDay) ~ \(c.toDay) (최근 \(c.days)일, \(c.timeZone.identifier) 날짜)")
        guard let started = c.trackingStartedAt else {
            out.append("아직 추적 기록이 없습니다 — usagebar-claude를 거친 claude 실행부터 집계합니다 (앱이 1분마다 집계, 지금 집계하려면 --refresh).")
            return out.joined(separator: "\n")
        }
        out.append("추적 시작 \(stamp.string(from: started)) · 단가: \(c.priceSource)")
        out.append("금액은 「API 환산 비용」 — 같은 토큰을 API 정가로 계산한 값이며 구독 청구액이 아닙니다.")
        if report.accounts.isEmpty {
            out.append("")
            out.append("이 기간에 집계된 기록이 없습니다 (usagebar-claude를 거친 실행만 집계).")
            return out.joined(separator: "\n")
        }
        let header = [pad("날짜", 10, left: true), pad("입력", 12), pad("출력", 12), pad("캐시쓰기5분", 13),
                      pad("캐시쓰기1시간", 13), pad("캐시읽기", 14), pad("웹검색", 7), pad("응답", 8),
                      pad("API 환산 비용", 16)].joined(separator: " ")
        func line(_ label: String, _ t: LedgerReport.Total) -> String {
            [pad(label, 10, left: true), pad(LedgerFormat.count(t.tokens.input), 12),
             pad(LedgerFormat.count(t.tokens.output), 12), pad(LedgerFormat.count(t.tokens.cacheWrite5m), 13),
             pad(LedgerFormat.count(t.tokens.cacheWrite1h), 13), pad(LedgerFormat.count(t.tokens.cacheRead), 14),
             pad(LedgerFormat.count(t.tokens.webSearches), 7), pad(LedgerFormat.count(t.tokens.messages), 8),
             pad(LedgerFormat.cost(t), 16)].joined(separator: " ")
        }
        for a in report.accounts {
            out.append("")
            out.append("■ \(c.label(a.accountId)) — 토큰 \(LedgerFormat.count(a.total.tokens.totalTokens)) · API 환산 비용 \(LedgerFormat.cost(a.total))")
            out.append("  " + header)
            for d in a.days { out.append("  " + line(d.day, d.total)) }
            if a.days.count > 1 { out.append("  " + line("합계", a.total)) }
            out.append("  모델별")
            for m in a.models {
                let share = m.costShare.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""
                out.append("    \(pad(m.model, 28, left: true)) 토큰 \(pad(LedgerFormat.count(m.total.tokens.totalTokens), 14))  \(LedgerFormat.cost(m.total))\(share)")
            }
        }
        if report.accounts.count > 1 {
            out.append("")
            out.append("전체 — 토큰 \(LedgerFormat.count(report.total.tokens.totalTokens)) · API 환산 비용 \(LedgerFormat.cost(report.total))")
        }
        if !report.total.unpricedModels.isEmpty {
            out.append("")
            out.append("단가 미상 모델 (토큰만 집계, 금액에서 빠짐): \(report.total.unpricedModels.sorted().joined(separator: ", "))")
        }
        return out.joined(separator: "\n")
    }

    /// Pads by display width (CJK = 2 columns).
    static func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
        let w = s.unicodeScalars.reduce(0) { n, u in
            n + ((0x1100...0x115F).contains(u.value) || (0x2E80...0xA4CF).contains(u.value)
                 || (0xAC00...0xD7A3).contains(u.value) || (0xF900...0xFAFF).contains(u.value)
                 || (0xFF00...0xFF60).contains(u.value) ? 2 : 1)
        }
        let fill = String(repeating: " ", count: max(0, width - w))
        return left ? s + fill : fill + s
    }

    // MARK: - JSON

    static func json(_ report: LedgerReport, _ c: Context) -> String {
        func totals(_ t: LedgerReport.Total) -> [String: Any] {
            [
                "inputTokens": t.tokens.input,
                "outputTokens": t.tokens.output,
                "cacheWrite5mTokens": t.tokens.cacheWrite5m,
                "cacheWrite1hTokens": t.tokens.cacheWrite1h,
                "cacheReadTokens": t.tokens.cacheRead,
                "webSearchRequests": t.tokens.webSearches,
                "messages": t.tokens.messages,
                "totalTokens": t.tokens.totalTokens,
                "apiCostUSD": t.cost,
                "costComplete": t.isFullyPriced,
                "unpricedModels": t.unpricedModels.sorted(),
            ]
        }
        func models(_ lines: [LedgerReport.ModelLine]) -> [[String: Any]] {
            lines.map { m in
                var o = totals(m.total)
                o["model"] = m.model
                o["costShare"] = m.costShare ?? NSNull()
                return o
            }
        }
        let iso = ISO8601DateFormatter()
        var obj: [String: Any] = [
            "from": c.fromDay,
            "to": c.toDay,
            "days": c.days,
            "timeZone": c.timeZone.identifier,
            "costLabel": "API 환산 비용",
            "priceSource": c.priceSource,
            "totals": totals(report.total),
        ]
        obj["trackingStartedAt"] = c.trackingStartedAt.map { iso.string(from: $0) } ?? NSNull()
        obj["accounts"] = report.accounts.map { a -> [String: Any] in
            [
                "accountId": a.accountId.uuidString,
                "label": c.label(a.accountId),
                "totals": totals(a.total),
                "models": models(a.models),
                "days": a.days.map { d -> [String: Any] in
                    ["date": d.day, "totals": totals(d.total), "models": models(d.models)]
                },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
