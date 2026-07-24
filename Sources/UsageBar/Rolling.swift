import Foundation

/// Claude 계정 자동 롤링 — 로컬 Claude Code 로그인의 한도(5h/7d/모델 주간)가
/// 임계치(95%)에 닿으면 등록된 다음 Claude 계정으로 키체인 자격증명을 교체한다.
///
/// 토큰 계보 소유권 프로토콜 (refresh_token_reused 사고 방지):
/// - 활성 계정의 계보는 키체인(Claude Code)이 단독 소유한다. 앱은 로컬 행을
///   직접 리프레시하지 않고, 같은 계정의 저장 행은 섀도 처리되어 폴링에서
///   빠진다 (Poller.isShadowed).
/// - 롤아웃: 키체인의 최신 아이템을 통째로 회수(harvest)해 그 계정의 저장
///   행에 보존한 뒤에만 다음 계정을 키체인에 쓴다 — 계보 유실 불가.
/// - 롤인: 대상 계정을 먼저 리프레시해 유효한 액세스 토큰을 확보·검증하고
///   (교체 직후 claude 실행이 없어도 모니터링이 즉시 동작), 키체인에 쓴
///   순간부터 그 계보의 소유권은 Claude Code로 넘어간다.
@MainActor
enum RollingEngine {
    nonisolated static let threshold: Double = 95
    nonisolated static let cooldown: TimeInterval = 10 * 60

    private(set) static var lastRollAt: Date?
    private static var notifiedExhausted = false

    /// 롤링 판단 지표: max(5h, 7d, 모델 주간 최대).
    static func trip(_ snap: UsageSnapshot?) -> Double? {
        guard let snap else { return nil }
        return [snap.fiveHour?.percent, snap.sevenDay?.percent, snap.modelWeeklyMax]
            .compactMap { $0 }.max()
    }

    /// 지표를 사람이 읽을 형태로 ("5h 96%" 등).
    static func tripName(_ snap: UsageSnapshot?) -> String {
        guard let snap else { return "?" }
        var best: (name: String, pct: Double) = ("?", -1)
        if let p = snap.fiveHour?.percent, p > best.pct { best = ("5h", p) }
        if let p = snap.sevenDay?.percent, p > best.pct { best = ("7d", p) }
        if let p = snap.modelWeeklyMax, p > best.pct { best = ("주간", p) }
        return "\(best.name) \(Int(best.pct))%"
    }

    /// Poller가 매 갱신 주기 끝에 호출. 실제로 롤링했으면 true.
    static func evaluate(states: [AccountState], store: AccountStore) async -> Bool {
        guard SettingsStore.shared.load().autoRoll == true else { return false }
        if let last = lastRollAt, Date().timeIntervalSince(last) < cooldown { return false }
        guard let local = states.first(where: {
                  $0.account.provider == .claude && $0.account.kind == .localClaudeCLI
              }),
              local.lastError == nil,
              let t = trip(local.snapshot), t >= threshold else {
            notifiedExhausted = false
            return false
        }

        let activeEmail = local.account.email
        guard let target = candidates(
            states: states, activeEmail: activeEmail, store: store).first else {
            if !notifiedExhausted {
                notifiedExhausted = true
                let header = "[!] 계정 롤링 불가 - 전 계정 한도 임박 (\(tripName(local.snapshot)))"
                LocalNotifier.send(
                    title: header,
                    body: "등록된 모든 Claude 계정이 \(Int(threshold))% 이상입니다.")
                if !SettingsStore.shared.load().isEmpty {
                    _ = await AlertSender.send(header: header, states: states)
                }
            }
            return false
        }

        do {
            try await roll(to: target.account, states: states, store: store,
                           reason: tripName(local.snapshot), from: activeEmail)
            return true
        } catch {
            LocalNotifier.send(title: "[!] 계정 롤링 실패", body: error.localizedDescription)
            return false
        }
    }

    /// 롤링 후보: 등록 순서대로 — 활성 계정 제외, 리프레시 토큰 보유,
    /// 마지막 조회가 정상이며 지표가 임계 미만인 Claude 계정.
    static func candidates(
        states: [AccountState], activeEmail: String, store: AccountStore
    ) -> [AccountState] {
        states.filter { s in
            s.account.provider == .claude
                && s.account.kind == .storedToken
                && s.account.email.caseInsensitiveCompare(activeEmail) != .orderedSame
                && s.lastError == nil
                && (trip(s.snapshot).map { $0 < threshold } ?? false)
                && store.secrets(for: s.account.id)?.refreshToken != nil
        }
    }

    /// 실제 교체. 순서가 곧 안전장치: 회수 → 대상 리프레시·검증 → 키체인
    /// 쓰기 → 읽기 재검증(불일치 시 원복). 키체인은 검증이 끝나기 전엔
    /// 건드리지 않는다.
    static func roll(to target: Account, states: [AccountState], store: AccountStore,
                     reason: String, from activeEmail: String?) async throws {
        // 1) 현 활성 계보 회수. 이메일을 특정 못 하면 계보 보존이 불가능하므로
        //    롤링 자체를 중단한다 (덮어쓰는 순간 그 계정 재로그인 필요해짐).
        let current = try? ClaudeProvider.readLocalCLIItem()
        if let current {
            var email = activeEmail
            if email == nil, let token = current.oauth["accessToken"] as? String {
                email = try? await ClaudeProvider()
                    .resolveLabel(secrets: AccountSecrets(accessToken: token))
            }
            guard let email else {
                throw UsageBarError.invalidCredentials("활성 계정 식별 실패 — 계보 보존이 안 되므로 롤링 중단")
            }
            try harvest(email: email, item: current, store: store)
        }

        // 2) 대상 리프레시(회전 즉시 영속화) + 사용량 엔드포인트로 실검증.
        guard var secrets = store.secrets(for: target.id) else {
            throw UsageBarError.invalidCredentials("대상 계정의 저장된 토큰 없음")
        }
        secrets = try await ClaudeOAuth.refresh(secrets)
        try store.updateSecrets(for: target.id, secrets)
        _ = try await ClaudeProvider().probe(secrets: secrets)

        // 3) 키체인 교체 + 읽기 재검증.
        let item = buildItem(secrets: secrets,
                             template: secrets.claudeKeychainItem,
                             fallbackTemplate: current?.raw)
        try ClaudeProvider.writeLocalCLIItem(raw: item)
        let back = try ClaudeProvider.readLocalCLIItem()
        guard (back.oauth["accessToken"] as? String) == secrets.accessToken else {
            if let current { try? ClaudeProvider.writeLocalCLIItem(raw: current.raw) }
            throw UsageBarError.invalidCredentials("키체인 재확인 불일치 — 이전 상태로 원복함")
        }

        lastRollAt = Date()
        notifiedExhausted = false

        let header = "[>] 계정 롤링: \(activeEmail ?? "?") → \(target.email) (\(reason))"
        LocalNotifier.send(title: header, body: "Claude Code 로그인이 교체되었습니다.")
        if !SettingsStore.shared.load().isEmpty {
            _ = await AlertSender.send(header: header, states: states)
        }
    }

    /// 키체인 아이템을 해당 이메일의 저장 행으로 회수. 행이 없으면 생성 —
    /// 이 자동 생성이 "키체인에만 존재하던 계정"의 계보 유실을 막는다.
    static func harvest(
        email: String, item: (raw: String, oauth: [String: Any]), store: AccountStore
    ) throws {
        let existing = store.loadAccounts().first {
            $0.provider == .claude && $0.kind == .storedToken
                && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }
        var secrets = existing.flatMap { store.secrets(for: $0.id) } ?? AccountSecrets()
        secrets.accessToken = item.oauth["accessToken"] as? String ?? secrets.accessToken
        secrets.refreshToken = item.oauth["refreshToken"] as? String ?? secrets.refreshToken
        if let ms = (item.oauth["expiresAt"] as? NSNumber)?.int64Value {
            secrets.expiresAtMs = ms
        }
        secrets.scopes = item.oauth["scopes"] as? [String] ?? secrets.scopes
        secrets.claudeKeychainItem = item.raw
        if let existing {
            try store.updateSecrets(for: existing.id, secrets)
        } else {
            try store.add(
                Account(provider: .claude, kind: .storedToken, label: email),
                secrets: secrets)
        }
    }

    /// 키체인 아이템 JSON 합성. 회수해둔 원본(template)이 있으면 그 구조에 새
    /// 토큰만 갈아끼우고, 없으면 현재 아이템을 틀로 삼는다. 틀에서 못 채우는
    /// 계정 고유 필드(subscriptionType 등)는 다음 claude 자체 리프레시가
    /// 권위 있는 값으로 교정한다.
    static func buildItem(
        secrets: AccountSecrets, template: String?, fallbackTemplate: String?
    ) -> String {
        var oauth: [String: Any] = [:]
        for t in [template, fallbackTemplate] {
            if let t,
               let json = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
               let o = json["claudeAiOauth"] as? [String: Any] {
                oauth = o
                break
            }
        }
        oauth["accessToken"] = secrets.accessToken ?? ""
        oauth["refreshToken"] = secrets.refreshToken ?? ""
        oauth["expiresAt"] = NSNumber(value: secrets.expiresAtMs ?? 0)
        oauth["scopes"] = secrets.scopes ?? ClaudeOAuth.legacyScopes
        let root = ["claudeAiOauth": oauth]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let raw = String(data: data, encoding: .utf8) else {
            return ""
        }
        return raw
    }
}
