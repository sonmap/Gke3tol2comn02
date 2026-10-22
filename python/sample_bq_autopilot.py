#!/usr/bin/env python3
"""GKE Autopilot 전환 사전검증 — BigQuery 읽기 전용 스모크 테스트.

인증: 명시적으로 마운트한 서비스 계정 JSON 키(기본 .oefj).
기본 동작은 지정한 테스트 테이블에 대한 제한된 읽기 전용 SELECT 뿐입니다.
키 원문, 토큰, 업무 데이터 값은 로그에 남기지 않습니다.

원본 대비 변경점
----------------
1. 실패 유형별 종료코드 분리
   실행계획서 7장이 "PermissionDenied / NotFound / DNS-TLS / 키 경로를 유형별
   분리"하라고 요구하는데 원본은 전부 1로 수렴했습니다. 30개 과제를 전환할 때
   로그를 일일이 읽지 않고 분류하려면 코드가 달라야 합니다.

2. 키 파일 권한 점검
   평문 SA 키를 NFS에 두는 구조라 group/other 읽기가 열려 있으면 경고합니다.

3. 키 경로 후보 진단
   .oef 와 .oefj 혼동(계획서 14장 위험 항목)을 한 번에 드러냅니다.

4. [RESULT] JSON 한 줄
   kubectl logs | tail -1 로 증적을 자동 수집할 수 있습니다.

5. dry run 모드
   BQ_DRY_RUN=1 이면 쿼리를 실행하지 않고 권한·구문·예상 처리량만 확인합니다.
   비용 0이므로 30개 과제 업무 SQL을 전환 전에 전수 점검할 수 있습니다.

환경변수
--------
  BQ_KEY_PATH       SA 키 경로 (기본 /var/run/bq-key/.oefj)
  BQ_JOB_PROJECT    Query Job 을 만들 프로젝트
  BQ_TEST_TABLE     대상 테이블 (project.dataset.table)
  BQ_LOCATION       데이터셋 리전. 비우면 자동
  BQ_DRY_RUN        1/true/yes 이면 실행 없이 검증만
  BQ_SQL_FILE       지정하면 그 파일의 업무 SQL 사용
  BQ_MAX_BYTES_BILLED  과금 상한 (기본 10 MiB)
"""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

# --- 종료 코드 (lib/common.sh 와 동일 규약) --------------------------------
EXIT_OK = 0
EXIT_QUERY = 1        # 쿼리 실패 / 예상과 다른 결과
EXIT_KEY_MISSING = 2  # 키 파일 없음 또는 읽을 수 없음
EXIT_PERM = 3         # 권한 거부
EXIT_NOTFOUND = 4     # 테이블·데이터셋·프로젝트 없음
EXIT_NETWORK = 5      # DNS / TLS / timeout

DEFAULT_KEY_PATH = "/var/run/bq-key/.oefj"

# .oef 와 .oefj 혼동을 가려내기 위한 후보 목록.
KEY_PATH_CANDIDATES = (
    "/var/run/bq-key/.oefj",
    "/var/run/bq-key/.oef",
    "/home/jupyter/.oefj",
    "/home/jupyter/.oef",
    "/mnt/batch_gke/l2/rsvp/.oefj",
)


def env_flag(name: str) -> bool:
    return os.getenv(name, "").strip().lower() in ("1", "true", "yes", "y")


def log(msg: str) -> None:
    print(msg, flush=True)


def err(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def emit_result(**fields) -> None:
    """증적 수집용 한 줄. kubectl logs | tail -1 로 집계합니다."""
    log("[RESULT] " + json.dumps(fields, ensure_ascii=False, sort_keys=True))


def diagnose_key_paths(expected: Path) -> None:
    """키를 못 찾았을 때 후보 경로의 존재 여부를 찍습니다.

    어떤 파일명이 실제로 있는지가 한 번에 드러나므로, .oef/.oefj 혼동과
    서브디렉터리 마운트 차이를 즉시 구분할 수 있습니다.
    """
    err(f"[FAIL] 서비스 계정 키 파일이 없습니다: {expected}")
    err("[DIAG] 후보 경로 점검:")
    for cand in KEY_PATH_CANDIDATES:
        p = Path(cand)
        if p.is_file():
            state = "존재"
        elif p.exists():
            state = "존재하나 파일이 아님"
        elif p.parent.is_dir():
            state = "없음 (상위 디렉터리는 있음)"
        else:
            state = "없음 (상위 디렉터리도 없음)"
        err(f"[DIAG]   {cand}: {state}")


def check_key_permissions(key_file: Path) -> str | None:
    """키 파일 권한을 점검해 과도하게 열려 있으면 경고 문자열을 돌려줍니다."""
    try:
        mode = key_file.stat().st_mode
    except OSError:
        return None
    octal = oct(stat.S_IMODE(mode))
    if mode & (stat.S_IRGRP | stat.S_IROTH):
        err(f"[WARN] 키 파일이 group/other 에 읽기 허용되어 있습니다: {octal}")
        err("[WARN] 여러 과제가 같은 키를 공유하는 구조라면 노출 범위를 확인하십시오.")
    return octal


def load_sql() -> tuple[str, str]:
    """실행할 SQL과 그 출처를 돌려줍니다."""
    sql_file = os.getenv("BQ_SQL_FILE", "").strip()
    if sql_file:
        return Path(sql_file).read_text(encoding="utf-8"), sql_file

    table = os.getenv("BQ_TEST_TABLE", "").strip()
    if not table:
        raise ValueError("BQ_TEST_TABLE 또는 BQ_SQL_FILE 중 하나는 지정해야 합니다")
    # 상수 1만 돌려받으므로 업무 데이터 값이 로그에 남지 않습니다.
    # 실제 테이블을 참조하므로 테이블 접근 권한은 그대로 검증됩니다.
    return f"SELECT 1 AS sample_ok FROM `{table}` LIMIT 1", f"table:{table}"


def classify(exc: BaseException) -> int:
    """예외를 종료코드로 환원합니다.

    google.api_core 가 없는 환경(단위 테스트)에서도 동작하도록
    클래스 이름과 메시지로 판정합니다.
    """
    name = type(exc).__name__
    text = f"{name}: {exc}"

    if name in ("Forbidden", "PermissionDenied") or "403" in text \
       or "PERMISSION_DENIED" in text or "Access Denied" in text:
        return EXIT_PERM
    if name in ("NotFound",) or "404" in text or "Not found" in text \
       or "NOT_FOUND" in text:
        return EXIT_NOTFOUND
    if name in ("RetryError", "ServiceUnavailable", "DeadlineExceeded") \
       or "timeout" in text.lower() or "TLS" in text \
       or "Name or service not known" in text or "getaddrinfo" in text:
        return EXIT_NETWORK
    return EXIT_QUERY


def run(client_factory=None) -> int:
    """본체. client_factory 를 주입하면 BigQuery 없이 단위 테스트할 수 있습니다."""
    key_path = Path(os.getenv("BQ_KEY_PATH", DEFAULT_KEY_PATH))
    job_project = os.getenv("BQ_JOB_PROJECT", "").strip()
    location = os.getenv("BQ_LOCATION", "").strip() or None
    dry_run = env_flag("BQ_DRY_RUN")
    max_bytes = int(os.getenv("BQ_MAX_BYTES_BILLED", str(10 * 1024 * 1024)))

    if not job_project:
        err("[FAIL] BQ_JOB_PROJECT 가 비어 있습니다")
        emit_result(ok=False, reason="missing_job_project")
        return EXIT_KEY_MISSING

    # --- 키 파일 ------------------------------------------------------------
    if not key_path.is_file():
        diagnose_key_paths(key_path)
        emit_result(ok=False, reason="key_missing", key_path=str(key_path))
        return EXIT_KEY_MISSING

    key_mode = check_key_permissions(key_path)

    # --- SQL ----------------------------------------------------------------
    try:
        sql, sql_source = load_sql()
    except Exception as exc:  # noqa: BLE001
        err(f"[FAIL] SQL 준비 실패: {type(exc).__name__}: {exc}")
        emit_result(ok=False, reason="sql_load_failed")
        return EXIT_QUERY

    client = None
    try:
        if client_factory is None:
            from google.cloud import bigquery  # noqa: PLC0415
            from google.oauth2 import service_account  # noqa: PLC0415

            credentials = service_account.Credentials.from_service_account_file(
                str(key_path),
                scopes=["https://www.googleapis.com/auth/cloud-platform"],
            )
            client = bigquery.Client(project=job_project, credentials=credentials)
            sa_email = credentials.service_account_email
            job_config = bigquery.QueryJobConfig(
                dry_run=dry_run,
                use_query_cache=False,
                # dry_run 과 maximum_bytes_billed 는 함께 쓸 수 없습니다.
                maximum_bytes_billed=None if dry_run else max_bytes,
            )
        else:
            client, sa_email, job_config = client_factory(
                key_path=key_path, project=job_project,
                dry_run=dry_run, max_bytes=max_bytes,
            )

        log("[INFO] BigQuery 읽기 전용 연결 테스트")
        log(f"[INFO] Job project : {job_project}")
        log(f"[INFO] SQL source  : {sql_source}")
        log(f"[INFO] Key path    : {key_path} (mode {key_mode})")
        log(f"[INFO] Service acct: {sa_email}")
        log(f"[INFO] Dry run     : {dry_run}")

        kwargs = {"job_config": job_config}
        if location:
            kwargs["location"] = location

        job = client.query(sql, **kwargs)

        # --- dry run: 실행하지 않고 여기서 끝 -------------------------------
        if dry_run:
            processed = getattr(job, "total_bytes_processed", None)
            log(f"[SUCCESS] dry run 통과 (예상 처리량 {processed} bytes)")
            emit_result(ok=True, dry_run=True, bytes_processed=processed,
                        sa_email=sa_email, sql_source=sql_source)
            return EXIT_OK

        # --- 실제 실행 -------------------------------------------------------
        rows = job.result(timeout=120)
        row = next(iter(rows), None)

        if row is None:
            log("[SUCCESS] BigQuery 연결/쿼리 성공 (대상 테이블에 행이 없음)")
        else:
            value = row["sample_ok"] if "sample_ok" in _row_keys(row) else None
            if value is not None and value != 1:
                err("[FAIL] 예상과 다른 결과")
                emit_result(ok=False, reason="unexpected_value")
                return EXIT_QUERY
            log("[SUCCESS] BigQuery 연결/쿼리 성공 (읽기 전용, 1행 확인)")

        job_id = getattr(job, "job_id", None)
        job_location = getattr(job, "location", None)
        billed = getattr(job, "total_bytes_billed", None)

        log(f"[INFO] Job ID      : {job_id}")
        log(f"[INFO] Location    : {job_location}")
        log(f"[INFO] Bytes billed: {billed}")

        emit_result(ok=True, dry_run=False, job_id=job_id,
                    location=job_location, bytes_billed=billed,
                    sa_email=sa_email, key_path=str(key_path),
                    sql_source=sql_source)
        return EXIT_OK

    except Exception as exc:  # noqa: BLE001
        code = classify(exc)
        err(f"[FAIL] BigQuery 실패: {type(exc).__name__}: {exc}")
        emit_result(ok=False, reason=type(exc).__name__, exit_code=code)
        return code
    finally:
        if client is not None and hasattr(client, "close"):
            try:
                client.close()
            except Exception:  # noqa: BLE001, S110
                pass


def _row_keys(row) -> tuple:
    """BigQuery Row 와 dict 양쪽을 지원합니다 (단위 테스트용)."""
    if hasattr(row, "keys"):
        return tuple(row.keys())
    return ()


def main() -> int:
    return run()


if __name__ == "__main__":
    sys.exit(main())
