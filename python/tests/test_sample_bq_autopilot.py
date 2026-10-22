"""sample_bq_autopilot.py 단위 테스트.

BigQuery 에 접속하지 않고 client_factory 를 주입해 분기를 검증합니다.
이것이 "내부 개발 테스트" 의 핵심입니다 — 운영에 들고 가기 전에
스크립트 자체의 실패 경로가 의도대로 동작하는지 확인합니다.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import sample_bq_autopilot as mod  # noqa: E402


# --- 테스트 더블 -----------------------------------------------------------

class FakeRow(dict):
    pass


class FakeJob:
    def __init__(self, rows=None, raise_on_result=None,
                 bytes_processed=1024, bytes_billed=10485760):
        self._rows = rows if rows is not None else [FakeRow(sample_ok=1)]
        self._raise = raise_on_result
        self.job_id = "fake_job_0001"
        self.location = "asia-northeast3"
        self.total_bytes_processed = bytes_processed
        self.total_bytes_billed = bytes_billed

    def result(self, timeout=None):
        if self._raise:
            raise self._raise
        return self._rows


class FakeClient:
    def __init__(self, job=None, raise_on_query=None):
        self._job = job or FakeJob()
        self._raise = raise_on_query
        self.closed = False
        self.last_sql = None
        self.last_kwargs = None

    def query(self, sql, **kwargs):
        self.last_sql = sql
        self.last_kwargs = kwargs
        if self._raise:
            raise self._raise
        return self._job

    def close(self):
        self.closed = True


class FakeJobConfig:
    def __init__(self, dry_run=False, max_bytes=None):
        self.dry_run = dry_run
        self.maximum_bytes_billed = max_bytes


def make_factory(client):
    def factory(key_path, project, dry_run, max_bytes):
        return (
            client,
            "fake-sa@example.iam.gserviceaccount.com",
            FakeJobConfig(dry_run=dry_run,
                          max_bytes=None if dry_run else max_bytes),
        )
    return factory


# --- 공통 픽스처 -----------------------------------------------------------

@pytest.fixture
def key_file(tmp_path):
    p = tmp_path / ".oefj"
    p.write_text(json.dumps({
        "type": "service_account",
        "client_email": "fake-sa@example.iam.gserviceaccount.com",
        "private_key": "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----\n",
    }))
    p.chmod(0o600)
    return p


@pytest.fixture
def base_env(monkeypatch, key_file):
    monkeypatch.setenv("BQ_KEY_PATH", str(key_file))
    monkeypatch.setenv("BQ_JOB_PROJECT", "fake-project")
    monkeypatch.setenv("BQ_TEST_TABLE", "fake-project.DS.TBL_TEST")
    monkeypatch.delenv("BQ_DRY_RUN", raising=False)
    monkeypatch.delenv("BQ_SQL_FILE", raising=False)
    monkeypatch.delenv("BQ_LOCATION", raising=False)
    return monkeypatch


def result_line(capsys):
    out = capsys.readouterr().out
    for line in reversed(out.splitlines()):
        if line.startswith("[RESULT] "):
            return json.loads(line[len("[RESULT] "):])
    return None


# --- 정상 경로 -------------------------------------------------------------

def test_success_returns_zero(base_env, capsys):
    client = FakeClient()
    assert mod.run(make_factory(client)) == mod.EXIT_OK
    res = result_line(capsys)
    assert res["ok"] is True
    assert res["job_id"] == "fake_job_0001"
    assert client.closed, "client.close() 가 호출되어야 합니다"


def test_empty_table_is_success(base_env, capsys):
    """대상 테이블이 비어 있어도 연결 검증은 유효합니다."""
    client = FakeClient(job=FakeJob(rows=[]))
    assert mod.run(make_factory(client)) == mod.EXIT_OK
    assert result_line(capsys)["ok"] is True


def test_query_is_read_only(base_env):
    """생성되는 SQL 에 쓰기 구문이 섞이지 않아야 합니다."""
    client = FakeClient()
    mod.run(make_factory(client))
    sql = client.last_sql.upper()
    for verb in ("INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "CREATE", "TRUNCATE"):
        assert verb not in sql, f"{verb} 가 SQL 에 포함되었습니다"
    assert "SELECT" in sql


def test_no_secret_in_output(base_env, capsys):
    """키 원문이 로그에 새지 않아야 합니다."""
    mod.run(make_factory(FakeClient()))
    captured = capsys.readouterr()
    combined = captured.out + captured.err
    assert "BEGIN PRIVATE KEY" not in combined
    assert "FAKE\n" not in combined


# --- 키 파일 경로 ----------------------------------------------------------

def test_missing_key_returns_config_code(base_env, tmp_path, capsys):
    base_env.setenv("BQ_KEY_PATH", str(tmp_path / "does-not-exist"))
    assert mod.run(make_factory(FakeClient())) == mod.EXIT_KEY_MISSING
    assert result_line(capsys)["reason"] == "key_missing"


def test_missing_key_prints_candidate_diagnostics(base_env, tmp_path, capsys):
    """.oef / .oefj 혼동을 가려내는 진단이 나와야 합니다."""
    base_env.setenv("BQ_KEY_PATH", str(tmp_path / "nope"))
    mod.run(make_factory(FakeClient()))
    errout = capsys.readouterr().err
    assert "[DIAG]" in errout
    assert ".oefj" in errout and ".oef:" in errout


def test_loose_key_permissions_warn(base_env, key_file, capsys):
    key_file.chmod(0o644)
    mod.run(make_factory(FakeClient()))
    assert "group/other" in capsys.readouterr().err


def test_missing_job_project(base_env, capsys):
    base_env.setenv("BQ_JOB_PROJECT", "")
    assert mod.run(make_factory(FakeClient())) == mod.EXIT_KEY_MISSING


# --- 실패 유형별 종료코드 --------------------------------------------------

class Forbidden(Exception):
    pass


class NotFound(Exception):
    pass


class RetryError(Exception):
    pass


@pytest.mark.parametrize("exc,expected", [
    (Forbidden("403 Access Denied on table"),        mod.EXIT_PERM),
    (NotFound("404 Not found: Table fake"),          mod.EXIT_NOTFOUND),
    (RetryError("Deadline exceeded, timeout"),       mod.EXIT_NETWORK),
    (ValueError("something else entirely"),          mod.EXIT_QUERY),
])
def test_error_classification(base_env, exc, expected, capsys):
    """계획서 7장의 '실패 유형별 분리' 요구가 종료코드로 구현되었는지."""
    client = FakeClient(raise_on_query=exc)
    assert mod.run(make_factory(client)) == expected
    assert result_line(capsys)["ok"] is False


def test_unexpected_value_fails(base_env):
    client = FakeClient(job=FakeJob(rows=[FakeRow(sample_ok=99)]))
    assert mod.run(make_factory(client)) == mod.EXIT_QUERY


# --- dry run ---------------------------------------------------------------

def test_dry_run_does_not_execute(base_env, capsys):
    """dry run 은 result() 를 부르지 않아야 합니다 (호출하면 예외가 납니다)."""
    base_env.setenv("BQ_DRY_RUN", "1")
    job = FakeJob(raise_on_result=AssertionError("dry run 인데 result() 가 호출됨"))
    client = FakeClient(job=job)
    assert mod.run(make_factory(client)) == mod.EXIT_OK
    res = result_line(capsys)
    assert res["dry_run"] is True
    assert res["bytes_processed"] == 1024


def test_dry_run_clears_max_bytes_billed(base_env):
    """dry_run 과 maximum_bytes_billed 는 함께 쓸 수 없습니다."""
    base_env.setenv("BQ_DRY_RUN", "true")
    client = FakeClient()
    mod.run(make_factory(client))
    cfg = client.last_kwargs["job_config"]
    assert cfg.dry_run is True
    assert cfg.maximum_bytes_billed is None


def test_normal_run_sets_max_bytes_billed(base_env):
    client = FakeClient()
    mod.run(make_factory(client))
    assert client.last_kwargs["job_config"].maximum_bytes_billed == 10 * 1024 * 1024


# --- 업무 SQL 파일 ---------------------------------------------------------

def test_sql_file_is_used(base_env, tmp_path):
    f = tmp_path / "GP_L2ZC24_003_3.sql"
    f.write_text("SELECT col FROM `p.d.t` WHERE dt = CURRENT_DATE()")
    base_env.setenv("BQ_SQL_FILE", str(f))
    client = FakeClient()
    mod.run(make_factory(client))
    assert "WHERE dt = CURRENT_DATE()" in client.last_sql


def test_location_passed_when_set(base_env):
    base_env.setenv("BQ_LOCATION", "asia-northeast3")
    client = FakeClient()
    mod.run(make_factory(client))
    assert client.last_kwargs.get("location") == "asia-northeast3"


def test_location_omitted_when_empty(base_env):
    client = FakeClient()
    mod.run(make_factory(client))
    assert "location" not in client.last_kwargs
