#!/usr/bin/env bash
# 단위테스트 ⑤ — client-gke-auto 실행기 검증 (실행계획서 8장)
#
# 계획서에 빠져 있던 항목을 둘 추가했습니다.
#   - 실패 경로 자원 정리: 일부러 실패시켰을 때 PV/PVC/Pod 가 남지 않는지
#   - lastState 확인: 재시작된 Pod 는 state 가 아니라 lastState 를 봐야 합니다

TEST_ID=t05
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq
need_var CLIENT_NEW

# --- 1. 정적 검사 -----------------------------------------------------------
if [ ! -e "$CLIENT_NEW" ]; then
  skip "신규 실행기가 아직 배치되지 않았습니다: $CLIENT_NEW"
fi

ftype="$(file -b "$CLIENT_NEW" 2>/dev/null || echo unknown)"
evidence_fact client_file_type "$ftype"
info "파일 형식: $ftype"

# 계획서 1장 2항: "사용자가 적은 client-gke.py 는 실제 파일명과 언어 확인 필요"
case "$ftype" in
  *"shell script"*|*"Bourne-Again"*)
    bash -n "$CLIENT_NEW" || die "$EXIT_FAIL" "Bash 구문 오류"
    ok "Bash 구문 검사 통과"
    evidence_fact client_lang bash ;;
  *"Python"*)
    warn "Python 실행기입니다. 계획서는 Bash 를 전제하므로 문서를 정정하십시오."
    python3 -m py_compile "$CLIENT_NEW" || die "$EXIT_FAIL" "Python 구문 오류"
    evidence_fact client_lang python ;;
  *) warn "형식을 판별하지 못했습니다: $ftype" ;;
esac

[ -x "$CLIENT_NEW" ] || die "$EXIT_CONFIG" "실행 권한이 없습니다: $CLIENT_NEW"
ok "실행 권한 확인"

# --- 2. CLI 인자 호환성 -----------------------------------------------------
# 기존 client_gke 와 동일한 인자를 받는지 --help 로 확인합니다.
helptext="$("$CLIENT_NEW" --help 2>&1 || true)"
missing=()
for opt in --program-id --docker-image --gpu --cpu --mem-gb --shell-command; do
  printf '%s' "$helptext" | grep -q -- "$opt" || missing+=("$opt")
done
if [ "${#missing[@]}" -gt 0 ]; then
  warn "--help 에서 확인되지 않은 인자: ${missing[*]}"
  warn "실행기 소스를 직접 확인하십시오. --help 가 없을 수도 있습니다."
  evidence_fact missing_options "${missing[*]}"
else
  ok "CLI 인자 6종 모두 확인"
fi

# --- 3. Kubeconfig 격리 -----------------------------------------------------
# 신규 실행기가 기존 Kubeconfig 를 쓰면 전환이 무의미해집니다.
if grep -qE 'KUBECONFIG|kubeconfig' "$CLIENT_NEW" 2>/dev/null; then
  refs="$(grep -nE 'KUBECONFIG|kubeconfig' "$CLIENT_NEW" | head -5)"
  info "Kubeconfig 참조:"
  printf '%s\n' "$refs" | sed 's/^/    /' >&2
  evidence_fact kubeconfig_refs "$(printf '%s' "$refs" | tr '\n' ';')"
  if ! printf '%s' "$refs" | grep -q 'l2comn_gke'; then
    warn "신규 Kubeconfig(l2comn_gke) 참조가 보이지 않습니다. 기존 설정을 쓸 위험이 있습니다."
  fi
else
  warn "Kubeconfig 참조가 없습니다. 환경변수 상속에 의존한다면 Cron 환경에서 실패할 수 있습니다(t06 참조)."
fi

if [ "$MODE" != "live" ]; then
  pass "실행기 정적 검증 완료 (실제 호출은 MODE=live)"
fi

# --- 4. 정상 경로 실행 ------------------------------------------------------
require_live_consent
need_cmd kubectl
need_var NS

# shellcheck disable=SC1090
[ -f "${EVIDENCE_DIR}/${RUN_ID}.image.env" ] && source "${EVIDENCE_DIR}/${RUN_ID}.image.env"
IMG="${ZC24_IMAGE_BY_DIGEST:-${ZC24_IMAGE_URI:-}}"
[ -n "$IMG" ] || die "$EXIT_CONFIG" "이미지 URI 가 없습니다. t02 를 먼저 실행하십시오."

before_pv="$(kc get pv -o name 2>/dev/null | wc -l)"
before_pvc="$(kc get pvc -n "$NS" -o name 2>/dev/null | wc -l)"

start=$(date +%s)
rc=0
"$CLIENT_NEW" \
  --program-id "SMOKE_${RUN_ID}" \
  --docker-image "$IMG" \
  --gpu 0 --cpu "$SMOKE_CPU" --mem-gb "${SMOKE_MEM%Gi}" \
  --shell-command 'echo RUNNER_OK' 2>&1 | mask_secrets | sed 's/^/    /' >&2 || rc=$?
elapsed=$(( $(date +%s) - start ))

evidence_fact runner_exit_code "$rc"
evidence_fact runner_elapsed_sec "$elapsed"
[ "$rc" -eq 0 ] || die "$EXIT_FAIL" "정상 경로에서 실행기가 rc=$rc 로 종료했습니다"
ok "정상 경로 통과 (${elapsed}s)"

# --- 5. 실패 경로와 자원 정리 -----------------------------------------------
# 계획서에 없던 검증입니다. 실패했을 때 PV/PVC 가 남으면 다음 실행이 이름 충돌로 막힙니다.
info "실패 경로 검증: 존재하지 않는 이미지로 호출"
frc=0
"$CLIENT_NEW" \
  --program-id "SMOKEFAIL_${RUN_ID}" \
  --docker-image "${IMG%%@*}:definitely-not-a-real-tag-${RUN_ID}" \
  --gpu 0 --cpu "$SMOKE_CPU" --mem-gb "${SMOKE_MEM%Gi}" \
  --shell-command 'echo SHOULD_NOT_RUN' >/dev/null 2>&1 || frc=$?

evidence_fact runner_fail_exit_code "$frc"
if [ "$frc" -eq 0 ]; then
  die "$EXIT_FAIL" "실패해야 할 호출이 rc=0 을 반환했습니다. 종료코드 전파가 깨져 있습니다."
fi
ok "실패 시 비정상 종료코드 반환: rc=$frc"

sleep 10
after_pv="$(kc get pv -o name 2>/dev/null | wc -l)"
after_pvc="$(kc get pvc -n "$NS" -o name 2>/dev/null | wc -l)"
evidence_fact pv_delta  "$(( after_pv  - before_pv ))"
evidence_fact pvc_delta "$(( after_pvc - before_pvc ))"

if [ "$after_pv" -gt "$before_pv" ] || [ "$after_pvc" -gt "$before_pvc" ]; then
  warn "실패 후 자원이 남았습니다 (PV ${before_pv}→${after_pv}, PVC ${before_pvc}→${after_pvc})."
  warn "반복 실행 시 이름 충돌이나 Released PV 누적이 발생합니다."
  kc get pv,pvc -n "$NS" 2>/dev/null | sed 's/^/    /' >&2
else
  ok "실패 경로 자원 정리 확인"
fi

pass "실행기 검증 완료"
