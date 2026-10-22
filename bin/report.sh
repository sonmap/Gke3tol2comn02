#!/usr/bin/env bash
# 증적 집계 — evidence/*.jsonl 을 읽어 판정표를 만듭니다.
#
#   bin/report.sh                 # 최신 실행
#   bin/report.sh 20261022-1430   # 특정 RUN_ID
#   bin/report.sh --all           # 전체 실행 이력
#   bin/report.sh --md            # 마크다운 표 (보고용)
#
# 실행계획서 12장 '증적 관리' 의 수집 항목을 자동으로 채웁니다.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-${REPO_ROOT}/evidence}"

FORMAT=table
TARGET=""
for a in "$@"; do
  case "$a" in
    --md)  FORMAT=md ;;
    --all) TARGET=all ;;
    *)     TARGET="$a" ;;
  esac
done

if [ "$TARGET" = "all" ]; then
  mapfile -t files < <(find "$EVIDENCE_DIR" -name '*.jsonl' ! -name '*.sql-dryrun.jsonl' | sort)
elif [ -n "$TARGET" ]; then
  files=("${EVIDENCE_DIR}/${TARGET}.jsonl")
else
  latest="$(find "$EVIDENCE_DIR" -name '*.jsonl' ! -name '*.sql-dryrun.jsonl' \
            -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [ -n "$latest" ] || { echo "증적이 없습니다: $EVIDENCE_DIR" >&2; exit 1; }
  files=("$latest")
fi

for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "파일 없음: $f" >&2; continue; }
done

if [ "$FORMAT" = "md" ]; then
  echo "## 사전검증 테스트 결과"
  echo
  echo "| 테스트 | 모드 | 결과 | 시각 | 비고 |"
  echo "|---|---|---|---|---|"
  jq -r '"| \(.test_id) | \(.mode) | \(.result) | \(.ts) | \(.message // "") |"' "${files[@]}"
  echo
  echo "### 수집된 사실"
  echo
  echo '| 테스트 | 항목 | 값 |'
  echo '|---|---|---|'
  jq -r '.test_id as $t | .facts | to_entries[] | "| \($t) | \(.key) | \(.value) |"' "${files[@]}"
else
  printf '%-6s %-8s %-10s %-22s %s\n' 테스트 모드 결과 시각 메시지
  printf '%s\n' "------------------------------------------------------------------------"
  jq -r '[.test_id, .mode, .result, .ts, (.message // "")] | @tsv' "${files[@]}" \
    | while IFS=$'\t' read -r t m r ts msg; do
        printf '%-6s %-8s %-10s %-22s %s\n' "$t" "$m" "$r" "$ts" "$msg"
      done
  echo
  echo "수집된 사실:"
  jq -r '.test_id as $t | .facts | to_entries[] | "  \($t)  \(.key) = \(.value)"' "${files[@]}"
fi

# --- Go / No-Go 판정 --------------------------------------------------------
echo
total="$(jq -s 'length' "${files[@]}")"
passed="$(jq -s '[.[]|select(.result=="OK")]|length' "${files[@]}")"
skipped="$(jq -s '[.[]|select(.result=="SKIP")]|length' "${files[@]}")"
failed="$(jq -s '[.[]|select(.result!="OK" and .result!="SKIP")]|length' "${files[@]}")"

echo "총 ${total} / 통과 ${passed} / 실패 ${failed} / 건너뜀 ${skipped}"

if [ "$failed" -gt 0 ]; then
  echo
  echo "실패 항목:"
  jq -r 'select(.result!="OK" and .result!="SKIP")
         | "  \(.test_id)  \(.result)  \(.message)"' "${files[@]}"
fi

# admission 거절은 설계 변경을 뜻하므로 따로 강조합니다.
if jq -e -s 'any(.[]; .result=="ADMISSION")' "${files[@]}" >/dev/null 2>&1; then
  echo
  echo "주의: Autopilot admission 거절이 있습니다."
  echo "      PV/Pod 설계 변경이 필요하며 사업 범위 1항(변경 최소화)과 충돌합니다."
fi

[ "$failed" -eq 0 ]
