#!/usr/bin/env bash
# 실패 주입 테스트 — 하네스가 장애를 "제대로 잡아내는지" 검증합니다.
#
# 통과하는 테스트를 만드는 것은 쉽습니다. 어려운 것은 실패를 놓치지 않는 것입니다.
# 운영에서 실제로 장애가 났을 때 하네스가 조용히 통과시켜 버리면,
# 테스트가 없는 것보다 나쁩니다.
#
# mock CLI 에 장애를 주입하고 기대하는 종료코드가 나오는지 확인합니다.
#
#   tests/negative.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export MODE=mock
export REPO_ROOT
export EVIDENCE_DIR="${EVIDENCE_DIR:-${REPO_ROOT}/evidence}"
. config/env.example.sh 2>/dev/null || true
export MODE=mock

PASS=0; FAIL=0

expect() { # expect <기대코드> <설명> -- <환경변수...> -- <테스트파일>
  local want="$1" label="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  shift
  local script="$1"

  local rc=0
  env MODE=mock REPO_ROOT="$REPO_ROOT" EVIDENCE_DIR="$EVIDENCE_DIR" \
      RUN_ID="neg-$(date +%s%N)" "${envs[@]}" \
      bash "$script" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq "$want" ]; then
    printf '  ok   %-46s (exit %s)\n' "$label" "$rc"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %-46s 기대 %s, 실제 %s\n' "$label" "$want" "$rc"
    FAIL=$((FAIL + 1))
  fi
}

echo "실패 주입 테스트 — 하네스가 장애를 잡아내는지 확인"
echo

# --- 권한 거부가 EXIT_PERM(3) 으로 분류되는가 -------------------------------
expect 3 "GKE 권한 거부 → PERM" \
  -- MOCK_GCLOUD_FAIL=perm -- tests/t01_gke_access.sh

expect 3 "RBAC can-i 거부 → PERM" \
  -- MOCK_KUBECTL_FAIL=perm -- tests/t01_gke_access.sh

# --- 대상 없음이 EXIT_NOTFOUND(4) 로 분류되는가 -----------------------------
expect 4 "AR 저장소명 불일치 → NOTFOUND" \
  -- MOCK_AR_REPO_MISMATCH=1 -- tests/t02_ar_pull.sh

expect 4 "네임스페이스 없음 → NOTFOUND" \
  -- MOCK_KUBECTL_FAIL=notfound -- tests/t01_gke_access.sh

# --- 네트워크 장애가 EXIT_NETWORK(5) 로 분류되는가 --------------------------
expect 5 "API 서버 연결 불가 → NETWORK" \
  -- MOCK_KUBECTL_FAIL=network -- tests/t01_gke_access.sh

# --- Autopilot 거절이 EXIT_ADMISSION(6) 으로 분류되는가 ---------------------
# 이것이 가장 중요합니다. admission 거절을 일반 실패로 뭉개면
# "설계를 다시 해야 한다"는 신호가 묻힙니다.
expect 6 "Autopilot admission 거절 → ADMISSION" \
  -- MOCK_KUBECTL_FAIL=admission -- tests/t07_autopilot_admission.sh

expect 6 "NFS PV admission 거절 → ADMISSION" \
  -- MOCK_KUBECTL_FAIL=admission SKIP_GKE_NFS=0 -- tests/t03b_gke_nfs_pv.sh

# --- VM NFS: 마운트 지점 부재가 EXIT_CONFIG(2) 로 분류되는가 ----------------
expect 2 "VM 마운트 지점 없음 → CONFIG" \
  -- MODE=dryrun VM_NFS_MOUNT=/nonexistent-mount -- tests/t03a_vm_nfs.sh

# --- Python 종료코드가 그대로 전파되는가 ------------------------------------
echo
echo "Python 종료코드 전파"
for case in "키없음:2:BQ_KEY_PATH=/nonexistent/.oefj"; do
  label="${case%%:*}"; rest="${case#*:}"
  want="${rest%%:*}"; envvar="${rest#*:}"
  rc=0
  env "$envvar" BQ_JOB_PROJECT=p BQ_TEST_TABLE=p.d.t \
    python3 python/sample_bq_autopilot.py >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  ok   %-46s (exit %s)\n' "$label" "$rc"; PASS=$((PASS + 1))
  else
    printf '  FAIL %-46s 기대 %s, 실제 %s\n' "$label" "$want" "$rc"; FAIL=$((FAIL + 1))
  fi
done

# --- 원복 리허설이 깨진 백업을 잡아내는가 -----------------------------------
echo
echo "원복 절차 결함 탐지"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
printf '#!/bin/bash\necho OLD\n' > "${sandbox}/client_gke.real"
chmod +x "${sandbox}/client_gke.real"
# 깨진 링크를 원본으로 둡니다 — 백업 단계에서 걸려야 합니다.
ln -s missing-target "${sandbox}/client_gke"
printf '#!/bin/bash\necho NEW\n' > "${sandbox}/client-gke-auto"
chmod +x "${sandbox}/client-gke-auto"

rc=0
( cd "$sandbox" && bash -c '
  set -e
  CANON=client_gke
  BACKUP=backup
  cp -a "$CANON" "$BACKUP"
  if [ -L "$BACKUP" ] && [ ! -e "$BACKUP" ]; then exit 1; fi
' ) || rc=$?
if [ "$rc" -eq 1 ]; then
  printf '  ok   %-46s (exit %s)\n' "깨진 심볼릭 링크 백업 탐지" "$rc"; PASS=$((PASS + 1))
else
  printf '  FAIL %-46s 기대 1, 실제 %s\n' "깨진 심볼릭 링크 백업 탐지" "$rc"; FAIL=$((FAIL + 1))
fi

echo
echo "통과 ${PASS} / 실패 ${FAIL}"
[ "$FAIL" -eq 0 ]
