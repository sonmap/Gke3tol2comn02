# 운영 VM NFS 점검 가이드 (t03a)

Filestore/GKE 측 검증은 네트워크·방화벽 승인이 선행되어야 합니다. 그 승인을
기다리는 동안 운영 VM 에서 지금 수행할 수 있는 절차입니다.

모두 읽기 중심입니다. 쓰기는 `.preflight-<RUN_ID>` 전용 경로에서만 하고 즉시
지웁니다. 업무 파일과 키 원본은 건드리지 않습니다.

---

## 실행

운영 VM 에서, **Cron 을 소유한 계정으로** 실행하십시오. 계정이 다르면 uid/gid 와
키 파일 접근 권한이 달라져 결과가 의미를 잃습니다.

```bash
git clone https://github.com/sonmap/Gke3tol2comn02.git
cd Gke3tol2comn02

make setup
vi config/env.sh          # VM_NFS_MOUNT 만 맞으면 t03a 는 돌아갑니다

MODE=dryrun bin/run-all.sh t03a
```

`config/env.sh` 에서 `t03a` 에 필요한 값은 둘뿐입니다.

```bash
export VM_NFS_MOUNT='/mnt/batch_gke'   # 실제 마운트 지점
export VM_KEY_PATH=''                  # 비우면 .oefj / .oef 후보를 자동 탐색
```

나머지 `__CONFIRM__` 항목은 `t03a` 에 영향을 주지 않습니다.

---

## 확인 항목

### 1. 마운트 실측

`findmnt` 로 server, export, NFS 버전, 옵션을 읽습니다.

`fstype` 이 `nfs` 계열이 아니면 **실패 처리**합니다. 로컬 디스크를 NFS 로 오인해
엉뚱한 PV 값을 권고하지 않기 위해서입니다. `ext4` 가 잡힌다면 NFS 가 아직
마운트되지 않았거나 `VM_NFS_MOUNT` 설정이 틀린 것입니다.

```bash
findmnt -T /mnt/batch_gke -o SOURCE,FSTYPE,OPTIONS
```

### 2. 방화벽 포트

NFS 버전이 확정되어야 네트워크 담당자에게 정확히 요청할 수 있습니다.

| 버전 | 보통 필요한 포트 |
|---|---|
| v4.x | TCP 2049 단일 포트 |
| v3 | TCP/UDP 111, 2049 + mountd·nlockmgr·statd 포트 (사이트마다 다름) |

v3 라면 담당자와 정확한 포트를 확인하십시오. 계획서 6장 4항이 예시로 든
2046/2050/4045 는 사이트에 따라 다릅니다.

### 3. uid / gid

`t03b` 가 수집할 Pod uid 와 대조할 기준값입니다. 둘이 다르면 **마운트는
성공하는데 쓰기만 거부**됩니다. 가장 늦게 발견되고 가장 당황스러운 실패입니다.

### 4. 업무 디렉터리 대조

`l2/` 하위를 열거해 `config/tasks30.csv` 의 30개 과제와 대조합니다. NFS 에
디렉터리가 안 보이는 업무가 있으면 경고합니다. 다른 export 를 쓰거나 경로 구조가
계획서 가정과 다를 수 있습니다.

### 5. SA Key

계획서 14장이 지적한 `.oef` / `.oefj` 혼동을 VM 쪽에서 가려냅니다.

- `.oefj`, `.oef` 후보를 모두 점검해 **실제로 어느 것이 있는지** 출력
- 권한·소유자·크기 기록. `600`/`400` 이 아니면 경고
- JSON 형식 검증과 `client_email` 만 추출

**파일 내용은 출력하지 않습니다.** `mask_secrets` 가 PEM 블록과 토큰을 모든
출력에서 걸러냅니다.

여기서 확인된 SA 는 **BigQuery 용**입니다. AR 이미지 Pull 권한을 갖는 GKE Node SA
와는 다를 수 있습니다 (계획서 1장 4항).

### 6. 읽기 · 쓰기

실제 배치는 결과 파일을 씁니다. 읽기만 확인하면 운영 중에 실패합니다.

쓰기는 `${VM_NFS_MOUNT}/.preflight-<RUN_ID>` 에서만 하고 즉시 삭제합니다.
정리에 실패하면 경로를 알려주므로 수동으로 지우십시오.

### 7. 용량과 서버 도달성

`df` 사용률이 85% 이상이면 경고합니다. `nc` 로 2049 도달성, `showmount -e` 로
서버의 export 목록을 확인합니다.

export 목록은 GKE 쪽에서 어떤 경로를 직접 마운트할 수 있는지 판단하는 근거가
됩니다.

---

## 산출물

`t03a` 는 실측값을 두 곳에 남깁니다.

**1. `evidence/<RUN_ID>.nfs.env`** — `t03b` 가 읽어 PV 선언에 그대로 씁니다.

```
NFS_SERVER=10.136.209.130
NFS_EXPORT_ROOT=/batch_gke
NFS_VERSION=4.1
VM_UID=1000
VM_GID=1000
VM_KEY_PATH=/mnt/batch_gke/l2/rsvp/.oefj
SUGGEST_NFS_EXPORT_SOURCE=/batch_gke/l2/zc24
SUGGEST_NFS_EXPORT_BQKEY=/batch_gke/l2/rsvp
```

**2. 화면 출력** — `config/env.sh` 에 붙여 넣을 형태로 나옵니다.

```
config/env.sh 에 반영할 값:
  export NFS_SERVER='10.136.209.130'
  export NFS_EXPORT_SOURCE='/batch_gke/l2/zc24'
  export NFS_EXPORT_BQKEY='/batch_gke/l2/rsvp'
```

---

## 중요: 이 값을 그대로 믿지 마십시오

계획서 6장 1항이 경고하는 바로 그 지점입니다.

```
/mnt/batch_gke              ← VM 의 마운트 지점
10.136.209.130:/batch_gke   ← 서버와 export
```

`t03a` 가 제시하는 `SUGGEST_*` 경로는 **VM 의 마운트 지점 하위 구조를 export 루트
기준으로 바꿔 쓴 후보**일 뿐입니다. 서버가 그 하위 경로를 독립적으로 export
하는지, GKE 노드에서 직접 마운트할 수 있는지는 다른 문제입니다.

Filestore 는 보통 인스턴스당 하나의 share 를 export 하므로, `/batch_gke/l2/zc24` 를
직접 마운트하지 못하고 `/batch_gke` 전체를 마운트한 뒤 `subPath` 로 접근해야 할
수 있습니다. 이 경우 PV 설계가 달라집니다.

**Filestore 담당자에게 확인할 것:**

1. export 되는 경로가 정확히 무엇인가 (`showmount -e` 결과와 대조)
2. 하위 경로를 독립 export 할 수 있는가, 아니면 루트만 가능한가
3. export ACL 에 GKE **노드 서브넷**이 포함되어 있는가
   (NFS 트래픽은 노드 IP 가 원본으로 보입니다. Pod Secondary 만 허용하면 실패합니다)
4. NFS 버전과 그에 따른 방화벽 포트

---

## 다음 단계

승인이 나면 `config/env.sh` 에서 플래그를 바꾸고 GKE 측을 검증합니다.

```bash
export SKIP_GKE_NFS='0'
```

```bash
MODE=dryrun bin/run-all.sh t03a t03b   # admission dry-run 까지
MODE=live   bin/run-all.sh t03a t03b   # 실제 마운트 (승인 후)
```

`t03b` 는 `t03a` 의 실측값을 우선 사용하고, Pod uid 를 VM uid 와 대조합니다.
