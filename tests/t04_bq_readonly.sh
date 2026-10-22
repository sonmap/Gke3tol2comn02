#!/usr/bin/env bash
# 단위테스트 ④ — BigQuery 읽기 전용 검증 (실행계획서 7장)
#
# 두 가지를 나눠 확인합니다.
#   4a. BQ_KEY_PATH 를 명시한 실행  — 전환 요구사항(.oefj) 검증
#   4b. 환경변수 없는 기본 경로 실행 — 기존 Python 이 실제로 어디를 읽는지 검증
# 계획서 7장 주의사항("이 테스트 통과가 전체 Python 의 .oefj 사용을 뜻하지 않는다")
# 에 대응하는 구성입니다.

TEST_ID=t04
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq
need_var BQ_JOB_PROJECT BQ_TEST_TABLE

# --- mock 모드: Python 을 로컬에서 단위 테스트 ------------------------------
# 실제 BQ 없이 스크립트 자체의 분기(키 없음/권한거부/정상)를 검증합니다.
if [ "$MODE" = "mock" ]; then
  need_cmd python3
  info "Python 단위 테스트 실행 (BigQuery 접속 없음)"
  if python3 -m pytest --version >/dev/null 2>&1; then
    ( cd "$REPO_ROOT" && python3 -m pytest python/tests -q ) || \
      die "$EXIT_FAIL" "sample_bq_autopilot.py 단위 테스트 실패"
    evidence_fact python_test_runner pytest
  else
    # 폐쇄망이나 운영 VM 에는 pytest 가 없을 수 있습니다.
    # 표준 라이브러리만 쓰는 셀프테스트로 같은 분기를 검증합니다.
    info "pytest 가 없어 셀프테스트로 수행합니다"
    python3 "${REPO_ROOT}/python/tests/selftest.py" || \
      die "$EXIT_FAIL" "sample_bq_autopilot.py 셀프테스트 실패"
    evidence_fact python_test_runner selftest
  fi
  evidence_fact python_unit_tests pass
  pass "Python 단위 테스트 통과 (실제 BQ 검증은 MODE=dryrun/live)"
fi

need_cmd kubectl
need_var NS KSA

# --- dryrun 모드: BigQuery dry run -----------------------------------------
# 쿼리를 실행하지 않고 권한·구문·대상 테이블만 확인합니다. 비용 0.
if [ "$MODE" = "dryrun" ]; then
  if ! command -v bq >/dev/null 2>&1; then
    skip "bq CLI 가 없어 dry run 을 건너뜁니다"
  fi
  sql="SELECT 1 AS sample_ok FROM \`${BQ_TEST_TABLE}\` LIMIT 1"
  out=""; rc=0
  out="$(bq --project_id="$BQ_JOB_PROJECT" query --dry_run --use_legacy_sql=false "$sql" 2>&1)" || rc=$?
  printf '%s\n' "$out" | mask_secrets | sed 's/^/    /' >&2
  [ "$rc" -eq 0 ] || die "$(classify_error "$out")" "BigQuery dry run 실패"
  evidence_fact bq_dryrun pass
  pass "BigQuery dry run 통과 (실제 Job 생성은 MODE=live)"
fi

# --- live 모드: Pod 안에서 실제 SELECT --------------------------------------
require_live_consent
need_var NFS_SERVER NFS_EXPORT_SOURCE NFS_EXPORT_BQKEY

RENDER_DIR="${EVIDENCE_DIR}/${RUN_ID}.manifests"
"${REPO_ROOT}/bin/render.sh" "$RENDER_DIR" >/dev/null

POD="zc24-bq-smoke-${RUN_ID}"
cleanup() {
  kc delete -f "${RENDER_DIR}/bq-smoke.yaml" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kc apply -f "${RENDER_DIR}/bq-smoke.yaml" >/dev/null

deadline=$(( $(date +%s) + POD_TIMEOUT_SEC ))
while :; do
  phase="$(kc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  case "$phase" in Succeeded|Failed) break ;; esac
  [ "$(date +%s)" -lt "$deadline" ] || die "$EXIT_NETWORK" "BQ smoke 타임아웃"
  sleep 5
done

logs="$(kc logs "$POD" -n "$NS" 2>&1 | mask_secrets)"
printf '%s\n' "$logs" | sed 's/^/    /' >&2

code="$(kc get pod "$POD" -n "$NS" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo '')"
evidence_fact pod_phase "$phase"
evidence_fact container_exit_code "$code"

# Python 이 마지막에 남기는 [RESULT] 한 줄을 증적에 그대로 넣습니다.
result_line="$(printf '%s\n' "$logs" | sed -n 's/^\[RESULT\] //p' | tail -1)"
if [ -n "$result_line" ]; then
  evidence_fact bq_result "$result_line"
  job_id="$(printf '%s' "$result_line" | jq -r '.job_id // ""' 2>/dev/null || echo '')"
  [ -n "$job_id" ] && ok "Job ID: $job_id"
fi

case "$code" in
  0) ;;
  2) die "$EXIT_CONFIG"   "SA Key 파일을 찾지 못했습니다 — 로그의 [DIAG] 줄에서 실제 경로를 확인하십시오" ;;
  3) die "$EXIT_PERM"     "권한 거부 — Key 내부 SA 의 bigquery.jobUser / dataViewer 를 확인하십시오" ;;
  4) die "$EXIT_NOTFOUND" "대상 없음 — 테이블·데이터셋·프로젝트를 확인하십시오" ;;
  5) die "$EXIT_NETWORK"  "네트워크 — Private Google Access / DNS / 443 경로를 확인하십시오" ;;
  *) die "$EXIT_FAIL"     "BQ smoke 실패 (exitCode=$code, phase=$phase)" ;;
esac

[ "$phase" = "Succeeded" ] || die "$EXIT_FAIL" "exitCode 는 0 이지만 phase 가 $phase 입니다"

pass "BigQuery 읽기 전용 검증 완료"
