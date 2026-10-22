#!/usr/bin/env python3
"""pytest 없이 돌아가는 셀프테스트.

운영 VM 이나 폐쇄망 CI 에 pytest 가 없을 수 있습니다. test_sample_bq_autopilot.py
와 같은 분기를 표준 라이브러리만으로 검증합니다.

    python3 python/tests/selftest.py

pytest 가 있으면 그쪽이 더 자세하므로 함께 쓰십시오.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sample_bq_autopilot as mod  # noqa: E402

FAILS: list[str] = []
PASSES = 0


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print(f"  ok   {label}")
    else:
        FAILS.append(label)
        print(f"  FAIL {label}")


# --- 테스트 더블 -----------------------------------------------------------

class FakeJob:
    def __init__(self, rows=None, raise_on_result=None):
        self._rows = [{"sample_ok": 1}] if rows is None else rows
        self._raise = raise_on_result
        self.job_id = "fake_job_0001"
        self.location = "asia-northeast3"
        self.total_bytes_processed = 1024
        self.total_bytes_billed = 10485760

    def result(self, timeout=None):
        if self._raise:
            raise self._raise
        return self._rows


class FakeClient:
    def __init__(self, job=None, raise_on_query=None):
        self.job = job or FakeJob()
        self._raise = raise_on_query
        self.closed = False
        self.last_sql = None
        self.last_kwargs = None

    def query(self, sql, **kwargs):
        self.last_sql = sql
        self.last_kwargs = kwargs
        if self._raise:
            raise self._raise
        return self.job

    def close(self):
        self.closed = True


class FakeCfg:
    def __init__(self, dry_run, max_bytes):
        self.dry_run = dry_run
        self.maximum_bytes_billed = max_bytes


def factory_for(client):
    def f(key_path, project, dry_run, max_bytes):
        return (client, "fake-sa@example.iam.gserviceaccount.com",
                FakeCfg(dry_run, None if dry_run else max_bytes))
    return f


class Forbidden(Exception):
    pass


class NotFound(Exception):
    pass


class RetryError(Exception):
    pass


@contextlib.contextmanager
def scenario(env=None, key_mode=0o600, write_key=True):
    """임시 키 파일과 환경변수를 갖춘 실행 맥락."""
    saved = dict(os.environ)
    with tempfile.TemporaryDirectory() as td:
        key = Path(td) / ".oefj"
        if write_key:
            key.write_text(json.dumps({
                "type": "service_account",
                "client_email": "fake-sa@example.iam.gserviceaccount.com",
                "private_key": "-----BEGIN PRIVATE KEY-----\nSECRETFAKE\n-----END PRIVATE KEY-----\n",
            }))
            key.chmod(key_mode)
        for k in ("BQ_DRY_RUN", "BQ_SQL_FILE", "BQ_LOCATION"):
            os.environ.pop(k, None)
        os.environ["BQ_KEY_PATH"] = str(key)
        os.environ["BQ_JOB_PROJECT"] = "fake-project"
        os.environ["BQ_TEST_TABLE"] = "fake-project.DS.TBL_TEST"
        os.environ.update(env or {})
        out, errbuf = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(errbuf):
                yield key, out, errbuf, td
        finally:
            os.environ.clear()
            os.environ.update(saved)


def result_of(out: io.StringIO):
    for line in reversed(out.getvalue().splitlines()):
        if line.startswith("[RESULT] "):
            return json.loads(line[len("[RESULT] "):])
    return None


# --- 테스트 ----------------------------------------------------------------

def t_success():
    with scenario() as (_k, out, _e, _d):
        c = FakeClient()
        rc = mod.run(factory_for(c))
    check(rc == mod.EXIT_OK, "정상 실행 → exit 0")
    check(result_of(out)["ok"] is True, "정상 실행 → [RESULT] ok=true")
    check(c.closed, "정상 실행 → client.close() 호출")


def t_read_only_sql():
    with scenario() as (_k, _o, _e, _d):
        c = FakeClient()
        mod.run(factory_for(c))
    sql = (c.last_sql or "").upper()
    bad = [v for v in ("INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "TRUNCATE")
           if v in sql]
    check(not bad, f"생성 SQL 이 읽기 전용 (발견된 쓰기 구문: {bad})")


def t_no_secret_leak():
    with scenario() as (_k, out, errbuf, _d):
        mod.run(factory_for(FakeClient()))
    combined = out.getvalue() + errbuf.getvalue()
    check("SECRETFAKE" not in combined, "키 원문이 로그에 남지 않음")
    check("BEGIN PRIVATE KEY" not in combined, "PEM 헤더가 로그에 남지 않음")


def t_empty_table():
    with scenario() as (_k, out, _e, _d):
        rc = mod.run(factory_for(FakeClient(job=FakeJob(rows=[]))))
    check(rc == mod.EXIT_OK, "빈 테이블도 성공 처리")
    check(result_of(out)["ok"] is True, "빈 테이블 → ok=true")


def t_missing_key():
    with scenario(write_key=False) as (_k, out, errbuf, _d):
        rc = mod.run(factory_for(FakeClient()))
    check(rc == mod.EXIT_KEY_MISSING, "키 없음 → exit 2")
    check("[DIAG]" in errbuf.getvalue(), "키 없음 → 후보 경로 진단 출력")
    check(".oefj" in errbuf.getvalue() and ".oef:" in errbuf.getvalue(),
          "키 없음 → .oef / .oefj 양쪽 점검")
    check(result_of(out)["reason"] == "key_missing", "키 없음 → reason 기록")


def t_loose_permissions():
    with scenario(key_mode=0o644) as (_k, _o, errbuf, _d):
        mod.run(factory_for(FakeClient()))
    check("group/other" in errbuf.getvalue(), "느슨한 키 권한 → 경고")


def t_error_classification():
    cases = [
        (Forbidden("403 Access Denied on table"), mod.EXIT_PERM, "권한거부 → exit 3"),
        (NotFound("404 Not found: Table fake"), mod.EXIT_NOTFOUND, "대상없음 → exit 4"),
        (RetryError("Deadline exceeded, timeout"), mod.EXIT_NETWORK, "네트워크 → exit 5"),
        (ValueError("something else"), mod.EXIT_QUERY, "기타 → exit 1"),
    ]
    for exc, expected, label in cases:
        with scenario() as (_k, _o, _e, _d):
            rc = mod.run(factory_for(FakeClient(raise_on_query=exc)))
        check(rc == expected, label)


def t_dry_run():
    with scenario({"BQ_DRY_RUN": "1"}) as (_k, out, _e, _d):
        job = FakeJob(raise_on_result=AssertionError("dry run 인데 result() 호출됨"))
        c = FakeClient(job=job)
        rc = mod.run(factory_for(c))
    check(rc == mod.EXIT_OK, "dry run → exit 0")
    check(result_of(out)["dry_run"] is True, "dry run → [RESULT] dry_run=true")
    check(c.last_kwargs["job_config"].maximum_bytes_billed is None,
          "dry run → maximum_bytes_billed 해제")


def t_normal_sets_cost_cap():
    with scenario() as (_k, _o, _e, _d):
        c = FakeClient()
        mod.run(factory_for(c))
    check(c.last_kwargs["job_config"].maximum_bytes_billed == 10 * 1024 * 1024,
          "일반 실행 → 과금 상한 적용")


def t_sql_file():
    with scenario() as (_k, _o, _e, td):
        f = Path(td) / "GP_L2ZC24_003_3.sql"
        f.write_text("SELECT col FROM `p.d.t` WHERE dt = CURRENT_DATE()")
        os.environ["BQ_SQL_FILE"] = str(f)
        c = FakeClient()
        mod.run(factory_for(c))
    check("CURRENT_DATE()" in (c.last_sql or ""), "BQ_SQL_FILE 의 업무 SQL 사용")


def t_location():
    with scenario({"BQ_LOCATION": "asia-northeast3"}) as (_k, _o, _e, _d):
        c = FakeClient()
        mod.run(factory_for(c))
    check(c.last_kwargs.get("location") == "asia-northeast3", "BQ_LOCATION 전달")

    with scenario() as (_k, _o, _e, _d):
        c2 = FakeClient()
        mod.run(factory_for(c2))
    check("location" not in c2.last_kwargs, "BQ_LOCATION 미지정 시 생략")


def main() -> int:
    print("sample_bq_autopilot.py 셀프테스트")
    for fn in (t_success, t_read_only_sql, t_no_secret_leak, t_empty_table,
               t_missing_key, t_loose_permissions, t_error_classification,
               t_dry_run, t_normal_sets_cost_cap, t_sql_file, t_location):
        fn()
    print()
    if FAILS:
        print(f"실패 {len(FAILS)}건 / 통과 {PASSES}건")
        for f in FAILS:
            print(f"  - {f}")
        return 1
    print(f"전부 통과 ({PASSES}건)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
