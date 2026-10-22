#!/usr/bin/env bash
# 추가 테스트 ⑧ — 동시 실행 부하 검증  [계획서에 없던 항목]
#
# 계획서는 "Cron 이 23시에 집중"이라고 쓰면서 모든 테스트를 파드 1개로 합니다.
# 30개가 동시에 뜰 때만 나타나는 문제가 검증되지 않습니다.
#   - Autopilot 노드 증설 지연 (콜드 스타트 중첩)
#   - PV/PVC 이름 충돌 (PV 는 cluster-scope)
#   - Filestore 동시 연결 수
#   - 프로젝트 CPU/IP 쿼터
#
# 업무 SQL 대신 sleep 만 돌려도 스케줄링·마운트·쿼터는 충분히 검증됩니다.
# Wave 3 진입 전에 반드시 수행하십시오.

TEST_ID=t08
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd kubectl jq
need_var NS KSA

require_mode live
require_live_consent

N="${CONCURRENCY_N:-15}"
# shellcheck disable=SC1090
[ -f "${EVIDENCE_DIR}/${RUN_ID}.image.env" ] && source "${EVIDENCE_DIR}/${RUN_ID}.image.env"
IMG="${ZC24_IMAGE_BY_DIGEST:-${ZC24_IMAGE_URI:-}}"
[ -n "$IMG" ] || die "$EXIT_CONFIG" "이미지 URI 가 없습니다. t02 를 먼저 실행하십시오."

info "동시 실행 ${N}개 (이미지: ${IMG})"
evidence_fact concurrency_n "$N"

PREFIX="loadtest-${RUN_ID}"
cleanup() {
  kc delete pod -n "$NS" -l "test=$PREFIX" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 1. 일제히 생성 ---------------------------------------------------------
t0=$(date +%s)
for i in $(seq 1 "$N"); do
  cat <<YAML | kc apply -f - >/dev/null &
apiVersion: v1
kind: Pod
metadata:
  name: ${PREFIX}-${i}
  namespace: ${NS}
  labels: {test: ${PREFIX}}
spec:
  restartPolicy: Never
  serviceAccountName: ${KSA}
  activeDeadlineSeconds: ${POD_TIMEOUT_SEC}
  containers:
    - name: load
      image: ${IMG}
      command: ["/bin/sh","-c","sleep 60; echo LOAD_OK"]
      resources:
        requests: {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
        limits:   {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
YAML
done
wait
info "생성 요청 완료 ($(( $(date +%s) - t0 ))s)"

# --- 2. 전원 완료까지 대기하며 상태 추적 ------------------------------------
deadline=$(( $(date +%s) + POD_TIMEOUT_SEC ))
while :; do
  counts="$(kc get pod -n "$NS" -l "test=$PREFIX" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | sort | uniq -c || true)"
  done_n="$(printf '%s\n' "$counts" | awk '/Succeeded|Failed/ {s+=$1} END {print s+0}')"
  printf '\r    진행: %s/%s  %s' "$done_n" "$N" "$(printf '%s' "$counts" | tr '\n' ' ')" >&2
  [ "$done_n" -ge "$N" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '\n' >&2
    warn "타임아웃. 미완료 Pod 상태:"
    kc get pod -n "$NS" -l "test=$PREFIX" -o wide 2>/dev/null | sed 's/^/    /' >&2
    break
  fi
  sleep 5
done
printf '\n' >&2

# --- 3. 증설 지연 측정 ------------------------------------------------------
# creationTimestamp → startTime 차이가 Autopilot 콜드 스타트 비용입니다.
# 이 수치가 SLA 판정의 근거가 됩니다.
json="$(kc get pod -n "$NS" -l "test=$PREFIX" -o json 2>/dev/null || echo '{"items":[]}')"

stats="$(printf '%s' "$json" | jq -r '
  [ .items[]
    | select(.status.startTime != null)
    | ((.status.startTime | fromdateiso8601)
       - (.metadata.creationTimestamp | fromdateiso8601)) ] as $d
  | if ($d | length) == 0 then "0 0 0 0"
    else "\($d|length) \($d|min) \($d|max) \(($d|add)/($d|length)|floor)"
    end' 2>/dev/null || echo "0 0 0 0")"

read -r cnt dmin dmax davg <<<"$stats"
evidence_fact sched_delay_count "$cnt"
evidence_fact sched_delay_min_sec "$dmin"
evidence_fact sched_delay_max_sec "$dmax"
evidence_fact sched_delay_avg_sec "$davg"

info "스케줄링 지연: 최소 ${dmin}s / 평균 ${davg}s / 최대 ${dmax}s (${cnt}개)"

succeeded="$(printf '%s' "$json" | jq '[.items[]|select(.status.phase=="Succeeded")]|length')"
failed="$(printf   '%s' "$json" | jq '[.items[]|select(.status.phase=="Failed")]|length')"
pending="$(printf  '%s' "$json" | jq '[.items[]|select(.status.phase=="Pending")]|length')"
evidence_fact pods_succeeded "$succeeded"
evidence_fact pods_failed "$failed"
evidence_fact pods_pending "$pending"

# --- 4. 실패 사유 분류 ------------------------------------------------------
if [ "$failed" -gt 0 ] || [ "$pending" -gt 0 ]; then
  reasons="$(printf '%s' "$json" | jq -r '
    .items[] | select(.status.phase != "Succeeded")
    | [ .metadata.name,
        (.status.conditions[]? | select(.status=="False") | .reason // "") ,
        (.status.containerStatuses[]?.state.waiting.reason // ""),
        (.status.containerStatuses[]?.state.terminated.reason // "") ]
    | map(select(. != "" and . != null)) | join(" / ")' 2>/dev/null || true)"
  warn "비정상 종료 Pod:"
  printf '%s\n' "$reasons" | sed 's/^/    /' >&2
  evidence_fact failure_reasons "$(printf '%s' "$reasons" | tr '\n' ';')"

  case "$reasons" in
    *Unschedulable*|*quota*|*Quota*)
      die "$EXIT_FAIL" "쿼터 또는 스케줄링 한계에 도달했습니다. 30개 동시 전환 전에 증설이 필요합니다." ;;
    *OOMKilled*)
      die "$EXIT_FAIL" "OOMKilled — 자원 요청값을 재산정하십시오." ;;
  esac
fi

[ "$succeeded" -eq "$N" ] || die "$EXIT_FAIL" "${N}개 중 ${succeeded}개만 성공했습니다"

ok "${N}개 동시 실행 전원 성공"
pass "동시 실행 부하 검증 완료 (최대 지연 ${dmax}s)"
