# 업무 SQL 배치 위치

t09(업무 SQL 전수 dry run)가 이 디렉터리의 `<과제ID>.sql` 을 읽습니다.

```
sql/
├── GP_L2ZC24_003_3.sql
├── GP_L2EM22_002_11.sql
└── ...
```

실행:

```bash
tests/t09_sql_dryrun.sh                  # 전체
tests/t09_sql_dryrun.sh GP_L2ZC24_003_3  # 특정 과제만
```

`.sql` 파일은 운영 쿼리이므로 `.gitignore` 되어 있습니다.
팀 정책상 버전관리가 필요하면 `.gitignore` 의 `sql/*.sql` 행을 제거하십시오.
