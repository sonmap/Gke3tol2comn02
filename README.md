# GKE Autopilot 전환 사전검증 테스트 하네스

운영 GKE → GKE Autopilot 배치 30개 과제 전환의 **사전검증 테스트**를 실행 가능한
코드로 구현한 저장소입니다. 실행계획서의 단위테스트 ①~⑤에 누락 항목 5종을 더해
10개 테스트로 구성했습니다.

워드 문서의 셸 조각을 복사해 붙이는 대신, 설정을 한 곳에 모으고 결과를 기계가 읽을
수 있는 증적으로 남깁니다. 30개 과제 × 수작업 기록에서 누락이 생기는 문제를 막는 것이
목적입니다.

---

## 핵심 설계: 3단계 모드

운영 환경에 들고 가기 전에 **테스트 자체를 먼저 검증**합니다.

| MODE | 접속 대상 | 용도 | 안전성 |
|---|---|---|---|
| `mock` | 없음 | 하네스 자체 검증, CI | 완전 안전 |
| `dryrun` | 운영 클러스터 | 조회와 server-side dry-run 만 | 운영 영향 없음 |
| `live` | 운영 클러스터 | 실제 Pod/PV/PVC 생성 | 승인 후에만 |

`mock` 모드는 `fixtures/mockbin` 의 가짜 `kubectl`·`gcloud` 를 PATH 앞에 끼워
GCP 없이 전 과정을 돌립니다. 노트북에서도, 폐쇄망 CI 에서도 동작합니다.

`live` 는 `I_UNDERSTAND_THIS_TOUCHES_PROD=yes` 를 함께 지정해야 실행됩니다.

---

## 빠른 시작

```bash
git clone https://github.com/sonmap/gke3tol2comn02
cd gke3tol2comn02

# 1. 하네스 자체 검증 — 설정 없이 바로 됩니다
make test

# 2. 운영값 설정
make setup
vi config/env.sh        # __CONFIRM__ 항목을 실측값으로 치환

# 3. 운영 클러스터 조회·dry-run (안전)
make test-dryrun

# 4. 실제 Pod 생성 (운영 승인 후)
make test-live

# 5. 증적 집계
make report-md > 결과보고.md
```

---

## 테스트 구성

### 실행계획서의 단위테스트

| 파일 | 계획서 | 검증 내용 |
|---|---|---|
| `t01_gke_access.sh` | 4장 ① | 클러스터 접속, Namespace, RBAC(pods/pvc/**pv**) |
| `t02_ar_pull.sh` | 5장 ② | AR 저장소 확인, 전체 URI 확정, **digest 기록**, 아키텍처 |
| `t03a_vm_nfs.sh` | 6장 ③ | **운영 VM 측 NFS** — 마운트, export 실측, 키 파일, 읽기·쓰기 |
| `t03b_gke_nfs_pv.sh` | 6장 ③ | GKE PV/PVC 마운트, 읽기, **쓰기**, **uid 대조** |
| `t04_bq_readonly.sh` | 7장 ④ | SA Key 인식, SELECT, **실패 유형별 종료코드** |
| `t05_client_runner.sh` | 8장 ⑤ | 실행기 구문·인자·Kubeconfig 격리, **실패 경로 자원 정리** |

굵게 표시한 항목은 계획서에 없거나 불충분해 보강한 부분입니다.

### 단위테스트 ③을 둘로 나눈 이유

Filestore/GKE 측 검증(`t03b`)은 네트워크·방화벽 승인이 선행되어야 해서 지금
당장은 수행할 수 없습니다. 그 승인을 기다리는 동안 **운영 VM 에서 이미 돌고 있는
NFS 로 확인할 수 있는 것**이 상당히 많습니다. 그것을 `t03a` 로 분리했습니다.

```bash
# 승인 전: VM 측만 수행 (config/env.sh 의 SKIP_GKE_NFS=1 이 기본)
MODE=dryrun bin/run-all.sh t03a

# 승인 후: SKIP_GKE_NFS=0 으로 바꾸고 GKE 측까지
MODE=dryrun bin/run-all.sh t03a t03b
```

`t03a` 가 운영 VM 에서 확인하는 것:

| 항목 | 내용 |
|---|---|
| 마운트 실측 | `findmnt` 로 server·export·NFS 버전·옵션. **ext4 등 비 NFS 면 실패 처리** |
| 방화벽 포트 | NFS 버전에 따라 필요한 포트를 안내 (v4 는 2049, v3 는 추가 포트) |
| uid/gid | `t03b` 의 Pod uid 와 대조할 기준값 |
| 업무 디렉터리 | `l2/` 하위를 열거해 **30개 과제 목록과 대조**, 안 보이는 업무를 경고 |
| SA Key | `.oefj` / `.oef` 후보를 모두 점검, 권한·소유자·SA 이메일 확인 (**내용은 미출력**) |
| 읽기·쓰기 | `.preflight-<RUN_ID>` 전용 경로에서만 쓰고 즉시 삭제 |
| 용량 | `df` 와 사용률 경고. PV 의 `100Gi` 는 선언값일 뿐임을 명시 |
| 서버 도달성 | `nc` 로 2049, `showmount -e` 로 export 목록 |

**산출물이 핵심입니다.** `t03a` 는 실측값을 `evidence/<RUN_ID>.nfs.env` 로 남기고,
`config/env.sh` 에 붙여 넣을 값을 그대로 출력합니다.

```
config/env.sh 에 반영할 값:
  export NFS_SERVER='10.136.209.130'
  export NFS_EXPORT_SOURCE='/batch_gke/l2/zc24'
  export NFS_EXPORT_BQKEY='/batch_gke/l2/rsvp'
```

`t03b` 는 이 파일이 있으면 설정값보다 우선해서 씁니다. PV 의 `server`/`path` 를
추측이 아니라 실측으로 채우는 것이 목적입니다.

다만 계획서 6장 1항이 경고하듯, **VM 의 마운트 지점 하위 경로가 곧바로 NFS export
경로가 되는 것은 아닙니다.** `t03a` 는 후보를 제시할 뿐이고, 실제로 그 경로를 직접
마운트할 수 있는지는 Filestore 담당자 확인이 필요합니다. 테스트도 그렇게 경고합니다.

### 추가한 테스트 5종

| 파일 | 추가 이유 |
|---|---|
| `t06_cron_env.sh` | **가장 흔한 실패 지점.** `get-credentials` 가 만든 kubeconfig 는 `gke-gcloud-auth-plugin` 을 exec 로 부르는데, cron 은 PATH 가 `/usr/bin:/bin` 수준이라 찾지 못합니다. 대화형 테스트는 전부 통과하고 cron 만 실패합니다 |
| `t07_autopilot_admission.sh` | 계획서 6장은 정적 NFS PV 를, 부록 B 는 Filestore CSI 를 가리킵니다. Autopilot 이 거절하면 `client-gke-auto` 의 PV 생성 로직을 다시 써야 하므로 **설계 전제**가 흔들립니다 |
| `t08_concurrency.sh` | "Cron 이 23시 집중"이라면서 모든 테스트가 파드 1개입니다. 증설 지연, PV 이름 충돌, 쿼터는 동시 실행에서만 드러납니다 |
| `t09_sql_dryrun.sh` | ④는 `SELECT 1` 만 돌립니다. 쓰기 권한의 첫 검증이 P-06 본 배치이고, 거기서 실패하면 운영 데이터가 중간 상태로 남습니다. dry run 은 비용 0으로 30개 전수 점검이 가능합니다 |
| `t10_rollback_rehearsal.sh` | 11장 절차는 정확하지만 **해보지 않은 원복은 장애 중에 처음 실행**하게 됩니다. 샌드박스에서 절체→원복→재절체를 돌립니다 |

### 실패 주입 테스트

```bash
make test-negative
```

통과하는 테스트를 만드는 것은 쉽고, 어려운 것은 **실패를 놓치지 않는 것**입니다.
mock CLI 에 장애를 주입해 기대하는 종료코드가 나오는지 확인합니다.

이 테스트가 실제로 버그를 하나 잡았습니다. GKE Warden 의 admission 거절은
`Error from server (Forbidden): admission webhook ... denied the request` 형태로
옵니다. 권한 패턴을 먼저 검사하면 "설계를 다시 해야 한다"는 신호가 단순 권한 문제로
묻힙니다. `lib/common.sh` 의 `classify_error` 는 admission 을 먼저 봅니다.

---

## 종료 코드 규약

계획서 7장의 "실패 유형별 분리" 요구를 셸과 Python 양쪽에서 동일하게 씁니다.
로그를 읽지 않고도 30개 과제의 실패 원인을 분류할 수 있습니다.

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 통과 | — |
| 1 | 테스트 실패 | 기대와 다른 결과 |
| 2 | 설정 미비 | `config/env.sh`, 키 경로 |
| 3 | 권한 거부 | IAM / RBAC 담당자 |
| 4 | 대상 없음 | 저장소·테이블·네임스페이스명 |
| 5 | 네트워크 | 방화벽 / DNS / Private Google Access |
| 6 | **Autopilot 거절** | **설계 변경 필요 — 즉시 보고** |
| 77 | 건너뜀 | 현재 MODE 에서 수행 불가 |

---

## 증적

모든 테스트가 `evidence/<RUN_ID>.jsonl` 에 한 줄씩 남깁니다.

```json
{"run_id":"20261022-1430","test_id":"t02","mode":"live","result":"OK",
 "exit_code":0,"facts":{"image_digest":"sha256:...","image_architecture":"amd64"}}
```

```bash
bin/report.sh           # 판정표
bin/report.sh --md      # 보고용 마크다운
bin/report.sh --all     # 전체 이력
```

`mask_secrets` 가 SA Key 원문, OAuth 토큰, PEM 블록을 모든 출력에서 걸러냅니다.

---

## 원본 YAML 대비 변경점

`bin/render.sh` 가 환경변수를 치환해 매니페스트를 생성합니다.

1. **`bq-key` 를 인라인 `nfs:` → PV/PVC 로 전환**
   Autopilot 은 Pod spec 의 직접 `nfs:` 선언을 거절합니다. `t07` 이 양쪽을 모두
   시험해 실제 정책을 확인합니다.

2. **모든 자원 이름에 `RUN_ID` 접미사**
   PV 는 cluster-scope 입니다. 고정 이름이면 동시 실행과 `Released` 잔존에서
   충돌합니다. `t08` 에서 반드시 걸립니다.

3. **`activeDeadlineSeconds` 추가**
   파드가 무한정 매달리는 것을 막습니다.

4. **진단 명령 포함**
   `id`, `mount`, 키 경로 후보를 찍어 "마운트는 됐는데 권한이 거부"되는 경우를
   구분합니다. `set -x` 는 명령만 찍으므로 키 내용은 노출되지 않습니다.

---

## Python 변경점

`python/sample_bq_autopilot.py` 는 원본을 유지하면서 다섯 가지를 보완했습니다.

- 실패 유형별 종료코드 (원본은 전부 `1`로 수렴)
- 키 파일 권한 점검 — group/other 읽기가 열려 있으면 경고
- **키 경로 후보 진단** — `.oef` / `.oefj` 혼동(계획서 14장 위험)을 한 번에 노출
- `[RESULT]` JSON 한 줄 — `kubectl logs | tail -1` 로 증적 자동 수집
- **dry run 모드** — `BQ_DRY_RUN=1` 로 실행 없이 권한·구문 검증, 비용 0

단위 테스트는 `client_factory` 주입으로 BigQuery 없이 돌아갑니다.
pytest 가 없는 환경(폐쇄망, 운영 VM)을 위해 표준 라이브러리만 쓰는
`python/tests/selftest.py` 를 함께 둡니다.

```bash
python3 python/tests/selftest.py     # 24건
```

---

## Wave 라우터 (선택)

계획서 10.3 은 스스로 모순을 인정합니다. 심볼릭 링크를 한 번 바꾸면 공통 경로를
쓰는 새 호출이 전부 신규 클러스터로 향하므로 Wave 구분이 무의미해집니다.
해법이 "운영 절차 합의"로만 남아 있는데, 23시 집중 구간에서 사람 손에 의존한
순차 재개는 지키기 어렵습니다.

`bin/client-gke-router` 는 `--program-id` 를 보고 허용 목록에 있으면 신규,
없으면 기존으로 보냅니다.

```bash
cp bin/client-gke-router /ssw/dlk/
echo 'GP_L2ZC24_003_3' >> /ssw/dlk/autopilot_allow.txt   # Wave 확대 = 한 줄 추가
```

목록 파일이 없으면 **전부 기존으로** 보냅니다. 파일 유실이 대량 전환으로 이어지지
않도록 한 안전한 기본값입니다. 라우터 자체가 단일 장애점이므로 `t10` 이 양쪽 분기를
검증합니다.

---

## 권장 실행 순서

계획서 3장 일정과 다릅니다. **설계 전제를 흔들 수 있는 두 테스트를 앞으로 당겼습니다.**

| 시점 | 테스트 | 이유 |
|---|---|---|
| D-5 | `t06`, `t07` | 여기서 막히면 나머지 일정이 전부 밀립니다 |
| D-5 | `t01` | `pv create` 는 ClusterRole 발급에 승인 시간이 걸립니다 |
| D-4 | `t02` | IAM 승인 후 |
| D-5 | `t03a` | **승인 불필요** — 운영 VM 에서 지금 바로 가능 |
| D-3 | `t03b` | 네트워크·방화벽 승인 후 |
| D-2 | `t04`, `t09` | `t09` 로 30개 SQL 전수 점검 |
| D-2 | `t05`, `t10` | 실행기와 원복 절차 |
| D-1 | `t08` | Wave 3 전 동시 부하 |

또한 권한·방화벽 요청은 **D-10 전후에 전부 동시에 제출**하시길 권합니다.
13장 분장표를 보면 AR IAM, 스토리지, 네트워크, BQ IAM 이 전부 다른 담당자이고,
하루에 한 단계씩이라는 일정은 현실적이지 않습니다.

---

## 보안

- `config/env.sh` 는 `.gitignore` — 프로젝트·SA 정보가 들어갑니다
- `sql/*.sql` 도 기본 제외 — 운영 쿼리입니다
- 모든 출력에 `mask_secrets` 적용
- 테스트는 읽기 중심. 쓰기는 `.preflight-<RUN_ID>` 전용 하위 경로에서만
- `kubectl delete` 는 이 하네스가 만든 자원에만 적용. **Filestore 파일은 삭제하지 않습니다**

---

## 디렉터리

```
├── bin/
│   ├── run-all.sh            전체 실행기
│   ├── preflight.sh          설정 검증 (__CONFIRM__ 잔존 차단)
│   ├── render.sh             매니페스트 렌더링
│   ├── report.sh             증적 집계
│   └── client-gke-router     Wave 라우터 (선택 배치)
├── lib/common.sh             로깅·종료코드·증적·오류 분류
├── config/
│   ├── env.example.sh        모든 가변값 (2장 확정 필요 항목)
│   └── tasks30.csv           부록 A 30개 과제 + digest 칸
├── tests/
│   ├── t01 ~ t10             단위테스트 (t03a=VM측 NFS, t03b=GKE측)
│   └── negative.sh           실패 주입
├── python/
│   ├── sample_bq_autopilot.py
│   └── tests/                pytest + 의존성 없는 셀프테스트
├── fixtures/mockbin/         가짜 kubectl·gcloud
├── sql/                      업무 SQL (t09 입력)
└── evidence/                 증적 JSONL
```

---

## 알려진 제약

- `t02`/`t03b`/`t08` 의 실제 Pull·마운트·부하는 `MODE=live` 에서만 수행됩니다
- `t03b` 는 `SKIP_GKE_NFS=1` 이 기본값입니다. Filestore 네트워크 승인 후 `0` 으로 바꾸십시오
- `t03a` 는 **운영 VM 에서 실행해야** 의미가 있습니다. 다른 호스트에서는 마운트 지점이 없어 CONFIG 실패합니다
- `t09` 는 `sql/<과제ID>.sql` 을 사람이 배치해야 합니다
- Node SA 는 Autopilot 에서 `describe` 로 안 보일 수 있습니다. GKE 운영 담당자 확인 필요
- 이 하네스는 검증만 합니다. 실제 절체는 계획서 10장 절차를 따르십시오

---

## 중장기 과제 (이번 범위 밖)

SA JSON 키를 Filestore 에 평문으로 두는 구조는 Workload Identity 로 대체하면
키 파일 자체가 불필요해집니다. Autopilot 은 Workload Identity 가 기본 활성이라
전환 여건이 좋습니다. 다만 이번 사업의 "변경 최소화" 원칙과 충돌하므로
**전환 완료 후 별도 과제**로 두시길 권합니다.
