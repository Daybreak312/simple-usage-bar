# UsageBar

Claude Code / Codex(ChatGPT 구독) 계정들의 5h/7d 사용량을 메뉴바에서 보여주는 macOS 앱.
계정이 이 맥에서 사용 중일 필요 없음 — 10분마다 각 프로바이더의 usage API를 직접 폴링한다.

```
Claude | example-one@gmail.com  5h [====------] 43%  7d [==--------] 21%
Codex  | example-two@gmail.com  5h [=---------] 12%  7d [===-------] 33%
```

## 빌드 & 실행

```bash
swift build                     # 개발 빌드
.build/debug/usagebar           # GUI (메뉴바 아이콘)
scripts/make-app.sh --install   # /Applications/UsageBar.app 설치
```

요구사항: macOS 14+, Command Line Tools (Xcode 불필요).

## 계정 등록

### Claude — 앱 내장 OAuth 로그인

> ⚠️ `claude setup-token` 토큰은 **사용 불가** — usage/profile 엔드포인트가
> `user:profile` 스코프를 요구하는데 setup-token엔 없음 (403, 2026-07-10 실측).
> 그래서 앱이 Claude Code와 동일한 OAuth PKCE 플로우를 내장한다.

1. 계정 추가 → Claude → "OAuth 로그인" → **브라우저에서 로그인 열기**
   (다른 계정은 **URL 복사** 후 시크릿 창에 붙여넣어 그 계정으로 로그인)
2. 승인하면 화면에 코드(`code#state`)가 뜸 → 앱에 붙여넣고 추가

액세스 토큰 만료 시 리프레시 토큰으로 자동 갱신 (회전 가정, 즉시 재저장).

이 맥에 로그인된 Claude Code 계정은 "토큰 직접 입력" 탭의 "로컬 Claude Code 계정
자동 감지"로 등록 가능 (Keychain 읽기 전용 참조, 갱신은 Claude Code에 위임).

CLI: `usagebar add-claude --oauth` / `usagebar add-claude --from-local-cli`

### Codex

그 계정으로 로그인된 `~/.codex/auth.json` 내용을 붙여넣기 (또는 `usagebar add-codex <경로>`).

**⚠️ 토큰 계보 주의:** OpenAI 리프레시 토큰은 1회용 회전식이다. auth.json을 복사해오면
이 앱이 그 로그인 세션을 **가져가며**, 원본 머신의 codex CLI는 다음 갱신 때 죽는다
(`refresh_token_reused`). 원본 머신에서 codex를 계속 쓸 거면 전용 세션을 새로 만들 것:

```bash
CODEX_HOME=/tmp/cx codex login   # 새 로그인 세션 (기존 세션과 독립)
usagebar add-codex /tmp/cx/auth.json
rm -rf /tmp/cx
```

## CLI

| 명령 | 설명 |
|---|---|
| `usagebar check` | 모든 계정 사용량을 stdout으로 (GUI 없이 파이프라인 검증) |
| `usagebar list` | 등록된 계정 목록 |
| `usagebar add-claude [--from-local-cli]` | Claude 계정 추가 |
| `usagebar add-codex <auth.json \| ->` | Codex 계정 추가 |
| `usagebar remove <uuid-prefix>` | 계정 제거 |

## 데이터 위치

- `~/Library/Application Support/UsageBar/accounts.json` — 계정 메타 (비밀 없음)
- `~/Library/Application Support/UsageBar/secrets.json` — 토큰 (chmod 600, `~/.codex/auth.json`과 동일한 보안 수준)
- 폴링 주기: `defaults write dev.daybreak.usagebar pollIntervalSeconds 300` (기본 600초)

Keychain 마이그레이션은 서명된 .app 배포 시점에 예정 (ad-hoc 빌드는 서명이 매번 바뀌어
Keychain ACL 프롬프트가 빌드마다 뜨기 때문에 v0.1은 파일 저장 채택).

## API 레퍼런스 (실측 기준)

### Claude — 2026-07-10 본 머신에서 검증

```
GET https://api.anthropic.com/api/oauth/usage
GET https://api.anthropic.com/api/oauth/profile
Authorization: Bearer sk-ant-oat01-…
anthropic-beta: oauth-2025-04-20
```

usage 응답: `five_hour`/`seven_day` `{utilization: 0-100, resets_at: ISO8601}`,
`limits[]`에 모델 스코프 주간 한도 (`kind: weekly_scoped`, `scope.model.display_name`).
profile 응답: `account.email`. **usage/profile 모두 `user:profile` 스코프 필수**
(setup-token 토큰은 `user:inference`뿐이라 403 — 실측 확인).

OAuth: authorize `https://claude.ai/oauth/authorize` (PKCE S256, client_id는
Claude Code 공용), token `https://console.anthropic.com/v1/oauth/token`
(authorization_code / refresh_token grant). 코드는 `code#state`로 붙여넣기 방식.

### Codex — 스펙은 codex-rs 소스 기준, 토큰 만료로 라이브 검증 대기

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
User-Agent: codex-cli
```

응답: `rate_limit.primary_window`(5h)/`secondary_window`(7d)
`{used_percent, reset_at: epoch, limit_window_seconds}`, `plan_type`, `credits`.

리프레시: `POST https://auth.openai.com/oauth/token`
`{client_id: "app_EMoamEEZ73f0CkXaXp7hrann", grant_type: "refresh_token", refresh_token, scope: "openid profile email"}`
→ 새 access/refresh/id 토큰 (회전식 — 즉시 저장 필수, 앱이 자동 처리).
