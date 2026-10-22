#!/usr/bin/env bash
# 단위테스트 ③-a — 운영 VM 측 NFS 검증 (실행계획서 6장 1·5·6항)
#
# GKE/Filestore 측 PV·PVC 검증(t03b)은 네트워크·방화벽 승인이 필요해 아직
# 수행할 수 없습니다. 그 전에 운영 VM 에서 지금 당장 확인할 수 있는 것을
# 전부 확인해 둡니다. 여기서 수집한 값이 t03b 의 PV 선언 입력이 됩니다.
#
# 계획서 6장 1항이 경고하는 혼동을 코드로 가려냅니다.
#   /mnt/batch_gke        ← VM 상의 마운트 지점 (이 테스트가 보는 곳)
#   10.136.209.130:/batch_gke  ← 서버와 export (PV 에 적을 값)
# 둘은 다른 것이며, VM 의 마운트 지점 이름이 export 경로와 같다는 보장이 없습니다.
#
# 모두 읽기 중심입니다. 쓰기는 .preflight-<RUN_ID> 전용 하위 경로에서만 하고
# 즉시 지웁니다. 업무 파일과 키 원본은 건드리지 않습니다.

TEST_ID=t03a
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq

: "${VM_NFS_MOUNT:=/mnt/batch_gke}"
: "${VM_KEY_PATH:=${VM_NFS_MOUNT}/l2/rsvp/.oefj}"

# --- mock 모드: 가짜 마운트 트리를 만들어 로직 전체를 실제로 돌립니다 -------
if [ "$MODE" = "mock" ]; then
  _fake="$(mktemp -d)"
  trap 'rm -rf "$_fake"' EXIT
  mkdir -p "${_fake}/l2/rsvp" "${_fake}/l2/zc24"
  printf '{"type":"service_account","client_email":"mock@x.iam.gserviceaccount.com"}\n' \
    > "${_fake}/l2/rsvp/.oefj"
  chmod 600 "${_fake}/l2/rsvp/.oefj"
  printf 'print("mock")\n' > "${_fake}/l2/zc24/sample_bq_autopilot.py"
  VM_NFS_MOUNT="$_fake"
  VM_KEY_PATH="${_fake}/l2/rsvp/.oefj"
  info "mock 모드: 가짜 마운트 트리로 검증합니다 (${VM_NFS_MOUNT})"
fi

evidence_fact vm_nfs_mount "$VM_NFS_MOUNT"
fail_count=0
fstype=""

# --- 1. 마운트 지점 존재 ----------------------------------------------------
if [ ! -d "$VM_NFS_MOUNT" ]; then
  ng "마운트 지점이 없습니다: $VM_NFS_MOUNT"
  ng "이 호스트가 운영 VM 이 맞는지, VM_NFS_MOUNT 설정이 맞는지 확인하십시오."
  die "$EXIT_CONFIG" "VM NFS 마운트 지점 없음"
fi
ok "마운트 지점 확인: $VM_NFS_MOUNT"

# --- 2. 마운트 정보에서 서버·export·NFS 버전 추출 ---------------------------
# 이것이 이 테스트의 가장 큰 산출물입니다. PV 에 적을 server/path 를
# 추측이 아니라 실측으로 확정합니다.
NFS_SERVER_ACTUAL=""
NFS_EXPORT_ACTUAL=""
NFS_VERS=""
MOUNT_OPTS=""

IS_NFS=0
if [ "$MODE" = "mock" ]; then
  # 가짜 트리는 로컬 디스크에 있으므로 findmnt 를 그대로 쓰면 ext4 가 잡힙니다.
  # mock 에서는 NFS 마운트 정보를 합성합니다.
  NFS_SERVER_ACTUAL="10.0.0.1"; NFS_EXPORT_ACTUAL="/mock/export"
  NFS_VERS="4.1"; MOUNT_OPTS="rw,relatime,vers=4.1"; IS_NFS=1
  info "mock: 마운트 정보를 합성합니다 (${NFS_SERVER_ACTUAL}:${NFS_EXPORT_ACTUAL})"
elif command -v findmnt >/dev/null 2>&1; then
  line="$(findmnt -T "$VM_NFS_MOUNT" -o SOURCE,FSTYPE,OPTIONS -n 2>/dev/null || echo '')"
  if [ -n "$line" ]; then
    src="$(printf '%s' "$line" | awk '{print $1}')"
    fstype="$(printf '%s' "$line" | awk '{print $2}')"
    MOUNT_OPTS="$(printf '%s' "$line" | awk '{print $3}')"

    info "SOURCE : $src"
    info "FSTYPE : $fstype"
    info "OPTIONS: $MOUNT_OPTS"

    # fstype 이 nfs 계열일 때만 server:export 로 해석합니다.
    # 로컬 디스크(ext4 등)를 NFS 로 오인해 엉뚱한 PV 값을 권고하면 안 됩니다.
    case "$fstype" in
      nfs|nfs4|nfs3)
        IS_NFS=1
        NFS_SERVER_ACTUAL="${src%%:*}"
        NFS_EXPORT_ACTUAL="${src#*:}"
        NFS_VERS="$(printf '%s' "$MOUNT_OPTS" | tr ',' '\n' | sed -n 's/^vers=//p' | head -1)"
        [ -z "$NFS_VERS" ] && case "$fstype" in nfs4) NFS_VERS=4 ;; nfs) NFS_VERS=3 ;; esac
        ;;
      *)
        ng "${VM_NFS_MOUNT} 가 NFS 마운트가 아닙니다 (fstype=${fstype})."
        ng "NFS 가 아직 마운트되지 않았거나, VM_NFS_MOUNT 설정이 틀렸습니다."
        ng "운영 VM 에서 실행 중인지, mount 상태가 정상인지 확인하십시오."
        evidence_fact not_nfs "fstype=${fstype} source=${src}"
        fail_count=$((fail_count + 1))
        ;;
    esac
  fi
elif command -v mount >/dev/null 2>&1; then
  line="$(mount | grep -F " ${VM_NFS_MOUNT} " | head -1 || echo '')"
  if [ -n "$line" ]; then
    src="$(printf '%s' "$line" | awk '{print $1}')"
    info "mount: $line"
    case "$line" in
      *" type nfs"*)
        IS_NFS=1
        NFS_SERVER_ACTUAL="${src%%:*}"
        NFS_EXPORT_ACTUAL="${src#*:}" ;;
      *) ng "NFS 마운트가 아닙니다: $line"
         fail_count=$((fail_count + 1)) ;;
    esac
  fi
fi

if [ -z "$NFS_SERVER_ACTUAL" ] && [ "$IS_NFS" -eq 0 ] && [ "$fail_count" -eq 0 ]; then
  warn "마운트 정보를 읽지 못했습니다. findmnt/mount 를 사용할 수 없는 환경입니다."
  warn "PV 의 server/path 는 Filestore 담당자 확인으로 확정하십시오."
fi

evidence_fact nfs_server_actual "$NFS_SERVER_ACTUAL"
evidence_fact nfs_export_actual "$NFS_EXPORT_ACTUAL"
evidence_fact nfs_version "$NFS_VERS"
evidence_fact mount_options "$MOUNT_OPTS"

# 계획서 2장의 계획값과 실측값이 다르면 알립니다.
if [ -n "${NFS_SERVER:-}" ] && [ "$NFS_SERVER" != "__CONFIRM__" ] \
   && [ -n "$NFS_SERVER_ACTUAL" ] && [ "$NFS_SERVER" != "$NFS_SERVER_ACTUAL" ]; then
  warn "설정값과 실측값이 다릅니다: NFS_SERVER=${NFS_SERVER} vs 실측 ${NFS_SERVER_ACTUAL}"
  evidence_fact nfs_server_mismatch "configured=${NFS_SERVER} actual=${NFS_SERVER_ACTUAL}"
fi

# --- 3. NFS 버전에 따른 방화벽 포트 안내 ------------------------------------
# 계획서 6장 4항 대응. 버전이 확정되어야 네트워크 담당자에게 정확히 요청할 수 있습니다.
case "$NFS_VERS" in
  4*)
    ok "NFSv${NFS_VERS} — 방화벽은 보통 TCP 2049 단일 포트로 충분합니다"
    evidence_fact required_ports "TCP 2049" ;;
  3*)
    warn "NFSv${NFS_VERS} — 2049 단일 포트로는 부족할 수 있습니다."
    warn "  보통 필요: TCP/UDP 111(portmapper), 2049(nfs), 그리고"
    warn "  mountd/nlockmgr/statd 의 포트(사이트에 따라 2046/2050/4045 등)"
    warn "  정확한 포트는 Filestore 담당자와 확인하십시오."
    evidence_fact required_ports "TCP/UDP 111, 2049, + mountd/nlockmgr (사이트 확인)" ;;
  *)
    info "NFS 버전을 특정하지 못했습니다. 방화벽 요청 전에 반드시 확인하십시오." ;;
esac

# --- 4. 실행 주체의 uid/gid ------------------------------------------------
# GKE Pod 의 uid 와 비교할 기준값입니다. 둘이 다르면 마운트는 성공해도
# 쓰기만 거부됩니다. t03b 가 Pod 쪽 uid 를 수집해 여기와 대조합니다.
vm_id="$(id 2>/dev/null || echo '')"
vm_uid="$(id -u 2>/dev/null || echo '')"
vm_gid="$(id -g 2>/dev/null || echo '')"
evidence_fact vm_id "$vm_id"
evidence_fact vm_uid "$vm_uid"
evidence_fact vm_gid "$vm_gid"
info "실행 주체: $vm_id"

# --- 5. 업무 디렉터리 점검 --------------------------------------------------
# 계획서 6장 '중요 경로 검증': zc24 업무 소스와 rsvp/.oefj 는 다른 하위 경로일
# 수 있습니다. 어느 과제 디렉터리가 실제로 있는지 열거해 둡니다.
L2_DIR="${VM_NFS_MOUNT}/l2"
if [ -d "$L2_DIR" ]; then
  mapfile -t subdirs < <(find "$L2_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  evidence_fact l2_subdir_count "${#subdirs[@]}"
  evidence_fact l2_subdirs "$(printf '%s,' "${subdirs[@]}" | sed 's/,$//')"
  info "업무 디렉터리 ${#subdirs[@]}개: ${subdirs[*]:0:12}${subdirs[12]:+ ...}"

  # 부록 A 30개 과제와 대조합니다.
  TASKS="${REPO_ROOT}/config/tasks30.csv"
  if [ -f "$TASKS" ]; then
    missing=()
    while IFS=, read -r _no biz _id _tag _a _b _c _d; do
      [ "$_no" = "no" ] && continue
      [ -z "$biz" ] && continue
      printf '%s\n' "${subdirs[@]}" | grep -qxF "$biz" || missing+=("$biz")
    done < "$TASKS"
    # 중복 제거
    if [ "${#missing[@]}" -gt 0 ]; then
      uniq_missing="$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')"
      warn "30개 과제 중 NFS 에 디렉터리가 안 보이는 업무: ${uniq_missing}"
      warn "다른 export 나 다른 경로일 수 있습니다. 전환 전에 확인하십시오."
      evidence_fact tasks_without_nfs_dir "$uniq_missing"
    else
      ok "30개 과제의 업무 디렉터리가 모두 확인됩니다"
    fi
  fi
else
  warn "업무 디렉터리가 없습니다: $L2_DIR"
  warn "경로 구조가 계획서 가정과 다를 수 있습니다."
  evidence_fact l2_dir_missing "$L2_DIR"
fi

# --- 6. SA Key 파일 ---------------------------------------------------------
# 계획서 14장 '.oef / .oefj 혼동' 위험 대응. 파일 내용은 절대 출력하지 않습니다.
key_found=""
_seen=""
for cand in "$VM_KEY_PATH" \
            "${VM_NFS_MOUNT}/l2/rsvp/.oefj" "${VM_NFS_MOUNT}/l2/rsvp/.oef"; do
  [ -z "$cand" ] && continue
  case "$_seen" in *"|${cand}|"*) continue ;; esac
  _seen="${_seen}|${cand}|"
  if [ -f "$cand" ]; then
    state=ok
    [ -r "$cand" ] || state="존재하나 읽기 불가"
    info "키 후보: $cand ($state)"
    [ -z "$key_found" ] && [ -r "$cand" ] && key_found="$cand"
  else
    info "키 후보: $cand (없음)"
  fi
done

if [ -z "$key_found" ]; then
  ng "읽을 수 있는 SA Key 를 찾지 못했습니다."
  ng "계획서는 .oefj 를 전제하지만 과거 config.py 는 .oef 를 썼습니다."
  ng "실제 파일명과 경로를 확정해야 t04 가 의미를 갖습니다."
  fail_count=$((fail_count + 1))
else
  ok "SA Key 확인: $key_found"
  evidence_fact vm_key_path "$key_found"
  evidence_fact vm_key_basename "$(basename "$key_found")"

  # 소유자·권한 — 여러 과제가 공유하는 키인지 판단 근거가 됩니다.
  kstat="$(stat -c '%a %U:%G %s' "$key_found" 2>/dev/null || echo '')"
  evidence_fact vm_key_stat "$kstat"
  info "키 권한/소유자/크기: $kstat"
  kmode="${kstat%% *}"
  case "$kmode" in
    600|400) ok "키 권한 적절: $kmode" ;;
    *) warn "키가 group/other 에 열려 있습니다: $kmode"
       warn "같은 export 를 쓰는 다른 과제에서도 읽힙니다." ;;
  esac

  # JSON 형식인지만 확인합니다. 내용은 출력하지 않습니다.
  if command -v jq >/dev/null 2>&1; then
    if jq -e 'type == "object" and has("client_email")' "$key_found" >/dev/null 2>&1; then
      sa_email="$(jq -r '.client_email' "$key_found" 2>/dev/null || echo '')"
      ok "유효한 SA JSON 키 (계정: $sa_email)"
      evidence_fact vm_key_sa_email "$sa_email"
      # 계획서 1장 4항: AR Pull 용 Node SA 와 BQ 용 .oefj SA 는 다를 수 있습니다.
      info "이 계정은 BigQuery 용입니다. AR Pull 용 Node SA 와 혼동하지 마십시오."
    else
      ng "SA JSON 키 형식이 아닙니다: $key_found"
      fail_count=$((fail_count + 1))
    fi
  fi
fi

# --- 7. 읽기 검증 -----------------------------------------------------------
if [ -r "$VM_NFS_MOUNT" ] && ls "$VM_NFS_MOUNT" >/dev/null 2>&1; then
  ok "NFS_READ_OK — 마운트 지점 읽기 가능"
  evidence_fact vm_nfs_read ok
else
  ng "마운트 지점을 읽을 수 없습니다"
  evidence_fact vm_nfs_read failed
  fail_count=$((fail_count + 1))
fi

# --- 8. 쓰기 검증 (전용 하위 경로) -----------------------------------------
# 실제 배치는 결과 파일을 씁니다. 읽기만 확인하면 운영 중 실패합니다.
# 전용 디렉터리를 만들어 쓰고 즉시 지웁니다. 업무 파일은 건드리지 않습니다.
probe_dir="${VM_NFS_MOUNT}/.preflight-${RUN_ID}"
if mkdir -p "$probe_dir" 2>/dev/null && echo ok > "${probe_dir}/w.tmp" 2>/dev/null; then
  ok "NFS_WRITE_OK — 전용 하위 경로 쓰기 가능"
  evidence_fact vm_nfs_write ok
  rm -rf "$probe_dir" 2>/dev/null || warn "정리 실패, 수동 삭제 필요: $probe_dir"
else
  warn "NFS_WRITE_DENIED — 마운트 지점에 쓸 수 없습니다"
  warn "실제 배치가 결과 파일을 쓴다면 운영 중 실패합니다. uid/gid 와 export"
  warn "rw 설정을 확인하십시오."
  evidence_fact vm_nfs_write denied
  rm -rf "$probe_dir" 2>/dev/null || true
fi

# --- 9. 용량 ----------------------------------------------------------------
if command -v df >/dev/null 2>&1; then
  dfline="$(df -h "$VM_NFS_MOUNT" 2>/dev/null | tail -1 || echo '')"
  if [ -n "$dfline" ]; then
    evidence_fact df "$dfline"
    info "용량: $dfline"
    use="$(printf '%s' "$dfline" | awk '{print $5}' | tr -d '%')"
    if [ -n "$use" ] && [ "$use" -ge 85 ] 2>/dev/null; then
      warn "사용률 ${use}% — 전환 중 쓰기 실패 위험이 있습니다"
    fi
  fi
fi
# 계획서 6장 2항: PV 의 100Gi 는 선언값이지 실제 용량 제한이 아닙니다.
info "참고: PV 의 storage 100Gi 는 NFS 볼륨 선언값이며 실제 할당량이 아닙니다"

# --- 10. 서버 도달성 --------------------------------------------------------
if [ -n "$NFS_SERVER_ACTUAL" ] && [ "$MODE" != "mock" ]; then
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w3 "$NFS_SERVER_ACTUAL" 2049 >/dev/null 2>&1; then
      ok "VM → ${NFS_SERVER_ACTUAL}:2049 도달 가능"
      evidence_fact vm_to_nfs_2049 reachable
    else
      warn "VM 에서 ${NFS_SERVER_ACTUAL}:2049 에 닿지 않습니다 (이미 마운트되어 있다면 무시 가능)"
      evidence_fact vm_to_nfs_2049 unreachable
    fi
  fi
  # export 목록 — GKE 쪽에서 쓸 수 있는 경로를 확인합니다.
  if command -v showmount >/dev/null 2>&1; then
    exports="$(showmount -e "$NFS_SERVER_ACTUAL" 2>/dev/null | tail -n +2 || echo '')"
    if [ -n "$exports" ]; then
      evidence_fact nfs_exports "$(printf '%s' "$exports" | tr '\n' ';')"
      info "서버 export 목록:"
      printf '%s\n' "$exports" | sed 's/^/    /' >&2
    fi
  fi
fi

# --- 11. t03b 용 입력값 산출 ------------------------------------------------
# 여기서 확정한 값을 파일로 떨궈 GKE PV 선언에 그대로 쓰게 합니다.
# 추측값이 아니라 실측값으로 PV 를 만드는 것이 목적입니다.
mkdir -p "$EVIDENCE_DIR"
NFS_ENV="${EVIDENCE_DIR}/${RUN_ID}.nfs.env"
{
  printf '# t03a 가 운영 VM 에서 실측한 값입니다. t03b 의 PV 선언 입력으로 쓰십시오.\n'
  printf 'NFS_SERVER=%s\n' "$NFS_SERVER_ACTUAL"
  printf 'NFS_EXPORT_ROOT=%s\n' "$NFS_EXPORT_ACTUAL"
  printf 'NFS_VERSION=%s\n' "$NFS_VERS"
  printf 'VM_UID=%s\n' "$vm_uid"
  printf 'VM_GID=%s\n' "$vm_gid"
  [ -n "$key_found" ] && printf 'VM_KEY_PATH=%s\n' "$key_found"
  # export 루트 기준 상대 경로로 변환해 PV 의 path 후보를 제시합니다.
  if [ -n "$NFS_EXPORT_ACTUAL" ] && [ "$IS_NFS" -eq 1 ]; then
    printf 'SUGGEST_NFS_EXPORT_SOURCE=%s\n' "${NFS_EXPORT_ACTUAL%/}/l2/zc24"
    printf 'SUGGEST_NFS_EXPORT_BQKEY=%s\n'  "${NFS_EXPORT_ACTUAL%/}/l2/rsvp"
  fi
} > "$NFS_ENV"

evidence_fact nfs_env_file "$NFS_ENV"
info "t03b 입력값 저장: $NFS_ENV"

if [ -n "$NFS_EXPORT_ACTUAL" ] && [ "$IS_NFS" -eq 1 ]; then
  echo >&2
  info "config/env.sh 에 반영할 값:"
  info "  export NFS_SERVER='${NFS_SERVER_ACTUAL}'"
  info "  export NFS_EXPORT_SOURCE='${NFS_EXPORT_ACTUAL%/}/l2/zc24'"
  info "  export NFS_EXPORT_BQKEY='${NFS_EXPORT_ACTUAL%/}/l2/rsvp'"
  echo >&2
  warn "주의: 위 경로가 서버의 export 루트 기준으로 직접 마운트 가능한지"
  warn "      Filestore 담당자와 확인하십시오. VM 의 마운트 지점 하위 경로가"
  warn "      곧바로 NFS export 경로가 되는 것은 아닙니다 (계획서 6장 1항)."
fi

[ "$fail_count" -eq 0 ] || die "$EXIT_FAIL" "VM NFS 검증에서 ${fail_count}건 실패"

pass "VM 측 NFS 검증 완료 (server=${NFS_SERVER_ACTUAL:-미확인} vers=${NFS_VERS:-미확인})"
