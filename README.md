# SimpleUsageBar

Claude Code / Codex(ChatGPT 구독) 계정들의 5h/7d 사용량을 메뉴바에서 보여주는 macOS 앱.
계정이 이 맥에서 사용 중일 필요 없음 — 3분마다 각 프로바이더의 usage API를 직접 폴링한다.

```
Claude | example-one@gmail.com  5h [====------] 43%  7d [==--------] 21%
Codex  | example-two@gmail.com  5h [=---------] 12%  7d [===-------] 33%
```

## 빌드 & 실행

```bash
swift build                     # 개발 빌드
.build/debug/usagebar           # GUI (메뉴바 아이콘)
scripts/make-app.sh --install   # /Applications/SimpleUsageBar.app 설치
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
Claude Code에서 다른 계정으로 로그인을 바꾸면 다음 폴링에서 라벨(이메일)이 자동으로
따라온다 — 토큰이 바뀐 폴링에서만 프로필을 재조회하고, 교체 시점에는 알럿 기준선을
리셋해 계정 전환이 임계 돌파 알럿으로 오인되지 않는다.

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

## Claude 계정 자동 롤링

설정에서 켤 수 있다 (기본 꺼짐). 켜면 로컬 Claude Code 계정의 5h/7d/모델 주간 중
하나가 **95% 이상**이 되는 순간, 등록된 다음 Claude 계정으로 **키체인 로그인 자체를
교체**한다 — claude CLI를 쓰는 모든 도구가 다음 계정으로 이어서 동작한다.
수동 교체는 팝오버에서 계정 행에 마우스를 올리면 나오는 **전환 버튼**(실수 방지를
위해 두 번 클릭) 또는 `usagebar roll --to <email>` (`--dry-run` 지원).

동작 규칙:

- 후보는 **우선순위 → 등록 순서**로 고른다. 우선순위는 계정별 설정(기본 1,
  낮을수록 우선)이며 지표 95% 미만·리프레시 토큰 보유 계정만 후보가 된다.
  전부 한도 임박이면 교체하지 않고 알림만 보낸다. 교체 간 최소 10분 쿨다운.
  우선순위 변경: 팝오버에서 계정 행 호버 → `P1` 메뉴, 또는
  `usagebar priority <email> <1-9>`.
- **계보 보존 프로토콜:** 교체 전에 현 활성 계정의 키체인 아이템을 통째로 앱에
  회수(등록 안 된 계정이면 행 자동 생성)한 뒤에만 다음 계정을 쓴다. 대상 계정은
  교체 직전 한 번 리프레시해 유효한 액세스 토큰을 넘기므로, 교체 직후 claude를
  실행하지 않아도 모니터링이 끊기지 않는다. 활성 계정과 중복되는 저장 행은
  섀도 처리(비표시·비폴링)되어 Claude Code와 토큰 갱신이 경합하지 않는다.
- 교체 시 네이티브 알림 + (설정돼 있으면) 웹훅 알림이 나간다.
- 구버전(스코프 3종)으로 등록한 계정으로 교체하면 claude 핵심 기능(추론)은
  동작하나 일부 기능(세션 동기화·MCP·파일 업로드) 스코프가 없다 — OAuth로
  재등록하면 Claude Code와 동일한 5종 스코프로 발급된다.
- `~/.claude.json`의 표시용 계정 정보는 건드리지 않는다 — `/status` 표기가
  다음 로그인까지 이전 계정으로 보일 수 있으나 실제 API 신원은 키체인 토큰을
  따른다 (2026-07-24 왕복 실측: 교체 후 `claude -p` 정상 동작).

## CLI

| 명령 | 설명 |
|---|---|
| `usagebar check` | 모든 계정 사용량을 stdout으로 (GUI 없이 파이프라인 검증) |
| `usagebar list` | 등록된 계정 목록 |
| `usagebar add-claude [--from-local-cli]` | Claude 계정 추가 |
| `usagebar add-codex <auth.json \| ->` | Codex 계정 추가 |
| `usagebar remove <uuid-prefix>` | 계정 제거 |
| `usagebar roll [--to <email>] [--dry-run]` | Claude Code 키체인 로그인 교체 |

## 데이터 위치

- `~/Library/Application Support/UsageBar/accounts.json` — 계정 메타 (비밀 없음)
- `~/Library/Application Support/UsageBar/secrets.json` — 토큰 (chmod 600, `~/.codex/auth.json`과 동일한 보안 수준)
- 폴링: 계정별 독립 스케줄 — 사용량과 무관하게 평탄한 3분 주기.
  오버라이드: `pollIntervalSeconds`(기본 180) defaults 키

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
