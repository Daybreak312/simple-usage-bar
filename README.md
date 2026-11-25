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
swift test                      # 단위 테스트
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

`make-app.sh --install`(자동 업데이트 포함)이 `/opt/homebrew/bin/usagebar` 링크를
만들어, 터미널 어디서든 `usagebar <명령>`으로 쓸 수 있다. GUI와 같은 바이너리라
데이터도 완전히 같다. 인자 없이 터미널에서 실행하면 도움말이 나온다.

| 명령 | 설명 |
|---|---|
| `usagebar check` | 모든 계정 사용량을 stdout으로 (GUI 없이 파이프라인 검증) |
| `usagebar list` | 등록된 계정 목록 |
| `usagebar add-claude [--from-local-cli]` | Claude 계정 추가 |
| `usagebar add-codex <auth.json \| ->` | Codex 계정 추가 |
| `usagebar remove <uuid-prefix>` | 계정 제거 |
| `usagebar roll [--to <email>] [--dry-run]` | Claude Code 키체인 로그인 교체 |
| `usagebar stats [--days N] [--json] [--refresh]` | 이 맥 사용량 장부 — 일별·모델별 토큰과 API 환산 비용 ([사용량 장부](#사용량-장부-이-맥-전체-토큰--api-환산-비용)) |

## 데이터 위치

- `~/Library/Application Support/UsageBar/accounts.json` — 계정 메타 (비밀 없음)
- `~/Library/Application Support/UsageBar/secrets.json` — 토큰 (chmod 600, `~/.codex/auth.json`과 동일한 보안 수준)
- `~/Library/Application Support/UsageBar/claude/` (0700) — Claude 관측 기록 (토큰 없음, 파일 0600)
  - `usage-history.jsonl` — 계정 사용률 이력. Claude 계정 조회가 **성공할 때마다**
    `{"v":1,"ts":<ms>,"key":<이메일 소문자>,"fiveHour":<0~100|null>,"sevenDay":<0~100|null>}` 1줄.
    키는 계정 이메일이라 같은 사람의 저장 행·로컬 행이 한 이력으로 합쳐진다(로컬 행은 그
    조회에서 확인된 로그인 이메일, 확인 못 하면 기록하지 않음). 실패·429로 이전 값을 유지한
    조회, 섀도 처리된 행, Codex는 기록하지 않는다. 같은 계정의 3분 버킷 안 표본은 최신 것
    하나로 합치고, 400일 지난 표본은 정리 때 지운다.
  - `roll-history.jsonl` — 키체인 로그인 교체 기록. 교체가 확정(키체인 재검증 통과)된
    뒤에만 `{"v":1,"ts":<ms>,"from":<이메일|null>,"to":<이메일>,"reason":…}` 1줄.
    자동 롤링·팝오버 전환·`usagebar roll` 모두 기록되고 `--dry-run`·실패·원복은 기록되지 않는다. 400일 보존.
  - `ledger.sqlite` — 이 맥 사용량 장부(SQLite WAL): 로컬 날짜×모델별 토큰 합계, 집계 시작 시각,
    세션 기록 파일별 읽은 위치, 중복 제거 키. 400일 보존. 아래 「사용량 장부」 절.
  - `prices.json` — LiteLLM 단가표의 Claude 부분 캐시(하루 1회 갱신).
- 폴링: 계정별 독립 스케줄 — 사용량과 무관하게 평탄한 3분 주기.
  오버라이드: `pollIntervalSeconds`(기본 180) defaults 키

Keychain 마이그레이션은 서명된 .app 배포 시점에 예정 (ad-hoc 빌드는 서명이 매번 바뀌어
Keychain ACL 프롬프트가 빌드마다 뜨기 때문에 v0.1은 파일 저장 채택).

## 사용량 장부 (이 맥 전체 토큰 · API 환산 비용)

이 맥에서 claude로 토큰을 얼마나, 어떤 모델로 썼고 API 정가로 치면 얼마어치인지를 일 단위로
쌓는다. **계정 구분 없이 이 맥 전체 합계**다 — 어느 응답이 어느 계정으로 나갔는지는 세션 기록에
없어서, 정하려 들면 키체인 교체 경계에서 엉뚱한 계정에 붙는다. 계정별로는 서버가 준 사용률
(5h·7d, 위 `usage-history.jsonl`)만 본다. ccusage(오픈소스)와 같은 원천·단가표·중복 제거 키를 쓴다.

**원천:** Claude Code가 남기는 세션 기록 `~/.claude/projects/<cwd>/<세션 id>.jsonl`과 서브에이전트
기록 `…/<세션 id>/subagents/agent-*.jsonl`. 어떤 경로로 실행된 claude든(터미널·OpenClaw·스크립트)
모두 여기 남으므로 전부 센다. 기록 파일은 읽기만 한다(수정·삭제 없음).

- 대상 줄: `type == "assistant"`이고 `message.usage`가 있는 줄. 모델 `<synthetic>`(claude가 API
  호출 없이 남기는 오류 자리표시)은 뺀다.
- **중복 제거:** 한 응답이 콘텐츠 블록마다 같은 usage로 여러 줄 기록되므로 `message.id` +
  `requestId`(둘 중 하나가 없으면 `uuid`)가 같은 줄은 한 번만 센다.
- 토큰 6구분: 입력(`input_tokens`), 출력(`output_tokens`), 캐시 쓰기 5분
  (`cache_creation.ephemeral_5m_input_tokens`), 캐시 쓰기 1시간(`ephemeral_1h_input_tokens`),
  캐시 읽기(`cache_read_input_tokens`), 웹 검색 횟수(`server_tool_use.web_search_requests`).
  `cache_creation` 내역 없이 `cache_creation_input_tokens`만 있으면 5분으로 본다.
- 날짜는 맥 시간대의 로컬 날짜(자정 경계)다.

**집계 시작 이후만:** 장부를 처음 열어 집계한 순간(이 기능이 든 앱이 처음 돈 시각)을 집계 시작
시각으로 장부에 한 번 저장하고 이후 바꾸지 않는다. 그보다 이른 메시지는 버리고, 마지막 수정
시각이 그보다 이른 기록 파일은 열지도 않는다 — **기존 기록은 넣지 않는다**(백필 없음). 집계 시작
때 열려 있던 세션도 그 뒤에 쓴 줄부터 센다. 또 90일 넘은 메시지는 받지 않는다(중복 제거 키를
90일 보관하므로).

**증분 집계:** 앱이 1분마다(폴러 틱, 백그라운드 큐 — 메인 스레드를 막지 않음) 파일별 (inode, 읽은
바이트 오프셋)부터 새로 붙은 완결 줄만 읽는다. 개행 없는 마지막 줄은 다음 주기로 미룬다. inode가
바뀌었거나 파일이 줄었으면 처음부터 다시 읽되 중복 제거 키로 이중 집계를 막는다. 집계 창 밖
시각의 줄은 JSON 파싱 없이 건너뛴다. 한 번의 집계(오프셋·중복 제거 키·합계)는 SQLite 트랜잭션
하나라 도중에 죽어도 누락·이중 집계가 없고, 앱을 다시 켜면 이어서 집계한다.

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
  없으면 기본 단가). 단가표에 없던 모델의 응답은 기본 구간으로 저장된다. `usagebar stats`는
  구간을 합쳐 보이고 장문 응답 수·토큰을 한 줄로, `--json`은 `longContextTokens`·
  `longContextMessages`로 따로 준다.
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

**조회:** `usagebar stats [--days N] [--json] [--refresh]` — 일별·모델별 토큰과 API 환산 비용,
집계 시작 시각(기본 최근 7일, `--days`는 1~400). GUI 없이 장부 파일만 읽고 네트워크를 쓰지
않는다(단가는 캐시/번들). `--refresh`는 앱과 같은 집계를 1회 실행한다(앱과 동시에 돌아도
SQLite 쓰기 잠금으로 차례로 실행). 계정 구분이 없으므로 `--account`는 없다.

## 그래프 창 (계정 사용률 · 이 맥 사용량)

팝오버에서 여는 두 창(macOS 14+ Swift Charts). 메뉴바 앱이라 창은 버튼을 눌렀을 때만 열리고,
같은 버튼을 다시 누르면 열려 있는 창을 앞으로 가져온다. 두 창 모두 기간 7일/30일/90일(기본
30일)을 고르면 그 창의 모든 그래프·합계가 같은 기간을 따르고, 그래프에 마우스를 올리면 그
날짜(시각)의 값이 위에 표시된다. 열려 있는 동안 1분마다 다시 읽고, 오른쪽 위 버튼으로 바로
새로고침한다. 날짜는 이 맥의 로컬 날짜, 금액은 모두 「API 환산 비용」(아래 사용량 장부 절의
정의 — 구독 청구액이 아니다).

**계정 사용률 창** — 팝오버의 Claude 계정 행(OAuth 행·로컬 행) 오른쪽 끝 그래프 아이콘
(「자세히」). Codex 행에는 없다. 계정 이메일마다 창 하나(제목 「<이메일> — 사용률」)이고, 로컬
행은 지금 로그인된 이메일의 창을 연다. 이메일을 아직 모르면(첫 조회 전, 이메일이 아닌 라벨)
아이콘이 흐리게 비활성으로 보인다.
- 요약: 현재 7d·5h 사용률과 리셋까지 남은 시간(값이 있는 것만), 기간 내 7d 최고값.
- 그래프: 7d 사용률 선(0~100%), 5h 기록이 있으면 두 번째 선, 95% 롤링 임계선, `roll-history.jsonl`
  기준 **이 계정으로 교체된 시점**과 **이 계정에서 빠져나간 시점**의 세로 점선, 그 아래 교체 시점
  목록(최근 8건). 교체 기록으로 양끝이 확인되는 활성 구간(이 계정으로 교체 → 이 계정에서 교체,
  또는 지금도 로그인 중)은 옅은 띠로 표시한다 — 사이에 기록 없는 로그인 변경(`claude login` 등)이
  끼어 끝을 알 수 없는 구간은 그리지 않는다.
- 원천은 `usage-history.jsonl`(서버가 준 사용률)뿐이다. **토큰·비용은 계정별로 나누지 않는다** —
  이 맥 사용량 창에서 본다.
- 기록이 없으면 「<기록 시작 날짜> 이후 이 계정의 사용률 기록이 없습니다」(기록 시작 = 이력의
  가장 오래된 표본).

**이 맥 사용량 창** — 팝오버 아래 아이콘 줄의 막대그래프 아이콘(「이 맥 사용량」).
- 요약: 기간 합계 토큰(입력·출력·캐시 쓰기·캐시 읽기 구분), 기간 합계 API 환산 비용, 오늘 토큰·
  비용, 집계 시작 날짜. 「이 맥에서 실행된 claude 전체(계정 구분 없음)」.
- 일별 토큰: 날짜별 누적 막대(입력/출력/캐시 쓰기(5분+1시간)/캐시 읽기). 캐시 읽기는 다른 구분의
  수십 배인 경우가 많아 「캐시 읽기 포함」을 켤 때만 쌓는다. 기록 없는 날은 0.
- 일별 API 환산 비용: 날짜별 막대, 모델별 색 누적. 모델이 8개를 넘으면 비용 하위 모델을 「기타」로
  묶는다. 단가 미상 모델은 금액에서 빠지고 그 사실을 그래프 아래에 표시한다.
- 모델 비중: 기간 내 모델별 API 환산 비용·비용 비중·토큰·토큰 비중(비용 내림차순, 단가 미상은
  맨 뒤에 「단가 미상」).
- 장부에 아무것도 없으면 「<집계 시작 날짜> 이후 기록된 claude 사용량이 없습니다」.
- 새로고침 버튼은 세션 기록 집계를 바로 1회 돌린 뒤 다시 읽는다.

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
