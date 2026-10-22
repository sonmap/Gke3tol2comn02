#!/usr/bin/env bash
# 단위테스트 ③ — Filestore / PV·PVC / 방화벽 (실행계획서 6장)
#
# 계획서는 읽기만 검증하지만 실제 배치는 결과 파일을 "씁니다".
# 마운트가 성공해도 POSIX uid/gid 불일치로 쓰기만 거부되는 경우가 있으므로
# 전용 하위 경로에서 쓰기까지 확인합니다. 업무 데이터는 건드리지 않습니다.

TEST_ID=t03
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd kubectl jq
need_var NS KSA NFS_SERVER NFS_EXPORT_SOURCE NFS_EXPORT_BQKEY

# --- 1. VM 측 마운트 상태 (운영 VM 에서 실행할 때만) ------------------------
if [ -d "${VM_NFS_MOUNT:-/nonexistent}" ]; then
  info "VM 측 마운트: $VM_NFS_MOUNT"
  if command -v findmnt >/dev/null 2>&1; then
    mnt="$(findmnt -T "$VM_NFS_MOUNT" -o SOURCE,FSTYPE,OPTIONS -n 2>/dev/null || echo '')"
    evidence_fact vm_mount "$mnt"
    info "  $mnt"
    # NFS 버전은 방화벽 포트 요구사항을 가릅니다.
    # v4.1 은 보통 2049 단일 포트, v3 는 111/2046/2049/2050/4045 등이 더 필요합니다.
    case "$mnt" in
      *nfs4*) info "  NFSv4 계열 — 보통 TCP 2049 단일 포트" ;;
      *nfs*)  warn "  NFSv3 가능성 — 방화벽 담당자와 추가 포트를 확인하십시오" ;;
    esac
  fi
else
  info "VM NFS 마운트 지점이 없습니다. 이 호스트는 운영 VM 이 아닌 것으로 보입니다."
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
