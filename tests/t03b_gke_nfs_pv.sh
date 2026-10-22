#!/usr/bin/env bash
# 단위테스트 ③ — Filestore / PV·PVC / 방화벽 (실행계획서 6장)
#
# 계획서는 읽기만 검증하지만 실제 배치는 결과 파일을 "씁니다".
# 마운트가 성공해도 POSIX uid/gid 불일치로 쓰기만 거부되는 경우가 있으므로
# 전용 하위 경로에서 쓰기까지 확인합니다. 업무 데이터는 건드리지 않습니다.

TEST_ID=t03b
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

# Filestore 네트워크·방화벽 승인이 아직 없으면 이 테스트는 수행할 수 없습니다.
# 그동안 t03a(VM 측 NFS)로 확인 가능한 것을 먼저 확보합니다.
if [ "${SKIP_GKE_NFS:-0}" = "1" ]; then
  skip "Filestore/GKE NFS 검증 보류 중 (SKIP_GKE_NFS=1). t03a 가 VM 측을 검증합니다."
fi

need_cmd kubectl jq

# t03a 가 운영 VM 에서 실측한 값이 있으면 그것을 우선 씁니다.
# PV 의 server/path 를 추측이 아니라 실측으로 채우기 위한 것입니다.
_nfsenv="${EVIDENCE_DIR}/${RUN_ID}.nfs.env"
if [ -f "$_nfsenv" ]; then
  # shellcheck disable=SC1090
  . "$_nfsenv"
  : "${NFS_EXPORT_SOURCE:=${SUGGEST_NFS_EXPORT_SOURCE:-}}"
  : "${NFS_EXPORT_BQKEY:=${SUGGEST_NFS_EXPORT_BQKEY:-}}"
  info "t03a 실측값 사용: server=${NFS_SERVER} vers=${NFS_VERSION:-?}"
  evidence_fact source_of_nfs_values "t03a"
fi

need_var NS KSA NFS_SERVER NFS_EXPORT_SOURCE NFS_EXPORT_BQKEY

# --- 1. 선행 조건: t03a 의 VM 측 검증 --------------------------------------
# VM 측 마운트 확인은 t03a 가 전담합니다. 여기서는 그 결과가 있는지만 봅니다.
if [ -f "$_nfsenv" ]; then
  ok "t03a 선행 완료 (${_nfsenv})"
else
  warn "t03a 의 실측값이 없습니다. config/env.sh 의 설정값으로 진행합니다."
  warn "먼저 운영 VM 에서 tests/t03a_vm_nfs.sh 를 실행하시길 권합니다."
fi

# --- 2. 매니페스트 렌더링 ---------------------------------------------------
RENDER_DIR="${EVIDENCE_DIR}/${RUN_ID}.manifests"
"${REPO_ROOT}/bin/render.sh" "$RENDER_DIR" >/dev/null
info "렌더링: ${RENDER_DIR}"

# --- 3. Autopilot admission 통과 여부 (server-side dry-run) -----------------
# 실제로 만들지 않으면서 admission 웹훅까지 통과시켜 봅니다. 운영에 영향 없음.
out=""; rc=0
out="$(kc apply --dry-run=server -f "${RENDER_DIR}/nfs-smoke.yaml" 2>&1)" || rc=$?
printf '%s\n' "$out" | mask_secrets | sed 's/^/    /' >&2
if [ "$rc" -ne 0 ]; then
  code="$(classify_error "$out")"
  if [ "$code" = "$EXIT_ADMISSION" ]; then
    ng "Autopilot admission 이 거절했습니다."
    ng "정적 NFS PV 설계 자체를 재검토해야 하며, client-gke-auto 의 PV 생성 로직"
    ng "수정이 필요할 수 있습니다 (사업 범위 1항 '변경 최소화'와 충돌)."
  fi
  die "$code" "dry-run 실패"
fi
ok "server-side dry-run 통과"
evidence_fact admission_dryrun pass

if [ "$MODE" != "live" ]; then
  pass "NFS 매니페스트 admission 검증 완료 (실제 마운트는 MODE=live)"
fi

# --- 4. 실제 마운트 ---------------------------------------------------------
require_live_consent

POD="nfs-probe-${RUN_ID}"
cleanup() {
  kc delete -f "${RENDER_DIR}/nfs-smoke.yaml" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kc apply -f "${RENDER_DIR}/nfs-smoke.yaml" >/dev/null

deadline=$(( $(date +%s) + POD_TIMEOUT_SEC ))
while :; do
  phase="$(kc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  [ "$phase" = "Succeeded" ] && break
  if [ "$phase" = "Failed" ]; then
    kc logs "$POD" -n "$NS" 2>&1 | mask_secrets | sed 's/^/    /' >&2
    die "$EXIT_FAIL" "NFS probe Pod 실패"
  fi
  msg="$(kc describe pod "$POD" -n "$NS" 2>/dev/null | grep -iE 'mount|FailedMount' | tail -3 || true)"
  if printf '%s' "$msg" | grep -qi 'FailedMount'; then
    evidence_fact mount_error "$msg"
    ng "$msg"
    die "$EXIT_NETWORK" "마운트 실패 — Node 서브넷 원본 IP, NFS export ACL, 방화벽 포트를 확인하십시오"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || die "$EXIT_NETWORK" "NFS probe 타임아웃"
  sleep 5
done

logs="$(kc logs "$POD" -n "$NS" 2>&1 | mask_secrets)"
printf '%s\n' "$logs" | sed 's/^/    /' >&2

# uid 기록 — 마운트 성공 후 쓰기만 거부되는 경우를 가려냅니다.
uid_line="$(printf '%s\n' "$logs" | grep -m1 '^uid=' || echo '')"
evidence_fact pod_uid "$uid_line"

# t03a 가 잰 VM 쪽 uid 와 대조합니다. 둘이 다르면 POSIX 권한에 따라
# 마운트는 되는데 쓰기만 거부되는 상황이 생깁니다.
pod_uid_num="$(printf '%s' "$uid_line" | sed -n 's/^uid=\([0-9]*\).*/\1/p')"
if [ -n "${VM_UID:-}" ] && [ -n "$pod_uid_num" ]; then
  evidence_fact vm_uid "$VM_UID"
  if [ "$VM_UID" = "$pod_uid_num" ]; then
    ok "uid 일치: VM=${VM_UID} Pod=${pod_uid_num}"
  else
    warn "uid 불일치: VM=${VM_UID} Pod=${pod_uid_num}"
    warn "기존 배치가 만든 파일을 신규 Pod 가 못 읽거나 못 쓸 수 있습니다."
    evidence_fact uid_mismatch "vm=${VM_UID} pod=${pod_uid_num}"
  fi
fi

for marker in NFS_READ_OK KEY_READ_OK; do
  if printf '%s\n' "$logs" | grep -q "$marker"; then
    ok "$marker"
  else
    die "$EXIT_PERM" "$marker 가 확인되지 않았습니다 — POSIX 권한을 확인하십시오"
  fi
done

if printf '%s\n' "$logs" | grep -q 'NFS_WRITE_OK'; then
  ok "NFS_WRITE_OK — 전용 하위 경로 쓰기 가능"
  evidence_fact nfs_write ok
else
  warn "쓰기 검증 실패. 읽기만 가능한 상태입니다."
  warn "실제 배치가 결과 파일을 쓴다면 운영 중 실패하므로 uid/gid 를 맞춰야 합니다."
  evidence_fact nfs_write failed
fi

pass "NFS 마운트 검증 완료"
