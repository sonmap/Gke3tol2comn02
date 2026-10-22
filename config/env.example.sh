# shellcheck shell=bash
# ---------------------------------------------------------------------------
# 사전검증 테스트 환경 변수 (예시)
#
#   cp config/env.example.sh config/env.sh
#   vi config/env.sh          # __CONFIRM__ 을 실측값으로 치환
#   chmod 600 config/env.sh
#
# config/env.sh 는 .gitignore 되어 있습니다. 커밋하지 마십시오.
#
# 값이 __CONFIRM__ 인 항목은 실행계획서 2장 "확정 필요 항목" 입니다.
# bin/preflight.sh 가 미치환 항목을 찾아내 실행을 거부합니다.
# ---------------------------------------------------------------------------

# --- 실행 모드 -------------------------------------------------------------
# mock   : GCP 접속 없음. fixtures/mockbin 의 가짜 CLI 사용. CI·로컬 개발용.
# dryrun : 실제 클러스터에 접속하되 조회와 server-side dry-run 만. 운영 안전.
# live   : 실제 Pod/PV/PVC 를 생성. 운영 승인 후에만 사용.
: "${MODE:=mock}"

# --- GKE -------------------------------------------------------------------
export GKE_PROJECT='__CONFIRM__'          # 계획 기준값: gcp-prod-dlk-l2comn
export GKE_CLUSTER='__CONFIRM__'          # 계획 기준값: gkea-prod-l2comn-batch
export REGION='asia-northeast3'
export NS='__CONFIRM__'                   # 계획 기준값: l2comm-batch
export KSA='__CONFIRM__'                  # 계획 기준값: ksa-l2comm-batch
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/l2comn_gke}"

# --- Artifact Registry -----------------------------------------------------
export AR_PROJECT='__CONFIRM__'           # 계획 기준값: gcp-prod-edp-edge
export AR_LOCATION='asia-northeast3'
export AR_REPO='__CONFIRM__'              # 화면의 dlk-lguplus-deeplearing 이
                                          # 저장소명인지 UI 태그 화면인지 확인 필요
export ZC24_TAG='2.3-zc24-zc24-003-3'
# 전체 URI. AR_REPO 확정 후 t02 가 자동 조립하거나, 여기에 직접 적습니다.
export ZC24_IMAGE_URI="${ZC24_IMAGE_URI:-}"

# --- VM 측 NFS (t03a) ------------------------------------------------------
# GKE/Filestore 검증 전에 운영 VM 에서 지금 확인할 수 있는 부분입니다.
# t03a 가 여기서 실측한 값을 evidence/<RUN_ID>.nfs.env 로 떨궈
# t03b 의 PV 선언 입력으로 넘깁니다.
export VM_NFS_MOUNT='/mnt/batch_gke'      # 운영 VM 측 마운트 지점
export VM_KEY_PATH=''                     # 비우면 <VM_NFS_MOUNT>/l2/rsvp/.oefj 를 찾고
                                          # .oef 후보까지 함께 점검합니다

# --- GKE 측 Filestore / NFS (t03b) -----------------------------------------
# 네트워크·방화벽 승인 전이라 아직 검증이 불가하면 1 로 두십시오.
# t03b 가 건너뛰고, t03a 가 VM 측 검증을 계속 수행합니다.
export SKIP_GKE_NFS='1'

# 아래 세 값은 t03a 실행 후 그 출력에 나온 실측값으로 채우십시오.
# 계획 기준값(10.136.209.130 등)을 그대로 쓰지 마십시오.
export NFS_SERVER='__CONFIRM__'           # t03a 가 findmnt 로 실측
export NFS_EXPORT_SOURCE='__CONFIRM__'    # zc24 업무 소스 export 경로
export NFS_EXPORT_BQKEY='__CONFIRM__'     # SA Key 가 있는 export 경로

# --- BigQuery --------------------------------------------------------------
export BQ_JOB_PROJECT='__CONFIRM__'       # 계획 기준값: gcp-prod-edp-lake
export BQ_TEST_TABLE='__CONFIRM__'        # 계획 기준값:
                                          # gcp-prod-edp-lake.DLKUDF.L2MQ_TL_SUBJ_H_TEST
export BQ_LOCATION=''                     # 비우면 자동. 데이터셋 리전과 일치해야 함
export BQ_KEY_PATH='/var/run/bq-key/.oefj'   # Pod 내부 경로
export BQ_MAX_BYTES_BILLED=$((10 * 1024 * 1024))

# --- 실행기 ----------------------------------------------------------------
export CLIENT_DIR='/ssw/dlk'
export CLIENT_CANONICAL="${CLIENT_DIR}/client_gke"       # Cron 이 부르는 경로
export CLIENT_NEW="${CLIENT_DIR}/client-gke-auto"        # 신규 실행기
export CLIENT_ROUTER="${CLIENT_DIR}/client-gke-router"   # Wave 라우터(선택)
export ALLOW_LIST="${CLIENT_DIR}/autopilot_allow.txt"

# --- 테스트 파라미터 -------------------------------------------------------
export SMOKE_CPU='1'
export SMOKE_MEM='2Gi'
export ZC24_CPU='4'          # P-06 본 배치용. 기존 실행 로그에서 확인할 것
export ZC24_MEM='16Gi'
export POD_TIMEOUT_SEC=900
export CONCURRENCY_N=15      # t08 동시 실행 부하 테스트 파드 수

# --- 증적 ------------------------------------------------------------------
export EVIDENCE_DIR="${EVIDENCE_DIR:-$(pwd)/evidence}"
export RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
