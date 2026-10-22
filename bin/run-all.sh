#!/usr/bin/env bash
# 전체 테스트 실행기
#
#   bin/run-all.sh                 # config/env.sh 의 MODE 로 전체
#   MODE=mock bin/run-all.sh       # 하네스 자체 검증 (GCP 접속 없음)
#   MODE=dryrun bin/run-all.sh     # 운영 클러스터에 조회·dry-run 만
#   bin/run-all.sh t01 t06         # 특정 테스트만
#
# 각 테스트는 독립 프로세스로 돌며 실패해도 다음으로 넘어갑니다.
# 전체 결과는 evidence/<RUN_ID>.jsonl 에 한 줄씩 쌓입니다.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export MODE="${MODE:-mock}"
if [ -f config/env.sh ]; then
  . config/env.sh
elif [ "$MODE" = "mock" ]; then
  . config/env.example.sh      # mock 은 설정 없이도 하네스를 검증합니다
fi
export RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
export EVIDENCE_DIR="${EVIDENCE_DIR:-${REPO_ROOT}/evidence}"
export REPO_ROOT

bin/preflight.sh || exit $?

mkdir -p "$EVIDENCE_DIR"

if [ "$#" -gt 0 ]; then
  files=()
  for t in "$@"; do
    f="$(find tests -maxdepth 1 -name "${t}*.sh" | head -1)"
    [ -n "$f" ] && files+=("$f") || echo "테스트를 찾을 수 없습니다: $t" >&2
  done
else
  mapfile -t files < <(find tests -maxdepth 1 -name 't*.sh' | sort)
fi

echo "================================================================"
echo " 사전검증 테스트   MODE=${MODE}  RUN_ID=${RUN_ID}"
echo "================================================================"

declare -a results=()
worst=0

for f in "${files[@]}"; do
  name="$(basename "$f" .sh)"
  echo
  echo "---- ${name} ----"
  rc=0
  bash "$f" || rc=$?
  results+=("${rc}:${name}")
  # SKIP(77) 은 실패로 치지 않습니다.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 77 ] && [ "$rc" -gt "$worst" ]; then
    worst="$rc"
  fi
done

echo
echo "================================================================"
echo " 결과 요약"
echo "================================================================"
pass_n=0; fail_n=0; skip_n=0
for r in "${results[@]}"; do
  rc="${r%%:*}"; name="${r#*:}"
  case "$rc" in
    0)  printf '  PASS   %s\n' "$name"; pass_n=$((pass_n+1)) ;;
    77) printf '  SKIP   %s\n' "$name"; skip_n=$((skip_n+1)) ;;
    2)  printf '  CONFIG %s\n' "$name"; fail_n=$((fail_n+1)) ;;
    3)  printf '  PERM   %s\n' "$name"; fail_n=$((fail_n+1)) ;;
    4)  printf '  NOTFND %s\n' "$name"; fail_n=$((fail_n+1)) ;;
    5)  printf '  NET    %s\n' "$name"; fail_n=$((fail_n+1)) ;;
    6)  printf '  ADMSSN %s\n' "$name"; fail_n=$((fail_n+1)) ;;
    *)  printf '  FAIL   %s (rc=%s)\n' "$name" "$rc"; fail_n=$((fail_n+1)) ;;
  esac
done
echo
echo "  통과 ${pass_n} / 실패 ${fail_n} / 건너뜀 ${skip_n}"
echo "  증적: ${EVIDENCE_DIR}/${RUN_ID}.jsonl"
echo

exit "$worst"
