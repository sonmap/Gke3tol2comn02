#!/usr/bin/env bash
# 추가 테스트 ⑨ — 업무 SQL 전수 dry run  [계획서에 없던 항목]
#
# 단위테스트 ④ 는 SELECT 1 만 돌립니다. 실제 배치는 DML 과 업무 SQL 을 돌리므로
# 지금 설계대로면 쓰기 권한의 첫 검증이 P-06 본 배치이고, 거기서 실패하면
# 운영 데이터가 중간 상태로 남습니다.
#
# BigQuery dry run 은 쿼리를 실행하지 않고 권한·구문·대상 테이블·예상 처리량만
# 확인하며 비용이 0 입니다. 30개 과제 SQL 을 전부 걸어두면 권한 누락 과제를
# 전환 전에 전수로 걸러낼 수 있습니다. 비용 대비 효과가 가장 큰 항목입니다.
#
# 사용법:
#   sql/ 디렉터리에 <과제ID>.sql 로 배치한 뒤 실행
#   tests/t09_sql_dryrun.sh              # 전체
#   tests/t09_sql_dryrun.sh GP_L2ZC24_003_3   # 특정 과제만

TEST_ID=t09
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

need_cmd jq
need_var BQ_JOB_PROJECT

SQL_DIR="${SQL_DIR:-${REPO_ROOT}/sql}"
FILTER="${1:-}"

if [ ! -d "$SQL_DIR" ]; then
  skip "SQL 디렉터리가 없습니다: ${SQL_DIR} (업무 SQL 을 <과제ID>.sql 로 배치하십시오)"
fi

mapfile -t files < <(find "$SQL_DIR" -maxdepth 1 -name '*.sql' | sort)
if [ "${#files[@]}" -eq 0 ]; then
  skip "SQL 파일이 없습니다: ${SQL_DIR}/*.sql"
fi

REPORT="${EVIDENCE_DIR}/${RUN_ID}.sql-dryrun.jsonl"
mkdir -p "$EVIDENCE_DIR"
: > "$REPORT"

if [ "$MODE" = "mock" ]; then
  # mock 에서는 구문 수준만 봅니다 — 빈 파일, DML 혼입 여부.
  info "mock 모드: SQL 정적 검사만 수행합니다"
fi

total=0; passed=0; failed=0; warned=0

for f in "${files[@]}"; do
  task="$(basename "$f" .sql)"
  [ -n "$FILTER" ] && [ "$task" != "$FILTER" ] && continue
  total=$((total + 1))

  sql="$(cat "$f")"
  if [ -z "${sql//[[:space:]]/}" ]; then
    ng "${task}: 빈 파일"
    failed=$((failed + 1))
    jq -cn --arg t "$task" '{task:$t, result:"FAIL", reason:"empty"}' >> "$REPORT"
    continue
  fi

  # --- 쓰기 구문 식별 ------------------------------------------------------
  # dry run 은 DML 도 검증해 주지만, 어떤 과제가 쓰기를 하는지 미리 알아야
  # 전환 중 사고 시 영향 범위를 판단할 수 있습니다.
  writes=""
  if printf '%s' "$sql" | grep -qiE '^[[:space:]]*(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|DROP|ALTER)'; then
    writes="$(printf '%s' "$sql" | grep -ioE '^[[:space:]]*(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|CREATE|DROP|ALTER)' \
      | tr -d ' \t' | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ',' | sed 's/,$//')"
  fi

  if [ "$MODE" = "mock" ]; then
    ok "${task}: 구문 OK${writes:+ (쓰기: $writes)}"
    passed=$((passed + 1))
    jq -cn --arg t "$task" --arg w "$writes" \
      '{task:$t, result:"PASS", mode:"mock", write_ops:$w}' >> "$REPORT"
    continue
  fi

  need_cmd bq
  out=""; rc=0
  out="$(bq --project_id="$BQ_JOB_PROJECT" query \
          --dry_run --use_legacy_sql=false "$sql" 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    bytes="$(printf '%s' "$out" | grep -oE '[0-9]+ bytes' | head -1 | grep -oE '[0-9]+' || echo 0)"
    if [ -n "$writes" ]; then
      warn "${task}: 통과 (쓰기 구문 ${writes}, 예상 ${bytes} bytes)"
      warned=$((warned + 1))
    else
      ok "${task}: 통과 (읽기 전용, 예상 ${bytes} bytes)"
    fi
    passed=$((passed + 1))
    jq -cn --arg t "$task" --arg w "$writes" --argjson b "${bytes:-0}" \
      '{task:$t, result:"PASS", write_ops:$w, bytes_processed:$b}' >> "$REPORT"
  else
    code="$(classify_error "$out")"
    ng "${task}: 실패 ($(exit_name "$code"))"
    printf '%s\n' "$out" | mask_secrets | head -3 | sed 's/^/      /' >&2
    failed=$((failed + 1))
    jq -cn --arg t "$task" --arg r "$(exit_name "$code")" \
           --arg m "$(printf '%s' "$out" | head -1)" \
      '{task:$t, result:"FAIL", reason:$r, message:$m}' >> "$REPORT"
  fi
done

evidence_fact sql_total "$total"
evidence_fact sql_passed "$passed"
evidence_fact sql_failed "$failed"
evidence_fact sql_with_writes "$warned"
evidence_fact sql_report "$REPORT"

info "결과: 총 ${total} / 통과 ${passed} / 실패 ${failed} / 쓰기포함 ${warned}"
info "상세: $REPORT"

if [ "$warned" -gt 0 ]; then
  warn "쓰기 구문을 포함한 과제가 ${warned}건 있습니다."
  warn "전환 중 중단 시 중간 상태가 남을 수 있으므로 해당 과제는 Wave 후순위로 두십시오."
fi

[ "$failed" -eq 0 ] || die "$EXIT_FAIL" "${failed}개 과제의 SQL 이 dry run 을 통과하지 못했습니다"

pass "업무 SQL dry run 전수 통과 (${passed}/${total})"
