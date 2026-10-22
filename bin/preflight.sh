#!/usr/bin/env bash
# 설정 검증 — 테스트를 돌리기 전에 config/env.sh 가 채워졌는지 확인합니다.
# __CONFIRM__ 이 남아 있으면 실행계획서 2장 "확정 필요 항목"이 미해결이라는 뜻입니다.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENV_FILE="${REPO_ROOT}/config/env.sh"

# mock 모드는 설정 없이도 돌아야 합니다 — 하네스 자체를 검증하는 모드이므로
# 예시 파일을 그대로 씁니다. GCP 에 접속하지 않으므로 안전합니다.
if [ ! -f "$ENV_FILE" ] && [ "${MODE:-mock}" = "mock" ]; then
  ENV_FILE="${REPO_ROOT}/config/env.example.sh"
fi

if [ ! -f "$ENV_FILE" ]; then
  cat >&2 <<MSG
config/env.sh 가 없습니다.

  cp config/env.example.sh config/env.sh
  vi config/env.sh
  chmod 600 config/env.sh

MODE=mock 으로는 설정 없이도 하네스 자체를 검증할 수 있습니다:
  make test-mock
MSG
  exit 2
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

MODE="${MODE:-mock}"
echo "MODE=$MODE"

# mock 은 설정 없이 돌아갑니다.
if [ "$MODE" = "mock" ]; then
  echo "mock 모드: 설정 검증을 건너뜁니다 (GCP 에 접속하지 않음)"
  exit 0
fi

unresolved=()
while IFS= read -r line; do
  var="${line%%=*}"
  unresolved+=("$var")
done < <(grep -E "^export [A-Z_]+='__CONFIRM__'" "$ENV_FILE" | sed 's/^export //')

if [ "${#unresolved[@]}" -gt 0 ]; then
  echo "미확정 항목이 ${#unresolved[@]}건 남아 있습니다:" >&2
  printf '  %s\n' "${unresolved[@]}" >&2
  echo >&2
  echo "실행계획서 2장 '확정 필요 항목'을 운영 담당자와 확인한 뒤 채우십시오." >&2
  exit 2
fi

# 권한 — SA 관련 값이 들어가므로 600 을 권장합니다.
perm="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
if [ "$perm" != "600" ]; then
  echo "경고: config/env.sh 권한이 $perm 입니다. chmod 600 을 권장합니다." >&2
fi

echo "설정 검증 통과"

# live 모드는 한 번 더 확인합니다.
if [ "$MODE" = "live" ] && [ "${I_UNDERSTAND_THIS_TOUCHES_PROD:-}" != "yes" ]; then
  echo >&2
  echo "MODE=live 는 실제 Pod/PV/PVC 를 생성합니다." >&2
  echo "I_UNDERSTAND_THIS_TOUCHES_PROD=yes 를 함께 지정하십시오." >&2
  exit 2
fi
