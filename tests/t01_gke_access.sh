#!/usr/bin/env bash
# 단위테스트 ① — GKE 접속 및 RBAC 기본 검증 (실행계획서 4장)
#
# 판정: cluster-info 응답, Namespace 존재, pods/pvc/pv create 권한
# 주의: persistentvolumes 는 cluster-scope 라 Namespace RBAC 와 별개입니다.
#       여기서 막히면 ClusterRole 발급에 승인 시간이 걸리므로 가장 먼저 확인합니다.

TEST_ID=t01
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd gcloud kubectl jq
need_var GKE_PROJECT GKE_CLUSTER REGION NS

info "클러스터: ${GKE_PROJECT}/${GKE_CLUSTER} (${REGION})"

# --- 1. 클러스터 메타데이터 -------------------------------------------------
desc="$(run_classified "클러스터 describe" -- \
  gcloud container clusters describe "$GKE_CLUSTER" \
    --project="$GKE_PROJECT" --region="$REGION" \
    --format='yaml(name,status,autopilot,privateClusterConfig,networkConfig,nodeConfig)')"

cluster_status="$(printf '%s' "$desc" | yq -r '.status // "unknown"' 2>/dev/null || echo unknown)"
autopilot="$(printf '%s' "$desc" | yq -r '.autopilot.enabled // false' 2>/dev/null || echo false)"
node_sa="$(printf '%s' "$desc" | yq -r '.nodeConfig.serviceAccount // ""' 2>/dev/null || echo "")"

evidence_fact cluster_status "$cluster_status"
evidence_fact autopilot_enabled "$autopilot"
evidence_fact node_service_account "$node_sa"

[ "$cluster_status" = "RUNNING" ] || die "$EXIT_FAIL" "클러스터 상태가 RUNNING 이 아닙니다: $cluster_status"

if [ "$autopilot" != "true" ]; then
  warn "Autopilot 이 아닙니다. 전환 대상 클러스터가 맞는지 확인하십시오."
fi

# Node SA 는 단위테스트 ②(AR Pull 권한)의 입력이 됩니다.
if [ -n "$node_sa" ]; then
  info "Node SA: $node_sa  ← t02 의 artifactregistry.reader 부여 대상"
else
  warn "nodeConfig.serviceAccount 가 비어 있습니다. Autopilot 은 노드 설정을 숨기므로 "
  warn "실제 노드에서 확인하거나 GKE 운영 담당자에게 문의하십시오."
fi

# --- 2. Kubeconfig 발급 -----------------------------------------------------
# 기존 설정을 덮지 않도록 전용 경로를 씁니다 (실행계획서 1장 3항).
mkdir -p "$(dirname "$KUBECONFIG")"
run_classified "get-credentials" -- \
  gcloud container clusters get-credentials "$GKE_CLUSTER" \
    --project="$GKE_PROJECT" --region="$REGION" --internal-ip >/dev/null

if [ -f "$KUBECONFIG" ]; then
  perm="$(stat -c '%a' "$KUBECONFIG" 2>/dev/null || echo '?')"
  evidence_fact kubeconfig_mode "$perm"
  if [ "$perm" != "600" ]; then
    warn "Kubeconfig 권한이 $perm 입니다. 600 을 권장합니다: chmod 600 $KUBECONFIG"
  fi
fi

# --- 3. 접속 및 Namespace ---------------------------------------------------
run_classified "cluster-info" -- kc cluster-info >/dev/null
run_classified "namespace 조회" -- kc get ns "$NS" >/dev/null

# --- 4. 권한 (can-i) --------------------------------------------------------
# can-i 는 권한이 없어도 "no" 를 출력하며 종료코드 1 을 반환합니다.
# 따라서 run_classified 가 아니라 직접 판정합니다.
check_cani() { # check_cani <설명> <verb> <resource> [-n ns]
  local label="$1"; shift
  local ans rc=0
  ans="$(kc auth can-i "$@" 2>&1)" || rc=$?
  evidence_fact "cani_${label}" "$ans"
  if [ "$ans" = "yes" ]; then
    ok "권한 있음: $label"
    return 0
  fi
  ng "권한 없음: $label (응답: $ans, rc=$rc)"
  return 1
}

rbac_fail=0
check_cani "pods_create"  create pods                   -n "$NS" || rbac_fail=1
check_cani "pvc_create"   create persistentvolumeclaims -n "$NS" || rbac_fail=1
check_cani "pods_delete"  delete pods                   -n "$NS" || rbac_fail=1
check_cani "logs_get"     get pods/log                  -n "$NS" || rbac_fail=1
# cluster-scope — 실패 시 승인 리드타임이 길므로 별도로 강조합니다.
if ! check_cani "pv_create" create persistentvolumes; then
  rbac_fail=1
  ng "persistentvolumes 는 cluster-scope 입니다. ClusterRole 발급이 필요하며"
  ng "승인에 시간이 걸립니다. 즉시 GKE 운영 담당자에게 요청하십시오."
fi

[ "$rbac_fail" -eq 0 ] || die "$EXIT_PERM" "RBAC 권한이 부족합니다"

pass "GKE 접속 및 RBAC 확인 완료 (autopilot=$autopilot)"
