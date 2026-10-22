#!/usr/bin/env bash
# 매니페스트 렌더링 — 환경변수를 치환해 실제 적용 가능한 YAML 을 만듭니다.
#
#   bin/render.sh [출력디렉터리]
#
# 원본 YAML 대비 변경점:
#   1. bq-key 를 인라인 nfs 볼륨 → PV/PVC 로 전환
#      (Autopilot 은 Pod spec 의 직접 nfs 선언을 거절합니다)
#   2. 모든 자원 이름에 RUN_ID 접미사
#      (PV 는 cluster-scope 라 고정 이름이면 동시 실행과 Released 잔존에서 충돌)
#   3. activeDeadlineSeconds 추가 (무한 대기 방지)
#   4. 진단 명령 포함 (id, mount, 키 경로 후보) — 마운트 성공 후 권한 거부를 구분

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${REPO_ROOT}/evidence/manifests}"

[ -f "${REPO_ROOT}/config/env.sh" ] && . "${REPO_ROOT}/config/env.sh"
: "${RUN_ID:=$(date +%Y%m%d-%H%M%S)}"
: "${NS:=l2comm-batch}"
: "${KSA:=ksa-l2comm-batch}"
: "${NFS_SERVER:=__CONFIRM__}"
: "${NFS_EXPORT_SOURCE:=__CONFIRM__}"
: "${NFS_EXPORT_BQKEY:=__CONFIRM__}"
: "${BQ_JOB_PROJECT:=__CONFIRM__}"
: "${BQ_KEY_PATH:=/var/run/bq-key/.oefj}"
: "${ZC24_IMAGE_URI:=REPLACE_FULL_ZC24_IMAGE_URI}"
: "${SMOKE_CPU:=1}"
: "${SMOKE_MEM:=2Gi}"
: "${POD_TIMEOUT_SEC:=900}"

# t02 가 digest 를 확정했으면 그것을 씁니다 (태그보다 안전).
_imgenv="${EVIDENCE_DIR:-${REPO_ROOT}/evidence}/${RUN_ID}.image.env"
# shellcheck disable=SC1090
[ -f "$_imgenv" ] && . "$_imgenv"
IMAGE="${ZC24_IMAGE_BY_DIGEST:-$ZC24_IMAGE_URI}"

SFX="$RUN_ID"
mkdir -p "$OUT"

# 업무 소스 볼륨 ------------------------------------------------------------
cat > "${OUT}/pv-source.yaml" <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-zc24-source-${SFX}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  capacity: {storage: 100Gi}
  volumeMode: Filesystem
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_EXPORT_SOURCE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-zc24-source-${SFX}
  namespace: ${NS}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ""
  volumeName: pv-zc24-source-${SFX}
  resources:
    requests: {storage: 100Gi}
YAML

# SA Key 볼륨 — 인라인 nfs 를 PV/PVC 로 전환한 부분 ------------------------
cat > "${OUT}/pv-bqkey.yaml" <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-zc24-bqkey-${SFX}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  capacity: {storage: 1Gi}
  volumeMode: Filesystem
  accessModes: [ReadOnlyMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions: ["ro"]
  nfs:
    server: ${NFS_SERVER}
    path: ${NFS_EXPORT_BQKEY}
    readOnly: true
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-zc24-bqkey-${SFX}
  namespace: ${NS}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  accessModes: [ReadOnlyMany]
  storageClassName: ""
  volumeName: pv-zc24-bqkey-${SFX}
  resources:
    requests: {storage: 1Gi}
YAML

# NFS 진단 Pod (t03) --------------------------------------------------------
# set -x 는 명령만 찍고 파일 내용은 출력하지 않으므로 키가 노출되지 않습니다.
cat > "${OUT}/pod-nfs-probe.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: nfs-probe-${SFX}
  namespace: ${NS}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  restartPolicy: Never
  serviceAccountName: ${KSA}
  activeDeadlineSeconds: ${POD_TIMEOUT_SEC}
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -x
          id
          mount | grep -E 'jupyter|bq-key' || true
          ls -ld /home/jupyter
          test -r /home/jupyter && echo NFS_READ_OK
          test -r ${BQ_KEY_PATH} && echo KEY_READ_OK
          # 전용 하위 경로에서만 쓰기 확인. 업무 데이터는 건드리지 않습니다.
          probe_dir=/home/jupyter/.preflight-${SFX}
          if mkdir -p "\$probe_dir" 2>/dev/null \\
             && echo ok > "\$probe_dir/w.tmp" 2>/dev/null; then
            echo NFS_WRITE_OK
            rm -rf "\$probe_dir"
          else
            echo NFS_WRITE_DENIED
          fi
      resources:
        requests: {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
        limits:   {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
      volumeMounts:
        - {name: zc24-source, mountPath: /home/jupyter}
        - {name: bq-key, mountPath: /var/run/bq-key, readOnly: true}
  volumes:
    - name: zc24-source
      persistentVolumeClaim: {claimName: pvc-zc24-source-${SFX}}
    - name: bq-key
      persistentVolumeClaim: {claimName: pvc-zc24-bqkey-${SFX}, readOnly: true}
YAML

# BigQuery smoke Pod (t04) --------------------------------------------------
cat > "${OUT}/pod-bq-smoke.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: zc24-bq-smoke-${SFX}
  namespace: ${NS}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  restartPolicy: Never
  serviceAccountName: ${KSA}
  activeDeadlineSeconds: ${POD_TIMEOUT_SEC}
  containers:
    - name: bq-test
      image: ${IMAGE}
      imagePullPolicy: Always
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -x
          id
          test -r ${BQ_KEY_PATH} && echo KEY_READ_OK
          python3 /home/jupyter/sample_bq_autopilot.py
      env:
        - {name: BQ_KEY_PATH,    value: "${BQ_KEY_PATH}"}
        - {name: BQ_JOB_PROJECT, value: "${BQ_JOB_PROJECT}"}
        - {name: BQ_TEST_TABLE,  value: "${BQ_TEST_TABLE:-}"}
        - {name: BQ_LOCATION,    value: "${BQ_LOCATION:-}"}
      resources:
        requests: {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
        limits:   {cpu: "${SMOKE_CPU}", memory: "${SMOKE_MEM}"}
      volumeMounts:
        - {name: zc24-source, mountPath: /home/jupyter}
        - {name: bq-key, mountPath: /var/run/bq-key, readOnly: true}
  volumes:
    - name: zc24-source
      persistentVolumeClaim: {claimName: pvc-zc24-source-${SFX}}
    - name: bq-key
      persistentVolumeClaim: {claimName: pvc-zc24-bqkey-${SFX}, readOnly: true}
YAML

# 조합본 --------------------------------------------------------------------
{ cat "${OUT}/pv-source.yaml"; echo '---'
  cat "${OUT}/pv-bqkey.yaml";  echo '---'
  cat "${OUT}/pod-nfs-probe.yaml"; } > "${OUT}/nfs-smoke.yaml"

{ cat "${OUT}/pv-source.yaml"; echo '---'
  cat "${OUT}/pv-bqkey.yaml";  echo '---'
  cat "${OUT}/pod-bq-smoke.yaml"; } > "${OUT}/bq-smoke.yaml"

# admission 탐침용 (t07) ----------------------------------------------------
cp "${OUT}/pv-source.yaml" "${OUT}/probe-pv.yaml"
cp "${OUT}/pod-bq-smoke.yaml" "${OUT}/probe-pod.yaml"

# 원본 YAML 의 인라인 nfs 방식 — Autopilot 이 거절하는지 확인하는 탐침
cat > "${OUT}/probe-inline-nfs.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: inline-nfs-probe-${SFX}
  namespace: ${NS}
  labels: {harness: gke-autopilot-preflight, run: "${SFX}"}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 300
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["/bin/sh","-c","echo INLINE_NFS_OK"]
      resources:
        requests: {cpu: "250m", memory: "512Mi"}
        limits:   {cpu: "250m", memory: "512Mi"}
      volumeMounts:
        - {name: bq-key, mountPath: /var/run/bq-key, readOnly: true}
  volumes:
    - name: bq-key
      nfs:
        server: ${NFS_SERVER}
        path: ${NFS_EXPORT_BQKEY}
        readOnly: true
YAML

echo "$OUT"
