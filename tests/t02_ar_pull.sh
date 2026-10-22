#!/usr/bin/env bash
# 단위테스트 ② — Edge Artifact Registry 이미지 Pull 검증 (실행계획서 5장)
#
# 태그만으로는 Pull 할 수 없습니다. 전체 URI 를 확정하고 digest 를 증적에 남깁니다.
# digest 를 남기는 이유: 같은 태그가 나중에 덮어써지면 "그때 무슨 이미지였나"를
# 추적할 수 없게 됩니다. 부록 A 30개 표의 digest 칸을 이 테스트가 채웁니다.

TEST_ID=t02
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd gcloud jq
need_var AR_PROJECT AR_LOCATION AR_REPO ZC24_TAG

AR_BASE="${AR_LOCATION}-docker.pkg.dev/${AR_PROJECT}/${AR_REPO}"
info "저장소: $AR_BASE"

# --- 1. 저장소 존재 확인 ----------------------------------------------------
# AR 은 "저장소 없음"과 "볼 권한 없음"을 같은 메시지로 돌려줍니다.
# list 로 먼저 확인해 두 경우를 구분합니다.
repos="$(run_classified "저장소 목록" -- \
  gcloud artifacts repositories list \
    --project="$AR_PROJECT" --location="$AR_LOCATION" \
    --format='value(name)')"

if ! printf '%s\n' "$repos" | grep -qx -- "$AR_REPO" \
   && ! printf '%s\n' "$repos" | grep -q "/${AR_REPO}\$"; then
  ng "저장소 '$AR_REPO' 가 목록에 없습니다. 확인된 저장소:"
  printf '%s\n' "$repos" | sed 's/^/    /' >&2
  die "$EXIT_NOTFOUND" "AR_REPO 값을 확인하십시오 (UI 태그 화면명을 저장소명으로 오인했을 수 있습니다)"
fi
ok "저장소 확인: $AR_REPO"

# --- 2. 이미지와 태그 목록 --------------------------------------------------
images="$(run_classified "이미지 목록" -- \
  gcloud artifacts docker images list "$AR_BASE" \
    --include-tags --format='value(package,version,tags)')"

# ZC24_IMAGE_URI 가 비어 있으면 태그로 역추적합니다.
if [ -z "${ZC24_IMAGE_URI:-}" ]; then
  pkg="$(printf '%s\n' "$images" | awk -v t="$ZC24_TAG" '$0 ~ t {print $1; exit}')"
  [ -n "$pkg" ] || die "$EXIT_NOTFOUND" "태그 $ZC24_TAG 를 가진 이미지를 찾지 못했습니다"
  ZC24_IMAGE_URI="${pkg}:${ZC24_TAG}"
  info "이미지 URI 자동 확정: $ZC24_IMAGE_URI"
fi
evidence_fact image_uri "$ZC24_IMAGE_URI"

# --- 3. digest 확정 ---------------------------------------------------------
dsc="$(run_classified "이미지 describe" -- \
  gcloud artifacts docker images describe "$ZC24_IMAGE_URI" --format='yaml')"
digest="$(printf '%s' "$dsc" | yq -r '.image_summary.digest // ""' 2>/dev/null || echo "")"
[ -n "$digest" ] || die "$EXIT_FAIL" "digest 를 확인하지 못했습니다"

evidence_fact image_digest "$digest"
ok "digest: $digest"

# 배포에는 태그가 아니라 digest 를 쓰는 편이 안전합니다.
IMAGE_BY_DIGEST="${ZC24_IMAGE_URI%%:*}@${digest}"
evidence_fact image_by_digest "$IMAGE_BY_DIGEST"
info "digest 고정 주소: $IMAGE_BY_DIGEST"

# 후속 테스트가 쓰도록 파일로 떨굽니다.
mkdir -p "$EVIDENCE_DIR"
printf 'ZC24_IMAGE_URI=%s\nZC24_IMAGE_DIGEST=%s\nZC24_IMAGE_BY_DIGEST=%s\n' \
  "$ZC24_IMAGE_URI" "$digest" "$IMAGE_BY_DIGEST" \
  > "${EVIDENCE_DIR}/${RUN_ID}.image.env"

# --- 4. 아키텍처 확인 -------------------------------------------------------
# 계획서에 빠져 있던 항목입니다. arm64 이미지를 amd64 노드에서 돌리면
# exec format error 로 실패합니다.
arch="$(printf '%s' "$dsc" | yq -r '.image_summary.architecture // ""' 2>/dev/null || echo "")"
if [ -n "$arch" ]; then
  evidence_fact image_architecture "$arch"
  case "$arch" in
    amd64|x86_64) ok "아키텍처: $arch" ;;
    *) warn "아키텍처가 $arch 입니다. GKE 노드와 일치하는지 확인하십시오." ;;
  esac
else
  info "describe 에 아키텍처 정보가 없습니다. 실제 Pull 이벤트로 확인됩니다."
fi

# --- 5. 실제 Pull (live 모드에서만) -----------------------------------------
if [ "$MODE" != "live" ]; then
  pass "AR 메타데이터 검증 완료 (실제 Pull 은 MODE=live 또는 t07 에서 수행)"
fi

require_live_consent
need_cmd kubectl
need_var NS KSA

POD="ar-pull-probe-${RUN_ID}"
cat <<YAML | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
spec:
  restartPolicy: Never
  serviceAccountName: ${KSA}
  activeDeadlineSeconds: 600
  containers:
    - name: probe
      image: ${IMAGE_BY_DIGEST}
      command: ["/bin/sh","-c","echo PULL_OK; uname -m"]
      resources:
        requests: {cpu: "250m", memory: "512Mi"}
        limits:   {cpu: "250m", memory: "512Mi"}
YAML

cleanup() { kc delete pod "$POD" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

deadline=$(( $(date +%s) + POD_TIMEOUT_SEC ))
while :; do
  phase="$(kc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
  case "$phase" in
    Succeeded) break ;;
    Failed)    die "$EXIT_FAIL" "Pull probe Pod 가 Failed 로 종료했습니다" ;;
  esac
  reason="$(kc get pod "$POD" -n "$NS" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo '')"
  case "$reason" in
    ImagePullBackOff|ErrImagePull)
      evidence_fact pull_failure_reason "$reason"
      die "$EXIT_PERM" "$reason — 이미지 경로, Node SA 의 artifactregistry.reader, 네트워크를 구분해 확인하십시오" ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || die "$EXIT_NETWORK" "Pull probe 타임아웃 (${POD_TIMEOUT_SEC}s)"
  sleep 5
done

pulled="$(kc get pod "$POD" -n "$NS" \
  -o jsonpath='{.status.containerStatuses[0].imageID}' 2>/dev/null || echo '')"
evidence_fact pulled_image_id "$pulled"
ok "실제 Pull 성공: $pulled"

pass "AR Pull 검증 완료"
