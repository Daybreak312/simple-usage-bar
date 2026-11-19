#!/bin/bash
# usagebar-claude 시험 — 가짜 claude(USAGEBAR_CLAUDE_REAL_BIN)로 래퍼의 모든 동작을 확인한다.
# 실제 claude·토큰·네트워크를 쓰지 않는다. `swift test`와 별개로 실행:
#
#   scripts/test-wrapper.sh            # 관측기는 .build/debug/usagebar (없으면 swift build)
#   USAGEBAR_TEST_OBSERVER=<경로> scripts/test-wrapper.sh
#
# macOS 기본 /bin/bash 3.2로 래퍼를 실행한다 (배포 환경과 같게). JSON 검증은 python3.
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"
WRAPPER="$REPO/scripts/usagebar-claude"

OBSERVER="${USAGEBAR_TEST_OBSERVER:-$REPO/.build/debug/usagebar}"
if [ ! -x "$OBSERVER" ]; then
    swift build >/dev/null || { echo "swift build 실패"; exit 1; }
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/usagebar-wrapper-test.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "${@:2}"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "명령: $*"; fi; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "기대: [$3]" "실제: [$2]"; }
section() { printf '\n[%s]\n' "$1"; }

# ─── 고정 데이터 ───
ACC="0A1B2C3D-0000-4000-8000-00000000000A"
TOKEN="sk-ant-oat01-test-token-AAAA"
CALLER_TOKEN="sk-ant-oat01-caller-token-BBBB"
hash16() { printf '%s' "$1" | /usr/bin/openssl dgst -sha256 | awk '{print substr($NF,1,16)}'; }
TOKEN_HASH="$(hash16 "$TOKEN")"
CALLER_HASH="$(hash16 "$CALLER_TOKEN")"
S1="11111111-2222-4333-8444-555555555555"

FAKE_DIR="$T/fakebin"; mkdir -p "$FAKE_DIR"
FAKE="$FAKE_DIR/claude"
cat > "$FAKE" <<'EOF'
#!/bin/bash
# 가짜 claude: 자기 상태를 $FAKE_REPORT에, 지정 출력을 stdout에.
{
    echo "pid=$$"
    echo "token=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
    echo "apikey=${ANTHROPIC_API_KEY-<unset>}"
    echo "authtoken=${ANTHROPIC_AUTH_TOKEN-<unset>}"
    echo "obsacct=${USAGEBAR_ACCOUNT_ID-<unset>}"
    for a in "$@"; do echo "arg=$a"; done
} > "${FAKE_REPORT:-/dev/null}"
[ -n "${FAKE_STDIN_TO:-}" ] && cat > "$FAKE_STDIN_TO"
[ -n "${FAKE_OUT:-}" ] && cat "$FAKE_OUT"
[ "${FAKE_SELF_KILL:-}" = "1" ] && kill -9 $$
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$FAKE"

DATA="$T/data"            # 래퍼 데이터 디렉터리 (claude/)
HOMEDIR="$T/home"; mkdir -p "$HOMEDIR"
REPORT="$T/report"

write_active() { mkdir -p "$DATA"; printf '%s\n%s\n' "$1" "$2" > "$DATA/active"; chmod 600 "$DATA/active"; }
reset_data() { rm -rf "$DATA"; rm -f "$REPORT"; }

# run_w <래퍼 인자…> — 표준 시험 환경으로 래퍼 실행 (stdout은 파이프로 받아 관측기 종료까지 기다림)
run_w() {
    env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$HOMEDIR" \
        USAGEBAR_CLAUDE_REAL_BIN="$FAKE" USAGEBAR_CLAUDE_DIR="$DATA" \
        USAGEBAR_OBSERVER_BIN="${OBS_OVERRIDE:-$OBSERVER}" FAKE_REPORT="$REPORT" \
        ANTHROPIC_API_KEY="sk-api-should-be-unset" ANTHROPIC_AUTH_TOKEN="auth-should-be-unset" \
        ${EXTRA_ENV:-} /bin/bash "$WRAPPER" "$@" < "${STDIN_FILE:-/dev/null}" | cat
    return "${PIPESTATUS[0]}"
}

rep() { sed -n "s/^$1=//p" "$REPORT" | head -1; }
rep_args() { sed -n 's/^arg=//p' "$REPORT"; }
last_launch() { tail -n 1 "$DATA/launches.jsonl" 2>/dev/null; }
jget() {  # jget <json 한 줄> <키> → 값 (null/없음은 "null")
    printf '%s' "$1" | python3 -I -c '
import json, sys
o = json.loads(sys.stdin.read())
v = o.get(sys.argv[1])
print("null" if v is None else (json.dumps(v) if isinstance(v, (dict, list, bool)) else v))' "$2"
}

# ════════════════════════════════════════════════════════════
section "실제 claude 찾기"
SELF_LINK="$T/links/claude"; mkdir -p "$T/links" "$T/fo"
ln -s "$WRAPPER" "$SELF_LINK"
ln -s "$FAKE" "$T/fo/claude-failover"
out="$(env HOME="$HOMEDIR" USAGEBAR_CLAUDE_DIR="$DATA" FAKE_REPORT="$REPORT" \
    USAGEBAR_CLAUDE_REAL_BIN="$SELF_LINK" USAGEBAR_CLAUDE_SEARCH_PATHS="$T/fo/claude
$FAKE" /bin/bash "$WRAPPER" --version 2>&1)"
eq "자기 자신 링크·claude-failover 건너뛰고 다음 후보 사용" "$(rep pid >/dev/null; [ -f "$REPORT" ] && echo ran)" "ran"
rm -f "$REPORT"
mkdir -p "$T/p1" "$T/p2"; ln -s "$WRAPPER" "$T/p1/claude"; ln -s "$FAKE" "$T/p2/claude"
env HOME="$HOMEDIR" USAGEBAR_CLAUDE_DIR="$DATA" FAKE_REPORT="$REPORT" USAGEBAR_CLAUDE_SEARCH_PATHS="" \
    PATH="$T/p1:$T/p2:/usr/bin:/bin" /bin/bash "$WRAPPER" --version >/dev/null 2>&1
check "PATH 순회에서 자기 자신(링크) 건너뜀" test -f "$REPORT"
err="$(env HOME="$HOMEDIR" USAGEBAR_CLAUDE_DIR="$DATA" USAGEBAR_CLAUDE_SEARCH_PATHS="" PATH="$T/p1:/usr/bin:/bin" \
    /bin/bash "$WRAPPER" -p hi 2>&1 >/dev/null)"; rc=$?
eq "못 찾으면 exit 127" "$rc" "127"
eq "못 찾으면 stderr 한 줄" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "1"

# ════════════════════════════════════════════════════════════
section "우회 (USAGEBAR_CLAUDE_BYPASS=1)"
reset_data; write_active "$ACC" "$TOKEN"
EXTRA_ENV="USAGEBAR_CLAUDE_BYPASS=1" run_w -p hi >/dev/null
eq "우회: 토큰 주입 없음" "$(rep token)" "<unset>"
eq "우회: ANTHROPIC_API_KEY 그대로" "$(rep apikey)" "sk-api-should-be-unset"
eq "우회: 인자 그대로 (세션 주입 없음)" "$(rep_args | tr '\n' ' ')" "-p hi "
check "우회: 실행 기록 없음" test ! -e "$DATA/launches.jsonl"

# ════════════════════════════════════════════════════════════
section "토큰 주입 (fail-open)"
reset_data; write_active "$ACC" "$TOKEN"
run_w -p hi >/dev/null
L="$(last_launch)"
eq "active 토큰 → CLAUDE_CODE_OAUTH_TOKEN" "$(rep token)" "$TOKEN"
eq "주입 시 ANTHROPIC_API_KEY unset" "$(rep apikey)" "<unset>"
eq "주입 시 ANTHROPIC_AUTH_TOKEN unset" "$(rep authtoken)" "<unset>"
eq "기록 accountId = active 계정" "$(jget "$L" accountId)" "$ACC"
eq "기록 tokenHash = SHA-256 앞 16자리" "$(jget "$L" tokenHash)" "$TOKEN_HASH"
check "기록에 토큰 원문 없음" bash -c "! grep -q -- '$TOKEN' '$DATA/launches.jsonl'"
eq "관측기 env는 claude에 새지 않음" "$(rep obsacct)" "<unset>"

reset_data; write_active "$ACC" "$TOKEN"
EXTRA_ENV="CLAUDE_CODE_OAUTH_TOKEN=$CALLER_TOKEN" run_w -p hi >/dev/null
L="$(last_launch)"
eq "호출자 토큰 유지" "$(rep token)" "$CALLER_TOKEN"
eq "호출자 토큰이면 API 키 손대지 않음" "$(rep apikey)" "sk-api-should-be-unset"
eq "호출자 토큰(활성과 다름) → accountId null" "$(jget "$L" accountId)" "null"
eq "호출자 토큰 tokenHash" "$(jget "$L" tokenHash)" "$CALLER_HASH"

reset_data; write_active "$ACC" "$TOKEN"
EXTRA_ENV="CLAUDE_CODE_OAUTH_TOKEN=$TOKEN" run_w -p hi >/dev/null
eq "호출자 토큰 = 활성 토큰 → accountId 기록" "$(jget "$(last_launch)" accountId)" "$ACC"

reset_data
run_w -p hi >/dev/null; rc=$?
L="$(last_launch)"
eq "active 없음: claude 정상 실행" "$rc" "0"
eq "active 없음: 토큰 주입 없음" "$(rep token)" "<unset>"
eq "active 없음: API 키 그대로" "$(rep apikey)" "sk-api-should-be-unset"
eq "active 없음: accountId·tokenHash null" "$(jget "$L" accountId)/$(jget "$L" tokenHash)" "null/null"

for bad_case in "not-a-uuid|$TOKEN" "$ACC|token with space" "$ACC|"; do
    reset_data; write_active "${bad_case%%|*}" "${bad_case#*|}"
    run_w -p hi >/dev/null
    eq "active 형식 오류 [${bad_case}] → 주입 없음" "$(rep token)" "<unset>"
done
reset_data; mkdir -p "$DATA"; printf '%s' "$ACC" > "$DATA/active"
run_w -p hi >/dev/null
eq "active 1줄뿐 → 주입 없음" "$(rep token)" "<unset>"
reset_data; mkdir -p "$DATA"; printf '%s\n%s' "$ACC" "$TOKEN" > "$DATA/active"
run_w -p hi >/dev/null
eq "active 끝 개행 없음 → 주입" "$(rep token)" "$TOKEN"
reset_data; write_active "$ACC" "$TOKEN"; chmod 000 "$DATA/active"
err="$(run_w -p hi 2>&1 >/dev/null)"; rc=$?
eq "active 읽기 불가 → 주입 없이 실행" "$(rep token)/$rc" "<unset>/0"
eq "active 읽기 불가 → stderr 잡음 없음" "$err" ""
chmod 600 "$DATA/active"

# ════════════════════════════════════════════════════════════
section "세션 id 확정"
sess_case() {  # sess_case <이름> <기대 id> <기대 source> <인자…>
    local name="$1" want_id="$2" want_src="$3"; shift 3
    reset_data
    run_w "$@" >/dev/null
    local L; L="$(last_launch)"
    eq "$name: sessionId/source" "$(jget "$L" sessionId)/$(jget "$L" sessionSource)" "$want_id/$want_src"
}
sess_case "--session-id X" "$S1" arg -p --session-id "$S1" hi
eq "--session-id: 인자 그대로 (추가 주입 없음)" "$(rep_args | tr '\n' ' ')" "-p --session-id $S1 hi "
sess_case "--session-id=X" "$S1" arg -p "--session-id=$S1" hi
sess_case "--resume X" "$S1" resume -p --resume "$S1" hi
sess_case "-r X" "$S1" resume -p -r "$S1" hi
sess_case "--resume=X" "$S1" resume "--resume=$S1"
sess_case "--resume (값 없음 = 피커)" null resume --resume
sess_case "-r 검색어" null resume -r "검색어"
sess_case "--resume X --fork-session" null none -p --resume "$S1" --fork-session
eq "--fork-session: 주입 없음" "$(rep_args | grep -c -- --session-id)" "0"

# --continue: cwd의 프로젝트 기록에서 가장 최근 *.jsonl
WORK="$T/work dir/my_proj.v2"; mkdir -p "$WORK"
SLUG="$(printf '%s' "$WORK" | sed 's/[^A-Za-z0-9]/-/g')"
PROJ="$HOMEDIR/.claude/projects/$SLUG"; mkdir -p "$PROJ"
OLD="aaaaaaaa-0000-4000-8000-000000000001"; NEW="bbbbbbbb-0000-4000-8000-000000000002"
touch -t 202601010000 "$PROJ/$OLD.jsonl"; touch -t 202602010000 "$PROJ/$NEW.jsonl"
mkdir -p "$PROJ/$NEW"  # 서브에이전트 디렉터리는 무시돼야 함
(cd "$WORK" && reset_data && run_w -p --continue >/dev/null)
L="$(last_launch)"
eq "--continue: 최근 세션 파일 id" "$(jget "$L" sessionId)/$(jget "$L" sessionSource)" "$NEW/continue"
eq "--continue: cwd 기록" "$(jget "$L" cwd)" "$WORK"
(cd "$T" && reset_data && run_w -c >/dev/null)
L="$(last_launch)"
eq "-c: 프로젝트 기록 없으면 null" "$(jget "$L" sessionId)/$(jget "$L" sessionSource)" "null/continue"

reset_data; run_w -p hi >/dev/null
L="$(last_launch)"; SID="$(jget "$L" sessionId)"
check "주입: 소문자 UUID" bash -c "[[ '$SID' =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$ ]]"
eq "주입: source" "$(jget "$L" sessionSource)" "injected"
eq "주입: --session-id <id>를 맨 앞에" "$(rep_args | tr '\n' ' ')" "--session-id $SID -p hi "
reset_data; run_w "이거 고쳐줘" >/dev/null
L="$(last_launch)"
eq "대화형 프롬프트 인자(공백 포함) → 주입" "$(jget "$L" mode)/$(jget "$L" sessionSource)" "interactive/injected"
reset_data; run_w -p hi -- --literal >/dev/null
eq "-- 이 있어도 주입은 앞쪽" "$(rep_args | head -1)" "--session-id"

# ════════════════════════════════════════════════════════════
section "하위 명령·--version 비주입"
for args in "mcp list" "setup-token" "update" "doctor" "--version" "-v" "--help" "-p --help"; do
    reset_data; write_active "$ACC" "$TOKEN"
    # shellcheck disable=SC2086
    run_w $args >/dev/null
    L="$(last_launch)"
    eq "[$args] 인자 그대로" "$(rep_args | tr '\n' ' ')" "$args "
    eq "[$args] 토큰·세션 주입 없음, mode=subcommand" \
        "$(rep token)/$(jget "$L" sessionSource)/$(jget "$L" mode)" "<unset>/none/subcommand"
done

# ════════════════════════════════════════════════════════════
section "launches.jsonl 형식·이스케이프"
reset_data; write_active "$ACC" "$TOKEN"
NASTY="$T/q\"uo\\te	tab
nl"; mkdir -p "$NASTY"
(cd "$NASTY" && run_w -p --output-format stream-json hi >/dev/null)
L="$(last_launch)"
eq "cwd 이스케이프 왕복(따옴표·역슬래시·탭·개행)" "$(printf '%s' "$L" | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["cwd"] == sys.argv[1])' "$NASTY")" "True"
eq "launches 한 줄 = 한 레코드" "$(wc -l < "$DATA/launches.jsonl" | tr -d ' ')" "1"
eq "키 집합" "$(printf '%s' "$L" | python3 -I -c 'import json,sys; print(",".join(sorted(json.loads(sys.stdin.read()))))')" \
    "accountId,cwd,launchId,mode,pid,sessionId,sessionSource,tokenHash,ts,v"
eq "mode=stream-json" "$(jget "$L" mode)" "stream-json"
check "ts = epoch ms" bash -c "[[ '$(jget "$L" ts)' =~ ^1[0-9]{12}\$ ]]"
check "launchId UUID" bash -c "[[ '$(jget "$L" launchId)' =~ ^[0-9a-f-]{36}\$ ]]"
eq "파일 권한 0600" "$(stat -f '%Lp' "$DATA/launches.jsonl")" "600"
eq "디렉터리 권한 0700" "$(stat -f '%Lp' "$DATA")" "700"
reset_data; run_w -p hi >/dev/null
eq "mode=print" "$(jget "$(last_launch)" mode)" "print"
reset_data; run_w --model opus "hi there" >/dev/null
eq "mode=interactive" "$(jget "$(last_launch)" mode)" "interactive"

# 4096바이트 상한: 제어문자로 된 긴 경로(이스케이프 후 6배) → cwd null
C250="$(printf '\001%.0s' $(seq 1 250))"
LONG="$T/$C250/$C250/$C250"; mkdir -p "$LONG"
(cd "$LONG" && reset_data && run_w -p hi >/dev/null)
L="$(last_launch)"
eq "이스케이프 후 4000바이트 이상이면 cwd만 null" "$(jget "$L" cwd)/$(jget "$L" mode)" "null/print"
check "줄 길이 < 4096 바이트" test "$(LC_ALL=C awk '{print length($0)}' "$DATA/launches.jsonl")" -lt 4096
C120="$(printf '\001%.0s' $(seq 1 120))"
MID="$T/$C120"; mkdir -p "$MID"
(cd "$MID" && reset_data && run_w -p hi >/dev/null)
eq "제어문자 \\u0001 이스케이프 왕복" "$(last_launch | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["cwd"] == sys.argv[1])' "$MID")" "True"

# 기록 실패 무시: 데이터 디렉터리를 만들 수 없는 경로
touch "$T/notadir"
out="$(env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$HOMEDIR" USAGEBAR_CLAUDE_REAL_BIN="$FAKE" \
    USAGEBAR_CLAUDE_DIR="$T/notadir/claude" USAGEBAR_OBSERVER_BIN="$OBSERVER" FAKE_REPORT="$REPORT" \
    /bin/bash "$WRAPPER" -p hi 2>&1 </dev/null)"; rc=$?
eq "기록 불가 디렉터리 → claude 정상 실행·잡음 없음" "$rc/$out" "0/"

# 동시 실행: 줄이 섞이지 않음
reset_data; write_active "$ACC" "$TOKEN"
for i in $(seq 1 20); do run_w -p "hi $i" >/dev/null & done; wait
eq "동시 20회 실행 → 20줄 모두 유효 JSON" "$(python3 -I -c '
import json,sys
n=0
for l in open(sys.argv[1]):
    json.loads(l); n+=1
print(n)' "$DATA/launches.jsonl")" "20"

# ════════════════════════════════════════════════════════════
section "실행 모드·스트림 통과"
STREAM="$T/stream.jsonl"
python3 -I - "$STREAM" <<'PY'
import json, sys
init = {"type":"system","subtype":"init","cwd":"/tmp","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6","tools":[],"model":"claude-haiku-4-5"}
big = {"type":"assistant","message":{"content":[{"type":"text","text":"x" * (3 * 1024 * 1024)}]},"session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6"}
rl = '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795143600,"rateLimitType":"seven_day","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedWindows":{"seven_day":{"utilization":0.62,"resetsAt":1795143600}}},"uuid":"b4356288-7cb0-4778-89bd-58ce793e309b","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6"}'
result = '{"duration_api_ms":8269,"stop_reason":"end_turn","session_id":"289f7f57-3ee2-48b6-9eab-7594cf4cd2c6","total_cost_usd":0.0947547,"modelUsage":{"claude-haiku-4-5":{"inputTokens":10,"outputTokens":891,"cacheReadInputTokens":17957,"cacheCreationInputTokens":44247,"webSearchRequests":0,"costUSD":0.0947547,"contextWindow":200000}},"is_error":true,"subtype":"success","result":"You\'ve hit your weekly limit · resets 3pm","type":"result"}'
with open(sys.argv[1], "wb") as f:
    f.write((json.dumps(init, separators=(",", ":")) + "\n").encode())
    f.write((json.dumps(big, separators=(",", ":")) + "\n").encode())
    f.write((rl + "\n").encode())
    f.write("한글 텍스트 줄 é\r\n".encode())
    f.write(b"\xff\xfe invalid utf8 bytes\n")
    f.write(b"Claude usage limit reached|1795143600\n")
    f.write((result + "\n").encode())
    f.write(b"tail fragment without newline")
PY
reset_data; write_active "$ACC" "$TOKEN"
EXTRA_ENV="FAKE_OUT=$STREAM" run_w -p --output-format stream-json hi > "$T/out.bin"
check "stream-json 바이트 동일 통과 (3MB 줄·CRLF·비UTF-8·끝 개행 없음)" cmp -s "$STREAM" "$T/out.bin"
EV="$DATA/events.jsonl"
etypes="$(python3 -I -c '
import json,sys
print(" ".join(json.loads(l)["type"] for l in open(sys.argv[1])))' "$EV" 2>/dev/null)"
eq "이벤트 순서 (init·rate_limit·텍스트 한도·result+한도 문구)" "$etypes" "session rate_limit limit_text result limit_text"
RL="$(sed -n 2p "$EV")"
eq "rate_limit: status·type·resetsAt" "$(jget "$RL" status)/$(jget "$RL" rateLimitType)/$(jget "$RL" resetsAt)" "allowed/seven_day/1795143600"
eq "rate_limit: windows" "$(jget "$RL" windows)" '{"seven_day": {"resetsAt": 1795143600, "utilization": 0.62}}'
eq "rate_limit: overageStatus" "$(jget "$RL" overageStatus)" "rejected"
eq "이벤트 accountId·tokenHash·launchId" "$(jget "$RL" accountId)/$(jget "$RL" tokenHash)/$(jget "$RL" launchId)" \
    "$ACC/$TOKEN_HASH/$(jget "$(last_launch)" launchId)"
SE="$(sed -n 1p "$EV")"
eq "session: session_id" "$(jget "$SE" sessionId)" "289f7f57-3ee2-48b6-9eab-7594cf4cd2c6"
RS="$(sed -n 4p "$EV")"
eq "result: isError·비용·토큰" "$(jget "$RS" isError)/$(jget "$RS" totalCostUsd)/$(jget "$RS" modelUsage)" \
    'true/0.0947547/{"claude-haiku-4-5": {"cacheCreationInputTokens": 44247, "cacheReadInputTokens": 17957, "inputTokens": 10, "outputTokens": 891}}'
LT="$(sed -n 5p "$EV")"
eq "limit_text(result): 출처·문구" "$(jget "$LT" source)/$(jget "$LT" match)" "result/hit your weekly limit"
LT="$(sed -n 3p "$EV")"
eq "limit_text(text): 출처·문구" "$(jget "$LT" source)/$(jget "$LT" match)" "text/usage limit reached"
check "events.jsonl에 토큰 원문 없음" bash -c "! grep -q -- '$TOKEN' '$EV'"
eq "events.jsonl 권한 0600" "$(stat -f '%Lp' "$EV")" "600"

TEXT="$T/text.out"; printf 'plain text answer\nsecond line' > "$TEXT"
reset_data
EXTRA_ENV="FAKE_OUT=$TEXT" run_w -p hi > "$T/out.txt"
check "-p 텍스트 모드 바이트 동일" cmp -s "$TEXT" "$T/out.txt"
check "-p 텍스트: 한도 문구 없으면 이벤트 없음" test ! -s "$DATA/events.jsonl"

# 대화형: 관측기 없이 exec (관측기를 '실패하면 표시를 남기는' 스크립트로 바꿔 확인)
SPY="$T/spy-observer"; printf '#!/bin/bash\ntouch "%s/spy-ran"\nexec cat\n' "$T" > "$SPY"; chmod +x "$SPY"
reset_data; rm -f "$T/spy-ran"
EXTRA_ENV="FAKE_OUT=$TEXT" OBS_OVERRIDE="$SPY" run_w "대화 프롬프트" > "$T/out.txt"
check "대화형: 관측기 미사용" test ! -e "$T/spy-ran"
check "대화형: 출력 그대로" cmp -s "$TEXT" "$T/out.txt"
EXTRA_ENV="FAKE_OUT=$TEXT" OBS_OVERRIDE="$SPY" run_w -p hi > "$T/out.txt"
check "-p: 관측기 경유" test -e "$T/spy-ran"

# 관측기 없음/기동 실패
for obs in "$T/no-such-observer" "$T/fail-observer" "$T/notexec-observer" "$T"; do
    printf '#!/bin/bash\nexit 3\n' > "$T/fail-observer"; chmod +x "$T/fail-observer"
    printf '#!/bin/bash\nexit 3\n' > "$T/notexec-observer"; chmod -x "$T/notexec-observer"
    reset_data
    EXTRA_ENV="FAKE_OUT=$STREAM" OBS_OVERRIDE="$obs" run_w -p --output-format stream-json hi > "$T/out.bin"; rc=$?
    check "관측기 [${obs##*/}] → 출력 그대로·exit 0" bash -c "cmp -s '$STREAM' '$T/out.bin' && [ $rc = 0 ]"
done

# ════════════════════════════════════════════════════════════
section "종료 코드·stdin·PID"
for code in 0 1 2 137; do
    reset_data
    EXTRA_ENV="FAKE_EXIT=$code" run_w -p hi >/dev/null; rc=$?
    eq "-p exit $code 전달" "$rc" "$code"
    EXTRA_ENV="FAKE_EXIT=$code" run_w "hi there" >/dev/null; rc=$?
    eq "대화형 exit $code 전달" "$rc" "$code"
done
reset_data
EXTRA_ENV="FAKE_SELF_KILL=1" run_w -p hi >/dev/null; rc=$?
eq "SIGKILL 종료 → 137" "$rc" "137"

printf 'line1\nstdin payload\0binary\n' > "$T/stdin.bin"
for m in "-p hi" "--output-format stream-json -p hi" "--model opus"; do
    reset_data
    # shellcheck disable=SC2086
    STDIN_FILE="$T/stdin.bin" EXTRA_ENV="FAKE_STDIN_TO=$T/stdin.got" run_w $m >/dev/null
    check "stdin 그대로 전달 [$m]" cmp -s "$T/stdin.bin" "$T/stdin.got"
done

for m in "-p --output-format stream-json hi" "--model opus"; do
    reset_data
    # shellcheck disable=SC2086
    env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$HOMEDIR" USAGEBAR_CLAUDE_REAL_BIN="$FAKE" USAGEBAR_CLAUDE_DIR="$DATA" \
        USAGEBAR_OBSERVER_BIN="$OBSERVER" FAKE_REPORT="$REPORT" /bin/bash "$WRAPPER" $m </dev/null >/dev/null &
    wpid=$!; wait $wpid
    eq "PID 유지(exec) [$m]" "$(rep pid)" "$wpid"
    eq "launches pid = 래퍼 PID [$m]" "$(jget "$(last_launch)" pid)" "$wpid"
done

# ════════════════════════════════════════════════════════════
section "설치 (scripts/install-wrapper.sh)"
SB="$T/support/bin"; LD="$T/linkdir"; mkdir -p "$LD"
inst() { USAGEBAR_SUPPORT_BIN="$SB" USAGEBAR_LINK_DIRS="$T/no-such-dir $LD" scripts/install-wrapper.sh "$OBSERVER" >/dev/null; }
inst; rc=$?
eq "설치 성공" "$rc" "0"
check "래퍼·관측기 설치됨(실행 가능)" test -x "$SB/usagebar-claude" -a -x "$SB/usagebar"
eq "설치 디렉터리 0700" "$(stat -f '%Lp' "$SB")" "700"
check "래퍼 사본 = 레포 원본" cmp -s "$WRAPPER" "$SB/usagebar-claude"
check "관측기 사본 = 빌드 산출물" cmp -s "$OBSERVER" "$SB/usagebar"
eq "링크: 첫 쓰기 가능 디렉터리 → 고정 경로" "$(readlink "$LD/usagebar-claude")" "$SB/usagebar-claude"
eq "임시 파일 남지 않음" "$(ls -A "$SB" | grep -c '^\.')" "0"
INODE1="$(stat -f '%i' "$LD/usagebar-claude")"; W1="$(stat -f '%i' "$SB/usagebar-claude")"
inst
eq "재설치: 맞는 링크는 그대로(같은 inode)" "$(stat -f '%i' "$LD/usagebar-claude")" "$INODE1"
check "재설치: 파일은 rename으로 교체(새 inode)" test "$(stat -f '%i' "$SB/usagebar-claude")" != "$W1"
reset_data; write_active "$ACC" "$TOKEN"
env -u CLAUDE_CODE_OAUTH_TOKEN HOME="$HOMEDIR" USAGEBAR_CLAUDE_REAL_BIN="$FAKE" USAGEBAR_CLAUDE_DIR="$DATA" \
    USAGEBAR_OBSERVER_BIN="$SB/usagebar" FAKE_REPORT="$REPORT" FAKE_OUT="$STREAM" \
    "$LD/usagebar-claude" -p --output-format stream-json hi </dev/null | cat > "$T/out.bin"
check "링크로 실행 → 설치된 관측기 경유 통과" bash -c "cmp -s '$STREAM' '$T/out.bin' && test -s '$DATA/events.jsonl'"
eq "링크로 실행 → 토큰 주입" "$(rep token)" "$TOKEN"

# ════════════════════════════════════════════════════════════
section "부가 시간 (가짜 claude, -p stream-json, 관측기 기동 포함)"
SMALL="$T/small.jsonl"; head -n 3 "$STREAM" | grep -v '"assistant"' > "$SMALL"
ms_now() { local ns; ns="$(date +%s%N)"; echo "${ns:0:13}"; }
median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
reset_data; write_active "$ACC" "$TOKEN"
N=21
: > "$T/direct.ms"; : > "$T/wrapped.ms"
for i in $(seq 1 $N); do
    s=$(ms_now); FAKE_OUT="$SMALL" "$FAKE" -p --output-format stream-json hi </dev/null | cat >/dev/null; e=$(ms_now)
    echo $((e - s)) >> "$T/direct.ms"
    s=$(ms_now); EXTRA_ENV="FAKE_OUT=$SMALL" run_w -p --output-format stream-json hi >/dev/null; e=$(ms_now)
    echo $((e - s)) >> "$T/wrapped.ms"
done
D="$(median < "$T/direct.ms")"; W="$(median < "$T/wrapped.ms")"
OVER=$((W - D))
echo "  직접 실행 중앙값 ${D}ms · 래퍼 경유 중앙값 ${W}ms · 부가 시간 중앙값 ${OVER}ms (N=$N)"
check "부가 시간 중앙값 ≤ 100ms" test "$OVER" -le 100

printf '\n결과: %d 통과, %d 실패\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
