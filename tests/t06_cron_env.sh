#!/usr/bin/env bash
# 추가 테스트 ⑥ — Cron 실행 환경 검증  [계획서에 없던 항목]
#
# 가장 흔하게 터지는 지점입니다. get-credentials 가 만드는 kubeconfig 는
# gke-gcloud-auth-plugin 을 exec 로 호출하는데, cron 은 PATH 가 /usr/bin:/bin
# 수준이라 플러그인도 gcloud 도 찾지 못합니다.
# 대화형 테스트는 전부 통과하고 cron 만 실패합니다.
#
# 이 테스트가 D-5 로 앞당겨져야 하는 이유: 여기서 막히면 나머지 일정이 전부 밀립니다.

TEST_ID=t06
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq
need_var KUBECONFIG NS

fail_count=0

# --- 1. kubeconfig 가 exec 플러그인에 의존하는가 ----------------------------
if [ ! -f "$KUBECONFIG" ]; then
  skip "Kubeconfig 가 아직 없습니다. t01 을 먼저 실행하십시오: $KUBECONFIG"
fi

if grep -q 'exec:' "$KUBECONFIG" 2>/dev/null; then
  plugin="$(grep -A3 'exec:' "$KUBECONFIG" | sed -n 's/.*command:[[:space:]]*//p' | head -1)"
  evidence_fact auth_plugin "$plugin"
  info "Kubeconfig 가 exec 인증 플러그인을 사용합니다: $plugin"

  plugin_path="$(command -v "$plugin" 2>/dev/null || echo '')"
  if [ -z "$plugin_path" ]; then
    if [ "$MODE" = "mock" ]; then
      info "mock 모드이므로 플러그인 부재는 실패로 보지 않습니다: $plugin"
    else
      ng "플러그인을 PATH 에서 찾을 수 없습니다: $plugin"
      ng "  설치: gcloud components install gke-gcloud-auth-plugin"
      fail_count=$((fail_count + 1))
    fi
  else
    ok "플러그인 위치: $plugin_path"
    evidence_fact auth_plugin_path "$plugin_path"
    # cron 의 기본 PATH 에 들어 있는지가 핵심입니다.
    case "$plugin_path" in
      /usr/bin/*|/bin/*) ok "cron 기본 PATH 안에 있습니다" ;;
      *)
        warn "cron 기본 PATH(/usr/bin:/bin) 밖입니다: $plugin_path"
        warn "run-gke.sh 또는 crontab 에 PATH 를 명시해야 합니다."
        evidence_fact plugin_outside_cron_path "$plugin_path" ;;
    esac
  fi
else
  info "exec 플러그인을 쓰지 않습니다 (정적 토큰 또는 다른 방식)."
  evidence_fact auth_plugin none
fi

# --- 2. cron 과 동일한 최소 환경으로 재현 -----------------------------------
# 이것이 이 테스트의 핵심입니다. 대화형 셸의 PATH·환경변수를 전부 걷어내고
# cron 이 주는 것만으로 kubectl 이 동작하는지 확인합니다.
CRON_PATH=/usr/bin:/bin
# mock 모드에서는 가짜 CLI 가 fixtures/mockbin 에 있으므로 거기까지 포함합니다.
# 운영에서는 순수한 /usr/bin:/bin 으로만 재현해야 의미가 있습니다.
[ "$MODE" = "mock" ] && CRON_PATH="${REPO_ROOT}/fixtures/mockbin:${CRON_PATH}"

info "cron 최소 환경 재현 중 (PATH=${CRON_PATH})"

cron_out=""; cron_rc=0
cron_out="$(env -i \
  HOME="$HOME" \
  PATH="$CRON_PATH" \
  KUBECONFIG="$KUBECONFIG" \
  /bin/sh -c "kubectl get ns ${NS}" 2>&1)" || cron_rc=$?

printf '%s\n' "$cron_out" | mask_secrets | sed 's/^/    /' >&2
evidence_fact cron_env_exit_code "$cron_rc"

if [ "$cron_rc" -ne 0 ]; then
  ng "cron 최소 환경에서 kubectl 이 실패했습니다 (rc=$cron_rc)"
  ng "대화형 셸에서는 통과하지만 실제 Cron 배치는 전부 실패합니다."
  ng "대응: run-gke.sh 상단에 PATH 와 CLOUDSDK 경로를 명시하거나,"
  ng "      crontab 에 PATH= 행을 추가하십시오."
  fail_count=$((fail_count + 1))
else
  ok "cron 최소 환경에서 kubectl 동작 확인"
fi

# --- 3. 실행 계정 일치 ------------------------------------------------------
# kubeconfig 의 HOME 과 cron 소유 계정이 다르면 파일을 못 읽습니다.
cur_user="$(id -un)"
evidence_fact current_user "$cur_user"
info "현재 계정: $cur_user, Kubeconfig: $KUBECONFIG"

if command -v crontab >/dev/null 2>&1; then
  if crontab -l >/dev/null 2>&1; then
    cron_refs="$(crontab -l 2>/dev/null | grep -cE 'run-gke|client_gke' || true)"
    evidence_fact crontab_matching_lines "$cron_refs"
    if [ "${cron_refs:-0}" -gt 0 ]; then
      ok "현재 계정 crontab 에 관련 항목 ${cron_refs}건"
      crontab -l 2>/dev/null | grep -E 'run-gke|client_gke' | sed 's/^/    /' >&2
    else
      warn "현재 계정 crontab 에 run-gke/client_gke 항목이 없습니다."
      warn "다른 계정이 Cron 을 소유한다면 그 계정으로 이 테스트를 다시 실행하십시오."
    fi
  else
    info "crontab 을 읽을 수 없습니다 (권한 또는 미설정)."
  fi
fi

# --- 4. 자격 증명 유효기간 --------------------------------------------------
# 23시 배치가 장시간 돌 때 토큰이 만료되면 중간에 끊깁니다.
if command -v gcloud >/dev/null 2>&1; then
  acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
  evidence_fact active_gcloud_account "$acct"
  if [ -n "$acct" ]; then
    ok "활성 gcloud 계정: $acct"
  else
    ng "활성 gcloud 계정이 없습니다. exec 플러그인이 토큰을 얻지 못합니다."
    fail_count=$((fail_count + 1))
  fi
fi

[ "$fail_count" -eq 0 ] || die "$EXIT_CONFIG" "Cron 환경 검증에서 ${fail_count}건 실패"

pass "Cron 실행 환경 검증 완료"
