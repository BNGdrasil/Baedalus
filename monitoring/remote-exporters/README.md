# 원격 호스트 exporter

VM2의 Prometheus가 수집하는 대상 중에서 VM2 바깥에 있는 것들을 설치하는 스크립트를 모아 둔
디렉터리입니다. VM2 자신의 exporter는 `monitoring/docker-compose.monitoring.yml`이 컨테이너로
띄우지만, VM1과 VM3에는 관측 스택이 없기 때문에 호스트에 직접 설치해야 합니다.

| 스크립트 | 설치 대상 호스트 | 노출 주소 | 무엇을 수집하는가 |
|---|---|---|---|
| `install-node-exporter.sh` | VM1(10.0.1.133), VM3(10.0.2.134) | `<private IP>:9100` | CPU와 메모리와 디스크 같은 호스트 지표를 수집하고, VM3에서는 백업 스크립트가 남긴 textfile 지표도 함께 노출합니다. |
| `install-postgres-exporter.sh` | VM3(10.0.2.134) | `<private IP>:9187` | 호스트에 설치된 PostgreSQL의 접속 수와 트랜잭션과 복제 상태를 수집합니다. |
| `install-nginx-exporter.sh` | VM1(10.0.1.133) | `<private IP>:9113` | nginx의 `stub_status`를 읽어서 연결 수와 요청 수를 수집합니다. |

세 스크립트는 모두 systemd 서비스로 설치하며 Docker를 사용하지 않습니다. VM1과 VM3에는 관측용
compose 파일이 없고, node-exporter를 컨테이너로 띄우려면 호스트의 `/proc`과 `/sys`와 루트
파일시스템을 모두 mount해야 해서 얻는 것보다 잃는 것이 많다고 판단했습니다.

## 현재 운영 상태와 이 스크립트의 관계

`bngdrasil/docs/overhaul-2026-09/README.md`의 실행 기록 16번 항목에는 2026-09-19 이후에 VM1과
VM3에 node-exporter를 설치했고, 호스트 iptables의 `REJECT` 규칙보다 앞선 위치에 허용 규칙을 넣어서
수집이 되도록 만들었다고 적혀 있습니다. 그 뒤에 2026-09-20에 두 호스트를 읽기 전용으로 점검해서
설치 방식을 확인했으므로, 아래 표에 그 결과를 정리해 둡니다.

| 항목 | VM1(10.0.1.133) | VM3(10.0.2.134) |
|---|---|---|
| 설치 방식 | 2026-09-19에 `docker run`으로 띄운 컨테이너입니다. compose 파일을 쓰지 않았습니다. | VM1과 같습니다. |
| systemd 유닛과 호스트 바이너리 | 없습니다. | 없습니다. |
| 컨테이너 이름과 이미지 | `node-exporter`, `prom/node-exporter:v1.9.1` | `node-exporter`, `prom/node-exporter:v1.9.1` |
| 실행 옵션 | `--network host`, `--pid host`, restart 정책은 `unless-stopped`입니다. | VM1과 같습니다. |
| 바인드 마운트 | `/:/host:ro,rslave` 하나입니다. | `/:/host:ro,rslave`와 `/var/lib/node_exporter/textfile_collector:/textfile:ro` 두 개입니다. |
| 프로세스 인자 | `--path.rootfs=/host` | `--path.rootfs=/host`, `--collector.textfile.directory=/textfile` |
| 듣고 있는 주소 | 모든 주소의 9100번 포트(`*:9100`)입니다. | 모든 주소의 9100번 포트(`*:9100`)입니다. |
| 방화벽 | 호스트 iptables의 `INPUT` 사슬에서 `REJECT`보다 앞에 `-s 10.0.1.60/32 -p tcp --dport 9100 -j ACCEPT`가 들어 있습니다. | VM1과 같습니다. |
| textfile 수집 | 설정하지 않았습니다. VM1에는 백업이 돌지 않기 때문입니다. | `/var/lib/node_exporter/textfile_collector`를 읽습니다. |

따라서 이 디렉터리의 스크립트는 현재 운영 상태를 그대로 옮겨 적은 것이 아니라, 저장소의 다른
정의와 맞추어 새로 작성한 기준안입니다. 두 방식의 차이는 세 가지입니다. 첫째, 컨테이너는 모든
주소의 9100번 포트를 듣지만 스크립트가 만드는 유닛은 호스트의 private IP에만 바인딩합니다. 둘째,
컨테이너는 root로 돌지만 유닛은 전용 시스템 사용자 `node_exporter`로 돕니다. 셋째, 유닛에는
systemd 하드닝 옵션과 `IPAddressDeny=any`가 붙습니다.

### 지금은 그대로 두어도 됩니다

현재의 컨테이너 방식은 정상으로 동작하고 있습니다. 두 호스트 모두 9100번 포트를 열어 두었고
방화벽 허용 규칙도 `REJECT` 앞에 들어가 있으므로, VM2의 Prometheus가 두 target을 수집합니다.
VM3에서는 백업 스크립트가 남기는 `bngdrasil_backup_` 지표도 함께 올라옵니다. 그러므로 이 스크립트를
지금 당장 적용해야 할 이유는 없으며, systemd 방식으로 바꾸는 작업은 선택입니다.

선택지는 두 가지입니다. 하나는 현재의 컨테이너 방식을 그대로 유지하면서 이 문서의 표를 설치
기록으로 삼는 방법이고, 다른 하나는 아래 절차를 밟아서 systemd 유닛으로 전환하는 방법입니다.
후자를 고르면 바인딩 주소가 좁아지고 실행 사용자의 권한이 낮아지지만, 전환하는 동안 수집이 잠시 끊기고
VM3에서는 `/var/lib/node_exporter`의 권한을 함께 바꾸어야 합니다.

세 스크립트는 설치를 시작하기 전에 대상 포트를 다른 프로세스가 듣고 있는지 확인하고,
`install-node-exporter.sh`는 이름이 `node-exporter`이거나 이미지가 `prom/node-exporter`인
컨테이너가 남아 있는지도 함께 확인합니다. 둘 중 하나라도 걸리면 스크립트는 아무것도 바꾸지 않고
비정상 종료 상태로 끝납니다. 이 점검을 건너뛰는 플래그는 일부러 만들지 않았으므로, 전환하려면
아래 절차대로 기존 컨테이너를 먼저 정리해야 합니다.

### 컨테이너에서 systemd 유닛으로 전환하는 절차

전환하는 동안 해당 호스트의 지표 수집이 대략 1분에서 2분 정도 끊깁니다. Prometheus의 수집 주기와
`TargetDown` 경보의 `for` 조건을 고려하면 경보가 울리기 전에 끝나는 길이이지만, 작업 시간을 미리
공유해 두는 편이 안전합니다. 아래는 VM3를 대상으로 적은 명령이며, VM1에서는 주소만 바꾸면
됩니다.

```bash
# 1) 지금 무엇이 돌고 있는지 다시 확인합니다
sudo docker inspect node-exporter --format '{{.Config.Image}} {{.HostConfig.RestartPolicy.Name}}'
sudo ss -H -ltnp | grep :9100

# 2) 기존 컨테이너를 중지하고 제거합니다. restart 정책이 unless-stopped 이므로
#    stop 만 하고 rm 을 빠뜨리면 호스트를 재부팅할 때 되살아납니다
sudo docker stop node-exporter
sudo docker rm node-exporter

# 3) 스크립트를 실행합니다. 먼저 --dry-run 으로 무엇이 바뀌는지 봅니다
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.2.134 --dry-run
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.2.134

# 4) 호스트에서 유닛과 지표를 확인합니다
systemctl status node_exporter.service
curl -s http://10.0.2.134:9100/metrics | head
```

다음으로 VM2에서 원격 수집이 돌아왔는지 확인합니다. VM3에서는 백업 지표가 함께 올라오는지도 같이
보아야 합니다. 유닛은 컨테이너와 달리 비root 사용자로 돌기 때문에, `/var/lib/node_exporter`가
0700으로 남아 있으면 textfile 지표만 조용히 사라집니다.

```bash
# VM2에서 실행합니다
curl -s http://10.0.2.134:9100/metrics | head
curl -s http://10.0.2.134:9100/metrics | grep bngdrasil_backup_
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | select(.labels.job == "vm3-node") | {health, lastError}'
```

`bngdrasil_backup_`으로 시작하는 지표가 한 줄도 보이지 않으면 전환이 끝나지 않은 상태입니다.
`install-node-exporter.sh`는 설치를 마치면서 서비스 사용자로 textfile 디렉터리를 읽어 보고, 읽지
못하면 경고가 아니라 오류로 끝냅니다. 그래도 지표가 비어 있다면 경로 위의 어느 디렉터리에서
막히는지 `namei -l /var/lib/node_exporter/textfile_collector`로 확인하십시오.

### 되돌리는 방법

전환한 뒤에 문제가 생기면 유닛을 제거하고 원래의 컨테이너를 그대로 다시 띄웁니다. 아래 명령은
2026-09-20에 확인한 실제 실행 옵션을 그대로 옮긴 것입니다.

```bash
# 먼저 유닛을 제거합니다. textfile 디렉터리와 그 안의 .prom 파일은 남습니다
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.2.134 --uninstall

# VM1(10.0.1.133)에서 되돌릴 때 사용합니다
sudo docker run -d \
  --name node-exporter \
  --network host \
  --pid host \
  --restart unless-stopped \
  -v /:/host:ro,rslave \
  prom/node-exporter:v1.9.1 \
  --path.rootfs=/host

# VM3(10.0.2.134)에서 되돌릴 때 사용합니다. textfile collector 설정이 하나 더 붙습니다
sudo docker run -d \
  --name node-exporter \
  --network host \
  --pid host \
  --restart unless-stopped \
  -v /:/host:ro,rslave \
  -v /var/lib/node_exporter/textfile_collector:/textfile:ro \
  prom/node-exporter:v1.9.1 \
  --path.rootfs=/host \
  --collector.textfile.directory=/textfile
```

컨테이너는 root로 돌기 때문에 `/var/lib/node_exporter`의 권한이 0755로 바뀌어 있어도 그대로
동작합니다. 권한을 원래대로 되돌리고 싶다면 `sudo chmod 0700 /var/lib/node_exporter`를 함께
실행하십시오. 다만 그 상태에서 다시 systemd 유닛으로 전환하면 스크립트가 같은 권한을 또 고칩니다.

방화벽 규칙은 컨테이너와 유닛이 같은 9100번 포트를 쓰므로 전환할 때 건드릴 필요가 없습니다.

---

## 적용 순서

전체 디렉터리를 대상 호스트로 옮긴 다음에 실행합니다. 각 스크립트가 `lib/common.sh`를 읽기
때문에 파일 하나만 복사하면 동작하지 않습니다.

```bash
# 작업용 장비에서
rsync -av --exclude '.git' monitoring/remote-exporters/ ubuntu@<대상 호스트>:/tmp/remote-exporters/
```

VM3는 private subnet에 있으므로 VM2를 경유해야 합니다. `ProxyJump`를 사용하십시오.

### 1단계. 무엇을 바꿀지 먼저 확인합니다

모든 스크립트는 `--dry-run`을 지원합니다. 이 상태에서는 파일을 쓰지 않고 서비스도 건드리지
않으며, 내려받을 주소와 만들 파일의 목록만 출력합니다.

```bash
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.1.133 --dry-run
```

사전 점검은 `--dry-run`에서도 그대로 수행합니다. 대상 포트를 다른 프로세스가 듣고 있거나 기존
node-exporter 컨테이너가 남아 있으면, 계획을 출력하지 않고 점유 상황을 보여 준 뒤에 비정상 종료
상태로 끝냅니다. 이때는 위의 "컨테이너에서 systemd 유닛으로 전환하는 절차"를 먼저 밟아야 합니다.

### 2단계. VM1에 설치합니다

```bash
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.1.133
sudo /tmp/remote-exporters/install-nginx-exporter.sh --listen-address 10.0.1.133
```

`install-nginx-exporter.sh`는 nginx의 `stub_status`가 열려 있어야 실제 지표를 만듭니다. 아래의
nginx 설정 절을 먼저 읽으십시오.

### 3단계. VM3에 설치합니다

```bash
sudo /tmp/remote-exporters/install-node-exporter.sh --listen-address 10.0.2.134
sudo -u postgres psql -p 5432 -f /tmp/remote-exporters/postgres-exporter-role.sql
sudo -u postgres psql -p 5432 -c '\password bngdrasil_exporter'
sudo /tmp/remote-exporters/install-postgres-exporter.sh --listen-address 10.0.2.134
sudo vi /etc/bngdrasil-exporters/postgres-exporter.env     # 비밀번호를 채웁니다
sudo /tmp/remote-exporters/install-postgres-exporter.sh --listen-address 10.0.2.134
```

`install-postgres-exporter.sh`를 두 번 실행하는 이유는 다음과 같습니다. 첫 번째 실행은 바이너리와
유닛과 환경 파일 템플릿까지만 만들고 서비스를 기동하지 않습니다. 비밀번호 자리에 자리 표시
문자열이 남아 있는 상태로 기동하면 서비스가 접속에 실패하면서 재시작을 반복하기 때문입니다.
비밀번호를 채운 뒤에 같은 명령을 다시 실행하면 그때 기동합니다.

### 4단계. 방화벽 규칙을 넣습니다

스크립트는 방화벽을 바꾸지 않고, 필요한 규칙을 출력으로 안내만 합니다. 운영 기록에 따르면 이전에도
호스트 iptables 때문에 수집이 막힌 적이 있으므로, 규칙을 넣는 위치에 특히 주의해야 합니다. Ubuntu
기본 규칙에는 `INPUT` 사슬 끝부분에 `REJECT`가 있어서, 허용 규칙을 `-A`로 뒤에 붙이면 아무 효과가
없습니다.

```bash
# VM1에서 9100과 9113을 VM2에만 엽니다
sudo iptables -C INPUT -p tcp -s 10.0.1.60 --dport 9100 -j ACCEPT 2>/dev/null \
  || sudo iptables -I INPUT 1 -p tcp -s 10.0.1.60 --dport 9100 -j ACCEPT
sudo iptables -C INPUT -p tcp -s 10.0.1.60 --dport 9113 -j ACCEPT 2>/dev/null \
  || sudo iptables -I INPUT 1 -p tcp -s 10.0.1.60 --dport 9113 -j ACCEPT
sudo netfilter-persistent save
```

VM3에서는 같은 방식으로 9100과 9187을 엽니다. OCI security list 또는 network security group에도
출발지를 `10.0.1.60/32`로 한정한 ingress 규칙이 있어야 하며, `0.0.0.0/0`으로 열린 규칙이 있다면
제거해야 합니다. 세 exporter 모두 systemd 유닛에 `IPAddressDeny=any`를 넣고, loopback과 VM2
주소와 자기 호스트의 private IP만 `IPAddressAllow`로 허용해 두었습니다. 자기 호스트의 주소를
함께 허용하는 이유는, 같은 장비에서 자신의 private IP로 확인 조회를 하면 출발지 주소가 loopback이
아니라 그 private IP가 되기 때문입니다. 다만 이 설정은 커널이 cgroup BPF를 지원하지 않으면 경고만
남기고 무시되므로 방화벽 대신 쓸 수는 없습니다.

### 5단계. Prometheus 수집을 켭니다

exporter 설치와 방화벽 규칙을 모두 마친 뒤에 VM2에서 실행합니다.

```bash
cd /opt/bnbong/monitoring/prometheus
sudo cp targets-examples/vm1-nginx.json.example    targets/remote/vm1-nginx.json
sudo cp targets-examples/vm3-postgres.json.example targets/remote/vm3-postgres.json
```

`targets/remote/` 디렉터리는 모니터링 compose가 Prometheus의 bind mount로 지정해 두었으므로 이미
만들어져 있습니다. 없다면 `sudo mkdir -p targets/remote`로 만든 뒤에 복사하십시오.

Prometheus가 30초마다 이 디렉터리를 다시 읽으므로 재시작하지 않아도 됩니다. 확인 방법과 되돌리는
방법은 [../README.md](../README.md)의 "원격 exporter 수집 활성화" 항목에 있습니다.

---

## 검증

각 스크립트는 마지막에 스스로 `/metrics`를 한 번 조회하고 결과를 출력합니다. 그 뒤에 사람이 아래
명령으로 다시 확인합니다.

```bash
# 대상 호스트에서
curl -s http://10.0.1.133:9100/metrics | head
curl -s http://10.0.1.133:9113/metrics | grep -m1 nginx_up
curl -s http://10.0.2.134:9100/metrics | head
curl -s http://10.0.2.134:9187/metrics | grep -m1 pg_up

# VM2에서 원격 접근이 되는지 확인합니다. 방화벽 규칙이 맞아야 응답이 옵니다
curl -s http://10.0.1.133:9100/metrics | head
curl -s http://10.0.2.134:9187/metrics | grep -m1 pg_up

# Prometheus가 실제로 수집하는지 확인합니다
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, health: .health, error: .lastError}'
```

`nginx_up`과 `pg_up`은 값이 1이어야 정상입니다. 0이면 exporter 자체는 떠 있지만 대상에 접속하지
못하고 있다는 뜻이므로, `journalctl -u <유닛 이름> -n 50`으로 원인을 확인하십시오.

VM3에서는 백업 지표가 함께 올라오는지도 확인합니다. 백업 스크립트가 남기는 `.prom` 파일의 위치와
node-exporter의 `--collector.textfile.directory` 값이 같아야 합니다.

```bash
ls -l /var/lib/node_exporter/textfile_collector/
curl -s http://10.0.2.134:9100/metrics | grep bngdrasil_backup
```

이 경로는 `backup/lib/common.sh`의 `METRICS_DIR` 기본값과 같은 값입니다. 백업 쪽에서
`/etc/bngdrasil-backup/env`의 `METRICS_DIR`을 바꾸었다면, node-exporter 설치에도
`--textfile-dir`로 같은 경로를 넘겨야 합니다. 두 값이 어긋나면 지표가 사라지고 `BackupStale`
경보가 실제 상황과 무관하게 울립니다.

---

## nginx-exporter를 위한 nginx 설정

`stub_status`는 nginx에 기본으로 켜져 있지 않습니다. VM1의 `nginx.conf`는 Bantheon 저장소가
소유하고 있으므로 이 저장소에서는 고치지 않고, 필요한 설정 조각을 제안으로만 적어 둡니다.

VM1의 nginx는 `nginx:alpine` 컨테이너로 돌고 80번과 443번 포트를 게시하고 있습니다. 따라서 설정
조각을 추가하는 것만으로는 부족하고, 컨테이너의 8080번 포트를 호스트의 loopback에 게시하는 작업도
함께 필요합니다.

첫째, Bantheon의 nginx 설정에 아래 server 블록을 추가합니다. 외부에서는 닿을 수 없도록 접근
주소를 컨테이너 내부로 한정합니다.

```nginx
# stub_status 전용 server. 이 주소는 nginx-prometheus-exporter만 사용합니다.
server {
    listen 8080;
    server_name _;

    # 컨테이너 안에서 보는 출발지 주소입니다. Docker의 포트 게시를 거치면 출발지가
    # 게이트웨이 주소로 바뀌므로, loopback만 허용하면 접근이 막힐 수 있습니다.
    # 아래 172.16.0.0/12는 Docker 기본 bridge 대역입니다.
    location = /stub_status {
        stub_status;
        allow 127.0.0.1;
        allow 172.16.0.0/12;
        deny all;
        access_log off;
    }

    location / {
        return 404;
    }
}
```

둘째, VM1의 `/opt/bnbong/docker-compose.yml`에서 nginx 서비스의 포트 목록에 아래 항목을
추가합니다. 호스트의 loopback에만 게시하므로 외부에서는 보이지 않습니다.

```yaml
    ports:
      - "80:80"
      - "443:443"
      - "127.0.0.1:8080:8080"
```

셋째, 설정을 반영한 뒤에 `stub_status`가 응답하는지 확인하고 exporter를 설치합니다.

```bash
curl -s http://127.0.0.1:8080/stub_status
sudo ./install-nginx-exporter.sh --listen-address 10.0.1.133
```

`stub_status`가 주는 정보는 활성 연결 수와 누적 요청 수 정도이며, 상태 코드별 분포나 응답 시간은
포함하지 않습니다. 그런 지표가 필요해지면 로그 기반 수집이나 별도 모듈을 검토해야 합니다.

---

## Prometheus 수집 설정

이 절의 내용은 이미 `monitoring/prometheus/prometheus.yml`에 반영되어 있습니다. 여기에서 다시
고칠 것은 없으며, 아래는 무엇이 어떻게 들어갔는지를 설명하는 부분입니다.

`vm1-nginx` job과 `vm3-postgres` job을 추가했습니다. 두 job은 주소를 `static_configs`에 직접
적지 않고 파일 기반 서비스 디스커버리로 읽습니다. exporter를 설치하기 전에 주소를 적어 두면 두
target이 계속 down으로 남아서 `TargetDown` 경보가 쉬지 않고 울리고, 그러면 나머지 경보까지 함께
묻히기 때문입니다. 대상 파일이 없으면 target 자체가 만들어지지 않으므로, 설치를 마친 사람이
파일을 만들어서 수집을 켜는 구조입니다.

| job | 대상 파일 | 수집 주소 |
|---|---|---|
| `vm1-nginx` | `/etc/prometheus/targets/remote/vm1-nginx.json` | `10.0.1.133:9113` |
| `vm3-postgres` | `/etc/prometheus/targets/remote/vm3-postgres.json` | `10.0.2.134:9187` |

파일에 넣을 내용은 저장소의 `monitoring/prometheus/targets-examples/` 아래에 예시로 두었습니다.
`targets/remote/`는 배포 워크플로의 rsync 제외 대상이므로, 한 번 만들어 둔 파일은 배포를
반복해도 지워지지 않습니다.

`msa-services` job이 읽는 `targets/*.json`과는 겹치지 않습니다. file_sd의 `*`는 경로 구분자를
넘지 않기 때문에 `targets/remote/` 아래의 파일은 그 glob에 걸리지 않으며, VM2 애플리케이션의
`msa-<이름>` 명명 규칙과 호스트 exporter가 섞이는 일도 없습니다.

### 함께 들어간 경보 규칙

`monitoring/prometheus/rules/basic.yml`에 `NginxDown`과 `PostgresDown`을 추가했습니다. 각각
`nginx_up == 0`과 `pg_up == 0`이 5분 이어질 때 발화합니다. 두 지표는 exporter가 대상에 실제로
접속했는지를 나타내므로, exporter는 떠 있는데 nginx나 PostgreSQL이 멈춘 구간을 잡습니다. 그
구간에서는 `up`이 1이어서 `TargetDown`으로는 보이지 않습니다.

단위 시험은 `monitoring/prometheus/tests/remote-exporters.yml`에 있습니다.

## 버전과 무결성

| exporter | 고정 버전 | 배포처 |
|---|---|---|
| node_exporter | 1.9.1 | `prometheus/node_exporter` |
| postgres_exporter | 0.20.1 | `prometheus-community/postgres_exporter` |
| nginx-prometheus-exporter | 1.5.3 | `nginx/nginx-prometheus-exporter` |

node_exporter의 버전은 VM2 compose가 사용하는 `prom/node-exporter:v1.9.1` 태그와 맞추었습니다.
세 호스트가 같은 버전을 쓰면 지표 이름이 갈리지 않고 Grafana 대시보드도 한 벌로 유지됩니다.

체크섬은 스크립트에 적어 두지 않고, 릴리스가 함께 배포하는 `sha256sums.txt` 또는
`*_checksums.txt` 파일을 내려받아 대조합니다. 아키텍처마다 값이 다르기 때문에 소스에 고정하면
amd64와 arm64 중 한쪽이 반드시 틀리게 되고, 값을 갱신하는 일도 사람 손에 남습니다. 대조에
실패하면 스크립트는 설치를 진행하지 않고 즉시 종료합니다.

버전을 올릴 때에는 `--version` 인자로 먼저 시험해 보고, 확정되면 각 스크립트 상단의 기본값과 이
표를 함께 고칩니다.

---

## 멱등성과 재실행

같은 인자로 몇 번을 실행해도 결과가 같습니다. 구체적으로는 다음과 같이 동작합니다.

- 이미 설치된 바이너리가 같은 버전이면 내려받지 않습니다. `--version` 출력에서 버전 문자열을
  확인합니다.
- systemd 유닛 파일은 새로 만들 내용과 기존 내용을 비교해서, 달라졌을 때에만 교체합니다.
- 바이너리나 유닛이 실제로 바뀌었을 때에만 서비스를 재시작합니다. 바뀐 것이 없으면 실행 중인
  서비스를 그대로 둡니다.
- `postgres-exporter.env`는 이미 있으면 덮어쓰지 않습니다. 이 파일에 실제 비밀번호가 들어 있기
  때문입니다.
- textfile collector 디렉터리와 시스템 사용자는 없을 때에만 만듭니다.
- textfile collector 디렉터리까지 내려가는 경로에 others 실행 비트가 없는 디렉터리가 있으면 0755로
  고칩니다. 이미 0755인 경로는 그대로 둡니다. 고치는 대상은 목표 디렉터리 자신과 이름이
  `node_exporter` 계열인 디렉터리, 그리고 그 아래의 디렉터리로 한정하며, `/`와 `/var`와 `/var/lib`
  같은 시스템 디렉터리는 권한을 바꾸지 않고 경고만 남깁니다.
- 설치를 마치면서 서비스 사용자로 textfile collector 디렉터리를 실제로 읽어 봅니다. 여기에서
  실패하면 경고에 그치지 않고 오류로 끝냅니다. 이 확인이 없으면 textfile 지표만 조용히 사라지고
  `BackupStale` 경보가 실제 상황과 무관하게 울립니다.

`--uninstall`은 서비스를 중지하고 유닛 파일과 바이너리를 제거합니다. 백업 지표가 쌓인 textfile
디렉터리와 PostgreSQL 역할과 환경 파일은 지우지 않습니다. 이들은 exporter보다 수명이 길고, 다시
설치할 때 그대로 쓰는 편이 안전하기 때문입니다.

---

## 비밀 값을 다루는 방식

postgres_exporter는 접속 문자열을 명령 인자로 받지 않습니다. 인자로 넘기면 같은 호스트의 다른
사용자가 `ps`나 `/proc/<pid>/cmdline`으로 비밀번호를 읽을 수 있기 때문입니다. 대신 다음 경로를
따릅니다.

1. 접속 문자열은 `/etc/bngdrasil-exporters/postgres-exporter.env`에만 둡니다. 권한은 0600이고
   소유자는 root입니다.
2. systemd가 `EnvironmentFile`로 그 파일을 읽어서 프로세스 환경 변수로 넣습니다.
3. exporter는 `DATA_SOURCE_NAME` 환경 변수에서 접속 문자열을 읽습니다.

비밀번호 자체는 `postgres-exporter-role.sql`로 역할을 만든 뒤에 psql의 `\password` 명령으로
지정합니다. 이 명령은 입력을 화면에 보여 주지 않고 셸 이력에도 남기지 않습니다.

역할에는 `pg_monitor`만 부여합니다. 이 내장 역할은 설정값과 통계를 읽을 권한을 묶은 것이며 사용자
데이터를 읽을 권한은 포함하지 않습니다. 슈퍼유저 권한과 복제 권한은 SQL에서 명시적으로
제거하고, 동시 접속 수도 5로 제한합니다.

VM3에는 PostgreSQL 17이 5432번 포트에 있고 이전 세대인 14가 5433번 포트에 남아 있습니다.
**5433번의 14 클러스터는 관측 대상에 넣지 않습니다.** 2026-11-12에 지원이 끝나는 세대를 보존한
사본이고 그 시점에 제거할 예정이므로, 지금 수집을 붙이면 폐기할 때 exporter 인스턴스와 경보와
대시보드를 다시 걷어 내는 일만 남기 때문입니다. `vm3-postgres` job과 `PostgresDown` 규칙은
5432번 포트의 17 클러스터만 봅니다.

폐기 일정이 미루어져서 14 클러스터도 보아야 한다면, `--name`과 `--port`로 두 번째 인스턴스를
설치하고 그 환경 파일의 접속 문자열에서 포트를 5433으로 지정합니다. 이때 Prometheus에도 별도
job과 대상 파일을 추가해야 합니다.

```bash
sudo ./install-postgres-exporter.sh --listen-address 10.0.2.134 --name legacy14 --port 9188
```
