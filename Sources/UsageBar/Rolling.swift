import Foundation

/// Claude 계정 롤링의 판단 규칙 — 부작용 없는 순수 함수 (테스트 대상).
///
/// 롤링 = 활성 계정 파일(`ActiveAccountStore`) 교체. 키체인은 건드리지 않는다.
/// 활성 계정의 지표(max(5h 있으면, 7d))가 임계치(95%)에 닿으면 우선순위 →
/// 등록 순서로 다음 1년 토큰 계정을 고른다.
enum RollingPolicy {
    static let threshold: Double = 95
    static let cooldown: TimeInterval = 10 * 60

    /// 롤링 판단 지표: max(5h, 7d). 서버가 한도 거절(`rejected`)을 알린
    /// 스냅샷은 헤더 수치와 무관하게 100으로 본다.
    static func trip(_ snap: UsageSnapshot?) -> Double? {
        guard let snap else { return nil }
        let values = [snap.fiveHour?.percent, snap.sevenDay?.percent].compactMap { $0 }
        if snap.isLimitRejected { return max(values.max() ?? 100, 100) }
        return values.max()
    }

    /// 지표를 사람이 읽을 형태로 ("7d 96%", "한도 거절" 등).
    static func tripName(_ snap: UsageSnapshot?) -> String {
        guard let snap else { return "?" }
        if snap.isLimitRejected { return "한도 거절" }
        var best: (name: String, pct: Double) = ("?", -1)
        if let p = snap.fiveHour?.percent, p > best.pct { best = ("5h", p) }
        if let p = snap.sevenDay?.percent, p > best.pct { best = ("7d", p) }
        return best.pct < 0 ? "?" : "\(best.name) \(Int(best.pct))%"
    }

    /// 마지막 조회가 정상(오류·지연 없음)이고 지표를 읽을 수 있는 상태.
    static func isHealthy(_ s: AccountState) -> Bool {
        s.lastError == nil && s.staleNote == nil && trip(s.snapshot) != nil
    }

    /// 1년 토큰 계정, 우선순위(낮을수록 우선) → 등록 순서.
    static func ranked(_ states: [AccountState]) -> [AccountState] {
        states.enumerated()
            .filter { $0.element.account.isClaudeToken }
            .sorted { l, r in
                l.element.account.priority != r.element.account.priority
                    ? l.element.account.priority < r.element.account.priority
                    : l.offset < r.offset
            }
            .map(\.element)
    }

    /// 롤링 후보: 활성 계정이 아닌 1년 토큰 계정 중 마지막 조회 정상·지연
    /// 아님·지표 임계 미만. 순서 = `ranked`.
    static func candidates(states: [AccountState], activeId: UUID?) -> [AccountState] {
        ranked(states).filter { s in
            s.account.id != activeId
                && isHealthy(s)
                && (trip(s.snapshot).map { $0 < threshold } ?? false)
        }
    }

    enum Decision: Equatable {
        /// 할 일 없음 — 활성 계정이 임계 미만이거나 아직 판단 불가.
        case idle
        /// 자동 롤링 꺼짐.
        case disabled
        /// 임계 도달했지만 직전 교체 후 쿨다운 중.
        case cooldown
        /// 유효한 활성 계정이 없음 → 이 계정을 활성으로 지정.
        case assign(UUID)
        /// 임계 도달 → 이 계정으로 교체.
        case roll(from: UUID, to: UUID, reason: String)
        /// 임계 도달했지만 후보 없음.
        case exhausted(reason: String)
    }

    /// - Parameters:
    ///   - activeId: 활성 계정 파일의 계정 id (없으면 nil).
    ///   - autoRoll: 설정의 자동 롤링 스위치. 활성 지정(assign)은 이와 무관 —
    ///     래퍼가 쓸 토큰이 있어야 하므로.
    static func decide(
        states: [AccountState], activeId: UUID?, autoRoll: Bool,
        lastRollAt: Date?, now: Date
    ) -> Decision {
        let ranked = ranked(states)
        guard !ranked.isEmpty else { return .idle }

        guard let activeId, let active = ranked.first(where: { $0.account.id == activeId }) else {
            // 활성 지정이 없거나, 지정된 계정이 삭제·레거시가 됨.
            // 건강한 후보 1등, 없으면 정상 조회된 계정 중 1등. 아직 아무
            // 계정도 조회되지 않았으면 다음 주기까지 기다린다.
            let pick = candidates(states: states, activeId: nil).first
                ?? ranked.first(where: isHealthy)
            return pick.map { .assign($0.account.id) } ?? .idle
        }

        guard autoRoll else { return .disabled }
        guard isHealthy(active), let t = trip(active.snapshot), t >= threshold else {
            return .idle  // 지연·오류 값으로는 롤링 판단하지 않음
        }
        if let lastRollAt, now.timeIntervalSince(lastRollAt) < cooldown { return .cooldown }

        let reason = tripName(active.snapshot)
        guard let target = candidates(states: states, activeId: activeId).first else {
            return .exhausted(reason: reason)
        }
        return .roll(from: activeId, to: target.account.id, reason: reason)
    }
}

/// 롤링 실행기 — 활성 계정 파일 교체 + 이력 + 알림 + 웹훅.
@MainActor
enum RollingEngine {
    nonisolated static var threshold: Double { RollingPolicy.threshold }

    /// 같은 프로세스 안의 마지막 교체 시각. roll-history가 쓰기 실패해도
    /// 쿨다운이 지켜지도록 파일 기록과 함께 본다.
    private static var lastRollAt: Date?
    private static var notifiedExhausted = false

    /// Forget in-process state (tests; process-wide statics outlive a test).
    static func resetState() {
        lastRollAt = nil
        notifiedExhausted = false
    }

    /// 알림 경로 (테스트에서 교체). 기본: 네이티브 알림 / 설정된 웹훅.
    static var notify: (_ title: String, _ body: String) -> Void = LocalNotifier.send
    static var broadcast: (_ header: String, _ states: [AccountState]) async -> Void = { header, states in
        if !SettingsStore.shared.load().isEmpty {
            _ = await AlertSender.send(header: header, states: states)
        }
    }

    /// Poller가 매 갱신 주기 끝에 호출. 활성 계정 파일을 바꿨으면 true.
    static func evaluate(
        states: [AccountState], store: AccountStore,
        active: ActiveAccountStore = .shared,
        autoRoll: Bool = SettingsStore.shared.load().autoRoll == true,
        now: Date = Date()
    ) async -> Bool {
        let current = active.read()
        let decision = RollingPolicy.decide(
            states: states, activeId: current?.accountId, autoRoll: autoRoll,
            lastRollAt: [lastRollAt, active.lastRollAt()].compactMap { $0 }.max(),
            now: now)

        switch decision {
        case .idle, .disabled:
            notifiedExhausted = false
            return false
        case .cooldown:
            return false
        case .assign(let id):
            guard let target = states.first(where: { $0.account.id == id })?.account else { return false }
            do {
                try write(target, from: nil, reason: "활성 계정 자동 지정", store: store,
                          active: active, now: now)
                return true
            } catch {
                notify("[!] 활성 계정 지정 실패", error.localizedDescription)
                return false
            }
        case .exhausted(let reason):
            if !notifiedExhausted {
                notifiedExhausted = true
                let header = "[!] 계정 롤링 불가 - 전 계정 한도 임박 (\(reason))"
                notify(header, "등록된 모든 Claude 계정이 \(Int(RollingPolicy.threshold))% 이상입니다.")
                await broadcast(header, states)
            }
            return false
        case .roll(let fromId, let toId, let reason):
            guard let target = states.first(where: { $0.account.id == toId })?.account else { return false }
            let from = states.first(where: { $0.account.id == fromId })?.account
            do {
                try await roll(to: target, from: from, states: states, store: store,
                               active: active, reason: reason, now: now)
                return true
            } catch {
                notify("[!] 계정 롤링 실패", error.localizedDescription)
                return false
            }
        }
    }

    /// 실제 교체 (자동·수동 공통): 활성 계정 파일 원자 교체 → 이력 →
    /// 네이티브 알림 + 웹훅.
    static func roll(
        to target: Account, from: Account?, states: [AccountState], store: AccountStore,
        active: ActiveAccountStore = .shared, reason: String, now: Date = Date()
    ) async throws {
        try write(target, from: from?.id, reason: reason, store: store, active: active, now: now)
        lastRollAt = now
        notifiedExhausted = false

        let header = "[>] 계정 롤링: \(from?.email ?? "?") → \(target.email) (\(reason))"
        notify(header, "다음 claude 실행부터 이 계정의 1년 토큰이 쓰입니다 (usagebar-claude 경유).")
        await broadcast(header, states)
    }

    private static func write(
        _ target: Account, from: UUID?, reason: String, store: AccountStore,
        active: ActiveAccountStore, now: Date
    ) throws {
        guard target.isClaudeToken else { throw UsageBarError.reregistrationRequired }
        guard let token = store.secrets(for: target.id)?.accessToken, !token.isEmpty else {
            throw UsageBarError.invalidCredentials("대상 계정의 저장된 토큰 없음")
        }
        try active.write(accountId: target.id, token: token)
        do {
            try active.appendHistory(.init(ts: now, from: from, to: target.id, reason: reason))
        } catch {
            // 교체 자체는 끝났다 — 이력 실패는 알리되 롤링을 되돌리지 않는다.
            FileHandle.standardError.write(Data("roll-history 기록 실패: \(error.localizedDescription)\n".utf8))
        }
    }
}
