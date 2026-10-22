# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 공통 라이브러리: 로깅, 종료코드, 증적 수집, 모드 가드
# 모든 tests/*.sh 가 맨 앞에서 source 합니다.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- 종료 코드 규약 --------------------------------------------------------
# 실행계획서 7장 "실패 시 유형별 분리" 요구사항을 코드로 고정합니다.
readonly EXIT_OK=0            # 통과
readonly EXIT_FAIL=1          # 테스트 자체 실패 (기대와 다른 결과)
readonly EXIT_CONFIG=2        # 설정 미비 (__CONFIRM__ 잔존, 파일 없음)
readonly EXIT_PERM=3          # 권한 거부 (403 / Forbidden / PermissionDenied)
readonly EXIT_NOTFOUND=4      # 대상 없음 (404 / NotFound)
readonly EXIT_NETWORK=5       # 네트워크·DNS·TLS·timeout
readonly EXIT_ADMISSION=6     # Autopilot admission 거절
readonly EXIT_SKIP=77         # 현재 MODE 에서 수행 불가 (실패 아님)

exit_name() {
  case "${1:-}" in
    0) echo OK ;;      1) echo FAIL ;;       2) echo CONFIG ;;
    3) echo PERM ;;    4) echo NOTFOUND ;;   5) echo NETWORK ;;
    6) echo ADMISSION ;; 77) echo SKIP ;;    *) echo "UNKNOWN($1)" ;;
  esac
}

# --- 색상 (TTY 일 때만) ----------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_NG=$'\033[31m'; C_WARN=$'\033[33m'
  C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_NG=''; C_WARN=''; C_DIM=''; C_OFF=''
fi

TEST_ID="${TEST_ID:-unknown}"

log()  { printf '%s[%s] %s%s\n' "$C_DIM" "$TEST_ID" "$*" "$C_OFF" >&2; }
info() { printf '[INFO ][%s] %s\n' "$TEST_ID" "$*" >&2; }
warn() { printf '%s[WARN ][%s] %s%s\n' "$C_WARN" "$TEST_ID" "$*" "$C_OFF" >&2; }
ok()   { printf '%s[PASS ][%s] %s%s\n' "$C_OK" "$TEST_ID" "$*" "$C_OFF" >&2; }
ng()   { printf '%s[FAIL ][%s] %s%s\n' "$C_NG" "$TEST_ID" "$*" "$C_OFF" >&2; }

die() { # die <exit_code> <message>
  local code="$1"; shift
  ng "$*"
  evidence_emit "$code" "$*"
  exit "$code"
}

# --- 비밀값 마스킹 ---------------------------------------------------------
# SA Key 원문, 토큰이 로그에 섞여 들어가는 사고를 막습니다.
mask_secrets() {
  sed -E \
    -e 's/("private_key"[[:space:]]*:[[:space:]]*")[^"]*/\1<REDACTED>/g' \
    -e 's/(ya29\.)[A-Za-z0-9._-]+/\1<REDACTED>/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----).*/\1<REDACTED>/g'
}

# --- 증적 (JSONL) ----------------------------------------------------------
# 30개 과제 x 수작업 기록은 누락이 생깁니다. 모든 테스트가 한 줄씩 남깁니다.
EVIDENCE_DIR="${EVIDENCE_DIR:-$(pwd)/evidence}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
EVIDENCE_FILE="${EVIDENCE_DIR}/${RUN_ID}.jsonl"

declare -a _EV_FACTS=()

# evidence_fact <key> <value>  — 테스트가 수집한 사실을 증적에 덧붙입니다.
evidence_fact() {
  _EV_FACTS+=( "$(jq -cn --arg k "$1" --arg v "${2:-}" '{($k): $v}')" )
}

evidence_emit() { # evidence_emit <exit_code> <message>
  local code="${1:-0}" msg="${2:-}"
  mkdir -p "$EVIDENCE_DIR"
  local facts='{}'
  if [ "${#_EV_FACTS[@]}" -gt 0 ]; then
    facts="$(printf '%s\n' "${_EV_FACTS[@]}" | jq -cs 'add')"
  fi
  jq -cn \
    --arg run_id   "$RUN_ID" \
    --arg test_id  "$TEST_ID" \
    --arg mode     "${MODE:-mock}" \
    --arg ts       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg result   "$(exit_name "$code")" \
    --argjson code "$code" \
    --arg msg      "$msg" \
    --argjson facts "$facts" \
    '{run_id:$run_id, test_id:$test_id, mode:$mode, ts:$ts,
      result:$result, exit_code:$code, message:$msg, facts:$facts}' \
    >> "$EVIDENCE_FILE"
}

pass() { # pass [message]
  ok "${1:-통과}"
  evidence_emit "$EXIT_OK" "${1:-통과}"
  exit "$EXIT_OK"
}

skip() { # skip <reason>
  warn "SKIP: $1"
  evidence_emit "$EXIT_SKIP" "$1"
  exit "$EXIT_SKIP"
}

# --- 모드 가드 -------------------------------------------------------------
MODE="${MODE:-mock}"

case "$MODE" in
  mock|dryrun|live) ;;
  *) echo "MODE 는 mock|dryrun|live 중 하나여야 합니다 (현재: $MODE)" >&2; exit 2 ;;
esac

# mock 모드에서는 fixtures/mockbin 을 PATH 앞에 끼워 가짜 CLI 를 씁니다.
# 운영 환경에 전혀 접속하지 않으므로 하네스 자체를 안전하게 개발·검증할 수 있습니다.
if [ "$MODE" = "mock" ]; then
  _MOCKBIN="${REPO_ROOT:-$(pwd)}/fixtures/mockbin"
  [ -d "$_MOCKBIN" ] && PATH="${_MOCKBIN}:${PATH}" && export PATH
fi

# require_mode <mode> [mode...] — 지정 모드가 아니면 skip
require_mode() {
  local m
  for m in "$@"; do [ "$MODE" = "$m" ] && return 0; done
  skip "이 테스트는 MODE=$* 에서만 수행합니다 (현재 MODE=$MODE)"
}

# live 모드는 명시적 동의를 한 번 더 요구합니다.
require_live_consent() {
  if [ "$MODE" = "live" ] && [ "${I_UNDERSTAND_THIS_TOUCHES_PROD:-}" != "yes" ]; then
    die "$EXIT_CONFIG" \
      "MODE=live 는 I_UNDERSTAND_THIS_TOUCHES_PROD=yes 를 함께 지정해야 합니다"
  fi
}

# --- 설정 검증 -------------------------------------------------------------
# mock 모드에서 placeholder 를 대신할 값.
# mock 은 하네스 자체를 검증하는 모드이므로 설정 미비가 실패가 되면 안 됩니다.
_mock_value_for() {
  case "$1" in
    *PROJECT*)        echo "mock-project" ;;
    *CLUSTER*)        echo "mock-cluster" ;;
    NS)               echo "l2comm-batch" ;;
    KSA)              echo "ksa-l2comm-batch" ;;
    AR_REPO)          echo "mock-repo" ;;
    NFS_SERVER)       echo "10.0.0.1" ;;
    NFS_EXPORT_*)     echo "/mock/export" ;;
    BQ_TEST_TABLE)    echo "mock-project.DS.TBL_TEST" ;;
    *)                echo "mock-value" ;;
  esac
}

need_var() { # need_var VAR [VAR...]
  local v missing=()
  for v in "$@"; do
    local val="${!v:-}"
    if [ -z "$val" ] || [ "$val" = "__CONFIRM__" ]; then
      if [ "$MODE" = "mock" ]; then
        printf -v "$v" '%s' "$(_mock_value_for "$v")"
        export "${v?}"
      else
        missing+=("$v")
      fi
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "$EXIT_CONFIG" "미확정 설정값: ${missing[*]} (config/env.sh 를 채우십시오)"
  fi
}

need_cmd() { # need_cmd CMD [CMD...]
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "$EXIT_CONFIG" "필요한 명령이 없습니다: ${missing[*]}"
  fi
}

# --- 오류 분류 -------------------------------------------------------------
# gcloud / kubectl stderr 를 종료코드로 환원합니다.
classify_error() { # classify_error <text>  → 종료코드를 stdout 으로
  local t="$1"
  case "$t" in
    # admission 거절을 먼저 봅니다. GKE Warden 의 거절은
    #   Error from server (Forbidden): admission webhook ... denied the request
    # 형태로 Forbidden 에 싸여 오기 때문에, 권한 패턴을 먼저 두면
    # "설계를 다시 해야 한다"는 신호가 단순 권한 문제로 묻힙니다.
    *admission*|*Warden*|*denied\ the\ request*|*violates\ PodSecurity*)
      echo "$EXIT_ADMISSION" ;;
    *PERMISSION_DENIED*|*PermissionDenied*|*Forbidden*|*forbidden*|*403*)
      echo "$EXIT_PERM" ;;
    *NotFound*|*not\ found*|*404*|*does\ not\ exist*)
      echo "$EXIT_NOTFOUND" ;;
    *timeout*|*Timeout*|*i/o\ timeout*|*TLS*|*DNS*|*no\ such\ host*|*Unable\ to\ connect*|*EOF*)
      echo "$EXIT_NETWORK" ;;
    *) echo "$EXIT_FAIL" ;;
  esac
}

# run_classified <설명> -- <명령...>
# 실패 시 stderr 를 분류해 적절한 종료코드로 die 합니다.
run_classified() {
  local desc="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  printf '%s\n' "$out" | mask_secrets
  if [ "$rc" -ne 0 ]; then
    die "$(classify_error "$out")" "$desc 실패 (rc=$rc)"
  fi
  printf '%s' "$out"
}

kc() { kubectl --kubeconfig="$KUBECONFIG" "$@"; }
