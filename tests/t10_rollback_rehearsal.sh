#!/usr/bin/env bash
# 추가 테스트 ⑩ — 심볼릭 링크 절체·원복 리허설  [계획서에 없던 항목]
#
# 계획서 11장 절차는 정확합니다. 다만 실제로 해보지 않은 원복 절차는
# 장애 중에 처음 실행하게 됩니다.
#
# 이 테스트는 기본적으로 SANDBOX 에서 수행합니다. /ssw/dlk 구조를 임시
# 디렉터리에 복제해 절체 → 원복 → 재절체를 돌려보고 절차의 결함을 찾습니다.
# 운영 경로에서 하려면 ROLLBACK_TARGET=real 과 live 동의가 모두 필요합니다.
#
# 특히 확인하는 것: 원본이 심볼릭 링크였을 때 cp -a 가 링크를 링크로 보존하며,
# 링크 대상이 상대 경로였다면 복사 위치에 따라 깨질 수 있습니다.

TEST_ID=t10
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq

TARGET="${ROLLBACK_TARGET:-sandbox}"

if [ "$TARGET" = "real" ]; then
  require_mode live
  require_live_consent
  need_var CLIENT_DIR CLIENT_CANONICAL CLIENT_NEW
  DIR="$CLIENT_DIR"
  warn "운영 경로에서 리허설합니다: $DIR"
  warn "Cron 유입이 정지된 상태인지 반드시 확인하십시오."
else
  DIR="$(mktemp -d)"
  trap 'rm -rf "$DIR"' EXIT
  info "샌드박스 리허설: $DIR"

  # 운영 구조를 재현합니다. 원본을 '심볼릭 링크'로 만들어 둡니다 —
  # 계획서가 지적한 가장 까다로운 경우입니다.
  printf '#!/bin/bash\necho OLD_RUNNER "$@"\n' > "${DIR}/client_gke.real"
  chmod +x "${DIR}/client_gke.real"
  ln -s client_gke.real "${DIR}/client_gke"      # 상대 경로 링크
  printf '#!/bin/bash\necho NEW_RUNNER "$@"\n' > "${DIR}/client-gke-auto"
  chmod +x "${DIR}/client-gke-auto"
fi

CANON="${DIR}/client_gke"
NEW="${DIR}/client-gke-auto"

[ -e "$CANON" ] || die "$EXIT_CONFIG" "정식 실행 경로가 없습니다: $CANON"
[ -x "$NEW" ]   || die "$EXIT_CONFIG" "신규 실행기가 없거나 실행 권한이 없습니다: $NEW"

# --- 0. 원본 성격 파악 ------------------------------------------------------
if [ -L "$CANON" ]; then
  orig_target="$(readlink "$CANON")"
  orig_resolved="$(readlink -f "$CANON" || echo '')"
  info "원본은 심볼릭 링크입니다: $CANON -> $orig_target"
  evidence_fact original_is_symlink true
  evidence_fact original_link_target "$orig_target"
  case "$orig_target" in
    /*) info "  절대 경로 링크 — 백업 복사 후에도 안전" ;;
    *)  warn "  상대 경로 링크 — 백업을 다른 디렉터리로 옮기면 깨집니다" ;;
  esac
else
  orig_resolved="$CANON"
  info "원본은 일반 파일입니다"
  evidence_fact original_is_symlink false
fi
orig_sum="$(sha256sum "$orig_resolved" 2>/dev/null | cut -d' ' -f1 || echo '')"
orig_out="$("$CANON" --probe 2>&1 || true)"
evidence_fact original_output "$orig_out"

# --- 1. 사전 검사와 백업 (계획서 10.1) --------------------------------------
bash -n "$NEW" || die "$EXIT_FAIL" "신규 실행기 구문 오류"

BACKUP="${DIR}/client_gke.pre-autopilot.$(date +%Y%m%d%H%M%S)"
cp -a "$CANON" "$BACKUP"
evidence_fact backup_path "$BACKUP"
ok "백업 생성: $BACKUP"

# 백업이 링크라면 대상이 유효한지 즉시 확인합니다 (검토에서 지적한 항목).
if [ -L "$BACKUP" ]; then
  if [ -e "$BACKUP" ]; then
    ok "백업 링크의 대상이 유효합니다: $(readlink -f "$BACKUP")"
  else
    die "$EXIT_FAIL" "백업이 깨진 링크입니다: $BACKUP -> $(readlink "$BACKUP")"
  fi
fi

# --- 2. 절체 (계획서 10.2) --------------------------------------------------
NEXT="${DIR}/.client_gke.next.$$"
ln -s "$NEW" "$NEXT"
mv -Tf "$NEXT" "$CANON"          # 같은 파일시스템 내 원자적 교체

after_out="$("$CANON" --probe 2>&1 || true)"
evidence_fact after_cutover_output "$after_out"
info "절체 후: $CANON -> $(readlink -f "$CANON")"

if [ "$after_out" = "$orig_out" ]; then
  die "$EXIT_FAIL" "절체했는데 출력이 그대로입니다. 링크가 바뀌지 않았습니다."
fi
ok "절체 확인 — 신규 실행기로 전환됨"

# --- 3. 원복 (계획서 11.2) --------------------------------------------------
RESTORE="${DIR}/.client_gke.restore.$$"
test -e "$BACKUP" || test -L "$BACKUP" || die "$EXIT_FAIL" "백업을 찾을 수 없습니다"
cp -a "$BACKUP" "$RESTORE"
mv -Tf "$RESTORE" "$CANON"

restored_out="$("$CANON" --probe 2>&1 || true)"
restored_resolved="$(readlink -f "$CANON" || echo '')"
restored_sum="$(sha256sum "$restored_resolved" 2>/dev/null | cut -d' ' -f1 || echo '')"
evidence_fact restored_output "$restored_out"

if [ "$restored_out" != "$orig_out" ]; then
  ng "원복 후 출력이 원본과 다릅니다."
  ng "  원본: $orig_out"
  ng "  원복: $restored_out"
  die "$EXIT_FAIL" "원복 절차에 결함이 있습니다"
fi
ok "원복 확인 — 출력 일치"

if [ -n "$orig_sum" ] && [ "$orig_sum" != "$restored_sum" ]; then
  warn "실행 결과는 같지만 최종 대상 파일의 해시가 다릅니다."
  warn "  원본 대상: $orig_resolved"
  warn "  원복 대상: $restored_resolved"
else
  ok "최종 대상 파일 동일"
fi

# --- 4. 재절체 (원복 후에도 다시 전환할 수 있는가) ---------------------------
NEXT2="${DIR}/.client_gke.next2.$$"
ln -s "$NEW" "$NEXT2"
mv -Tf "$NEXT2" "$CANON"
again_out="$("$CANON" --probe 2>&1 || true)"
[ "$again_out" = "$after_out" ] || die "$EXIT_FAIL" "재절체가 처음 절체와 다르게 동작합니다"
ok "재절체 확인"

# 샌드박스는 원래 상태로 되돌려 둡니다.
cp -a "$BACKUP" "${DIR}/.final.$$" && mv -Tf "${DIR}/.final.$$" "$CANON"

# --- 5. Wave 라우터 검증 (선택) ---------------------------------------------
# 계획서 10.3 의 모순 — symlink 를 한 번 바꾸면 Wave 구분이 무의미해지는 문제 —
# 에 대한 구조적 해법입니다. 라우터가 배치되어 있으면 양쪽 분기를 검증합니다.
if [ -x "${REPO_ROOT}/bin/client-gke-router" ]; then
  info "Wave 라우터 분기 검증"
  ALLOW="${DIR}/autopilot_allow.txt"
  printf 'GP_L2ZC24_003_3\n' > "$ALLOW"

  r_allowed="$(ALLOW_LIST="$ALLOW" CLIENT_NEW="$NEW" CLIENT_OLD="${DIR}/client_gke.real" \
    "${REPO_ROOT}/bin/client-gke-router" --program-id GP_L2ZC24_003_3 --probe 2>&1 || true)"
  r_other="$(ALLOW_LIST="$ALLOW" CLIENT_NEW="$NEW" CLIENT_OLD="${DIR}/client_gke.real" \
    "${REPO_ROOT}/bin/client-gke-router" --program-id GP_L2EM22_002_11 --probe 2>&1 || true)"

  evidence_fact router_allowed_output "$r_allowed"
  evidence_fact router_other_output "$r_other"

  printf '%s' "$r_allowed" | grep -q NEW_RUNNER \
    || die "$EXIT_FAIL" "허용 목록 과제가 신규로 라우팅되지 않았습니다: $r_allowed"
  printf '%s' "$r_other" | grep -q OLD_RUNNER \
    || die "$EXIT_FAIL" "미허용 과제가 기존으로 라우팅되지 않았습니다: $r_other"
  ok "라우터 분기 정상 (허용→신규, 미허용→기존)"
fi

pass "절체·원복 리허설 완료 (target=${TARGET})"
