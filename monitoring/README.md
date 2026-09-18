# VM2 관측 스택

춘천 메인 리전의 지표와 로그를 수집하는 스택입니다. 설계 문서에는 관측을 오사카의 VM4에 두는
구상이 있었지만, 실제로 동작하는 위치는 VM2입니다. VM4는 미구성 예비 자원이며 이 스택을 옮길
계획은 현재 범위에 없습니다.

운영 배치 위치는 `/opt/bnbong/docker-compose.monitoring.yml`이고 compose project 이름은
`bnbong`입니다. compose의 상대 경로가 모두 `/opt/bnbong` 기준이므로, 이 저장소의 `monitoring/`
디렉터리를 `/opt/bnbong/monitoring/`으로 전송해야 합니다.

## 구성과 버전

| 구성 요소 | 이미지 태그 | 역할과 게시 주소 |
|---|---|---|
| Prometheus | `prom/prometheus:v3.7.2` | 지표를 수집하고 저장합니다. 9090번 포트를 loopback에만 게시합니다. |
| Grafana | `grafana/grafana:12.2.1` | 시각화와 통지를 담당합니다. 3000번 포트를 private IP와 loopback에 게시합니다. |
| Loki | `grafana/loki:3.5.7` | 로그를 저장합니다. 3100번 포트를 loopback에만 게시합니다. |
| Promtail | `grafana/promtail:3.5.7` | 로그를 수집해 Loki로 보냅니다. 포트를 게시하지 않습니다. |
| node-exporter | `prom/node-exporter:v1.9.1` | VM2 호스트의 지표를 노출합니다. |
| redis-exporter | `oliver006/redis_exporter:v1.78.0` | VM2 Redis의 지표를 노출합니다. |

태그는 2026-09-18에 실제로 실행 중이던 버전으로 고정했습니다. 그전까지는 네 이미지가 모두
`latest`를 쓰고 있어서 재시작할 때마다 다른 버전이 뜰 수 있었습니다.

exporter 두 개는 이번에 새로 추가한 구성입니다. 이전 `prometheus.yml`의 `vm2-node` target은
`localhost:9100`이었는데, 이 주소는 Prometheus 컨테이너 자신을 가리켜서 호스트 지표를 전혀
수집하지 못했습니다. Redis target도 Redis 프로토콜 포트인 6379를 HTTP `/metrics`로 긁으려 했기
때문에 항상 실패했습니다. 각각 `node-exporter:9100`과 `redis-exporter:9121`로 바로잡았습니다.

네트워크는 core compose가 만드는 `api-network`를 external로 사용합니다. 따라서 이 스택을 띄우기
전에 `vm2-deployment`의 core compose가 먼저 기동되어 있어야 합니다.

---

## 배포

### GitHub Actions로 배포하는 방법

`.github/workflows/deploy-monitoring.yml`이 이 디렉터리를 VM2로 전송하고 스택을 다시 기동합니다.
GitHub 화면의 Actions 탭에서 `Deploy Monitoring Stack`을 열고 `Run workflow`를 누르면 실행됩니다.
`production` environment를 사용하므로 승인자가 승인해야 배포가 진행됩니다.

이 워크플로는 수동 실행만 받습니다. push할 때마다 자동으로 실행하지 않는 이유는 두 가지입니다.
첫째, 이 배포는 Prometheus와 Grafana와 Loki를 함께 다시 기동하므로 관측이 잠시 끊깁니다. 둘째,
`prometheus/targets`의 내용이 운영에서 바뀌어 있을 수 있어서, 전송하기 전에 사람이 현재 상태를
확인하는 편이 안전합니다.

#### `prometheus/targets`를 전송 대상에서 제외하는 이유

워크플로의 `rsync`는 `--delete`를 사용하되 `prometheus/targets/`를 제외합니다. 저장소에서 지운
rule 파일이 서버에 남아 계속 평가되는 상황은 막아야 하지만, target 디렉터리에는 같은 규칙을
적용할 수 없기 때문입니다. 이 디렉터리의 JSON 파일은 `monitoring/scripts/add-service.sh`가 운영
중에 만들고 지우는 대상이고, Prometheus가 30초마다 다시 읽는 서비스 디스커버리 입력입니다.
저장소 사본으로 `--delete`하면 운영에서 추가한 target이 사라져서 해당 서비스의 지표 수집이 조용히
멈춥니다.

저장소의 target 정의를 서버에 반영해야 할 때에는 현재 상태를 먼저 확인하고 필요한 파일만 옮깁니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP> 'ls /opt/bnbong/monitoring/prometheus/targets/'
scp monitoring/prometheus/targets/<파일> ubuntu@<VM2_PUBLIC_IP>:/opt/bnbong/monitoring/prometheus/targets/
```

### 손으로 배포하는 방법

```bash
ssh ubuntu@<VM2_PUBLIC_IP>
cd /opt/bnbong
sudo docker compose -f docker-compose.monitoring.yml up -d
sudo docker compose -f docker-compose.monitoring.yml ps
```

`.env`의 `VM2_PRIVATE_IP`와 `GRAFANA_ADMIN_PASSWORD`를 채워야 합니다. `VM2_PRIVATE_IP`가 비어
있으면 Grafana의 포트 바인딩이 조용히 모든 인터페이스로 넓어지는 대신 compose가 즉시 중단됩니다.
워크플로는 `.env`를 전송하지 않습니다. 서버에 있는 값이 원본이며, 로컬 파일로 덮어쓰면 운영 비밀이
사라질 수 있기 때문입니다.

---

## 접근 방법

- Grafana는 `https://monitoring.bnbong.com`으로 접근합니다. VM1 Nginx가 `10.0.1.60:3000`으로
  프록시합니다.
- Prometheus와 Loki는 외부에 게시하지 않습니다. VM2 안에서는 `http://127.0.0.1:9090`과
  `http://127.0.0.1:3100`으로 접근하고, 외부에서 보려면 SSH 터널을 사용합니다.

```bash
ssh -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 ubuntu@<VM2_PUBLIC_IP>
```

운영 Grafana의 `GF_SERVER_ROOT_URL`이 아직 `monitoring.bnbong.xyz`일 수 있습니다. 저장소 쪽이 더
최근 수정본이므로 도메인 변경이 운영에 반영되지 않았다고 보아야 하며, 반영할 때 Cloudflare DNS와
VM1 Nginx의 `server_name`을 함께 확인합니다.

---

## 수집 대상과 서비스 추가

`prometheus.yml`은 VM1과 VM3의 node-exporter를 고정 target으로, VM2의 애플리케이션을 파일 기반
서비스 디스커버리로 수집합니다. `msa-services` job이 `targets/*.json`을 30초마다 다시 읽으므로,
새 서비스를 추가할 때 Prometheus를 재시작하지 않아도 됩니다. 이 job은 각 파일의 `service` label을
`msa-<서비스 이름>` 형태로 `job` label에 복사합니다.

현재 등록된 target은 네 개입니다.

| 파일 | target | 붙는 job label |
|---|---|---|
| `targets/gateway.json` | `gateway:8000` | `msa-gateway` |
| `targets/auth-server.json` | `auth-server:8001` | `msa-auth-server` |
| `targets/wegis-server.json` | `wegis_server:9000` | `msa-wegis-server` |
| `targets/redis.json` | `redis-exporter:9121` | `msa-redis` |

Wegis의 target 주소에 밑줄이 들어간 이유는, 실제 운영 컨테이너 이름이 `wegis_server`이기
때문입니다.

새 서비스는 VM2에서 스크립트로 추가하고 제거합니다.

```bash
cd /opt/bnbong
./monitoring/scripts/add-service.sh user-service 8002 backend   # targets/user-service.json 생성
./monitoring/scripts/list-services.sh                           # 등록된 target 목록 확인
./monitoring/scripts/remove-service.sh user-service             # 제거. .bak 사본을 남깁니다
```

수집이 실제로 시작되었는지는 Prometheus API로 확인합니다.

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

VM1과 VM3의 node-exporter 컨테이너는 2026-09-18 기준으로 exited 상태였습니다. 두 target은
exporter를 다시 띄우기 전까지 down으로 남습니다.

---

## 알림 규칙

`prometheus/rules/basic.yml`에 열 개의 규칙을 두었고 `prometheus.yml`의 `rule_files`가 이
디렉터리를 읽습니다.

| 규칙 | 조건 | 지표 출처 |
|---|---|---|
| `TargetDown` | 5분 이상 scrape가 실패합니다. | Prometheus가 자체 생성하는 `up` 지표입니다. |
| `GatewayHighServerErrorRate` | Bifrost 전체의 5xx 비율이 10분 동안 5%를 넘습니다. | Bifrost의 직접 계측(`bifrost/src/core/metrics.py`)이 내보내는 `http_requests_total{status_class="5xx"}`입니다. |
| `GatewayUpstreamHighServerErrorRate` | 특정 upstream의 5xx 비율이 10분 동안 10%를 넘습니다. | 같은 지표를 `service` label로 나눕니다. 등록된 서비스 수만큼만 늘어나므로 카디널리티가 제한됩니다. |
| `AuthServerHighServerErrorRate` | Bidar의 5xx 비율이 10분 동안 5%를 넘습니다. | prometheus-fastapi-instrumentator가 내보내는 `http_requests_total{status=~"5.."}`입니다. |
| `BackupStale` | `component`가 `ship`이 아닌 백업의 마지막 성공이 8시간을 넘겼습니다. | 백업 job이 textfile collector로 내보내는 `bngdrasil_backup_last_success_timestamp_seconds`입니다. |
| `BackupShipStale` | `component="ship"`의 마지막 전송 성공이 14시간을 넘겼습니다. | 같은 지표를 `ship` component로 나눕니다. |
| `BackupUnshippedPileup` | 한 구성 요소에서 전송하지 못한 성공본이 4개를 넘습니다. | `retention.sh`와 `ship.sh`가 내보내는 `bngdrasil_backup_unshipped_total`입니다. |
| `BackupDiskLow` | 백업이 쌓이는 파티션의 여유 공간이 10GiB 미만인 상태가 30분 이어집니다. | node-exporter의 `node_filesystem_avail_bytes`를 `/var/backups`와 `/var`와 `/`로 좁혀서 봅니다. |
| `DiskSpaceLow` | 파일시스템 여유 공간이 15% 미만인 상태가 15분 이어집니다. | node-exporter의 `node_filesystem_avail_bytes`와 `node_filesystem_size_bytes`입니다. |
| `DiskSpaceCritical` | 파일시스템 여유 공간이 5% 미만인 상태가 5분 이어집니다. | 위와 같습니다. |

Gateway와 Auth Server의 규칙을 나눈 이유는 두 앱이 같은 이름의 지표를 서로 다른 label로 내보내기
때문입니다. Bifrost는 상태 코드를 `status_class="5xx"`로 묶어서 내보내고, Bidar는
`should_group_status_codes=False`라서 `status="500"`처럼 원래 코드를 그대로 내보냅니다. 하나의
식으로 두 형태를 같이 다루면 label이 맞지 않아 조용히 빈 결과가 나옵니다.

### 통지 경로

**Alertmanager는 도입하지 않았습니다.** receiver가 비어 있는 Alertmanager를 두면 경보가 아무
곳에도 도달하지 않으면서 통지 경로가 있는 것처럼 보이기 때문입니다. 통지는 Grafana alerting으로
연결합니다. Grafana에서 Prometheus 데이터 원본의 경보 상태를 조회하는 규칙을 만들고 연락 지점을
지정하십시오.

### 백업 지표와 textfile collector

백업 규칙이 사용하는 지표는 백업 job이 `.prom` 파일로 남기는 값입니다. VM2의 node-exporter에는
`--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`를 지정하고 호스트의
같은 경로를 읽기 전용으로 mount했습니다. **백업이 VM3에서 동작한다면 VM3의 node-exporter에도 같은
설정이 필요합니다.**

시계열이 한 번도 보고된 적이 없으면 이 규칙은 아예 평가되지 않습니다. 따라서 백업이 도는지를 이
규칙 하나로 판단하면 안 되며, 첫 보고가 실제로 들어왔는지는 배포 후에 직접 확인해야 합니다.
백업 스크립트가 내보내는 지표의 전체 목록은 [backup/README.md](../backup/README.md)에 있습니다.

기준 시간이 규칙마다 다른 이유는 로컬 백업과 오프사이트 전송의 주기가 다르기 때문입니다. 로컬
백업은 6시간 주기이므로 한 번 걸러도 바로 울리지 않도록 8시간을 기준으로 삼았습니다. 전송은
`run.sh`가 백업 직후에 수행하여 같은 6시간 주기이지만, 실패했을 때 2시간 주기의 재시도가 몇 번
동작할 여유를 더해 14시간을 기준으로 삼았습니다. 하나의 기준으로 두 경로를 함께 평가하면 정상
전송 주기에도 경보가 울립니다.

`bngdrasil_backup_unshipped_total`은 전송하지 못한 성공본의 개수입니다. `retention.sh`는 이
백업들을 삭제 대상에서 제외하므로, 전송이 막히면 백업 파티션이 계속 찹니다. 그래서 개수 자체를
지표로 내보내고 `BackupDiskLow`와 함께 보게 했습니다. 네 규칙 모두 첫 대응 절차를 `action`
annotation에 적어 두었으므로, 경보를 받은 사람은 Grafana에서 그 값을 그대로 읽으면 됩니다.

**아직 검증하지 않은 부분이 있습니다.** 이 규칙들은 `promtool check rules`로 문법만 확인했고,
실제 지표가 들어온 상태에서 경보가 발생하고 통지가 도착하는 것까지는 확인하지 않았습니다.

### readiness 알림은 아직 없습니다

Bifrost에는 DB 연결과 서비스 등록부를 함께 확인하는 `/ready`가 있지만, Prometheus는 `/metrics`만
수집하므로 readiness 실패를 나타내는 지표가 존재하지 않습니다. 이전 판에 있던 `service_ready`
규칙은 어디에도 없는 지표를 참조했기 때문에 제거했습니다. `/ready`를 감시하려면 blackbox
exporter로 HTTP probe를 걸고 그 결과 지표에 규칙을 붙여야 합니다. 이 작업은 다음 범위로
넘겼습니다.

---

## 로그 수집

Promtail은 Docker service discovery로 컨테이너 로그를 수집하며 `container`, `service`,
`compose_project`, `stream` label을 붙입니다. compose label이 없는 컨테이너는 `service` label이
비므로, pipeline 단계에서 컨테이너 이름으로 채웁니다. 수동 `docker run`으로 기동한
`wegis_server`가 여기에 해당합니다.

positions 파일은 `/var/lib/promtail/positions.yaml` 전용 volume에 보관합니다. 이전 판은 이 파일을
`/tmp`에 두었기 때문에 컨테이너를 다시 만들 때 읽은 위치가 사라져서 같은 로그를 처음부터 다시
읽었습니다.

Grafana의 Explore 화면에서 다음과 같이 조회합니다.

```logql
{job="docker"}                               # 모든 컨테이너 로그
{job="docker", container="vm2-gateway"}      # 특정 컨테이너
{job="docker"} |= "ERROR"                    # 오류만
{job="varlogs", host="vm2"}                  # 호스트 시스템 로그
```

Loki의 보존 기간은 168시간이며 compactor가 그 기간을 넘긴 로그를 지웁니다.

### Promtail 교체 예정

**Promtail은 2026-03-02에 지원이 끝납니다.** Grafana Alloy로 전환할 예정이며 이번 범위에는 넣지
않았습니다. 전환할 때 label 구성과, 수집기를 재시작한 뒤의 중복과 유실과, 보존 설정을 따로
검증해야 합니다.

전환할 때 함께 재검토할 항목이 하나 더 있습니다. 현재 Promtail은 컨테이너 이름과 compose label을
읽기 위해 `/var/run/docker.sock`을 읽기 전용으로 mount합니다. 읽기 전용이라고 해도 Docker API
전체를 조회할 수 있는 권한이므로, 수집기를 바꾸는 시점에 권한 범위를 다시 판단합니다.

---

## 문제를 확인하는 순서

Prometheus가 서비스를 감지하지 못할 때에는 target 파일과 로그와 target 상태를 차례로 봅니다.

```bash
cat /opt/bnbong/monitoring/prometheus/targets/<서비스>.json
sudo docker logs vm2-prometheus | grep -i 'error\|warn'
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up")'
```

지표가 수집되지 않을 때에는 서비스가 `/metrics`를 실제로 노출하는지와, Prometheus 컨테이너에서
그 주소에 닿는지를 확인합니다.

```bash
sudo docker exec vm2-prometheus wget -O- http://<서비스>:<포트>/metrics
```

컨테이너가 실행 중이라는 사실만으로 그 구성 요소가 정상이라고 판단하지 않습니다. 예를 들어
2026-09-18 실사에서 `vm2-promtail`은 created 상태에 머물러 있었고, 그래서 Loki에 들어간 컨테이너
로그가 없었습니다. Grafana의 로그 조회 화면이 비어 있던 이유가 여기에 있습니다.

---

## 관련 문서

| 문서 | 다루는 내용 |
|---|---|
| [../README.md](../README.md) | 저장소 전체 구조와 Terraform 사용 절차를 설명합니다. |
| [../docs/deployment-inventory.md](../docs/deployment-inventory.md) | 2026-09-18 기준의 실제 배포 상태를 기록했습니다. |
| [../vm2-deployment/README.md](../vm2-deployment/README.md) | core compose와 애플리케이션 배포 절차를 설명합니다. |
| [../backup/README.md](../backup/README.md) | 백업 체계와 백업 지표의 출력 형식을 설명합니다. |
| [../docs/github-actions-setup.md](../docs/github-actions-setup.md) | 배포 워크플로의 전체 구조와 secret 구성, 최초 준비 절차를 설명합니다. |
