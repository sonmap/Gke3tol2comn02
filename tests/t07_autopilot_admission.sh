#!/usr/bin/env bash
# 추가 테스트 ⑦ — Autopilot admission 사전 확인  [계획서에 없던 항목]
#
# 계획서 6장은 정적 NFS PV 를, 부록 B 는 Filestore CSI 를 가리킵니다.
# 둘은 다른 방식이고 Autopilot 의 GKE Warden 은 일부 볼륨 타입과 Pod spec 을
# 거절합니다. 거절되면 client-gke-auto 의 PV 생성 로직 자체를 다시 써야 하므로
# "실행기 파라미터 호환" 수준의 문제가 아닙니다.
#
# server-side dry-run 은 실제로 만들지 않으면서 웹훅까지 통과시켜 봅니다.
# 운영에 영향이 없으므로 D-5 에 15분이면 끝납니다.

TEST_ID=t07
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd kubectl jq
need_var NS NFS_SERVER NFS_EXPORT_SOURCE NFS_EXPORT_BQKEY

RENDER_DIR="${EVIDENCE_DIR}/${RUN_ID}.manifests"
"${REPO_ROOT}/bin/render.sh" "$RENDER_DIR" >/dev/null

probe() { # probe <이름> <매니페스트 경로>
  local label="$1" path="$2" out rc=0
  out="$(kc apply --dry-run=server -f "$path" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "통과: $label"
    evidence_fact "admission_${label}" pass
    return 0
  fi
  local code; code="$(classify_error "$out")"
  ng "거절: $label"
  printf '%s\n' "$out" | sed 's/^/      /' >&2
  evidence_fact "admission_${label}" "rejected: $(printf '%s' "$out" | head -1)"
  return 1
}

fail_count=0

# --- 1. 정적 NFS PV (현재 설계의 전제) --------------------------------------
probe "static_nfs_pv" "${RENDER_DIR}/probe-pv.yaml" || fail_count=$((fail_count+1))

# --- 2. 인라인 nfs 볼륨 (원본 YAML 의 bq-key 방식) --------------------------
# Autopilot 은 Pod spec 의 직접 nfs 선언을 허용하지 않을 가능성이 높습니다.
# 거절되는 것이 정상이며, 그 사실을 확인하는 것이 목적입니다.
if probe "inline_nfs_volume" "${RENDER_DIR}/probe-inline-nfs.yaml"; then
  info "인라인 nfs 볼륨이 허용됩니다. 원본 YAML 을 그대로 쓸 수 있습니다."
else
  warn "인라인 nfs 볼륨이 거절되었습니다 (예상된 결과)."
  warn "bq-key 볼륨을 PV/PVC 쌍으로 바꿔야 합니다. manifests/ 에 전환본이 있습니다."
  evidence_fact inline_nfs_supported false
fi

# --- 3. 업무 Pod spec (zc24 실제 자원값) ------------------------------------
probe "workload_pod" "${RENDER_DIR}/probe-pod.yaml" || fail_count=$((fail_count+1))

# --- 4. 자원 요청 자동 조정 확인 --------------------------------------------
# Autopilot 은 requests 를 0.25 CPU 단위로 올림하고 최소값을 적용합니다.
# 요청값이 조용히 상향되면 테스트에서 잰 수치가 실제와 달라집니다.
if [ "$MODE" = "live" ]; then
  require_live_consent
  POD="autopilot-res-probe-${RUN_ID}"
  cleanup() { kc delete pod "$POD" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  cat <<YAML | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${POD}, namespace: ${NS}}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  containers:
    - name: probe
      image: gcr.io/google-containers/busybox:latest
      command: ["sh","-c","echo RES_OK"]
      resources:
        requests: {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
        limits:   {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
YAML

  sleep 5
  applied="$(kc get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].resources}' 2>/dev/null || echo '{}')"
  evidence_fact requested_cpu "$SMOKE_CPU"
  evidence_fact requested_memory "$SMOKE_MEM"
  evidence_fact applied_resources "$applied"
  info "요청: cpu=${SMOKE_CPU} memory=${SMOKE_MEM}"
  info "적용: $applied"

  got_cpu="$(printf '%s' "$applied" | jq -r '.requests.cpu // ""' 2>/dev/null || echo '')"
  if [ -n "$got_cpu" ] && [ "$got_cpu" != "$SMOKE_CPU" ]; then
    warn "Autopilot 이 CPU 요청을 ${SMOKE_CPU} → ${got_cpu} 로 조정했습니다."
    warn "Wave 3 용량 산정은 조정 후 값을 기준으로 하십시오."
  fi
else
  info "자원 자동 조정 확인은 MODE=live 에서 수행합니다."
fi

if [ "$fail_count" -gt 0 ]; then
  ng "현재 PV/Pod 설계가 Autopilot 정책을 통과하지 못합니다."
  ng "client-gke-auto 의 자원 생성 로직 수정이 필요하며, 이는 사업 범위 1항"
  ng "('변경 최소화')과 충돌하므로 즉시 보고 대상입니다."
  die "$EXIT_ADMISSION" "admission 검증 ${fail_count}건 실패"
fi

pass "Autopilot admission 사전 확인 완료"
