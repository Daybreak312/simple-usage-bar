import Foundation

/// 이력 파일의 계정 키 = 계정 이메일(소문자).
///
/// 로컬 행은 키체인 로그인을 따라 사람이 바뀌므로 행 UUID로 쌓으면 서로 다른
/// 계정이 섞인다. 이메일로 쌓으면 같은 사람의 저장 행·로컬 행이 한 이력이 된다.
enum AccountKey {
    /// 라벨/이메일 → 키. 로컬 표식(" (로컬)")을 떼고 공백 제거·소문자화.
    /// 이메일로 볼 수 없는 값(빈 값, '@' 없음)은 nil — 키를 못 정하면 기록하지 않는다.
    static func normalize(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasSuffix("(로컬)") {
            s = String(s.dropLast("(로컬)".count)).trimmingCharacters(in: .whitespaces)
        }
        s = s.lowercased()
        guard !s.isEmpty, s.contains("@"), !s.contains(where: \.isWhitespace) else { return nil }
        return s
    }
}

/// Claude 계정 사용률 표본 1개. percent 0…100, 없으면 nil.
struct UsageSample: Equatable {
    var key: String
    var ts: Date
    var fiveHour: Double?
    var sevenDay: Double?

    init(key: String, ts: Date, fiveHour: Double?, sevenDay: Double?) {
        self.key = key
        self.ts = ts
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// 폴링 결과 → 표본. 성공한 Claude 조회만 표본이 된다(실패·429로 이전 값을
    /// 유지한 경우, Codex, 이메일 미상은 nil).
    /// 키: 저장 행은 행 이메일, 로컬 행은 그 조회에서 해석된 이메일(`resolvedLabel`)
    /// — 저장된 라벨은 이전 로그인의 것일 수 있어 쓰지 않는다.
    init?(account: Account, result: Result<UsageSnapshot, Error>) {
        guard account.provider == .claude, case .success(let snapshot) = result else { return nil }
        let source = account.kind == .localClaudeCLI ? snapshot.resolvedLabel : account.email
        guard let key = AccountKey.normalize(source) else { return nil }
        self.init(key: key, ts: snapshot.fetchedAt,
                  fiveHour: snapshot.fiveHour?.percent, sevenDay: snapshot.sevenDay?.percent)
    }

    /// `{"fiveHour":…,"key":…,"sevenDay":…,"ts":<ms>,"v":1}`
    func jsonLine() -> Data {
        var obj: [String: Any] = ["v": 1, "ts": JSONLines.epochMs(ts), "key": key]
        obj["fiveHour"] = fiveHour ?? NSNull()
        obj["sevenDay"] = sevenDay ?? NSNull()
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    init?(json obj: [String: Any]) {
        guard let ts = JSONLines.timestamp(obj),
              let key = AccountKey.normalize(obj["key"] as? String) else { return nil }
        self.init(key: key, ts: ts,
                  fiveHour: (obj["fiveHour"] as? NSNumber)?.doubleValue,
                  sevenDay: (obj["sevenDay"] as? NSNumber)?.doubleValue)
    }
}

/// 계정(이메일)별 사용률 이력 — 계정 사용률 그래프의 원천.
///
/// 규칙:
/// - **3분 병합:** 같은 키의 같은 3분 버킷(epoch / 180초) 표본은 최신 것 하나로
///   합친다. 고정 버킷이라 도착 순서와 무관하고 3분당 최대 1점이다.
/// - **400일 보존:** 그보다 오래된 표본은 조회에서 빠지고 정리 때 지워진다.
///
/// 저장은 추가 전용(`claude/usage-history.jsonl`, 0600·디렉터리 0700). 중복은
/// 메모리에서 병합하고, 로드 시·원시 줄이 충분히 쌓였을 때·하루 1회 보존 점검에서
/// 지울 것이 있을 때 파일을 원자적으로 재작성한다. 단일 기록자: GUI 앱의 폴러.
/// 손상 줄은 무시하고 다음 재작성 때 정리된다.
///
/// 기록은 전용 직렬 큐에서 비동기로 처리돼 호출자(메인 스레드)를 막지 않는다.
/// 조회는 같은 큐에서 동기 — 앞서 넣은 기록이 반영된 뒤의 값을 돌려준다.
final class UsageHistoryStore: @unchecked Sendable {
    static let shared = UsageHistoryStore()

    static let mergeWindow: TimeInterval = 180
    static let retention: TimeInterval = 400 * 86_400
    /// 병합 후 표본 수를 넘는 원시 줄이 이만큼 쌓이면 재작성.
    static let compactionSlack = 2_000
    /// 보존 기간 점검 주기 (앱이 오래 떠 있어도 오래된 표본이 지워지게).
    static let maintenanceInterval: TimeInterval = 86_400

    let url: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.daybreak.usagebar.usage-history")
    // 아래 상태는 queue에서만 접근한다.
    private var cache: [String: [UsageSample]]?
    private var rawLines = 0
    private var lastMaintenance: Date?

    init(directory: URL = AppPaths.claudeDirectory, now: @escaping () -> Date = Date.init) {
        self.url = directory.appendingPathComponent("usage-history.jsonl")
        self.now = now
    }

    /// 표본 1개 기록(비동기). 실패는 로그만 남긴다 — 폴링을 막지 않는다.
    func record(_ sample: UsageSample) {
        queue.async { self.recordLocked(sample) }
    }

    /// 한 계정의 표본(오래된 것부터), 보존 기간 안 + [from, to] 구간(양끝 포함).
    func samples(key: String, from: Date? = nil, to: Date? = nil) -> [UsageSample] {
        guard let key = AccountKey.normalize(key) else { return [] }
        return queue.sync {
            let lower = max(from ?? .distantPast, retentionCutoff())
            let upper = to ?? .distantFuture
            return (loadLocked()[key] ?? []).filter { $0.ts >= lower && $0.ts <= upper }
        }
    }

    /// 이력이 있는 계정 키 목록(정렬).
    func keys() -> [String] {
        queue.sync {
            let cutoff = retentionCutoff()
            return loadLocked().filter { $0.value.contains { $0.ts >= cutoff } }.keys.sorted()
        }
    }

    /// 병합·보존 기간 내 표본만으로 파일 재작성.
    func compact() {
        queue.sync {
            _ = loadLocked()
            compactLocked()
        }
    }

    // MARK: - Pure rules (tested)

    static func bucket(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / mergeWindow).rounded(.down))
    }

    /// 시간순 시리즈에 표본 1개 병합.
    static func insert(_ sample: UsageSample, into series: inout [UsageSample]) {
        let b = bucket(sample.ts)
        if let last = series.last, last.ts <= sample.ts {
            // 빠른 경로: 순서대로 도착.
            if bucket(last.ts) == b {
                series[series.count - 1] = sample
            } else {
                series.append(sample)
            }
            return
        }
        if let i = series.firstIndex(where: { bucket($0.ts) == b }) {
            if series[i].ts <= sample.ts { series[i] = sample }
            return
        }
        let i = series.firstIndex(where: { $0.ts > sample.ts }) ?? series.count
        series.insert(sample, at: i)
    }

    /// 키별로 묶고 버킷 병합, `cutoff`보다 오래된 표본 제외.
    static func merge(_ samples: [UsageSample], cutoff: Date) -> [String: [UsageSample]] {
        var out: [String: [UsageSample]] = [:]
        for s in samples where s.ts >= cutoff {
            insert(s, into: &out[s.key, default: []])
        }
        return out
    }

    // MARK: - Plumbing (queue에서만 호출)

    private func retentionCutoff() -> Date { now().addingTimeInterval(-Self.retention) }

    private func recordLocked(_ sample: UsageSample) {
        var all = loadLocked()
        guard sample.ts >= retentionCutoff() else { return }
        Self.insert(sample, into: &all[sample.key, default: []])
        cache = all
        do {
            try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
            try JSONLines.append(sample.jsonLine(), to: url)
            rawLines += 1
        } catch {
            JSONLines.log("사용률 이력 기록 실패: \(error.localizedDescription)")
        }
        if rawLines > keptCount(all) + Self.compactionSlack {
            compactLocked()
        } else if let last = lastMaintenance,
                  now().timeIntervalSince(last) >= Self.maintenanceInterval {
            maintainLocked()
        }
    }

    private func keptCount(_ all: [String: [UsageSample]]) -> Int {
        all.values.reduce(0) { $0 + $1.count }
    }

    private func loadLocked() -> [String: [UsageSample]] {
        if let cache { return cache }
        var lineCount = 0
        var raw: [UsageSample] = []
        if let data = try? Data(contentsOf: url) {
            for line in data.split(separator: 0x0A) {
                lineCount += 1
                if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                   let s = UsageSample(json: obj) {
                    raw.append(s)
                }
            }
        }
        let merged = Self.merge(raw, cutoff: retentionCutoff())
        cache = merged
        rawLines = lineCount
        lastMaintenance = now()
        // 중복·만료·손상 줄이 있으면 한 번 정리해 둔다.
        if lineCount != keptCount(merged) { compactLocked() }
        return merged
    }

    /// 보존 기간 점검 — 지울 표본이 있을 때만 재작성.
    private func maintainLocked() {
        lastMaintenance = now()
        let cutoff = retentionCutoff()
        let expired = (cache ?? [:]).values.contains { $0.first.map { $0.ts < cutoff } ?? false }
        if expired { compactLocked() }
    }

    private func compactLocked() {
        let cutoff = retentionCutoff()
        var all = cache ?? [:]
        for (key, series) in all {
            let kept = series.filter { $0.ts >= cutoff }
            all[key] = kept.isEmpty ? nil : kept
        }
        cache = all
        lastMaintenance = now()
        let lines = all.values.flatMap { $0 }.sorted { $0.ts < $1.ts }
        var data = Data()
        for s in lines { data.append(s.jsonLine()) }
        do {
            try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
            try JSONLines.rewrite(data, to: url)
            rawLines = lines.count
        } catch {
            JSONLines.log("사용률 이력 정리 실패: \(error.localizedDescription)")
        }
    }
}
