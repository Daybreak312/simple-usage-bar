import Foundation

/// `usagebar stats [--days N] [--json] [--refresh]` — the Mac-wide usage
/// ledger without the GUI. Reads the ledger file only; `--refresh` runs one
/// ingest scan first (same scan the app runs every minute). Prices come from
/// the cached/bundled table — no network.
enum StatsCommand {
    static let defaultDays = 7

    struct Options: Equatable {
        var days = StatsCommand.defaultDays
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
                    return .bad("--days는 1~\(UsageLedger.retentionDays) 사이 정수여야 합니다")
                }
                o.days = n
                i += 1
            case "--json": o.json = true
            case "--refresh": o.refresh = true
            default: return .bad("알 수 없는 옵션: \(args[i])")
            }
            i += 1
        }
        return .ok(o)
    }

    static let usageLine = "사용법: usagebar stats [--days N] [--json] [--refresh]"

    static func run(_ args: [String], ledger: UsageLedger = .shared, prices: ModelPriceSource = .shared,
                    now: Date = Date()) -> Int32 {
        let options: Options
        switch parse(args) {
        case .ok(let o): options = o
        case .bad(let why):
            print("\(why)\n\(usageLine)")
            return 1
        }

        if options.refresh {
            do {
                let r = try ledger.ingest()
                let line = "집계: 새 응답 \(r.counted)건 · 중복 \(r.duplicates)건 (파일 \(r.filesRead)개 읽음)\n"
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
            rows = try ledger.rows(fromDay: fromDay, toDay: toDay)
        } catch {
            print("장부 읽기 실패: \(error.localizedDescription)")
            return 1
        }
        let (table, origin) = prices.current()
        let report = LedgerReport(rows: rows, table: table)
        let context = Context(fromDay: fromDay, toDay: toDay, days: options.days,
                              trackingStartedAt: ledger.trackingStartedAt(),
                              timeZone: ledger.timeZone, priceSource: origin.description)
        print(options.json ? json(report, context) : text(report, context))
        return 0
    }

    struct Context {
        var fromDay: String
        var toDay: String
        var days: Int
        var trackingStartedAt: Date?
        var timeZone: TimeZone
        var priceSource: String
    }

    // MARK: - Text

    static func text(_ report: LedgerReport, _ c: Context) -> String {
        let stamp = DateFormatter()
        stamp.timeZone = c.timeZone
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out: [String] = []
        out.append("Claude 사용량 장부 (이 맥 전체) — \(c.fromDay) ~ \(c.toDay) (최근 \(c.days)일, \(c.timeZone.identifier) 날짜)")
        guard let started = c.trackingStartedAt else {
            out.append("아직 집계 기록이 없습니다 — 장부를 처음 연 시각부터 집계합니다 (앱이 1분마다 집계, 지금 집계하려면 --refresh).")
            return out.joined(separator: "\n")
        }
        out.append("집계 시작 \(stamp.string(from: started)) (이전 기록은 넣지 않음) · 단가: \(c.priceSource)")
        out.append("금액은 「API 환산 비용」 — 같은 토큰을 API 정가로 계산한 값이며 구독 청구액이 아닙니다.")
        if report.days.isEmpty {
            out.append("")
            out.append("이 기간에 집계된 기록이 없습니다.")
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
        out.append("")
        out.append("전체 — 토큰 \(LedgerFormat.count(report.total.tokens.totalTokens)) · API 환산 비용 \(LedgerFormat.cost(report.total))")
        out.append("  " + header)
        for d in report.days { out.append("  " + line(d.day, d.total)) }
        if report.days.count > 1 { out.append("  " + line("합계", report.total)) }
        let long = report.total.longContextTokens
        if long.messages > 0 {
            out.append("  장문 구간(할증 단가) 응답 \(LedgerFormat.count(long.messages))건 · 토큰 \(LedgerFormat.count(long.totalTokens)) — 위 합계에 포함")
        }
        out.append("  모델별")
        for m in report.models {
            let share = m.costShare.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""
            out.append("    \(pad(m.model, 28, left: true)) 토큰 \(pad(LedgerFormat.count(m.total.tokens.totalTokens), 14))  \(LedgerFormat.cost(m.total))\(share)")
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
                "longContextTokens": t.longContextTokens.totalTokens,
                "longContextMessages": t.longContextTokens.messages,
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
            "scope": "mac",
            "from": c.fromDay,
            "to": c.toDay,
            "days": c.days,
            "timeZone": c.timeZone.identifier,
            "costLabel": "API 환산 비용",
            "priceSource": c.priceSource,
            "totals": totals(report.total),
            "models": models(report.models),
            "daily": report.days.map { d -> [String: Any] in
                ["date": d.day, "totals": totals(d.total), "models": models(d.models)]
            },
        ]
        obj["trackingStartedAt"] = c.trackingStartedAt.map { iso.string(from: $0) } ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
