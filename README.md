# SimpleUsageBar

Claude Code / Codex(ChatGPT 구독) 계정들의 5h/7d 사용량을 메뉴바에서 보여주는 macOS 앱.
계정이 이 맥에서 사용 중일 필요 없음 — 3분마다 계정별로 직접 조회한다
(Claude: 1년 토큰으로 1토큰 탐침 요청 → 응답 헤더, Codex: usage API).

```
Claude | example-one@gmail.com  5h [====------] 43%  7d [==--------] 21%
Codex  | example-two@gmail.com  5h [=---------] 12%  7d [===-------] 33%
```

## 빌드 & 실행

```bash
swift build                     # 개발 빌드
swift test                      # 단위 테스트 (Tests/UsageBarTests — 네트워크 없이 녹화 응답 사용)
.build/debug/usagebar           # GUI (메뉴바 아이콘)
scripts/make-app.sh --install   # /Applications/SimpleUsageBar.app 설치
```

요구사항: macOS 14+, Command Line Tools (Xcode 불필요).

## 계정 등록

### Claude — 1년 토큰 (`claude setup-token`)

1. 터미널에서 `claude setup-token`을 실행해 그 계정으로 로그인하면 1년 유효 토큰
   (`sk-ant-oat01-…`)이 나온다.
2. 계정 추가 → Claude → 토큰 붙여넣기 + **라벨(이메일) 직접 입력** — 이 토큰은
   `user:inference` 스코프뿐이라 이메일(profile)을 조회할 수 없다.
3. 저장 전에 탐침 요청으로 검증한다(200 또는 한도 거절 429면 통과). 같은 조직
   (`anthropic-organization-id`)의 토큰이 이미 있으면 경고하고, 한 번 더 눌러야 추가된다.

CLI: `usagebar add-claude-token --label <이메일> < 토큰파일` — 토큰은 **stdin**으로만
받는다(argv는 `ps`에 노출). 같은 조직 중복은 `--allow-duplicate` 없이는 거부.

**예전 OAuth 로그인 / 로컬 Claude Code 계정 행:** 목록에 남지만 조회·롤링에서 빠지고
「1년 토큰으로 재등록 필요」가 표시된다. 그 행의 토큰은 사용자가 행을 지울 때까지
`secrets.json`에 그대로 보존된다(자동 삭제 없음). 앱은 더 이상 키체인
(`Claude Code-credentials`)을 읽거나 쓰지 않는다.

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

## 활성 계정 · 자동 롤링

**활성 계정** = `~/Library/Application Support/UsageBar/claude/active` 파일이 가리키는
1년 토큰 계정. 래퍼 `usagebar-claude`(준비 중 — 이 맥의 claude 호출 앞단)가 이 파일의 토큰을
`CLAUDE_CODE_OAUTH_TOKEN`으로 넣어 claude를 실행한다. 팝오버에서 활성 계정 행에
「사용 중」이 붙는다. 활성 계정이 없고 1년 토큰 계정이 있으면 앱이 우선순위 1등
(임계 미만·정상 조회 계정 우선)을 자동 지정한다.

**롤링 = 이 파일 교체.** 키체인 로그인은 건드리지 않는다. 설정에서 자동 롤링을 켜면
(기본 꺼짐) 활성 계정의 지표 **max(5h 있으면, 7d)가 95% 이상**(또는 서버가 한도 거절
`rejected`를 알림)이 되는 순간 다음 계정으로 바꾼다. 수동 교체는 계정 행에 마우스를
올리면 나오는 **전환 버튼**(두 번 클릭) 또는 `usagebar roll --to <email>`
(`--dry-run` 지원).

- 후보는 활성 아닌 1년 토큰 계정 중 마지막 조회 정상·지연 아님·지표 95% 미만,
  **우선순위 → 등록 순서**. 우선순위는 계정별(기본 1, 낮을수록 우선) — 계정 행 호버 →
  `P1` 메뉴, 또는 `usagebar priority <email> <1-9>`.
- 전부 한도 임박이면 교체하지 않고 알림 1회. 교체 간 최소 10분 쿨다운
  (`roll-history.jsonl` 기준 — 앱 재시작·CLI 교체 뒤에도 유지).
- 교체 시 네이티브 알림 + (설정돼 있으면) 웹훅 알림.
- 파일 교체는 같은 디렉터리 임시 파일(처음부터 0600) + `rename`이라, 읽는 쪽은 항상
  옛 쌍 또는 새 쌍만 본다. 활성 계정을 삭제하면 파일도 지워진다.

## CLI

`make-app.sh --install`(자동 업데이트 포함)이 `/opt/homebrew/bin/usagebar` 링크를
만들어, 터미널 어디서든 `usagebar <명령>`으로 쓸 수 있다. GUI와 같은 바이너리라
데이터도 완전히 같다. 인자 없이 터미널에서 실행하면 도움말이 나온다.

| 명령 | 설명 |
|---|---|
| `usagebar check` | 모든 계정 사용량을 stdout으로 (GUI 없이 파이프라인 검증) |
| `usagebar list` | 등록된 계정 목록 |
| `usagebar add-claude-token --label <email>` | Claude 1년 토큰 계정 추가 (토큰은 stdin) |
| `usagebar add-codex <auth.json \| ->` | Codex 계정 추가 |
| `usagebar remove <uuid-prefix>` | 계정 제거 |
| `usagebar roll [--to <email>] [--dry-run]` | 활성 Claude 계정(활성 계정 파일) 교체 |
| `usagebar priority <email\|uuid> <1-9>` | 롤링 우선순위 |

## 데이터 위치

- `~/Library/Application Support/UsageBar/accounts.json` — 계정 메타 (비밀 없음 — 라벨·종류·우선순위·조직 id)
- `~/Library/Application Support/UsageBar/secrets.json` — 토큰 (chmod 600, `~/.codex/auth.json`과 동일한 보안 수준)
- `~/Library/Application Support/UsageBar/claude/` (0700)
  - `active` (0600) — 1줄 활성 계정 UUID, 2줄 토큰. 활성 계정이 없으면 파일 없음.
  - `roll-history.jsonl` — 교체 이력 `{"v":1,"ts":<ms>,"from":<uuid|null>,"to":<uuid>,"reason":…}` (토큰 없음)
  - `usage-history.jsonl` — 계정별 사용률 표본 `{"v":1,"ts":<ms>,"accountId","sevenDay","fiveHour","status"}`.
    같은 계정의 같은 3분 구간(epoch/180초) 표본은 최신 값 하나로 합치고, 90일 지난 표본은 지운다.
- 폴링: 계정별 독립 스케줄 — 사용량과 무관하게 평탄한 3분 주기.
  오버라이드: `pollIntervalSeconds`(기본 180, 최소 30) defaults 키

## API 레퍼런스 (실측 기준)

### Claude — 1년 토큰 탐침 (2026-11-19 본 머신, claude 2.1.293 실측)

```
POST https://api.anthropic.com/v1/messages
Authorization: Bearer sk-ant-oat01-…        (claude setup-token, 스코프 user:inference)
anthropic-version: 2023-06-01
anthropic-beta: oauth-2025-04-20
content-type: application/json

{"model":"claude-haiku-4-5","max_tokens":1,"system":"You are Claude Code, Anthropic's official CLI for Claude.","messages":[{"role":"user","content":"."}]}
```

- 응답 헤더(F1): `anthropic-ratelimit-unified-7d-utilization`(0~1 실수 → ×100),
  `-7d-reset`(epoch 초), `-7d-status`·`-status`(`allowed`/`allowed_warning`/`rejected`),
  `-reset`, `-representative-claim`(예: `seven_day`), `-overage-status`,
  `anthropic-organization-id`. **Ultra 플랜은 5h 헤더가 없다** — 있으면
  `-5h-utilization`/`-5h-reset`으로 5h 창을 채우고, 없으면 5h 게이지를 숨긴다.
  헤더 이름은 대소문자 무시.
- 429 + `-status: rejected` → 한도 도달 상태로 정상 스냅샷(롤링 지표 100 취급).
  ratelimit 헤더 없는 429 → 일반 레이트리밋(이전 값 유지 + 「429로 인해 지연됨」,
  `Retry-After` 존중). 401/403 → 「토큰 무효 또는 폐기됨 — 재발급 필요」.
- haiku 외 모델(F2)은 system 프롬프트가 위 Claude Code 문구일 때만 200, 아니면
  ratelimit 헤더 없는 429. haiku는 system 없이도 200이지만 계약을 하나로 두려고 항상 보낸다.
- `count_tokens`(F3)는 200이지만 ratelimit 헤더가 없어 사용률 조회에 못 쓴다.
- `/api/oauth/usage`·`/api/oauth/profile`은 이 토큰으로 403(`oauth_scope_insufficient`)
  — 그래서 이메일은 사용자가 입력한다.

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
