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
1년 토큰 계정. 래퍼 `usagebar-claude`(이 맥의 claude 호출 앞단 — 아래 절)가 이 파일의 토큰을
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
- **즉시 롤링:** 래퍼를 거쳐 실행 중인 claude가 활성 계정의 한도 거절
  (`rate_limit_event`의 `status: rejected`, 또는 한도 문구)을 내면, 앱이 15초 안에
  임계값·10분 쿨다운과 무관하게 다음 후보로 바꾼다. 직전 교체 후 60초 안이면 보류
  (새 계정도 곧바로 거절되는 연쇄 방지). 10분 넘은 이벤트로는 즉시 롤링하지 않는다.
  자동 롤링 스위치가 꺼져 있으면 하지 않는다.
- 교체 시 네이티브 알림 + (설정돼 있으면) 웹훅 알림.
- 파일 교체는 같은 디렉터리 임시 파일(처음부터 0600) + `rename`이라, 읽는 쪽은 항상
  옛 쌍 또는 새 쌍만 본다. 활성 계정을 삭제하면 파일도 지워진다.

## claude 래퍼 (`usagebar-claude`)

이 맥의 모든 claude 호출(OpenClaw·dev-loop·터미널) 앞단에 두는 bash 래퍼
(`scripts/usagebar-claude`, macOS 기본 `/bin/bash` 3.2에서 동작). 호출 경로 전환
(OpenClaw `command`, dev-loop `CLAUDE_BIN`, `~/.zshrc` alias)은 설치와 별개로 직접 한다.

**설치:** `scripts/make-app.sh --install`(자동 업데이트 포함)이 `scripts/install-wrapper.sh`로
래퍼와 관측기용 실행 파일 사본을 **앱 번들 밖 고정 경로**
`~/Library/Application Support/UsageBar/bin/`(0700)에 임시 파일 + `mv`로 원자 교체
설치하고, `/opt/homebrew/bin/usagebar-claude`(없으면 `/usr/local/bin`) 링크를 만든다.
번들은 설치 때 `rm -rf` 후 복사되므로, 번들 안 경로를 부르면 업데이트 순간의
claude 호출이 깨진다 — 래퍼는 관측기를 이 고정 경로로만 부른다.

**동작 (한 번의 실행):**
1. 실제 claude 찾기: `USAGEBAR_CLAUDE_REAL_BIN` → `/opt/homebrew/bin/claude` →
   `~/.claude/local/claude` → PATH. 자기 자신(링크 해석 후)과 `claude-failover`·
   `usagebar-claude`는 건너뛴다. 못 찾으면 stderr 한 줄 + exit 127.
2. 토큰: 호출자가 `CLAUDE_CODE_OAUTH_TOKEN`을 넣었으면 그대로. 아니면 활성 계정 파일의
   토큰을 넣고 `ANTHROPIC_API_KEY`·`ANTHROPIC_AUTH_TOKEN`을 unset. 하위 명령에는 넣지 않는다.
   주입할 때 토큰 해시(비밀 아님)를 `USAGEBAR_CLAUDE_INJECTED_HASH`로 함께 내보낸다. 넣은
   토큰은 claude의 Bash 도구·tmux·dev-loop 같은 자손 프로세스에 상속되므로, 중첩 호출에서
   토큰 해시가 이 표시와 같으면 호출자 토큰이 아니라 상속된 것으로 보고 활성 계정을 다시
   읽는다 — 롤링 뒤 자손 호출도 새 계정으로 간다(활성 파일이 없으면 상속 토큰을 걷고 키체인).
3. 세션 id: `--session-id X`/`=X` → X(arg), `--resume X`/`-r X`/`--resume=X` → X(resume,
   UUID일 때만 — 값 없는 피커·검색어는 null), `--continue`/`-c` → cwd의 Claude 프로젝트
   기록 디렉터리(`~/.claude/projects/<cwd의 영숫자 외 문자를 '-'로>/`)에서 가장 최근
   `*.jsonl`(continue). 아무것도 없고 `--fork-session`·`--from-pr`·`--teleport`·`--cloud`도
   없으면 `--session-id <uuidgen 소문자>`를 인자 **맨 앞에** 주입(injected).
4. 실행 기록 한 줄 → `claude/launches.jsonl`, 그리고 `exec` — claude가 래퍼 PID를 이어받아
   신호·종료 코드가 그대로 전달된다.
   - 대화형(`-p` 없음): 그대로 exec (TTY 유지, stdout 가로채지 않음).
   - `-p`/`--print`(text·json·stream-json): stdout만 관측기 `usagebar observe-claude`를
     거친다. 관측기가 못 뜨거나 죽으면 `cat`이 남은 출력을 넘긴다. stdin·stderr는 그대로.
   - 하위 명령(첫 인자가 `-`로 시작하지 않는 한 단어: `mcp`, `setup-token`, `update`,
     `doctor` …)과 `--version`/`-v`/`--help`/`-h`: 토큰·세션 주입·관측 없이 exec
     (기록은 `mode: subcommand`).

**관측기 (`usagebar observe-claude`):** 받은 바이트를 읽는 즉시 그대로 넘기고(줄 경계·
인코딩 무관, 개행 없는 끝 포함), 넘긴 뒤 줄을 검사한다. stream-json의 `system/init` →
`session`, `rate_limit_event` → `rate_limit`, `result` → `result`(토큰 수치·비용만),
오류 결과나 짧은 텍스트 줄(512바이트 이하)의 한도 문구 → `limit_text`. 파싱·쓰기 실패는
삼키고, stdout이 닫히면(EPIPE) 조용히 끝난다. SIGINT·SIGPIPE는 무시(Ctrl-C는 claude가
처리하고 관측기는 EOF까지 중계). GUI를 띄우지 않는다.

**fail-open:** 활성 계정 파일이 없거나 형식이 틀리거나 읽을 수 없으면 주입 없이(키체인
로그인으로) 실행. 해시·기록·관측기 문제도 claude 실행을 막지 않는다. 예외는 실제 claude를
못 찾은 경우뿐.

**우회:** `USAGEBAR_CLAUDE_BYPASS=1` → 기록·주입·관측 없이 실제 claude로 exec.

**비밀:** 토큰 원문은 기록·출력에 쓰지 않는다. 계정 대조용으로 SHA-256 앞 16자리
(`tokenHash`)만 남기며, 해시 계산 때도 토큰은 파이프(stdin)로만 넘겨 `ps`에 안 보인다.

**시험:** `scripts/test-wrapper.sh` — 가짜 claude로 토큰 주입·세션 id·기록 형식·바이트
동일 통과·종료 코드·stdin·PID 유지·관측기 실패·설치·부가 시간(중앙값 ≤ 100ms, 이 맥
실측 약 20ms)을 확인한다. 실제 claude·토큰·네트워크를 쓰지 않는다. 시험용 env:
`USAGEBAR_CLAUDE_DIR`(데이터 디렉터리), `USAGEBAR_OBSERVER_BIN`, `USAGEBAR_CLAUDE_SEARCH_PATHS`.

## 사용량 장부 (토큰 · API 환산 비용)

계정별로 토큰을 얼마나, 어떤 모델로 썼고 API 정가로 치면 얼마어치인지를 일 단위로 쌓는다.
ccusage(오픈소스)와 같은 원천·단가표·중복 제거 키를 쓴다.

**원천:** Claude Code가 남기는 세션 기록 `~/.claude/projects/<cwd>/<세션 id>.jsonl`과 서브에이전트
기록 `…/<세션 id>/subagents/agent-*.jsonl`(줄의 `sessionId` = 부모 세션). 대화형 터미널 실행도
여기 남으므로 모든 호출 경로를 같은 방식으로 덮는다. 기록 파일은 읽기만 한다(수정·삭제 없음).

- 대상 줄: `type == "assistant"`이고 `message.usage`가 있는 줄. 모델 `<synthetic>`(claude가 API
  호출 없이 남기는 오류 자리표시)은 뺀다.
- **중복 제거:** 한 응답이 콘텐츠 블록마다 같은 usage로 여러 줄 기록되므로 `message.id` +
  `requestId`(둘 중 하나가 없으면 `uuid`)가 같은 줄은 한 번만 센다.
- 토큰 6구분: 입력(`input_tokens`), 출력(`output_tokens`), 캐시 쓰기 5분
  (`cache_creation.ephemeral_5m_input_tokens`), 캐시 쓰기 1시간(`ephemeral_1h_input_tokens`),
  캐시 읽기(`cache_read_input_tokens`), 웹 검색 횟수(`server_tool_use.web_search_requests`).
  `cache_creation` 내역 없이 `cache_creation_input_tokens`만 있으면 5분으로 본다.

**계정 귀속:** 메시지(sessionId, timestamp) → `launches.jsonl`에서 같은 세션의 실행 기록 중
**시작 시각 ≤ 메시지 시각인 가장 늦은 것**의 계정. OpenClaw처럼 같은 세션을 매 턴 새 프로세스로
`--resume`하면, 롤링 뒤의 턴은 새 계정으로 간다(래퍼는 exec라 종료 시각이 없어 시작 시각만 쓴다).
그 실행 기록의 `accountId`가 null이면 `tokenHash`를 등록된 1년 토큰과 대조한다. 실행 기록의
`sessionId`가 null이면(`--fork-session` 등) 관측기의 `session` 이벤트(같은 `launchId`)로
채우고, 래퍼의 추정(`--continue` = 가장 최근 기록 파일)과 claude가 실제로 쓴 세션이 다르면
관측된 쪽을 따른다. 실행 기록이 없거나 계정을 못 정한 메시지(래퍼를 거치지 않은 호출, 키체인
로그인 실행)는 **집계하지 않는다**.

**추적 시작 이후만:** 처음 집계할 때 「`launches.jsonl`의 가장 이른 ts」를 추적 시작 시각으로
정해 장부에 고정한다(실행 기록이 나중에 정리돼도 안 바뀜). 그보다 이른 메시지는 버리고, 마지막
수정 시각이 그보다 이른 기록 파일은 열지도 않는다 — 기존 기록을 백필하지 않는다. 또 90일 넘은
메시지는 받지 않는다(중복 제거 키를 90일 보관하므로 — 실행 기록 보존 기간과 같다).

**증분 집계:** 앱이 1분마다(폴러 틱, 백그라운드 큐) 파일별 (inode, 읽은 바이트 오프셋)부터 새로
붙은 완결 줄만 읽는다. 개행 없는 마지막 줄은 다음 주기로 미룬다. inode가 바뀌었거나 파일이
줄었으면 처음부터 다시 읽되 중복 제거 키로 이중 집계를 막는다. 귀속될 수 없는 줄(실행 기록 없는
세션의 1분 넘은 줄)은 JSON 파싱 없이 건너뛴다. 이 맥 실측: 최근 3일치 기록 1,408개 파일
(439MB) 첫 집계 약 1.5초, 이후 주기 약 0.15초(디버그 빌드).

**API 환산 비용:** 같은 토큰을 Anthropic API 정가로 계산한 값 — 구독 청구액이 아니다(어디서나
이 이름으로 표기). 단가는 [LiteLLM 단가표](https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json)
(ccusage가 쓰는 원본).

- 모델 대조: 정확 일치 → 날짜 접미사 제거(`-20251001` 등) → `anthropic/` 접두.
- 비용 = 입력×`input_cost_per_token` + 출력×`output_cost_per_token` + 5분 캐시×
  `cache_creation_input_token_cost` + 1시간 캐시×`cache_creation_input_token_cost_above_1hr`
  (없으면 5분 단가) + 캐시 읽기×`cache_read_input_token_cost` + 웹 검색×
  `search_context_cost_per_query.search_context_size_medium`(없으면 0). 그 뒤 `usage.speed ==
  "fast"`면 `provider_specific_entry.fast`, `usage.inference_geo == "us"`면
  `provider_specific_entry.us` 배수를 곱한다(항목에 있을 때만).
- **장문 구간 할증:** 항목에 `<기본 필드>_above_<N>k_tokens` 키가 있으면(예: `claude-haiku-5-5`의
  `*_above_100k_tokens`) **요청 하나**의 프롬프트 합(`input_tokens` + `cache_creation_input_tokens`
  (5분+1시간) + `cache_read_input_tokens`)이 기준 N×1000을 **넘을 때**(`>`, 정확히 100,000은 기본)
  그 요청의 **모든 토큰 구분 — 출력까지 — 을 할증 단가**로 계산한다. 기준 초과분만 할증하는
  방식(ccusage)이 아니다. 근거(2026-11-19 실측, claude 2.1.293): haiku-5-5 입력 2 / 출력 4 /
  캐시 읽기 13,049 / 1시간 캐시 329,604(프롬프트 342,655) = 2×5e-7 + 4×2.5e-6 + 13,049×5e-8 +
  329,604×1e-6 = **$0.33026745** = CLI `costUSD`(기본 단가로는 약 $0.07). 62,834 프롬프트 요청은
  기본 단가 그대로 $0.0105774. 기준이 여러 개면 넘은 것 중 가장 큰 기준 하나를 쓰고, 할증 단가가
  빠진 구분은 기본 단가를 쓴다(1시간 캐시는 할증 1시간 → 할증 5분 → 기본 1시간 → 기본 5분).
  fast·us 배수는 할증 단가에 곱한다. `*_batches`(배치 API) 키는 쓰지 않는다.
- **판정 시점:** 장문 여부는 **집계할 때** 그때의 단가표 기준으로 응답마다 판정해 장부에 구간
  (`tier` = 기준 토큰 수, 0 = 기본)으로 따로 저장한다 — 하루치를 합친 뒤에는 어느 요청이 기준을
  넘었는지 알 수 없기 때문이다. 단가표의 기준이 나중에 바뀌어도 **과거 판정은 다시 하지 않는다**
  (단가 금액은 표시 시점의 표를 따른다. 저장된 기준이 표에서 사라졌으면 그 이하의 가장 큰 기준,
  없으면 기본 단가). 단가표에 없던 모델의 응답은 기본 구간으로 저장된다. 자세히 창·`usagebar
  stats`는 구간을 합쳐 보이고, `stats`는 계정마다 장문 응답 수·토큰을 한 줄로, `--json`은
  `longContextTokens`·`longContextMessages`로 따로 준다.
- 검증: haiku-4-5 응답 1건(입력 10 / 출력 891 / 캐시 읽기 17,957 / 1시간 캐시 44,247) =
  $0.0947547 = CLI `modelUsage.claude-haiku-4-5.costUSD`(단위 테스트로 고정).
- 단가를 못 찾은 모델(또는 캐시 단가 없이 캐시 토큰이 있는 경우)은 토큰만 집계하고 「단가 미상」
  으로 표시한다 — $0으로 위장하지 않으며, 합계는 「$X + 단가 미상」이 된다.
- 비용은 장부에 저장하지 않고 **표시할 때** 토큰 × 현재 단가로 계산한다(단가표가 갱신되면 과거
  비용도 같은 표로 다시 계산 — fast/us 응답과 장문 구간 응답은 장부에서 따로 칸을 둬 배수·할증을
  나중에도 적용한다).
- 단가표 원천: 앱이 하루 1회 원격 표를 받아 Claude 항목만 추려 `claude/prices.json`에 캐시한다.
  실패(네트워크·HTTP·파싱·Claude 항목 없음)하면 기존 캐시 → 앱에 컴파일된 번들 사본 순으로 쓰고
  6시간 뒤 다시 시도한다. 번들 사본은 `Sources/UsageBar/BundledPrices.swift`(출처 URL·받은 날짜
  기록) — `swift scripts/update-bundled-prices.swift [litellm.json]`로 다시 만든다.

**조회:** `usagebar stats [--days N] [--account <email>] [--json] [--refresh]` — 일별·계정별·모델별
토큰과 API 환산 비용(기본 최근 7일, 맥 로컬 날짜). GUI 없이 장부 파일만 읽고 네트워크를 쓰지
않는다(단가는 캐시/번들). `--refresh`는 앱과 같은 집계를 1회 실행한다(앱과 동시에 돌아도
SQLite 쓰기 잠금으로 차례로 실행).

## 자세히 창 (계정별 그래프)

팝오버의 Claude 1년 토큰 계정 행 맨 끝에 그래프 아이콘(툴팁 「자세히」)이 항상 보인다(레거시
「재등록 필요」 행·Codex 행에는 없음). 누르면 그 계정의 창 「<라벨> — 사용량」이 앞으로 열린다 —
계정마다 창 하나라서 다시 누르면 기존 창을 앞으로 가져온다. 크기 조절 가능(최소 640×520), 계정을
지우면 창도 닫힌다. 창은 앱이 직접 관리하는 AppKit 창이다(메뉴바 전용 앱이라 SwiftUI 창 장면이
시작 시 저절로 열리는 일을 피하려고).

- **기간:** 7일 / 30일(기본) / 90일 — 모든 그래프·합계가 따른다. 날짜는 맥 로컬 날짜(자정 경계).
- **요약:** 현재 7d 사용률과 리셋까지 남은 시간(5h 한도가 있는 계정은 5h도), 기간 합계 토큰(입력 ·
  출력 · 캐시 쓰기 5분+1시간 · 캐시 읽기 내역), 기간 합계 API 환산 비용, 오늘 토큰·비용, 추적 시작 날짜.
- **7d 사용률 추이:** 사용률 이력(`usage-history.jsonl`) 선 그래프(0~100%), 롤링 임계 95% 점선,
  이 계정이 활성 계정이던 구간을 초록 띠로 표시(`roll-history.jsonl` 기준 — 기록이 다음 기록까지
  그 계정을 활성으로 만든다. 마지막 구간은 활성 파일이 지금도 이 계정일 때만 현재까지 그린다).
- **일별 토큰:** 날짜별 누적 막대(입력 / 출력 / 캐시 쓰기 / 캐시 읽기). 캐시 읽기는 다른 구분보다
  수십 배 큰 경우가 많아 「캐시 읽기 포함」 체크(기본 끔)로 넣고 뺀다. 축은 K/M 축약.
- **일별 API 환산 비용:** 날짜별 막대, 모델별 색 누적. 단가 미상 모델은 금액에서 빠지고 아래에
  따로 표기된다.
- **모델 비중:** 기간 내 모델별 API 환산 비용·비용 비중·토큰·토큰 비중(비용 내림차순, 단가 미상은
  맨 뒤에 「단가 미상」).
- **호버:** 그래프 위에 마우스를 올리면 그 날짜(사용률은 가장 가까운 표본 시각)의 값이 그래프 위
  줄에 보인다.
- **갱신:** 창이 열려 있는 동안 1분마다, 그리고 장부 집계가 새 응답을 더하거나 사용률 조회가 끝날
  때마다 다시 읽는다. 새로고침 버튼은 세션 기록 집계를 바로 1회 실행한 뒤 다시 읽는다.
- **빈 상태:** 이 계정의 장부 기록이 없으면 「<추적 시작 날짜> 이후 이 계정으로 실행된 claude 기록이
  없습니다 — usagebar-claude를 거친 실행만 집계됩니다」, 사용률 표본이 없으면 그 그래프 자리에 안내.

그래프용 데이터 준비(기간 자르기·빈 날짜 0 채우기·누적 구분·캐시 읽기 토글·모델 정렬·비중·단가
미상·활성 구간)는 `DetailData`에 뷰와 분리돼 있고 `swift test`로 검증한다. 픽스처 장부로 창 내용을
PNG로 그려 보려면 `USAGEBAR_DETAIL_SNAPSHOT=/tmp/detail.png swift test --filter testRenderFixtureSnapshot`.

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
| `usagebar stats [--days N] [--account <email>] [--json] [--refresh]` | 사용량 장부 — 일별·계정별·모델별 토큰과 API 환산 비용 |
| `usagebar observe-claude --launch <id> --dir <경로>` | `usagebar-claude` 내부용 stdout 관측기 (직접 쓸 일 없음) |

## 데이터 위치

- `~/Library/Application Support/UsageBar/accounts.json` — 계정 메타 (비밀 없음 — 라벨·종류·우선순위·조직 id)
- `~/Library/Application Support/UsageBar/secrets.json` — 토큰 (chmod 600, `~/.codex/auth.json`과 동일한 보안 수준)
- `~/Library/Application Support/UsageBar/claude/` (0700)
  - `active` (0600) — 1줄 활성 계정 UUID, 2줄 토큰. 활성 계정이 없으면 파일 없음.
  - `roll-history.jsonl` — 교체 이력 `{"v":1,"ts":<ms>,"from":<uuid|null>,"to":<uuid>,"reason":…}` (토큰 없음)
  - `usage-history.jsonl` — 계정별 사용률 표본 `{"v":1,"ts":<ms>,"accountId","sevenDay","fiveHour","status"}`.
    같은 계정의 같은 3분 구간(epoch/180초) 표본은 최신 값 하나로 합치고, 90일 지난 표본은 지운다.
    탐침 결과와 래퍼의 `rate_limit` 이벤트가 모두 표본이 된다.
  - `launches.jsonl` — 래퍼 실행 기록 (실행마다 한 줄, 4096바이트 미만 O_APPEND):
    `{"v":1,"ts":<ms>,"launchId":<uuid>,"accountId":<uuid|null>,"tokenHash":<hex16|null>,"sessionId":<id|null>,"sessionSource":"arg|resume|continue|injected|none","cwd":<경로|null>,"mode":"interactive|print|stream-json|subcommand","pid":<pid>}`
    (cwd가 이스케이프 후 너무 길면 null)
  - `events.jsonl` — 관측기 이벤트 `{"v":1,"ts":<ms>,"launchId","accountId","tokenHash","type",…}`:
    `session`(`sessionId`), `rate_limit`(`status`, `rateLimitType`, `resetsAt`, `overageStatus`,
    `windows: {<창 이름>: {utilization 0~1, resetsAt}}`, `sessionId`), `result`(`sessionId`,
    `subtype`, `isError`, `totalCostUsd`, `modelUsage: {<모델>: {inputTokens, outputTokens,
    cacheReadInputTokens, cacheCreationInputTokens}}`), `limit_text`(`source: text|result`, `match`).
    앱은 `events.cursor`(inode + 바이트 오프셋)로 이어서 읽는다.
  - 보존: `launches`·`events`는 라이브 파일 `X.jsonl` + 보관본 `X.1.jsonl` 두 개로 둔다.
    라이브 파일의 첫 줄이 7일 지나면 앱이 `X.rotating.jsonl`로 rename(다음 append가 새
    라이브 파일을 만든다) → 1초 뒤 보관본에 합치고 지운다. 보관본은 하루 한 번 90일 지난
    줄을 지운다. 전체 기록은 `X.1.jsonl` → `X.rotating.jsonl` → `X.jsonl` 순서로 읽는다.
  - `ledger.sqlite` (0600, WAL) — 사용량 장부. `usage`(계정 × 로컬 날짜 × 모델 × fast/us × 장문 구간별
    토큰 6구분·응답 수, 400일 보존), `seen`(중복 제거 키 `message.id:requestId`, 90일 보존), `files`(세션 기록
    파일별 inode·오프셋), `meta`(`trackingStartedAt`, `schema`). 장문 구간 열이 없는 옛 장부(개발 빌드
    산출물)를 열면 `usage`·`seen`·`files`를 비우고 다음 집계가 세션 기록에서 다시 쌓는다(추적 시작은 유지). 토큰(비밀)·대화 내용·cwd는 저장하지 않는다.
  - `prices.json` — LiteLLM 단가표의 Claude 부분 캐시(하루 1회 갱신)
- `~/Library/Application Support/UsageBar/bin/` (0700) — `usagebar-claude` 래퍼와 관측기
  실행 파일 사본 (`make-app.sh --install`이 갱신)
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

### claude CLI 출력 (래퍼 관측 대상, 같은 날 실측)

- `CLAUDE_CODE_OAUTH_TOKEN=<1년 토큰>`으로 `claude -p`가 정상 동작하고 키체인보다 우선한다(F5).
- `claude -p --output-format stream-json --verbose` stdout(F4): 첫 줄
  `{"type":"system","subtype":"init",…,"session_id":…}`, 응답 뒤
  `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795143600,"rateLimitType":"seven_day","overageStatus":"rejected",…,"unifiedWindows":{"seven_day":{"utilization":0.62,"resetsAt":1795143600}}},"session_id":…}`
  (utilization 0~1), 마지막 `{…,"session_id":…,"total_cost_usd":…,"modelUsage":{"<모델>":{"inputTokens","outputTokens","cacheReadInputTokens","cacheCreationInputTokens",…,"costUSD"}},"is_error":false,…,"type":"result"}`
  — result 줄은 `type`이 맨 앞이 아니다. 컴팩트 JSON(공백 없음).
- `-p`에서 stdin이 TTY가 아니면 claude가 stdin을 기다린다(3초 뒤 경고) — 래퍼는 stdin을
  건드리지 않으므로 호출자가 `< /dev/null` 등으로 정한다.

### Claude Code 세션 기록 (사용량 장부 원천, 같은 날 실측)

- 경로 `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`, 서브에이전트
  `…/<sessionId>/subagents/agent-*.jsonl`(F6). assistant 줄 키: `sessionId`(서브에이전트도 부모 id),
  `timestamp`(ISO8601 UTC, 소수 3자리), `requestId`, `uuid`, `isSidechain`, `cwd`,
  `message.{id, model, usage}`. 비용 필드는 없다.
- 한 응답이 콘텐츠 블록별로 여러 줄 기록되며 같은 `message.id`+`requestId`·같은 usage가 반복된다
  (이 맥 최근 하루치 2,462개 키 중 1,576개가 반복, 반복 간 usage 차이 0건).
- `usage`(F7): `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens`, `cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`,
  `server_tool_use.{web_search_requests, web_fetch_requests}`, `speed`(`standard`/`fast`),
  `inference_geo`(`global`/`us`/`not_available` …), `service_tier`.
- LiteLLM 단가표(F8)에 `claude-opus-5-5`·`claude-fable-5-1`·`claude-sonnet-5`·`claude-sonnet-5-5`·
  `claude-haiku-4-5`(+`-20251001`)·`claude-haiku-5-5`·`claude-opus-4-8` 등이 있고, 필드는 위 비용
  공식의 것들(opus-5-5 `provider_specific_entry` = `{"us":1.1,"fast":2}`). 이 단가로 계산한 값이 CLI
  `modelUsage.<모델>.costUSD`와 일치한다(F9). **정정(2026-11-19):** 처음엔 「장문 구간 할증 필드는
  없다」고 적었으나 이는 opus-5-5·fable-5-1·sonnet-5·haiku-4-5만 본 결과였다 — `claude-haiku-5-5`에는
  `*_above_100k_tokens` 할증 키가 있고(Claude Code가 보조 작업·Explore 서브에이전트에 씀), CLI도
  요청 전체를 할증 단가로 계산한다(위 「장문 구간 할증」, 실측 $0.33026745).

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
