import Foundation

/// 키체인 로그인 교체 1건. from·to는 계정 키(이메일 소문자, `AccountKey`).
struct RollRecord: Equatable {
    var ts: Date
    /// 교체 전 활성 계정. 특정 못 했으면 nil.
    var from: String?
    var to: String
    var reason: String

    /// `{"from":…|null,"reason":…,"to":…,"ts":<ms>,"v":1}` — 토큰은 절대 넣지 않는다.
    func jsonLine() -> Data {
        var obj: [String: Any] = ["v": 1, "ts": JSONLines.epochMs(ts), "to": to, "reason": reason]
        obj["from"] = from ?? NSNull()
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    init(ts: Date, from: String?, to: String, reason: String) {
        self.ts = ts
        self.from = from
        self.to = to
        self.reason = reason
    }

    init?(json obj: [String: Any]) {
        guard let ts = JSONLines.timestamp(obj),
              let to = AccountKey.normalize(obj["to"] as? String) else { return nil }
        self.init(ts: ts, from: AccountKey.normalize(obj["from"] as? String),
                  to: to, reason: obj["reason"] as? String ?? "")
    }
}

/// 키체인 교체 기록(`claude/roll-history.jsonl`, 0600·디렉터리 0700, 400일 보존).
///
/// `RollingEngine.roll`이 교체를 확정한 뒤(키체인 재검증 통과) 1줄 추가한다 —
/// 자동 롤링·팝오버 전환·`usagebar roll` 모두 그 함수를 거친다. GUI와 CLI가
/// 함께 쓸 수 있어 추가는 O_APPEND 한 번, 보존 정리는 만료 줄이 있을 때만
/// 재작성한다(교체는 드물어 파일이 작다).
final class RollHistoryStore: @unchecked Sendable {
    static let shared = RollHistoryStore()

    static let retention: TimeInterval = 400 * 86_400

    let url: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.daybreak.usagebar.roll-history")

    init(directory: URL = AppPaths.claudeDirectory, now: @escaping () -> Date = Date.init) {
        self.url = directory.appendingPathComponent("roll-history.jsonl")
        self.now = now
    }

    /// 교체 1건 기록. 대상 이메일을 정하지 못하면 기록하지 않는다.
    /// 실패는 로그만 남긴다 — 이미 끝난 교체를 되돌리거나 실패로 보고하지 않는다.
    func record(from: String?, to: String, reason: String, at ts: Date? = nil) {
        guard let toKey = AccountKey.normalize(to) else {
            JSONLines.log("교체 기록 생략: 대상 계정 이메일 미상")
            return
        }
        let record = RollRecord(ts: ts ?? now(), from: AccountKey.normalize(from),
                                to: toKey, reason: reason)
        queue.sync {
            do {
                try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent())
                try JSONLines.append(record.jsonLine(), to: url)
                pruneLocked()
            } catch {
                JSONLines.log("교체 기록 실패: \(error.localizedDescription)")
            }
        }
    }

    /// [from, to] 구간(양끝 포함)의 교체 기록, 오래된 것부터. `key`를 주면 그
    /// 계정이 교체 전(from) 또는 후(to)인 기록만.
    func records(key: String? = nil, from: Date? = nil, to: Date? = nil) -> [RollRecord] {
        let account = key.flatMap(AccountKey.normalize)
        if key != nil, account == nil { return [] }
        return queue.sync {
            let lower = max(from ?? .distantPast, now().addingTimeInterval(-Self.retention))
            let upper = to ?? .distantFuture
            return loadLocked().filter {
                $0.ts >= lower && $0.ts <= upper
                    && (account == nil || $0.to == account || $0.from == account)
            }
        }
    }

    // MARK: - Plumbing (queue에서만 호출)

    private func loadLocked() -> [RollRecord] {
        JSONLines.objects(at: url).compactMap(RollRecord.init(json:)).sorted { $0.ts < $1.ts }
    }

    /// 보존 기간이 지난 줄이 있으면 남길 줄만으로 원자적 재작성(손상 줄도 정리).
    private func pruneLocked() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let all = loadLocked()
        guard all.contains(where: { $0.ts < cutoff }) else { return }
        var data = Data()
        for r in all where r.ts >= cutoff { data.append(r.jsonLine()) }
        do {
            try JSONLines.rewrite(data, to: url)
        } catch {
            JSONLines.log("교체 기록 정리 실패: \(error.localizedDescription)")
        }
    }
}
