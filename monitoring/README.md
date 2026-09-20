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
| Grafana | `grafana/grafana:12.2.1` | 지표와 로그를 시각화합니다. 3000번 포트를 private IP와 loopback에 게시합니다. 통지는 Grafana가 아니라 Alertmanager가 맡습니다. |
| Loki | `grafana/loki:3.5.7` | 로그를 저장합니다. 3100번 포트를 loopback에만 게시합니다. |
| Grafana Alloy | `grafana/alloy:v1.19.2` | 로그를 수집해 Loki로 보냅니다. 포트를 게시하지 않습니다. |
| docker-socket-proxy | `tecnativa/docker-socket-proxy:v0.5.0` | Alloy가 Docker API를 읽을 때 거치는 프록시입니다. 포트를 게시하지 않습니다. |
| node-exporter | `prom/node-exporter:v1.9.1` | VM2 호스트의 지표를 노출합니다. |
| redis-exporter | `oliver006/redis_exporter:v1.78.0` | VM2 Redis의 지표를 노출합니다. |
| blackbox-exporter | `prom/blackbox-exporter:v0.28.0` | 공개 도메인과 내부 endpoint에 HTTP probe를 겁니다. 포트를 게시하지 않습니다. |
| cAdvisor | `gcr.io/cadvisor/cadvisor:v0.52.1` | 컨테이너 단위의 CPU와 메모리 사용량을 노출합니다. 포트를 게시하지 않습니다. |
| Alertmanager | `prom/alertmanager:v0.28.1` | 경보를 Discord로 통지합니다. `alerting` profile에서만 기동하며 9093번 포트를 loopback에만 게시합니다. |

태그는 2026-09-18에 실제로 실행 중이던 버전으로 고정했습니다. 그전까지는 네 이미지가 모두
`latest`를 쓰고 있어서 재시작할 때마다 다른 버전이 뜰 수 있었습니다. 뒤에 추가한 이미지도 같은
이유로 태그를 고정했습니다. VM2는 Ampere 기반 ARM64 인스턴스(`VM.Standard.A1.Flex`)이므로 모든
이미지를 `linux/arm64` manifest가 있는 것으로 골랐고, `docker manifest inspect`로 직접
확인했습니다.

로그 수집기는 Promtail에서 Grafana Alloy로 교체했습니다. Promtail은 2026-03-02에 지원이
끝났습니다. 교체하면서 Docker API 접근 경로도 함께 바꾸었으며, 두 결정의 근거와 전환 절차는
아래의 "로그 수집" 항목에 모아 두었습니다.

node-exporter와 redis-exporter는 잘못된 수집 주소를 바로잡으면서 추가한 구성입니다. 이전
`prometheus.yml`의 `vm2-node` target은 `localhost:9100`이었는데, 이 주소는 Prometheus 컨테이너
자신을 가리켜서 호스트 지표를 전혀 수집하지 못했습니다. Redis target도 Redis 프로토콜 포트인
6379를 HTTP `/metrics`로 긁으려 했기 때문에 항상 실패했습니다. 각각 `node-exporter:9100`과
`redis-exporter:9121`로 바로잡았습니다.

VM1과 VM3에서 동작해야 하는 exporter는 이 표에 없습니다. 두 호스트에는 관측용 compose가 없기
때문입니다. 두 호스트의 node-exporter는 2026-09-19에 `docker run`으로 띄운 컨테이너로 돌고 있고,
저장소에는 같은 역할을 systemd 서비스로 설치하는 스크립트를 따로 두었습니다. 현재 상태와 두 방식의
차이는 [remote-exporters/](remote-exporters/README.md)에 정리해 두었습니다.

Prometheus의 보존 설정은 시간과 크기를 함께 지정합니다. 시간 기준은 7일이고, 크기 기준은 3GB를
상한으로 둡니다. 둘 가운데 먼저 걸리는 쪽이 적용됩니다. 현재 수집 규모에서 7일치는 수백 MB
수준이므로 크기 기준은 평소에 전혀 걸리지 않습니다. 이번에 cAdvisor와 blackbox probe를 추가하면서
시계열 수가 늘어나기 때문에, 카디널리티가 예상보다 커졌을 때 TSDB가 VM2의 root 디스크를 채우기
전에 오래된 블록부터 잘라 내게 하려는 안전장치입니다.

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

#### 배포 성공과 실패를 가르는 기준

워크플로는 컨테이너가 떴다는 사실만으로 성공을 판정하지 않습니다. 아래 네 가지를 확인하며, 그
가운데 하나라도 어긋나면 배포를 실패로 끝냅니다.

| 확인 항목 | 실패로 다루는 조건 |
|---|---|
| 이미지 내려받기 | `docker compose pull`이 실패할 때입니다. 이 단계는 컨테이너를 건드리기 전에 수행하므로, 실패하면 운영 상태가 그대로 유지된 채 배포만 중단됩니다. |
| 필수 scrape job | `prometheus`, `vm2-node`, `msa-gateway`, `msa-auth-server`, `blackbox-exporter`, `cadvisor`, `alloy` 가운데 하나라도 up이 아니거나 활성 target이 아예 없을 때입니다. |
| 나머지 scrape job | 실패로 다루지 않고 경고만 남깁니다. `vm1-node`와 `vm3-node`처럼 이 배포가 기동하지 않는 대상이 섞여 있기 때문입니다. |
| 구 Promtail 컨테이너 | 배포가 성공한 뒤에 `vm2-promtail`을 지웠는데도 그 이름의 컨테이너가 남아 있을 때입니다. |
| Alloy 컨테이너 상태 | compose의 healthcheck가 60초 안에 `healthy`에 이르지 못할 때입니다. Alloy는 포트를 게시하지 않아서 호스트에서 `curl`로 확인할 수 없으므로, 워크플로가 `docker inspect`로 healthcheck 결과를 읽습니다. |
| 로그 종단 확인 | 이번 배포가 만든 시험 문자열이 Alloy를 거쳐 Loki에 적재되지 않을 때입니다. 아래의 "로그가 실제로 도착하는지 확인하는 단계"에 방법과 근거를 적어 두었습니다. |
| 로드된 rule group 수 | 0일 때입니다. rule 파일이 전송되지 않거나 경로가 어긋나면 Prometheus는 오류 없이 규칙이 없는 상태로 뜨므로, 경보가 전부 사라진 채 배포가 성공하는 상황을 막습니다. |
| rule group 이름과 alert 규칙 이름 | Prometheus가 들고 있는 이름 집합이 저장소의 rule 파일에서 계산한 집합과 다를 때입니다. 현재 기대값은 group 8개와 alert 규칙 21개입니다. |
| scrape job 이름 | Prometheus가 읽고 있는 설정의 job 이름 집합이 저장소의 `prometheus.yml`과 다를 때입니다. 컨테이너가 옛 설정 파일을 그대로 들고 있는 상황을 이 항목이 잡습니다. |
| Grafana 프로비저닝 | Grafana 컨테이너가 이번에 기동한 시각 이후의 로그에 `provision`이 들어간 오류 줄이 있을 때입니다. 데이터 원본과 대시보드 프로비저닝은 컨테이너가 정상으로 떠 있어도 조용히 실패하고, `/api/health`는 그 경우에도 200을 돌려줍니다. 로그 조회 자체가 실패할 때에도 배포를 실패로 끝냅니다. |

Grafana 로그를 읽는 구간은 `docker inspect -f '{{.State.StartedAt}}' vm2-grafana`가 돌려주는 시각
이후로 한정합니다. 이전 판은 `--since 20m`이라는 고정된 구간을 사용했는데, 그러면 20분 안에 다시
배포할 때 직전 배포가 남긴 오류 줄이 그대로 다시 걸립니다. 원인을 이미 고친 배포가 계속 실패하는
상황이 여기에서 생깁니다. 워크플로는 `CONFIG_SERVICES`에 `grafana`를 넣어 배포할 때마다 반드시 다시
시작하므로, 이 기동 시각은 언제나 이번 배포의 값이고 그 뒤의 로그에는 이번 프로비저닝 결과가
빠짐없이 들어 있습니다. `StartedAt`은 나노초까지 붙은 형식이라 소수점 아래를 떼어서 초 단위로
내림하며, 내림한 시각은 실제 기동 시각보다 앞서기 때문에 첫 줄을 놓치지 않습니다.

마지막 두 항목이 "설정이 실제로 반영되었는가"를 판정합니다. 컨테이너가 옛 설정을 들고 있어도
컨테이너 자체는 정상으로 떠 있고 target도 up이므로, 상태 확인만으로는 반영 여부를 알 수
없습니다. 그래서 워크플로는 저장소의 rule 파일과 `prometheus.yml`에서 기대값을 직접 계산한
다음, Prometheus의 `/api/v1/rules`와 `/api/v1/status/config`가 돌려주는 값과 비교합니다.
기대값 계산은 러너의 checkout만 읽으므로 비밀을 사용하지 않습니다.

`/api/v1/status/config`는 설정 파일을 그대로 돌려주지 않고 기본값을 채워서 다시 직렬화한
YAML을 돌려줍니다. 그래서 파일과 통째로 비교하지 않고 job 이름의 집합만 뽑아서 비교합니다.

기대값을 계산할 때에는 실제 YAML 파서를 사용합니다. 이전 판은 `grep`과 `sed`로 줄 모양만
보았기 때문에 두 가지를 오판했습니다. 첫째, `- job_name: "alloy"  # 잠시 지켜본다`처럼 인라인
주석이 붙으면 주석까지 job 이름에 들어갔습니다. 둘째, `expr`나 `annotations`의 블록 스칼라
안에 `- alert: 무엇무엇`이라는 텍스트가 들어 있으면 그 텍스트까지 경보 규칙으로 세었습니다.
지금은 `yq`로 YAML을 JSON으로 바꾼 다음 `jq`로 이름만 뽑으므로 두 경우 모두 올바르게
처리됩니다. `yq`와 `jq`는 GitHub이 제공하는 `ubuntu-latest` 러너 이미지에 기본으로 들어
있으며, 워크플로는 두 도구가 있는지와 `yq`가 mikefarah 판인지를 먼저 확인하고 그렇지 않으면
배포를 실패로 끝냅니다. 도구가 없을 때 검사가 조용히 통과하는 상황을 막으려는 조치입니다.

이 비교의 한계는 이름 집합까지만 본다는 점입니다. 규칙의 이름이 같으면서 `expr`나 `for`나
`labels`가 바뀐 경우는 이 단계가 잡지 못합니다. Prometheus는 식을 파싱한 다음 자신의 표기로
다시 직렬화해서 돌려주기 때문에 저장소의 식과 문자열이나 해시로 맞비교하는 방법이 성립하지
않습니다. 이 단계가 막으려는 실패는 "설정이 전송되지 않았다"와 "컨테이너가 옛 파일을 들고
있다"이고 그 두 가지는 이름 집합만으로도 드러나므로, 식의 내용을 확인하는 일은 아래의
"규칙 단위 시험"에서 `promtool test rules`가 맡습니다.

scrape job 비교는 설정 파일에 적힌 `job_name`을 기준으로 삼습니다. `file_sd`를 사용하는
`msa-services` job은 relabel을 거치면서 최종 job label이 `msa-<서비스>`로 바뀌지만,
`/api/v1/status/config`가 돌려주는 값은 relabel 이전의 설정이라 양쪽 모두 `msa-services`로
나옵니다. relabel 이후의 이름을 확인하는 곳은 위의 필수 target 판정이며, 두 판정은 서로 다른
질문에 답합니다.

필수 job 목록은 워크플로 파일의 `REQUIRED_JOBS` 환경 변수에 있습니다. `msa-services` job은
relabel이 각 target의 `service` label을 `job` label로 옮기므로, 이 목록에는 scrape pool 이름인
`msa-services`가 아니라 relabel 이후의 이름인 `msa-gateway`와 `msa-auth-server`를 적습니다.

필수 집합에 `blackbox-exporter`와 `cadvisor`와 `alloy`를 넣은 기준은 "이 compose가 직접 기동하는
서비스인가"입니다. 세 서비스는 모두 이 워크플로가 `up -d`로 띄우므로, 배포가 끝난 뒤에도 down이라면
다른 호스트의 사정이 아니라 배포 자체가 잘못된 것입니다. `alloy` job은 로그 수집이 실제로 살아
있는지를 알려 주는 유일한 신호이기도 합니다. Promtail을 쓰던 동안에는 수집기의 지표를 긁는 job이
없어서, 2026-09-18 실사에서 확인한 것처럼 수집기가 created 상태로 멈춰 있어도 배포가 성공으로
끝났습니다.

목록에 없는 target이 down이면 워크플로가 GitHub의 job summary에 경고 표로 남깁니다. 배포는
성공하지만, 그 표는 실제로 수집이 끊긴 대상을 알려 주므로 배포할 때마다 읽어야 합니다.

#### 설정 변경을 반영하는 방법

**`docker compose up -d`만으로는 설정 변경이 반영되지 않습니다.** 이 사실을 확인하지 않은 채
배포하면 파일은 서버에 도착했는데 컨테이너는 옛 내용을 그대로 읽는 상태가 됩니다. 그래서
워크플로는 `up -d` 뒤에 설정을 들고 있는 서비스를 반드시 다시 시작합니다.

반영되지 않는 이유는 두 단계로 나뉩니다.

첫째, compose는 서비스 정의가 그대로이면 컨테이너를 다시 만들지 않습니다. bind mount한 설정
파일의 내용만 바뀐 경우가 정확히 여기에 해당하므로, `up -d`는 `Container ... Running`만 출력하고
아무 일도 하지 않습니다.

둘째, `rsync`는 파일을 제자리에서 고치지 않고 임시 파일을 만든 다음 `rename`으로 갈아 끼웁니다.
그래서 경로는 같아도 inode가 바뀝니다. 그런데 단일 파일을 bind mount하면 컨테이너를 만들 때의
inode에 mount가 묶이기 때문에, 컨테이너 안에서는 새 파일이 아니라 옛 inode의 내용이 계속
보입니다. 설정을 다시 읽히는 것만으로는 이 상태를 벗어날 수 없습니다. 같은 경로가 여전히 옛
inode를 가리키기 때문입니다.

| 마운트 방식 | 대상 파일 | rename 교체 후 컨테이너가 보는 내용 |
|---|---|---|
| 단일 파일 | `prometheus.yml`, `datasources.yml`, `dashboards.yml`, `loki-config.yml`, `config.alloy`, `blackbox.yml`, `alertmanager.yml` | 옛 내용입니다. 설정을 다시 읽혀도 그대로입니다. |
| 디렉터리 | `rules/`, `targets/`, `dashboards/` | 새 내용입니다. 다만 Prometheus는 설정을 다시 읽기 전까지 rule 파일을 다시 평가하지 않습니다. |

`prom/prometheus:v3.7.2`로 직접 재현해서 확인한 내용입니다. `prometheus.yml`을 `rename`으로 갈아
끼운 뒤 `/-/reload`를 호출하자 rule group 수는 1에서 2로 늘었지만 `/api/v1/status/config`가
돌려주는 설정은 옛 판 그대로였고, `docker compose up -d`를 실행해도 컨테이너를 다시 만들지
않아서 결과가 같았습니다. `docker compose restart`를 실행한 뒤에야 새 설정이 반영되었습니다.

`restart`는 컨테이너를 다시 만들지 않으면서도 컨테이너를 멈췄다가 시작할 때 mount를 다시
잡아 주므로, 단일 파일 mount라도 새 inode를 가리키게 됩니다. 컨테이너를 강제로 다시 만드는
방법보다 단순하고, volume과 컨테이너 이름을 그대로 유지한다는 점에서 부작용도 적습니다.

다시 시작하는 대상은 워크플로의 `CONFIG_SERVICES` 환경 변수에 있으며 현재 값은 `prometheus`,
`grafana`, `loki`, `alloy`, `blackbox-exporter`입니다. Alertmanager는 `alerting` profile이라
평소에는 기동되어 있지 않으므로 목록에 넣지 않고, 실행 중일 때에만 `--profile alerting`을 붙여
따로 다시 시작합니다.

이 단계 때문에 배포할 때마다 관측이 수십 초 끊깁니다. 이 워크플로가 수동 실행만 받는 이유
가운데 하나이며, 위의 "배포" 항목 첫머리에 적어 둔 전제와 같습니다.

#### 로그가 실제로 도착하는지 확인하는 단계

Alloy의 `/-/ready` healthcheck만으로는 로그 수집이 살아 있다고 판단할 수 없습니다. 그 endpoint는
Alloy 프로세스가 떠 있기만 하면 200을 돌려주기 때문입니다. 컨테이너 목록을 가져오는 경로가 막혀
있어도 healthcheck는 `healthy`를 유지하며, 그 상태에서 구 Promtail을 지우면 로그 수집이 조용히
끊깁니다. `docker:27-dind` 안에서 docker-socket-proxy의 `CONTAINERS` 권한을 0으로 두고 재현한
결과가 정확히 그러했습니다. Alloy의 healthcheck는 `healthy`였고, Alloy 로그에는
`error while listing containers: ... 403 Forbidden`이 15초마다 쌓이고 있었습니다.

그래서 워크플로는 종단 확인을 따로 수행합니다. 절차는 세 단계입니다.

1. 배포 실행 번호로 만든 시험 문자열을 준비합니다. 값은 `bngdrasil-log-probe-<run_id>-<run_attempt>`
   형태이므로 실행마다 반드시 달라지고, 비밀을 담고 있지 않습니다.
2. `vm2-log-probe`라는 이름으로 컨테이너를 하나 띄워서 그 문자열을 표준 출력에 10초 간격으로 열 번
   찍게 합니다. 일회성 `docker run --rm`을 쓰지 않는 이유는 Alloy의 `discovery.docker`가 실행 중인
   컨테이너만 목록에 올리고 갱신 주기가 15초이기 때문입니다. 곧바로 끝나고 사라지는 컨테이너는 한
   번도 발견되지 않을 수 있습니다. 이 컨테이너에는 compose label이 없으므로 `service` label은
   `config.alloy`의 fallback 규칙이 컨테이너 이름으로 채우며, 종단 확인은 그 규칙까지 함께
   시험합니다.
3. VM2의 loopback Loki에 `query_range`를 던져서 응답 본문에 그 문자열이 있는지 확인합니다. 5초
   간격으로 최대 30번 다시 시도하고, 끝까지 찾지 못하면 배포를 실패로 끝냅니다.

판정에 `jq`를 쓰지 않고 `grep`만 쓰는 이유는 VM2에 `jq`가 설치되어 있다고 보장할 수 없기
때문입니다. 질의 문자열은 응답 본문에 되돌아오지 않으므로, 본문에서 시험 문자열이 보인다는 사실은
그 줄이 실제로 Loki에 적재되었다는 뜻입니다. 실제 전환 시험에서는 컨테이너를 띄운 뒤 다섯 번째
시도, 즉 20초에서 25초 사이에 문자열이 도착했습니다.

시험 컨테이너의 정리는 원격 스크립트 첫머리에 걸어 둔 `trap ... EXIT`가 맡습니다. 확인에 성공하든
실패하든, 그리고 중간에 스크립트가 끝나든 같은 정리가 동작합니다. 이전 판은 확인이 끝나는 자리에서
`docker rm -f`를 부르기만 했기 때문에 그 사이에서 스크립트가 끝나면 컨테이너가 그대로 남았습니다.
워크플로가 취소될 때 러너가 SSH를 죽이면 원격 셸이 `SIGHUP`이나 `SIGPIPE`를 받으므로 그 신호도 함께
잡아서 정리합니다. 다만 원격이 아무 신호도 받지 못하는 경로가 남아 있어서 이 정리는 최선의 노력이며,
실제 보증은 확인을 시작할 때 같은 이름의 잔여 컨테이너를 먼저 지우는 쪽이 맡습니다.

시험 컨테이너를 띄우는 `docker run`의 실패도 따로 확인합니다. 이 확인 함수는 `함수 || exit 1`
형태로 불리는데, 그렇게 부르면 함수 본문 전체가 `||`의 왼쪽이 되어 `set -e`가 적용되지 않습니다.
이전 판은 그래서 컨테이너가 뜨지도 않은 상태로 도착 대기를 서른 번 끝까지 돌고 150초를 버린 뒤에야
실패했습니다. 지금은 종료 코드를 직접 확인하고 곧바로 배포를 실패로 끝냅니다.

#### 구 Promtail 컨테이너를 지우는 단계

compose에서 promtail 서비스를 없앴으므로 운영 서버의 `vm2-promtail` 컨테이너는 orphan으로 남습니다.
이 워크플로의 `docker compose up -d`는 `--remove-orphans`를 쓰지 않습니다. `alerting` profile로 꺼 둔
Alertmanager까지 orphan으로 보고 지우는 일을 피하려는 의도입니다. 그래서 `vm2-promtail`만 이름으로
지목해서 다루는 단계를 따로 두었습니다.

순서는 아래와 같습니다. 핵심은 **필수 확인을 모두 통과하기 전까지 Promtail을 지우지 않는다**는
점입니다. 이전 판은 원격 단계 안에서 Promtail을 지웠기 때문에, 러너에서 수행하는 target과 rule
판정이 실패했을 때에는 되돌릴 대상이 이미 사라진 뒤였습니다.

1. 구 Promtail의 상태를 먼저 기록합니다. 컨테이너가 있었는지와 돌고 있었는지를 따로 확인해서
   `/opt/bnbong/.monitoring-deploy-state/` 아래에 남깁니다. 복구가 별도의 단계이므로, 이 단계가
   어디에서 실패하더라도 복구 단계가 같은 판단을 다시 내릴 수 있어야 합니다. 같은 자리에 구
   Promtail 설정 파일의 사본도 함께 둡니다.
2. `docker compose pull`로 이미지를 내려받습니다. 실패하면 아무것도 건드리지 않고 배포를 중단합니다.
3. `docker compose up -d`와 설정 보유 서비스의 재시작을 수행합니다. Alloy가 여기에서 뜹니다.
4. 그다음에 `vm2-promtail`을 멈추기만 합니다. 지우지는 않습니다.
5. Prometheus와 Loki와 Grafana의 상태 확인, Alloy healthcheck, Grafana 프로비저닝 검사, 로그 종단
   확인을 차례로 수행합니다.
6. 러너로 돌아와서 target 집합과 rule group 이름과 alert 규칙 이름과 scrape job 이름을 저장소의
   기대값과 비교합니다.
7. 5번과 6번을 모두 통과했을 때에만 `vm2-promtail` 컨테이너를 지웁니다. 같은 단계에서 구 Promtail
   설정 파일과 전환 상태 파일도 함께 치웁니다.
8. 5번이나 6번에서 실패하거나 그 도중에 워크플로가 취소되면 복구 단계가 동작합니다. 되돌릴 수
   있는지 먼저 확인하고, 구 설정 파일을 제자리에 놓고, Promtail을 시작해서 실제로 `running`이
   되었는지 확인한 다음, 그 확인을 통과했을 때에만 Alloy와 docker-socket-proxy를 멈춥니다.

3번과 4번의 순서를 이렇게 잡은 이유는 두 가지입니다. 첫째, 수집기가 하나도 없는 구간이 생기지
않습니다. 이전 판은 Promtail을 먼저 멈추고 Alloy를 띄웠기 때문에 그 사이에 공백이 있었습니다.
둘째, 두 수집기가 겹쳐서 보내는 몇십 초 동안의 로그는 stream label과 시각과 내용이 모두 같으므로
Loki가 중복으로 보고 버립니다. 근거는 아래의 "positions와 전환 시점의 중복과 유실" 항목에 있습니다.

반대로 4번을 5번보다 앞에 두는 것은 반드시 지켜야 합니다. Promtail이 아직 돌고 있으면 시험 문자열을
Promtail이 넣었는지 Alloy가 넣었는지 구분할 수 없어서 종단 확인이 의미를 잃습니다.

##### 복구 단계가 Promtail을 먼저 살리고 Alloy를 나중에 멈추는 이유

이전 판의 복구 단계는 Alloy와 docker-socket-proxy를 가장 먼저 멈췄습니다. 복구에 성공했을 때
두 수집기가 같은 로그를 동시에 보내는 상태를 피하려는 의도였지만, 그 순서에는 더 나쁜 결말이
있었습니다. 복구가 동작하는 경우 가운데에는 로그 종단 확인까지 통과하고 러너의 target과 rule
판정만 실패하는 경로가 있습니다. 그 경로에서 Alloy는 실제로 로그를 보내고 있는데도 먼저 멈추게
되고, 이어지는 설정 복원이나 컨테이너 기동이 실패하면 `set -euo pipefail`이 스크립트를 그 자리에서
끝내기 때문에 두 수집기가 모두 멈춘 상태로 배포가 끝납니다. 복구 단계가 스스로 최악의 상태를
만드는 셈입니다.

그래서 지금은 순서를 뒤집었습니다. 되돌릴 수 있는지를 먼저 확인하고, 빈 디렉터리를 치우고 설정
파일을 제자리에 놓고, Promtail을 시작해서 `running`을 두 번 확인한 다음, 그 확인을 통과했을
때에만 Alloy와 docker-socket-proxy를 멈춥니다. Promtail을 되살리지 못하면 Alloy는 건드리지 않고
그대로 둔 채 배포를 실패로 끝내며, 그 사실과 현재 어느 수집기가 돌고 있는지를 `::error::` 주석으로
남깁니다. 적어도 한쪽 수집기는 계속 돌고 있게 만드는 것이 이 단계의 목적입니다.

이 순서의 대가로 두 수집기가 겹쳐서 도는 구간이 잠시 생깁니다. 그 구간의 로그는 stream label과
시각과 내용이 모두 같으므로 Loki가 중복으로 보고 버립니다. 근거는 아래의 "positions와 전환 시점의
중복과 유실" 항목에 있습니다. 겹치는 로그는 버려지지만 비어 있는 구간은 되돌릴 수 없으므로 겹침을
선택했습니다. docker-socket-proxy를 함께 멈추는 이유는 그 프록시를 사용하는 것이 Alloy뿐이기
때문이며, Alloy가 없는 동안 Docker 소켓을 들고 있는 컨테이너를 하나라도 줄여 두는 편이 안전합니다.
이 정지가 실패해도 배포를 실패로 끝내지는 않습니다. 그때 남는 상태는 두 수집기가 함께 도는 것이고
관측이 끊기지는 않으므로, 경고만 남기고 사람이 나중에 정리합니다.

##### 복구 단계가 동작하는 조건

복구 단계는 `if: failure()`를 쓰지 않고 앞선 두 단계의 결과를 직접 확인합니다. 마지막 정리 단계가
실패했을 때에는 되돌리면 안 되기 때문입니다. 그 시점에는 모든 검증을 이미 통과해서 Alloy가 정상으로
로그를 보내고 있으므로, Promtail을 다시 띄우려고 Alloy를 멈추는 쪽이 더 나쁩니다. 그때 남는 문제는
컨테이너 하나가 정지 상태로 남아 있는 것뿐이고, 그 정리는 다음 배포가 수행합니다.

조건에는 실패뿐 아니라 취소까지 넣습니다. GitHub Actions에서 워크플로를 취소하면 그 시점에 돌고
있던 단계의 결과는 `failure`가 아니라 `cancelled`가 되기 때문입니다. 이전 판은 `failure`만
확인했으므로, 적용 단계가 Promtail을 멈춘 다음 로그 종단 확인을 수행하는 도중에 취소되면 복구가
한 번도 동작하지 않았습니다. Alloy가 실제로는 로그를 전달하지 못하는 상태였다면 그 순간 수집기가
하나도 남지 않습니다.

| 적용 단계 결과 | 검증 단계 결과 | 복구 단계 |
|---|---|---|
| `success` | `success` | 동작하지 않습니다. 정리 단계가 Promtail을 지웁니다. |
| `success` | `failure` 또는 `cancelled` | 동작합니다. |
| `failure` 또는 `cancelled` | `skipped` | 동작합니다. |
| `skipped` | `skipped` | 동작하지 않습니다. |

적용 단계가 `skipped`인 경우는 그 앞의 SSH 설정이나 파일 전송이 실패했다는 뜻입니다. 이 실행은
Promtail을 멈춘 적이 없으므로 되돌릴 대상도 없습니다. 그런데 상태 디렉터리에는 지난 실행이 남긴
값이 있을 수 있어서, 이 경우까지 복구를 동작시키면 이번 배포가 건드리지도 않은 호스트를 지난 값으로
되돌리게 됩니다. 그 상황의 정리는 아래에 적은 미완료 전환 감지가 맡습니다.

취소된 job에서 단계를 동작시키려면 `if`에 `always()`가 필요합니다. `!cancelled()`는 취소된
job에서 거짓이 되므로 이 단계를 건너뜁니다. GitHub 문서는 실패했을 때 워크플로가 시간 초과까지
멈출 수 있는 작업에 `always()`를 쓰지 말라고 권고하는데, 이 단계는 SSH 한 번으로 끝나고 연결
제한 시간과 `timeout-minutes: 4`를 함께 걸어 두었습니다. 취소를 요청한 뒤 GitHub이 허용하는
시간은 5분이고 그 뒤에는 서버가 강제로 종료하므로, 4분이라는 상한은 그 5분 안에서 러너가 스스로
끝맺고 아래의 수동 복구 안내를 job summary에 남기게 하려는 값입니다.

복구 단계 자신의 SSH가 실패하면 워크플로가 `::error::` 주석과 함께 job summary에 수동 복구 명령을
적습니다. 이 단계가 조용히 넘어가면 사람이 "복구가 동작했다"고 잘못 믿게 되기 때문입니다.

##### 취소와 러너 사망으로 남는 상태

워크플로를 취소하면 복구 단계가 동작하지만, 러너 자체가 죽으면 어떤 단계도 동작하지 못합니다.
러너의 사망은 워크플로 안에서 막을 수 없으므로, 그 대신 상태를 기록해 두고 다음 배포가 감지하게
만들었습니다.

적용 단계는 Promtail을 멈추기 직전에 `/opt/bnbong/.monitoring-deploy-state/transition_in_progress`
파일에 실행 번호를 적습니다. 이 표식은 전환이 끝까지 성공해서 정리 단계가 동작했을 때나 복구가
성공했을 때에만 사라집니다. 상태 파일은 같은 디렉터리에 임시 파일을 만든 다음 `mv`로 갈아 끼우므로,
쓰는 도중에 배포가 끊겨도 반쪽짜리 내용이 남지 않습니다.

표식이 남아 있으면 다음 배포가 지난 실행을 미완료로 판단합니다. 그 배포는 `docker ps`가 돌려주는
값과 무관하게 "Promtail이 실행 중이었다"를 유지하고 경고를 남기므로, 이번 배포가 실패하면 지난
실행이 멈춘 Promtail을 복구 대상으로 삼습니다. 이 기록이 없던 이전 판은 매번 `docker ps`로 상태를
새로 계산했기 때문에, 지난 배포가 Promtail을 멈춘 채 끝났다면 다음 배포는 "원래 멈춰 있었다"고
판단하고 실패해도 되살리지 않았습니다.

표식이 남아 있는데 `vm2-promtail` 컨테이너가 이미 없다면 낡은 표식으로 보고 지웁니다. 사람이 손으로
컨테이너를 지웠다는 뜻이고 되살릴 대상이 없기 때문입니다.

러너가 죽어서 남는 상태는 "Promtail 정지, Alloy 실행"입니다. Alloy가 로그를 계속 수집하므로 관측이
끊기지는 않습니다. 곧바로 손으로 확인하려면 아래 절차를 따릅니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP>
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E 'vm2-(promtail|alloy)'
cat /opt/bnbong/.monitoring-deploy-state/transition_in_progress

# 두 수집기가 모두 멈춰 있으면 Alloy를 먼저 되살립니다
cd /opt/bnbong
sudo docker compose -f docker-compose.monitoring.yml up -d alloy docker-socket-proxy

# 구 Promtail로 되돌려야 한다면 설정 파일의 상태부터 확인합니다
ls -l /opt/bnbong/monitoring/loki/promtail-config.yml
# 그 경로가 디렉터리로 바뀌어 있으면 지우고 사본을 되돌립니다
sudo rm -rf /opt/bnbong/monitoring/loki/promtail-config.yml
sudo cp /opt/bnbong/.monitoring-deploy-state/promtail-config.yml \
  /opt/bnbong/monitoring/loki/promtail-config.yml
sudo docker start vm2-promtail
sudo docker compose -f docker-compose.monitoring.yml stop alloy docker-socket-proxy

# 되살린 뒤에는 전환 표식을 지웁니다
sudo rm -f /opt/bnbong/.monitoring-deploy-state/transition_in_progress
```

Alloy를 그대로 두기로 결정했다면 표식만 지워도 됩니다. 그러면 다음 배포가 평소대로 동작합니다.

이 절차는 몇 번을 반복해도 결과가 같습니다. Promtail 컨테이너가 이미 없으면 4번과 7번이 모두 아무
일도 하지 않고, 8번도 되살릴 대상이 없으므로 그대로 끝납니다. 전환이 끝난 호스트에서는 상태
디렉터리 자체가 없으므로 전환 표식도 만들어지지 않습니다. "있는지"와 "돌고 있었는지"를 따로
확인하는 이유는 2026-09-18 실사 때처럼 컨테이너가 `created` 상태로 멈춰 있을 수 있기 때문입니다.
그 상태는 로그를 보내고 있지 않았다는 뜻이므로, 배포가 실패해도 그 컨테이너를 새로 살리지 않습니다.
표식은 실행 중이던 Promtail을 멈추기 직전에만 적으므로, 원래 `created`나 `exited`였던 호스트에서는
표식이 생기지 않고 다음 배포의 판단도 달라지지 않습니다.

이 단계는 `promtail_positions` volume을 건드리지 않습니다. Alloy가 그 안의 `positions.yaml`을 한 번
가져가야 하기 때문이며, volume을 정리하는 절차는 사람이 따로 수행합니다.

#### 구 Promtail 설정 파일을 배포 도중에 지키는 방법

저장소에서 `loki/promtail-config.yml`을 지웠지만, VM2에서는 전환이 끝날 때까지 그 파일이 남아 있어야
합니다. 운영 중인 `vm2-promtail` 컨테이너가 그 파일 하나를 단일 파일 bind mount로 들고 있기
때문입니다. `rsync --delete`가 그 파일을 지운 뒤에 배포가 실패하면 복구 자체가 불가능해집니다.

`docker:27-dind` 안에서 실제 `vm2-promtail` 컨테이너로 재현한 결과는 아래와 같습니다.

```
Error response from daemon: ... error mounting "/opt/bnbong/monitoring/loki/promtail-config.yml"
to rootfs at "/etc/promtail/config.yml": ... not a directory: unknown:
Are you trying to mount a directory onto a file (or vice-versa)?
```

`docker start`가 실패할 뿐 아니라, 그 과정에서 Docker가 원본 경로에 빈 디렉터리를 만들어 둡니다.
그래서 나중에 파일을 되돌려 놓으려 해도 먼저 그 디렉터리를 지워야 하고, 지우기 전에는 몇 번을 다시
시도해도 같은 오류로 실패합니다.

대응은 두 겹입니다. 첫째, `rsync`에 `--exclude '/loki/promtail-config.yml'`을 붙여서 bind mount 원본
경로가 비는 구간 자체를 만들지 않습니다. 별도 경로에 사본만 두는 방법과 비교해서 이쪽을 고른 이유가
여기에 있습니다. 사본만 두면 배포 도중에 워크플로가 취소되었을 때 원본 경로가 빈 상태로 남고, 그
뒤에는 사람이 디렉터리를 지우고 파일을 되돌려야 Promtail이 다시 뜹니다. 둘째, 그럼에도 사본을 함께
남깁니다. 제외 규칙을 누가 먼저 지웠거나 사람이 파일을 지운 상태에서 배포가 실패하면, 복구 단계가
빈 디렉터리를 치우고 사본으로 원본을 되돌립니다.

제외 규칙만 두면 전환이 끝난 뒤에도 이 파일이 VM2에 영구히 남습니다. 그 문제는 마지막 정리 단계가
배포가 완전히 성공한 뒤에 파일을 지워서 해결합니다. 그 단계가 한 번 돌고 나면 제외 규칙은 지킬
대상이 없는 빈 규칙이 되므로, 워크플로의 Promtail 관련 단계들과 함께 통째로 지우면 됩니다. 남겨
두어도 동작에는 영향을 주지 않습니다.

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
# 설정 파일을 고쳤다면 up -d만으로는 반영되지 않습니다. 위의 "설정 변경을 반영하는 방법"을
# 참고하여 설정을 들고 있는 서비스를 반드시 다시 시작하십시오.
sudo docker compose -f docker-compose.monitoring.yml restart \
  prometheus grafana loki alloy blackbox-exporter
sudo docker compose -f docker-compose.monitoring.yml ps
```

`.env`의 `VM2_PRIVATE_IP`와 `GRAFANA_ADMIN_PASSWORD`를 채워야 합니다. 두 값 모두 compose가
`${변수:?...}` 형태로 참조하므로, 값이 비어 있으면 컨테이너를 만들기 전에 compose가 중단됩니다.
`VM2_PRIVATE_IP`가 비면 Grafana의 포트 바인딩이 조용히 모든 인터페이스로 넓어지고,
`GRAFANA_ADMIN_PASSWORD`가 비면 Grafana가 기본 비밀번호로 기동하여 공개 도메인에 그대로
노출됩니다. 두 경우 모두 조용히 넘어가지 않게 막아 두었습니다.

워크플로는 `.env`를 전송하지 않습니다. 서버에 있는 값이 원본이며, 로컬 파일로 덮어쓰면 운영 비밀이
사라질 수 있기 때문입니다.

---

## 접근 방법

- Grafana는 `https://monitoring.bnbong.com`으로 접근합니다. VM1 Nginx가 `10.0.1.60:3000`으로
  프록시합니다.
- Prometheus와 Loki는 외부에 게시하지 않습니다. VM2 안에서는 `http://127.0.0.1:9090`과
  `http://127.0.0.1:3100`으로 접근하고, 외부에서 보려면 SSH 터널을 사용합니다.
- Alertmanager도 loopback에만 게시하며 `alerting` profile을 켰을 때에만 기동합니다. 주소는
  `http://127.0.0.1:9093`입니다.
- blackbox exporter와 cAdvisor는 포트를 게시하지 않습니다. Prometheus가 `api-network` 안에서만
  호출하므로 호스트에서 직접 열어 둘 이유가 없습니다.
- docker-socket-proxy는 포트를 게시하지 않고 `api-network`에도 붙지 않습니다. `internal: true`인
  전용 네트워크 `bnbong_docker-socket`에만 붙으며, 그 네트워크에 함께 있는 컨테이너는 Alloy
  하나입니다. 근거는 아래의 "Docker API 접근 범위" 항목에 있습니다.
- Alloy도 포트를 게시하지 않습니다. Alloy의 12345번 포트에는 `/metrics`와
  함께 설정 그래프를 보여 주는 디버깅 화면이 붙어 있으므로, 호스트에도 외부에도 열지 않고
  `api-network` 안에서 Prometheus만 닿게 두었습니다. 화면을 볼 일이 생기면 SSH 터널과
  `docker port` 대신 `sudo docker exec vm2-prometheus wget -q -O- http://alloy:12345/metrics`처럼
  같은 네트워크 안의 컨테이너를 거쳐서 확인합니다.

```bash
ssh -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 -L 9093:127.0.0.1:9093 ubuntu@<VM2_PUBLIC_IP>
```

Grafana에는 익명 열람과 회원가입을 막는 설정과 session cookie를 HTTPS로 제한하는 설정을
compose에 명시했습니다. 현재 Grafana의 기본값도 같지만, 공개 도메인에 붙어 있는 화면이므로
기본값에 기대지 않고 파일에 남겼습니다. 쓰이지 않던 `GF_INSTALL_PLUGINS`는 제거했습니다. 지정된 두
플러그인을 사용하는 대시보드가 없었고, 새 volume에서 기동할 때 외부 저장소에서 플러그인을 내려받는
단계만 추가되었기 때문입니다.

운영 Grafana의 `GF_SERVER_ROOT_URL`이 아직 `monitoring.bnbong.xyz`일 수 있습니다. 저장소 쪽이 더
최근 수정본이므로 도메인 변경이 운영에 반영되지 않았다고 보아야 하며, 반영할 때 Cloudflare DNS와
VM1 Nginx의 `server_name`을 함께 확인합니다.

### 대시보드 프로비저닝

Grafana 대시보드는 저장소가 단일 출처입니다. provider 정의인
`grafana/provisioning/dashboards/dashboards.yml`과 대시보드 JSON이 들어 있는
`grafana/dashboards/` 디렉터리를 각각 컨테이너의
`/etc/grafana/provisioning/dashboards/dashboards.yml`과 `/var/lib/grafana/dashboards`로 읽기
전용 mount합니다. 데이터 원본 정의를 mount하던 기존 방식과 같은 구조입니다.

읽기 전용이므로 Grafana 화면에서 고친 내용은 저장되지 않습니다. provider 정의에
`allowUiUpdates: false`를 두었기 때문에 화면에서는 저장 자체가 막힙니다. 대시보드를 바꿀
때에는 저장소의 JSON을 고치고 배포를 다시 실행해야 합니다.

`disableDeletion`은 `false`로 두었습니다. 이 값은 화면에서의 삭제를 막는 설정이 아니라, JSON
파일이 사라졌을 때 Grafana가 그 대시보드를 지울지를 정하는 설정입니다. 이전 판은 이 값을
`true`로 두고도 "JSON 파일을 지우고 배포하면 대시보드가 없어진다"라고 적어 두었는데, 두 내용은
서로 어긋납니다. `grafana/grafana:12.2.1`로 두 값을 모두 시험해서 확인했습니다.

| `disableDeletion` | JSON 파일을 지운 뒤의 결과 |
|---|---|
| `false` (현재 값) | 5초 안에 대시보드가 Grafana에서 사라졌습니다. 대시보드 수가 8개에서 7개로 줄었습니다. |
| `true` (이전 값) | 90초를 기다려도 대시보드가 그대로 남아 있었습니다. 파일이 없는데도 8개였습니다. |

저장소를 단일 출처로 유지하려면 `false`가 맞습니다. 화면에서 손으로 고치거나 지우는 일은
`allowUiUpdates: false`와 읽기 전용 mount가 이미 막고 있으므로, 이 값을 `false`로 두어도
사람이 실수로 대시보드를 없앨 수 있는 경로는 생기지 않습니다.

저장소가 제공하는 대시보드는 여덟 개이고 uid는 다음과 같습니다. Grafana에서는 모두 `BNGdrasil`
폴더에 들어가며, 주소는 `https://monitoring.bnbong.com/d/<uid>` 형태입니다.

| uid | 제목 | 파일 |
|---|---|---|
| `bngdrasil-overview` | BNGdrasil 운영 개요 | `grafana/dashboards/BNGdrasil/overview.json` |
| `bngdrasil-gateway` | Bifrost 게이트웨이 | `grafana/dashboards/BNGdrasil/gateway.json` |
| `bngdrasil-auth-server` | Bidar 인증 서버 | `grafana/dashboards/BNGdrasil/auth-server.json` |
| `bngdrasil-hosts` | 호스트 자원 | `grafana/dashboards/BNGdrasil/hosts.json` |
| `bngdrasil-containers` | 컨테이너 자원 | `grafana/dashboards/BNGdrasil/containers.json` |
| `bngdrasil-backup` | 백업 | `grafana/dashboards/BNGdrasil/backup.json` |
| `bngdrasil-probes` | 외부 probe | `grafana/dashboards/BNGdrasil/probes.json` |
| `bngdrasil-logs` | 로그 탐색 | `grafana/dashboards/BNGdrasil/logs.json` |

uid는 JSON 파일 안의 `uid` 항목에 고정해 두었습니다. 이 값을 바꾸면 Grafana가 같은 대시보드를
새 항목으로 인식해서 이전 uid로 만들어 둔 즐겨찾기와 외부 링크가 모두 끊어지므로, 파일 이름은
바꾸더라도 uid는 그대로 두십시오.

### 데이터 원본 uid

대시보드 JSON과 Bantheon 어드민의 Explore 링크는 데이터 원본을 이름이 아니라 uid로 가리킵니다.
그래서 `grafana/datasources.yml`에서 Prometheus의 uid를 `prometheus`로, Loki의 uid를 `loki`로
고정했습니다.

uid를 적지 않으면 Grafana가 데이터 원본 이름에서 파생한 값을 스스로 붙입니다. 실제로 확인해 보니
Prometheus는 `PBFA97CFB590B2093`, Loki는 `P8E80F9AEF21F6940`이었습니다. 저장소의 JSON에 적어 둘
수 있는 값이 아니므로 uid를 고정하는 쪽이 유일한 방법입니다.

#### 기존 볼륨에 uid를 추가하면 Grafana가 기동에 실패합니다

이 변경이 운영 Grafana에서 어떻게 동작하는지 `grafana/grafana:12.2.1`로 직접 시험했습니다.
자동 생성 uid로 데이터 원본이 이미 들어 있는 볼륨에 대고 uid만 추가한 파일을 붙이면, Grafana는
제자리 갱신도 중복 생성도 하지 않습니다. 아래 오류를 남기면서 프로세스가 종료 코드 1로
끝납니다. 즉 Grafana가 아예 뜨지 않습니다.

```
logger=provisioning level=error msg="Failed to provision data sources" error="Datasource provisioning error: data source not found"
Error: ✗ *provisioning.ProvisioningServiceImpl run error: Datasource provisioning error: data source not found
```

그래서 `datasources.yml` 앞머리에 `deleteDatasources` 블록을 두어, 같은 이름의 데이터 원본을 먼저
지우고 고정 uid로 다시 만들게 했습니다. 같은 볼륨으로 다시 시험한 결과 오류 없이 기동했고,
데이터 원본은 중복 없이 두 개였으며 uid는 각각 `prometheus`와 `loki`였습니다. 대상이 없으면
아무 일도 하지 않으므로 새 볼륨에서도 결과가 같습니다.

이 블록은 전환이 끝난 뒤에도 그대로 둡니다. 사람이 전환 시점을 맞추어 파일을 두 번 고칠 필요가
없어지고, 어떤 상태의 볼륨에 배포해도 결과가 같아지기 때문입니다. 부수 효과는 Grafana를
재기동할 때마다 데이터 원본의 내부 정수 id가 새로 매겨지는 것뿐이며, 이 저장소의 모든 참조는
id가 아니라 uid를 사용합니다.

#### 운영에 적용할 때 확인할 점

운영 Grafana의 `grafana_data` 볼륨에는 사람이 화면에서 직접 만든 대시보드가 남아 있을 수
있습니다. 그런 대시보드가 예전 uid인 `PBFA97CFB590B2093`이나 `P8E80F9AEF21F6940`을 패널에 적어
두었다면, 전환 뒤에 그 uid로는 데이터 원본을 찾을 수 없어서 패널이 비고 "Datasource not found"
오류가 나타납니다. 시험에서도 같은 조건을 만들어 확인했으며, 전환 뒤에 예전 uid로 데이터 원본을
조회하면 404가 돌아왔습니다.

프로비저닝된 여덟 개 대시보드는 모두 `prometheus`와 `loki`를 참조하므로 영향을 받지 않습니다.
영향을 받는 것은 화면에서 손으로 만든 대시보드뿐이고, 그런 대시보드는 패널의 데이터 원본을 다시
지정해 주면 복구됩니다. 배포 전에 Grafana의 대시보드 목록에서 `BNGdrasil` 폴더 밖에 있는 항목이
있는지 확인해 두십시오.

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

#### target label `service`를 지우는 이유

`msa-services` job은 `service` label을 `job`으로 복사한 다음, target label 쪽 `service`를
`labeldrop`으로 지웁니다. 지우지 않으면 Bifrost가 직접 내보내는 `service` label과 충돌합니다.

Bifrost의 `http_requests_total{method, service, status_class}`에서 `service`는 프록시한
업스트림의 이름입니다. 반면 target label `service`는 target 파일 이름에서 온 `gateway`입니다.
`honor_labels`의 기본값이 `false`이므로 Prometheus는 충돌이 나면 target label을 남기고 metric
쪽 label을 `exported_service`로 밀어냅니다. 실제로 재현해서 확인한 결과는 다음과 같았습니다.

```
{__name__="http_requests_total", job="msa-gateway", service="gateway", exported_service="upstream-a", ...}
{__name__="http_requests_total", job="msa-gateway", service="gateway", exported_service="upstream-b", ...}
```

이 상태에서는 모든 시계열의 `service`가 `gateway` 하나로 뭉치기 때문에, 업스트림을 구분해야
하는 곳이 전부 동작하지 않았습니다. `rules/basic.yml`의 `GatewayUpstreamHighServerErrorRate`가
쓰는 `sum by (service)`는 업스트림이 둘이어도 결과를 하나만 돌려주었고, `gateway.json`과
`overview.json`의 `service` 변수가 사용하는 `label_values(http_requests_total{job="msa-gateway"}, service)`도
`gateway` 하나만 돌려주었습니다.

`labeldrop`을 넣은 뒤에 같은 시험을 반복하자 `service`가 `upstream-a`, `upstream-b`, `gateway`로
나뉘었고 `exported_service`는 사라졌습니다. target은 그대로 up이었고 `instance`와 `job`도
그대로였습니다. `regex`를 `service`로 정확히 지정하는 이유는, `labeldrop`이 target relabel
단계에서 `__address__` 같은 내부 label도 대상으로 삼기 때문입니다. 넓은 정규식을 쓰면 수집
주소 자체가 사라집니다.

`honor_labels: true`는 쓰지 않았습니다. 그 설정은 `service`만이 아니라 `job`과 `instance`까지
metric 쪽 값으로 덮으므로, 해결하려던 것보다 큰 충돌을 새로 만듭니다.

**운영에 적용할 때 주의할 점이 있습니다.** 이 변경 이후에 수집되는 시계열은 예전 시계열과
label 구성이 다릅니다. Prometheus의 보존 기간이 7일이므로, 배포 후 7일 동안은 `service="gateway"`
하나로 뭉쳐 있는 옛 시계열과 업스트림별로 나뉜 새 시계열이 함께 남아 있습니다. 그동안
`gateway.json`의 업스트림별 패널은 기간을 넓게 잡으면 두 형태가 겹쳐서 보이고, `service` 변수
목록에도 옛 `gateway`와 새 업스트림 이름이 함께 나타납니다. 7일이 지나면 옛 시계열이 보존
기간에서 밀려나면서 저절로 정리됩니다. 별도의 조치는 필요하지 않습니다.

target label에서 `service`가 사라지므로 target을 조회할 때에는 `service`가 아니라 `job`으로
골라야 합니다. `monitoring/scripts/add-service.sh`가 마지막에 안내하는 확인 명령도 그렇게
고쳤습니다.

```bash
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="msa-gateway")'
```

새 서비스는 VM2에서 스크립트로 추가하고 제거합니다.

```bash
cd /opt/bnbong
./monitoring/scripts/add-service.sh user-service 8002 backend   # targets/user-service.json 생성
./monitoring/scripts/list-services.sh                           # 등록된 target 목록 확인
./monitoring/scripts/remove-service.sh user-service             # 제거. .bak 사본을 남깁니다
```

#### 스크립트의 인자 검증

`add-service.sh`와 `remove-service.sh`는 인자로 받은 서비스 이름을 소문자 영숫자와 하이픈과
밑줄로만 이루어지고 첫 글자가 영숫자인 63자 이하의 문자열로 제한합니다. 이 이름이 두 가지 자리에
동시에 쓰이기 때문입니다. 하나는 `prometheus/targets/<이름>.json`이라는 파일 경로이고, 다른 하나는
scrape target의 호스트 이름입니다. 허용 문자 목록에 경로 구분자와 점이 없으므로 `../`가 섞인
인자로 target 디렉터리 밖에 파일을 쓰거나 지우는 일이 성립하지 않고, 큰따옴표와 역슬래시와 제어
문자도 함께 막히기 때문에 생성되는 JSON이 깨지지 않습니다. 길이를 63자로 제한한 근거는 DNS label의
한도입니다. 밑줄을 허용하기는 하지만 호스트 이름으로는 권장되지 않으므로, 새로 추가하는 서비스에는
하이픈을 쓰시기 바랍니다.

포트는 1부터 65535까지의 정수만 받습니다. `0`과 `65536` 같은 범위 밖의 값은 물론이고, 선행 0이 붙은
`08000`, 뒤에 공백이 붙은 `8000 `, 숫자가 아닌 문자가 섞인 `8000abc`도 모두 거부됩니다. 세 번째
인자인 team에도 같은 문자 규칙을 적용합니다. team은 파일 경로에 쓰이지 않지만 JSON 문자열의 값으로
그대로 들어가기 때문에, 큰따옴표가 하나만 섞여도 파일이 깨집니다.

이렇게 좁게 검증하는 이유는 실패하는 방식에 있습니다. Prometheus의 file_sd는 읽을 수 없는 JSON
파일을 만나면 오류를 크게 드러내지 않고 그 파일을 무시합니다. 그러면 해당 서비스의 지표 수집이
조용히 멈추고, 경보도 울리지 않기 때문에 사람이 한참 뒤에야 알아차리게 됩니다.

`add-service.sh`는 JSON을 `jq`가 아니라 셸 안에 고정해 둔 서식 문자열로 만듭니다. VM2에 `jq`가
설치되어 있다고 보장할 수 없는데, 이 스크립트는 수집 대상을 등록하는 쓰기 경로이므로 도구가 없다는
이유로 실패하면 곤란하기 때문입니다. `list-services.sh`가 `jq`를 사용하는 것은 조회 용도라서 사정이
다릅니다. 대신 파일을 임시 이름으로 먼저 쓰고, `python3`나 `jq`로 유효한 JSON인지 확인한 다음에야
제자리로 옮깁니다. 이렇게 하면 Prometheus가 30초 주기로 디렉터리를 다시 읽는 동안 절반만 기록된
파일을 읽는 상황도 함께 사라집니다.

`remove-service.sh`가 남기는 `.json.bak` 사본은 target 디렉터리 안에 그대로 둡니다. `msa-services`
job의 file_sd 패턴이 `targets/*.json`이어서 `.json.bak`으로 끝나는 파일은 여기에 걸리지 않고,
`list-services.sh`도 같은 패턴만 훑기 때문에 제거한 서비스가 목록에 다시 나타나지 않습니다. 배포
워크플로의 rsync가 `prometheus/targets/`를 제외하므로 배포를 반복해도 사본이 지워지지 않습니다.

세 스크립트 모두 `TARGETS_DIR` 환경 변수로 대상 디렉터리를 바꿀 수 있습니다. 기본값은
`/opt/bnbong/monitoring/prometheus/targets`이므로 운영 동작은 그대로이며, 임시 디렉터리를 지정하면
운영 파일을 건드리지 않고 스크립트의 동작을 확인할 수 있습니다.

#### 동시 실행을 막는 배타 락

`add-service.sh`와 `remove-service.sh`는 target 디렉터리에 `flock`으로 배타 락을 겁니다. 락 파일은
`<TARGETS_DIR>/.targets.lock`이고, 락은 스크립트가 끝날 때 파일 서술자가 닫히면서 저절로 풀리므로
중간에 스크립트가 죽어도 남지 않습니다. 락을 10초 동안 얻지 못하면 그 사실을 적고 실패합니다.

락이 없으면 존재 확인과 쓰기 사이에 경쟁이 생깁니다. 같은 이름으로 `add-service.sh` 두 개가 동시에
들어오면 둘 다 "파일이 없다"를 확인하고 둘 다 성공을 출력하지만, 실제로 남는 파일은 나중에 `mv`한
쪽 하나뿐입니다. 추가와 제거가 겹치면 제거한 직후에 파일이 다시 만들어져서, "제거했다"는 보고와
달리 target이 살아 있는 상태가 남습니다. 파일 내용 자체는 임시 파일을 만든 다음 `mv`로 갈아 끼우는
덕분에 깨지지 않지만, 보고와 결과가 어긋나는 문제는 그대로 남습니다. 실제로 Ubuntu 컨테이너에서
같은 이름으로 20개를 동시에 실행한 결과, 락이 없던 이전 판은 20번 가운데 17번이 성공을 출력했고
락을 건 뒤에는 정확히 한 번만 성공했습니다.

락의 단위를 파일이 아니라 디렉터리로 잡은 이유는 두 스크립트가 서로 다른 서비스 이름을 다루더라도
같은 디렉터리를 함께 고치기 때문입니다. 디렉터리 하나에 대한 작업은 밀리초 단위로 끝나므로 경합
비용은 문제가 되지 않습니다. 락 파일의 이름이 `.json`으로 끝나지 않으므로 `msa-services` job의
`file_sd` glob과 `list-services.sh`의 목록에는 걸리지 않습니다.

`flock`은 util-linux에 들어 있어서 Ubuntu인 VM2에는 반드시 있습니다. 그래도 없는 경우에는 락 없이
진행하지 않고 이유를 적으면서 실패합니다. 조용히 넘어가면 락이 있다고 믿은 채로 경쟁이 되살아나기
때문입니다.

수집이 실제로 시작되었는지는 Prometheus API로 확인합니다.

```bash
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
```

VM1과 VM3의 node-exporter 컨테이너는 2026-09-18 기준으로 exited 상태였고, 그동안 `vm1-node`와
`vm3-node` target은 down으로 남아 있었습니다. 2026-09-19에 두 호스트에서 컨테이너를 다시 띄웠고
호스트 iptables에 VM2를 허용하는 규칙을 넣었으므로, 2026-09-20에 확인한 시점에는 두 target이
정상으로 수집됩니다. 컨테이너의 실행 옵션과 권한 상태는
[remote-exporters/README.md](remote-exporters/README.md)의 "현재 운영 상태와 이 스크립트의 관계"
절에 적어 두었습니다.

### 이번에 추가한 job

| job | 대상 | 수집하는 내용 |
|---|---|---|
| `alloy` | `alloy:12345` | 로그 수집기 자신의 지표입니다. Loki로 보낸 줄 수, 실패한 요청 수, 버린 줄 수를 포함합니다. |
| `cadvisor` | `cadvisor:8080` | 컨테이너 단위의 CPU, 메모리, 디스크 입출력, 네트워크 사용량입니다. |
| `blackbox-http-origin` | VM1 사설 주소 `10.0.1.133`에 공개 도메인 다섯 곳의 이름으로 접속합니다 | HTTP probe의 성공 여부와 오리진 TLS 인증서의 만료 시각입니다. 경보가 보는 것은 이 job입니다. |
| `blackbox-http-external` | 공개 도메인 다섯 곳 | Cloudflare를 거친 결과입니다. 대시보드 표시용이며 어떤 경보도 이 job을 보지 않습니다. |
| `blackbox-http-internal` | `gateway:8000/ready`, `auth-server:8001/health` | 컨테이너 안에서 본 준비 상태와 건강 상태입니다. |
| `blackbox-exporter` | `blackbox-exporter:9115` | probe 결과가 아니라 exporter 프로세스 자신의 지표입니다. |
| `vm1-nginx` | `10.0.1.133:9113` | VM1 nginx의 활성 연결 수와 누적 요청 수입니다. 아직 켜지 않았습니다. |
| `vm3-postgres` | `10.0.2.134:9187` | VM3 호스트 PostgreSQL 17의 접속 수와 트랜잭션과 복제 상태입니다. 아직 켜지 않았습니다. |

공개 도메인 probe의 대상은 `api.bnbong.com`, `bnbong.com`, `admin.bnbong.com`,
`monitoring.bnbong.com`, `overlock.bnbong.com` 다섯 곳입니다. VM1 Nginx의 `server_name` 목록에서
확인한 실제 서비스 도메인입니다. 경로는 아래의 "오리진 probe와 Cloudflare 경유 probe"에서
설명합니다.

`blackbox-http-external`과 `blackbox-http-internal`은 같은 relabel 패턴을 씁니다. `static_configs`에
적은 주소를 `__param_target`으로 옮겨서 `/probe`의 질의 인자로 만들고, `instance` label에 남긴 뒤,
실제 scrape 주소를 exporter로 바꿉니다. 이 세 단계를 거치지 않으면 Prometheus가 exporter를 호출하지
않고 대상 URL 자체를 수집하려고 합니다. `blackbox-http-origin`은 여기에서 한 단계가 더 늘어나는데,
그 내용도 아래 항목에 있습니다.

cAdvisor는 `--docker_only`와 `--disable_metrics`로 수집 범위를 좁혔습니다. Docker가 관리하지 않는
cgroup을 빼고, 코어 수만큼 시계열이 늘어나는 `percpu`와 연결 수에 따라 늘어나는 `tcp`, `udp`
계열을 껐습니다. 이렇게 하지 않으면 컨테이너 하나가 수백 개의 시계열을 만들어서 Prometheus의
저장 용량과 질의 속도에 부담을 줍니다.

### 원격 exporter 수집 활성화

`vm1-nginx`와 `vm3-postgres` job은 정의만 넣어 두고 아직 켜지 않은 상태입니다. 두 exporter를
VM1과 VM3에 설치하지 않았기 때문입니다. node-exporter는 두 호스트에서 이미 컨테이너로 돌고 있으므로
이 항목에 해당하지 않습니다. 설치 절차와 스크립트는
[remote-exporters/README.md](remote-exporters/README.md)에 있습니다.

주소를 `static_configs`에 바로 적지 않은 이유는 `TargetDown` 때문입니다. 설치하기 전에 주소를
적어 두면 두 target이 계속 down으로 남고 경보가 쉬지 않고 울립니다. 울리는 경보가 하나 늘어나면
나머지 경보까지 함께 무시되므로, 설치가 끝난 뒤에 사람이 켜는 구조로 만들었습니다. 두 job은
파일 기반 서비스 디스커버리를 사용하며, 대상 파일이 없으면 target 자체가 만들어지지 않습니다.

디렉터리를 둘로 나눈 이유는 배포 방식이 다르기 때문입니다.

| 디렉터리 | 배포 워크플로의 취급 | 역할 |
|---|---|---|
| `prometheus/targets-examples/` | rsync가 그대로 전송합니다. | 대상 파일에 넣을 내용을 저장소가 관리합니다. |
| `prometheus/targets/remote/` | rsync의 제외 대상입니다. | 활성화한 파일이 배포를 반복해도 남아 있습니다. |

`prometheus/targets/`를 제외하는 규칙은 하위 디렉터리에도 그대로 적용되므로, `targets/remote/`에
만든 파일은 `--delete`로 지워지지 않습니다. 같은 디렉터리를 읽는 `msa-services` job은
`targets/*.json`만 보고 `*`는 경로 구분자를 넘지 않기 때문에, `targets/remote/*.json`을 두 job이
겹쳐서 수집하는 일도 생기지 않습니다.

`targets/remote/` 디렉터리 자체는 compose가 만듭니다. Prometheus 서비스의 volume 목록에 이 경로를
따로 적어 두었고, Docker는 bind mount의 원본 디렉터리가 없으면 호스트에 만들어 줍니다. 위의 rsync
제외 때문에 저장소에 빈 디렉터리를 두어도 VM2에 전달되지 않아서 이렇게 했습니다. 디렉터리가 없는
상태로 두면 Prometheus가 30초마다 아래 오류를 남기는데, 수집과 경보에는 영향이 없지만 로그를
grep해서 원인을 찾는 절차가 계속 이 줄에 걸립니다. 실제로 기동해서 확인한 내용입니다.

```
level=ERROR msg="Error adding file watch" discovery=file config=vm1-nginx path=/etc/prometheus/targets/remote/ err="no such file or directory"
```

exporter 설치를 마친 뒤에 VM2에서 아래를 실행하면 수집이 시작됩니다. Prometheus는 30초마다 이
파일을 다시 읽으므로 재시작할 필요가 없습니다.

```bash
cd /opt/bnbong/monitoring/prometheus
sudo cp targets-examples/vm1-nginx.json.example    targets/remote/vm1-nginx.json
sudo cp targets-examples/vm3-postgres.json.example targets/remote/vm3-postgres.json

# 30초를 기다린 뒤에 수집 상태를 확인합니다
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '.data.activeTargets[] | select(.labels.job | test("vm1-nginx|vm3-postgres")) | {job: .labels.job, health: .health, error: .lastError}'

# exporter가 대상에 실제로 접속했는지는 두 지표로 확인합니다. 값이 1이어야 정상입니다
curl -s 'http://localhost:9090/api/v1/query?query=nginx_up' | jq '.data.result'
curl -s 'http://localhost:9090/api/v1/query?query=pg_up'    | jq '.data.result'
```

한쪽만 설치했다면 그쪽 파일만 복사하십시오. 두 job은 서로 독립적입니다. 되돌릴 때에는 해당
파일을 지우면 되고, 30초 안에 target이 사라집니다.

활성화하기 전까지 `promtool check config`는 대상 파일이 없다는 경고를 남깁니다. 아직 켜지
않았다는 표시이며 검사 자체는 통과합니다.

```
WARNING: file "/etc/prometheus/targets/remote/vm1-nginx.json" for file_sd in scrape job "vm1-nginx" does not exist
```

VM3의 5433번 포트에 남아 있는 PostgreSQL 14 클러스터는 관측 대상에 넣지 않았습니다. 2026-11에
제거할 예정이어서, 지금 수집을 붙이면 폐기할 때 경보와 대시보드를 다시 걷어 내야 하기
때문입니다. `vm3-postgres` job은 5432번 포트의 17 클러스터만 봅니다.

### Overlock과 Wegis의 수집 상태

Overlock(`vm2-overlock`, 8010번 포트)은 아직 scrape 대상에 넣지 않았습니다. Overlock은 별도
저장소가 소유하고 있어서 이 저장소에 소스가 없으며, `/metrics`를 노출하는지 코드로 확인할 방법이
없었기 때문입니다. 확인하지 않은 채 target을 추가하면 영구히 down 상태인 target이 하나 늘어나고,
`TargetDown` 경보가 계속 울려서 다른 경보까지 묻히게 됩니다.

추가로 확인해야 할 사실이 하나 더 있습니다. `vm2-overlock` 컨테이너는 `api-network`가 아니라
기본 `bridge` 네트워크에 붙어 있습니다. Overlock이 `/metrics`를 노출한다고 확인되더라도, 컨테이너를
`api-network`에 연결하거나 VM2의 private IP와 8010번 포트를 target으로 지정하는 작업이 함께
필요합니다.

Wegis는 `targets/wegis-server.json`으로 이미 등록되어 있습니다. 실제로 `/metrics`를 돌려주는지는
이번에 확인하지 않았으므로, 수집이 되는지는 아래의 target 상태 조회로 직접 확인해야 합니다.

---

## 알림 규칙

`prometheus/rules/basic.yml`에 여덟 개의 group과 스물한 개의 alert 규칙을 두었고
`prometheus.yml`의 `rule_files`가 이 디렉터리를 읽습니다. 규칙의 단일 출처는 이 파일 하나입니다.
규칙 수는 `promtool check rules`의 출력으로 확인할 수 있습니다.

배포 워크플로는 로드된 rule group 수가 0이면 배포를 실패로 끝내고, 거기에 더해 Prometheus가
들고 있는 group 이름과 alert 규칙 이름의 집합을 저장소의 rule 파일에서 계산한 집합과 비교해서
하나라도 다르면 배포를 실패로 끝냅니다. 규칙을 더하거나 이름을 바꾸면 기대값도 함께 바뀌므로
사람이 따로 손댈 곳은 없습니다. 자세한 내용은 위의 "배포 성공과 실패를 가르는 기준"에 있습니다.

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
| `OriginEndpointDown` | 오리진 probe가 5분 이상 2xx를 돌려주지 않습니다. | blackbox exporter의 `probe_success`를 `blackbox-http-origin` job으로 좁혀서 봅니다. |
| `GatewayNotReady` | Bifrost의 `/ready`가 3분 이상 준비 상태를 보고하지 않습니다. | 같은 지표를 gateway의 `/ready` 대상으로 좁혀서 봅니다. |
| `InternalEndpointDown` | gateway readiness를 제외한 내부 probe가 5분 이상 실패합니다. | 같은 지표를 나머지 내부 대상으로 좁혀서 봅니다. |
| `TLSCertExpiringSoon` | 오리진 TLS 인증서의 남은 기간이 7일 이상 21일 미만입니다. | blackbox exporter의 `probe_ssl_earliest_cert_expiry`를 `blackbox-http-origin` job으로 좁혀서 봅니다. |
| `TLSCertExpiringCritical` | 오리진 TLS 인증서의 남은 기간이 7일 미만입니다. | 위와 같습니다. |
| `ContainerRestartLoop` | 한 컨테이너가 15분 동안 세 번보다 많이 다시 시작되었습니다. | cAdvisor의 `container_cpu_usage_seconds_total`이 0으로 돌아간 횟수입니다. |
| `ContainerMemoryNearLimit` | 컨테이너의 메모리 사용량이 지정한 한도의 90%를 넘었습니다. | cAdvisor의 `container_memory_working_set_bytes`와 `container_spec_memory_limit_bytes`입니다. |
| `PostgresDown` | VM3 postgres_exporter가 데이터베이스에 5분 이상 접속하지 못합니다. | postgres_exporter 0.20.1의 `pg_up`입니다. |
| `NginxDown` | VM1 nginx exporter가 `stub_status`를 5분 이상 읽지 못합니다. | nginx-prometheus-exporter 1.5.3의 `nginx_up`입니다. |
| `LogShippingDropping` | 최근 10분 안에 Alloy가 재시도를 소진하고 버린 로그 줄이 있습니다. | Alloy의 `loki_write_dropped_entries_total`입니다. |
| `LogShippingWriteFailing` | 최근 10분 안에 2xx가 아닌 응답이 있었고 그 상태가 5분 넘게 이어집니다. | Alloy의 `loki_write_request_duration_seconds_count`를 `status_code`로 나눕니다. |

`GatewayNotReady`와 `InternalEndpointDown`의 조건을 나눈 이유는, 하나의 장애로 두 경보가 함께
울리는 상황을 막기 위해서입니다. `InternalEndpointDown`의 조건에서 gateway의 `/ready` 대상을
제외했습니다. 인증서 규칙도 같은 이유로 warning 쪽 조건에 7일이라는 하한을 두어, 만료가 7일보다
가까워지면 critical 하나만 울리게 했습니다.

`ContainerRestartLoop`이 재시작 횟수를 직접 세지 않는 이유는, cAdvisor에 재시작 횟수를 세는
지표가 없기 때문입니다. 이전 판은 `container_start_time_seconds`의 값이 재시작마다 바뀐다고
보고 그 변경 횟수를 세었는데, **실제로 측정해 보니 그 값은 재시작해도 바뀌지 않습니다.**

`gcr.io/cadvisor/cadvisor:v0.52.1`로 더미 컨테이너를 `docker restart`로 다섯 번 다시 시작하는
동안, `docker inspect`의 `StartedAt`은 매번 앞으로 갔지만 `container_start_time_seconds`는 최초
생성 시각에 고정되어 있었습니다. 그 구간을 Prometheus로 수집해서 두 식을 평가한 결과는
다음과 같았습니다.

| 식 | 결과 |
|---|---|
| `changes(container_start_time_seconds{name="..."}[15m])` (이전 판) | 0 |
| `resets(container_cpu_usage_seconds_total{name="..."}[15m])` (현재 판) | 5 |

컨테이너를 다시 시작하면 cgroup이 새로 만들어지면서 누적 카운터가 0으로 돌아갑니다. 그래서
누적 CPU 카운터의 reset 횟수를 재시작 횟수로 사용합니다. 실제 재시작 횟수와 정확히 같은 값이
나왔습니다. `grafana/dashboards/BNGdrasil/containers.json`의 재시작 감지 패널 두 개도 같은 식으로
고쳤습니다.

이 규칙에는 한계가 있습니다. **기동하자마자 죽는 컨테이너는 이 규칙으로 감지되지 않습니다.**
cAdvisor의 housekeeping 주기가 30초이므로 그 안에 한 번도 표본이 잡히지 않고, 그러면 시계열
자체가 만들어지지 않습니다. 같은 시험에서 즉시 종료하는 crash loop 컨테이너는 어떤 cAdvisor
시계열도 남기지 않았고, `RestartCount`만 계속 올라갔습니다. 이 구간은 scrape 대상인 서비스라면
`TargetDown`이 대신 잡습니다. 컨테이너 단위로 감지하려면 Docker의 재시작 횟수를 노출하는
exporter가 따로 필요하며, 그 작업은 이번 범위에 넣지 않았습니다.

`PostgresDown`과 `NginxDown`이 `TargetDown`과 겹치지 않는 이유는 두 규칙이 보는 대상이 다르기
때문입니다. `TargetDown`은 Prometheus가 exporter의 `/metrics`를 긁는 데 실패했는지를 봅니다.
반면 `pg_up`과 `nginx_up`은 exporter가 그 뒤의 PostgreSQL이나 `stub_status`에 접속했는지를
나타냅니다. exporter는 떠 있는데 데이터베이스가 중단된 상황에서는 `up`이 1이고 `pg_up`만 0이
되므로, 이 구간은 `TargetDown`으로 잡히지 않습니다.

두 규칙은 exporter를 설치하기 전까지 발화하지 않습니다. 시계열 자체가 없어서 조건이 평가될
대상이 없기 때문입니다. 따라서 수집이 끊긴 것과 아직 설치하지 않은 것을 이 규칙으로 구분할 수
없으며, 수집 여부 자체는 위의 target 상태 조회로 확인해야 합니다.

`ContainerMemoryNearLimit`은 현재 상태에서 한 번도 발화하지 않습니다. VM2의 컨테이너에 메모리
한도를 지정해 두지 않았고, 그런 컨테이너는 `container_spec_memory_limit_bytes`가 0으로 보고되어
규칙의 조건에서 걸러지기 때문입니다. 이 규칙이 실제로 동작하게 하려면 compose에 `mem_limit`을
지정해야 하며, 그 작업은 이번 범위에 넣지 않았습니다.

로그 전송 규칙 두 개는 Alloy가 살아 있는 상태에서 Loki 쪽 밀어넣기만 실패하는 구간을 봅니다. 그
구간에서는 `up{job="alloy"}`가 계속 1이므로 `TargetDown`으로는 잡히지 않습니다. 반대로 Alloy
컨테이너가 통째로 사라지는 경우는 규칙을 따로 두지 않았습니다. `prometheus.yml`에 `alloy` job을
추가했으므로 `TargetDown`이 이미 그 상태를 잡고, 규칙을 겹쳐 두면 하나의 장애로 두 경보가 함께
울리기 때문입니다.

두 규칙이 읽는 지표 이름은 `grafana/alloy:v1.19.2`를 실제로 띄워서 `/metrics`에 나오는 것만
사용했습니다. Promtail이 내보내던 `promtail_*` 지표와는 이름이 전혀 다르므로, 옛 이름을 그대로
옮겨 적으면 조건이 조용히 빈 결과를 냅니다.

`LogShippingDropping`을 critical로 둔 이유는 그 지표가 늘어나는 동안의 로그가 영구히 사라지기
때문입니다. `reason` label을 통지에 남기는 이유는 첫 대응이 갈리기 때문입니다. `rate_limited`와
`stream_limited`는 Loki의 `limits_config`를 올려야 하고, `ingester_error`는 Loki가 요청 자체를
거절한 경우입니다. `LogShippingWriteFailing`은 그 앞 단계로, 재시도가 아직 남아 있어 유실이 없는
구간을 warning으로 알립니다.

두 규칙은 `rate`와 긴 `for`의 조합에서 `increase`와 짧은 `for`의 조합으로 바꾸었습니다. 이전
판은 `rate(...[10m]) > 0`에 `for: 15m`을 붙였는데, 그 형태는 **한 번에 크게 버리고 멈추는
유실을 영영 잡지 못합니다.** `rate`의 10분 창이 지나가면 식이 0으로 돌아가므로 `for`의 15분을
채울 수 없기 때문입니다. 유실은 한 번이라도 놓치면 안 되므로 `LogShippingDropping`에서는 `for`를
아예 없앴고, 첫 증가가 10분 창에 들어오는 즉시 발화합니다. 증가가 창에서 빠져나가면 스스로
해소됩니다.

`LogShippingWriteFailing`에는 같은 결함이 있었지만 이쪽은 아직 유실이 없는 앞 단계이므로
`for`를 완전히 없애지 않고 5분으로 두었습니다. `increase`의 창이 10분이라서 한 번의 실패
묶음도 5분 뒤에는 반드시 드러나며, 그만큼 첫 통지가 늦어지는 대신 짧은 흔들림이 곧바로 통지로
이어지지는 않습니다. 두 상황 모두 `prometheus/tests/logging.yml`의 "한 번 늘어난 뒤 멈춤"
시험으로 고정해 두었습니다.

이 변경은 아래 "전환 시점의 중복과 유실" 항목에 적어 둔 설명과 맞습니다. 수집기를 바꾼 직후에
7일이 지난 로그가 거절되면서 `reason="ingester_error"`로 한 번 세어질 수 있는데, 이전 형태는
그 한 번을 잡지 못했고 지금은 잡습니다. 그 경보가 전환 직후에 한 번 울렸다가 10분 안에
잦아든다면 정상입니다.

Gateway와 Auth Server의 규칙을 나눈 이유는 두 앱이 같은 이름의 지표를 서로 다른 label로 내보내기
때문입니다. Bifrost는 상태 코드를 `status_class="5xx"`로 묶어서 내보내고, Bidar는
`should_group_status_codes=False`라서 `status="500"`처럼 원래 코드를 그대로 내보냅니다. 하나의
식으로 두 형태를 같이 다루면 label이 맞지 않아 조용히 빈 결과가 나옵니다.

### 통지 경로

**통지는 아직 켜지 않았습니다.** 설정과 compose 서비스는 모두 준비해 두었습니다. Discord webhook URL을
발급받은 뒤에 아래 절차를 수행하면 통지가 동작합니다.

#### 왜 Grafana가 아니라 Alertmanager인가

이전 판에서는 통지를 Grafana alerting으로 연결하겠다고 적어 두었습니다. 그러나 Grafana의 연락
지점은 Grafana가 직접 관리하는 규칙만 통지하고, Prometheus가 `rule_files`에서 평가하는 규칙은
통지하지 못합니다. Grafana로 통지하려면 같은 조건을 Grafana 안에 다시 만들어야 하고, 그러면
규칙이 두 곳에 나뉘어 한쪽만 고치는 일이 생깁니다.

규칙의 단일 출처를 `prometheus/rules/basic.yml`로 유지하는 쪽을 골랐습니다. 그러려면 통지를
Alertmanager가 맡아야 합니다.

"receiver가 비어 있는 Alertmanager를 두지 않는다"는 기존 결정은 그대로 유지됩니다. compose의
alertmanager 서비스에 `profiles: ["alerting"]`을 붙였으므로 `docker compose up -d`로는 기동되지
않고, `prometheus.yml`의 `alerting:` 블록도 주석 처리한 상태로 두었습니다. 즉 도달하지 못하는
통지 경로가 켜져 있는 시점이 없습니다.

#### 준비해 둔 내용

`alertmanager/alertmanager.yml`에 Discord receiver 두 개와 severity 기준 라우팅을 적어 두었습니다.

| 항목 | 값 | 이유 |
|---|---|---|
| 묶는 기준 | `alertname`, `instance`, `severity` | 같은 경보라도 어느 대상에서 났는지 통지에 남깁니다. |
| warning 재통지 주기 | 12시간 | 채널 하나로 받으므로 너무 잦으면 알림에 둔감해집니다. |
| critical 재통지 주기 | 4시간 | 대응 시점이 빨라야 하므로 warning보다 자주 알립니다. |
| critical 대기 시간 | 10초 | 첫 통지를 빨리 보냅니다. warning은 30초를 기다립니다. |
| 억제 규칙 | 경보 이름이 같은 쌍에 적용되는 일반 규칙 하나와, 이름이 다른 쌍에 적용되는 규칙 세 개를 둡니다 | 같은 원인으로 통지가 두 번 나가는 상황을 막습니다. |

#### 이름이 다른 warning과 critical 쌍을 억제합니다

일반 억제 규칙은 `equal`에 `alertname`을 포함하기 때문에 경보 이름이 서로 같을 때에만 동작합니다.
그런데 `prometheus/rules/basic.yml`에는 같은 원인을 두 단계로 나누어 표현하면서 이름을 다르게 붙인
쌍이 있습니다. `DiskSpaceLow`와 `DiskSpaceCritical`이 대표적인 예인데, 여유 공간이 5% 미만으로
떨어지면 15% 미만이라는 조건도 반드시 함께 참이 되므로 같은 디스크에 대해 통지가 두 번 나갔습니다.
그래서 쌍마다 `alertname`을 직접 지정하는 억제 규칙을 따로 두었습니다.

| source (critical) | target (warning) | `equal`에 사용한 label | 그 label을 선택한 이유 |
|---|---|---|---|
| `DiskSpaceCritical` | `DiskSpaceLow` | `instance`, `mountpoint` | 두 규칙식이 모두 집계 없이 나눗셈만 수행하므로 계열 label이 그대로 남습니다. 억제의 단위는 어느 호스트의 어느 마운트인가입니다. |
| `LogShippingDropping` | `LogShippingWriteFailing` | `service` | 두 규칙식이 각각 `sum by (reason)`과 `sum by (status_code)`로 묶여 있어서, 양쪽에 같은 값으로 남는 label은 규칙이 직접 붙이는 `service="alloy"`뿐입니다. |
| `BackupShipStale` | `BackupUnshippedPileup` | `instance` | 미전송 적체는 전송 실패의 결과입니다. `component` 값은 한쪽이 `ship`으로 고정되어 서로 다르기 때문에 `equal`에 넣을 수 없습니다. |

여기에서 지켜야 하는 원칙이 하나 있습니다. `equal`에 적는 label은 source 경보와 target 경보 양쪽에
모두, 같은 값으로 남아 있어야 합니다. 한쪽에만 존재하는 label을 적으면 두 경보가 결코 같아지지
않으므로, 규칙을 넣어 두었는데도 억제는 일어나지 않고 통지는 그대로 두 번 나갑니다. 특히 규칙식이
`sum by (...)`나 `min by (...)`로 묶여 있으면 묶음에 포함되지 않은 label은 결과에서 사라지기
때문에, 원본 지표에 그 label이 있다는 사실만 확인하고 `equal`에 적으면 안 됩니다.

같은 이유로 `BackupDiskLow`는 `DiskSpaceCritical`의 억제 대상에 넣지 않았습니다. 이 경보의 규칙식은
`min by (instance)`로 묶여 있어서 어느 마운트의 여유 공간이 부족한지를 결과 label에서 알 수
없습니다. `instance`만으로 억제하면 같은 호스트의 관계없는 파일시스템이 위험할 때 백업 파티션
경고까지 함께 묻히는데, 백업 실패로 직결되는 경고를 잘못 묻는 쪽이 중복 통지보다 손해가 큽니다.

`TLSCertExpiringSoon`과 `TLSCertExpiringCritical`에도 억제 규칙을 두지 않았습니다. warning 쪽 식에
7일이라는 하한이 붙어 있어서 두 조건이 동시에 참이 되는 구간이 아예 없기 때문입니다.

기존의 일반 규칙은 그대로 유지합니다. 현재 `basic.yml`의 경보는 이름마다 severity가 하나로 고정되어
있어서 이 규칙이 실제로 맞물리는 쌍은 없지만, severity를 식으로 결정하는 규칙이나 다른 출처의
경보가 추가되었을 때의 안전망 역할을 합니다. 반대로 이 규칙에서 `alertname`을 제거하면 어떤
critical이 발생하든 같은 호스트의 무관한 warning이 전부 묻히게 되므로, 제거해서는 안 됩니다.

억제가 실제로 일어나는지는 `prom/alertmanager:v0.28.1`을 임시 포트로 띄우고 `amtool alert add`로
경보를 직접 주입해서 확인했습니다. 의도한 세 쌍은 `amtool alert query --inhibited`에 suppressed로
나타났고, 같은 호스트의 다른 마운트와 다른 호스트의 같은 마운트는 active로 남았습니다.

#### webhook URL을 두는 위치

webhook URL은 설정 파일에 적지 않고 `webhook_url_file`로 파일에서 읽습니다. 파일 위치는 저장소
밖인 `/opt/bnbong/secrets/discord-webhook-url`입니다. 저장소를 VM2로 전송하는 rsync의 대상
디렉터리는 `/opt/bnbong/monitoring/`이므로, 이 위치에 두면 배포할 때 덮어써지지 않습니다.

#### 파일이 없을 때 기동이 실패하도록 마운트 문법을 바꾸었습니다

이 파일의 mount는 compose의 long 문법으로 적고 `bind.create_host_path`를 `false`로, `read_only`를
`true`로 두었습니다. 이전의 short 문법(`원본:대상:ro`)은 원본 파일이 없을 때 **Docker가 그 경로에
디렉터리를 만들어 버립니다.** 실제로 재현해 보니 컨테이너는 정상으로 기동했고, 컨테이너 안의
`/run/secrets/discord_webhook_url`은 빈 디렉터리였습니다. 그러면 webhook URL이 없다는 사실이
경보가 실제로 발생하는 순간까지 드러나지 않고, 한 번 만들어진 디렉터리는 나중에 같은 경로에
파일을 만들려 할 때 방해가 됩니다.

long 문법으로 바꾼 뒤 같은 상황을 재현하자 기동 자체가 아래 오류로 실패했고, 호스트에는 아무
디렉터리도 만들어지지 않았습니다.

```
Error response from daemon: invalid mount config for type "bind":
  bind source path does not exist: /opt/bnbong/secrets/discord-webhook-url
```

`/var/run/docker.sock`을 마운트하는 cAdvisor와 docker-socket-proxy에도 같은 문법을 적용했습니다.
소켓이 없는 상태에서 조용히 기동해 모든 요청에 실패하는 것보다, 없다고 실패하는 편이 낫습니다.

**compose 버전 하한은 2.x입니다.** `bind.create_host_path`는 Compose 파일 규격의 항목이며 Docker
Compose v2에서 지원합니다. `docs/deployment-inventory.md`에 기록된 대로 VM1과 VM2, VM3의 Docker
Compose는 모두 2.40.0이므로 그대로 사용할 수 있습니다. 검증은 Compose 2.33.0에서 수행했고
`config --quiet`와 실제 기동이 모두 의도대로 동작했으며, Compose 2.18.1에서도 `config --quiet`가
통과했습니다. 저장소의 파일을 Compose v1이 있는 호스트로 가져가는 일은 현재 계획에 없습니다.

#### 활성화 절차

1. VM2에 비밀 디렉터리와 파일을 만들고 webhook URL을 적습니다. **파일의 소유자를
   `65534:65534`로 맞추고** 권한을 600으로 좁힙니다. 컨테이너는 이 파일을 읽기 전용으로
   mount하여 읽습니다.

   ```bash
   sudo mkdir -p /opt/bnbong/secrets
   sudo chmod 700 /opt/bnbong/secrets
   sudo tee /opt/bnbong/secrets/discord-webhook-url >/dev/null <<< 'https://discord.com/api/webhooks/<발급받은 경로>'
   # Alertmanager 컨테이너는 uid 65534로 실행됩니다. 소유자를 root로 두면 읽지 못합니다.
   sudo chown 65534:65534 /opt/bnbong/secrets/discord-webhook-url
   sudo chmod 600 /opt/bnbong/secrets/discord-webhook-url
   ```

   소유자를 맞추는 일이 왜 중요한지는 따로 적어 둘 필요가 있습니다. 소유자가 `root`이고 권한이
   600이면 컨테이너는 이 파일을 열지 못하는데, **그 실패가 기동 시점에는 전혀 드러나지
   않습니다.** Alertmanager는 설정을 읽을 때 이 파일을 확인하지 않으므로 컨테이너는 정상으로
   뜨고 `/-/healthy`도 200을 돌려줍니다. 경보가 실제로 발생한 뒤에야 아래 오류를 남기고 통지를
   버립니다. 즉 통지가 필요한 순간에 처음 알게 됩니다.

   ```
   level=ERROR msg="Notify for alerts failed" err="discord-critical/discord[0]: notify retry canceled due to unrecoverable error after 1 attempts: read webhook_url_file: open /run/secrets/discord_webhook_url: permission denied"
   ```

   이 동작은 `prom/alertmanager:v0.28.1`로 직접 재현해서 확인했습니다. 소유자를 65534로 바꾼
   뒤에는 같은 경보에서 파일을 정상적으로 읽고 Discord 응답 단계까지 진행했습니다. compose의
   alertmanager 서비스에는 `user: "65534:65534"`를 명시해 두었으므로, 이미지의 기본 실행
   사용자가 바뀌더라도 위 소유자 지정이 계속 유효합니다.

   파일을 만든 뒤에 아래 명령으로 컨테이너가 실제로 읽는지 확인하십시오. 경보를 기다리지 않고
   권한 문제를 걸러 낼 수 있는 가장 빠른 방법입니다.

   ```bash
   cd /opt/bnbong
   sudo docker compose -f docker-compose.monitoring.yml --profile alerting run --rm --no-deps \
     --entrypoint cat alertmanager /run/secrets/discord_webhook_url
   ```

2. `alerting` profile을 켜서 Alertmanager를 기동하고 상태를 확인합니다.

   ```bash
   cd /opt/bnbong
   sudo docker compose -f docker-compose.monitoring.yml --profile alerting up -d alertmanager
   sudo docker compose -f docker-compose.monitoring.yml --profile alerting ps alertmanager
   ```

3. `monitoring/prometheus/prometheus.yml`에서 `alerting:` 블록의 주석을 풀고 설정을 다시 읽힙니다.
   블록의 위치와 내용은 그 파일의 주석에 그대로 적어 두었습니다.

   ```bash
   sudo docker compose -f docker-compose.monitoring.yml restart prometheus
   curl -s http://localhost:9090/api/v1/alertmanagers | jq '.data.activeAlertmanagers'
   ```

   마지막 명령의 결과에 `http://alertmanager:9093/api/v2/alerts`가 나와야 연결된 것입니다.

4. 시험 알림을 직접 발화시켜 Discord에 도착하는지 확인합니다. 규칙이 실제로 울릴 때까지 기다리지
   말고, `amtool`로 경보 하나를 밀어 넣어 경로 전체를 검증합니다.

   ```bash
   sudo docker compose -f docker-compose.monitoring.yml --profile alerting exec alertmanager \
     amtool --alertmanager.url=http://localhost:9093 alert add \
     alertname=NotificationPathTest severity=critical instance=vm2 \
     --annotation='summary="통지 경로 시험"'
   ```

   주석 값을 큰따옴표로 한 번 더 감싼 이유는 amtool의 UTF-8 파서 때문입니다. 따옴표 없이 공백이
   들어간 한글 값을 넘기면 파서가 값을 끊어서 읽고, 옛 파서로 되돌아갔다는 경고를 남깁니다.

   Discord 채널에 메시지가 들어오면 통지 경로가 정상으로 동작하는 것입니다. 확인한 뒤에는 같은 이름의 경보를
   해소하거나 silence를 걸어 둡니다.

5. 4번까지 확인한 뒤에 이 문서의 이 항목을 "통지를 켰습니다"로 고치고, 확인한 날짜를 남깁니다.

#### 컨테이너 실행 사용자와 파일 권한

webhook URL 파일에서 겪은 문제는 컨테이너의 실행 사용자와 호스트 파일의 소유자가 어긋나서
생깁니다. 같은 종류의 문제가 다른 곳에도 있는지 스택 전체를 점검했고, 결과는 아래와 같습니다.

| 구성 요소 | 실행 uid | 점검 결과 |
|---|---|---|
| Alertmanager | 65534 | webhook URL 파일이 유일한 문제 지점이었고 위 절차로 해결했습니다. |
| `alertmanager_data` volume | 65534 | 문제가 없습니다. Docker가 비어 있는 named volume을 만들 때 이미지의 `/alertmanager` 디렉터리를 소유자까지 그대로 복사하며, 그 디렉터리가 이미 `65534:65534`입니다. 새 볼륨에 쓰기가 되는 것을 확인했습니다. |
| blackbox-exporter | 0 | 문제가 없습니다. 설정 파일을 저장소에서 읽기 전용으로 mount할 뿐이고 그 파일은 모두가 읽을 수 있습니다. |
| cAdvisor | 0 | 문제가 없습니다. 호스트의 `/sys`와 `/var/lib/docker`를 읽어야 하므로 root로 동작해야 합니다. |
| Alloy | 0 | 문제가 없습니다. 호스트에서 읽는 것은 `/var/log`뿐이고, 그 아래 파일은 root만 읽을 수 있는 것이 섞여 있으므로 root로 동작해야 합니다. Docker 소켓은 직접 mount하지 않습니다. |
| docker-socket-proxy | 0 | 문제가 없습니다. 소켓을 열려면 root가 필요하며, 이 컨테이너가 수행하는 일은 HAProxy로 요청을 걸러 내는 것뿐입니다. |
| Prometheus, Grafana, Loki | 65534, 472, 10001 | 이번 변경에서 새로 붙인 호스트 파일이 없으므로 그대로 둡니다. |

blackbox exporter가 root로 도는 이유는 ICMP probe에 원시 소켓 권한이 필요하기 때문이며, 이미지가
실행 사용자를 지정하지 않습니다. 현재 구성은 HTTP probe만 쓰므로 실행 사용자를 낮출 여지가
있지만, 이번 범위에서는 바꾸지 않았습니다.

#### 아직 확인하지 않은 부분

경보 규칙은 `promtool check rules`와 `promtool test rules`로 조건과 발화 시점을 확인했습니다.
그러나 실제 지표가 들어온 운영 환경에서 경보가 발생하고 Discord까지 도달하는 것은 아직 확인하지
않았습니다. 위 4번 절차가 그 확인에 해당합니다.

### 백업 지표와 textfile collector

백업 규칙이 사용하는 지표는 백업 job이 `.prom` 파일로 남기는 값입니다. VM2의 node-exporter에는
`--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`를 지정하고 호스트의
같은 경로를 읽기 전용으로 mount했습니다. VM3의 node-exporter 컨테이너에도 2026-09-19에 같은 설정을
넣었습니다. `/var/lib/node_exporter/textfile_collector`를 `/textfile`로 mount하고
`--collector.textfile.directory=/textfile`을 인자로 넘기고 있으며, 2026-09-20에 그대로 남아 있는
것을 확인했습니다. **VM3의 node-exporter를 systemd 유닛으로 바꾸면 이 조건을 다시 맞추어야 합니다.**
컨테이너는 root로 돌지만 유닛은 비root 사용자로 돌기 때문에, 0700으로 남아 있는
`/var/lib/node_exporter`의 권한도 함께 바꾸어야 지표가 사라지지 않습니다.

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

### readiness 감시와 blackbox exporter

Bifrost에는 DB 연결과 서비스 등록부를 함께 확인하는 `/ready`가 있지만, Prometheus는 `/metrics`만
수집하므로 readiness 실패를 나타내는 지표가 없었습니다. 이전 판에 있던 `service_ready` 규칙은
어디에도 없는 지표를 참조했기 때문에 제거했고, 감시 수단은 다음 범위로 넘겨 두었습니다.

이번에 blackbox exporter를 추가하여 그 감시 수단을 마련했습니다. `http://gateway:8000/ready`에 HTTP
probe를 걸면 준비되지 않은 상태가 503으로 돌아오고, 그 결과가 `probe_success` 0으로 기록됩니다.
`GatewayNotReady` 규칙이 이 지표를 봅니다. 컨테이너가 실행 중이라는 사실만으로는 알 수 없던
상태를 이제 지표로 확인할 수 있습니다.

probe 모듈은 `blackbox/blackbox.yml`에 셋으로 나누어 두었습니다. `http_2xx`는 `api-network` 안의
평문 HTTP 대상에 쓰고, `http_2xx_origin`은 VM1 오리진에 직접 접속하는 probe에 쓰며,
`http_2xx_tls`는 Cloudflare를 거치는 공개 도메인에 씁니다. 뒤의 두 모듈은 `fail_if_not_ssl`로 평문
응답을 실패로 처리하고 인증서 검증을 켜 둡니다. 검증을 끄면 이미 만료된 인증서도 성공으로
보이므로, 인증서 만료 규칙을 두는 목적과 어긋납니다.

### 오리진 probe와 Cloudflare 경유 probe

공개 endpoint 감시의 기준은 `blackbox-http-origin` job입니다. 이 job은 VM2의 blackbox exporter가
VM1의 사설 주소 `10.0.1.133`으로 곧장 HTTPS 접속을 열고, Host 헤더와 TLS SNI만 공개 도메인으로
맞추는 probe입니다. Cloudflare를 거치지 않으므로 edge에서 생기는 일과 오리진에서 생기는 일이 섞이지
않습니다.

기준을 이렇게 옮긴 이유는 Cloudflare가 요청을 봇으로 판단하면 챌린지 403을 돌려주기 때문입니다.
2026-09-19에 GitHub 러너가 실제로 그 403을 받은 적이 있습니다. 오리진이 멀쩡한데도 경보가 울리는
구성이었고, 403을 성공 코드로 인정하는 방식은 챌린지와 진짜 거부를 구분하지 못하므로 택하지
않았습니다.

VM1의 Nginx에는 이름이 맞지 않는 요청을 444로 끊는 default server가 있고, 443 vhost는
`server_name`으로만 갈립니다. 사설 주소로 그냥 접속하면 default server에 걸려 연결이 끊기고, 그
전에 인증서 검증부터 실패합니다. 인증서에 IP SAN이 없기 때문입니다. blackbox exporter의 `hostname`
질의 인자가 Host 헤더와 SNI를 함께 덮어 주므로, vhost 다섯 곳을 모듈 하나로 다룰 수 있습니다.
`prom/blackbox-exporter:v0.28.0`에서 실제로 동작하는 것을 자체 CA 환경으로 재현해 확인했습니다.

`prometheus.yml`의 `static_configs`에 적는 값은 사람이 읽을 공개 URL입니다. relabel이 그 값을
`instance` label에 그대로 남겨서 대시보드와 경보 본문에 표시하고, 같은 값에서 도메인만 떼어
`__param_hostname`으로, 경로만 떼어 VM1 사설 주소에 붙여 `__param_target`으로 만듭니다.

이때 정규식의 경로 부분은 `(/.*)?`로 두어 선택 항목으로 만들었습니다. Prometheus의 relabel
정규식은 양끝이 고정되어 있어서, 경로를 `(/.*)`로 두면 `https://bnbong.com`처럼 트레일링 슬래시가
없는 주소는 아예 일치하지 않습니다. 일치하지 않은 relabel 규칙은 오류를 내지 않고 그냥 건너뛰므로,
`__param_hostname`과 `__param_target`이 비어 있는 채로 target이 만들어지고 probe가 계속
실패합니다. `prom/prometheus:v3.7.2`에 두 정규식을 각각 넣고 `/api/v1/targets`의 `scrapeUrl`을
읽어서 확인했습니다. 이전 정규식에서는 슬래시가 없는 주소의 `scrapeUrl`이
`/probe?module=http_2xx_origin`까지만 남았고, 지금 정규식에서는
`/probe?hostname=bnbong.com&module=http_2xx_origin&target=https://10.0.1.133`으로 올바르게
만들어집니다. 현재 `static_configs`에는 그런 주소가 없지만 하나만 늘어나도 같은 일이 생깁니다.

이 relabel을 거치면서 표시용 주소와 실제 접속 주소가 서로 분리됩니다.

오리진 probe는 redirect를 따라가지 않습니다. 따라가게 두면 상대 경로 redirect를 만났을 때 다음
요청의 host가 공개 도메인으로 바뀌면서 다시 Cloudflare를 거치게 되고, 오리진 probe라는 성질 자체가
사라집니다. 그래서 경로를 두 곳에서 다르게 잡았습니다. `api.bnbong.com`은 게이트웨이의 rate limit
zone에서 예외로 둔 `/health`를 쓰고, `monitoring.bnbong.com`은 `/`가 Grafana 로그인 화면으로 302를
돌려주므로 인증 없이 200을 돌려주는 `/api/health`를 씁니다. 나머지 세 곳은 정적 `index.html`이라
`/`로 충분합니다.

`blackbox-http-external` job은 그대로 남겨 두었지만 어떤 경보도 이 job의 시계열을 보지 않습니다.
대시보드에서 두 경로의 결과를 비교하는 용도입니다. 두 job의 결과가 갈리는 구간이 곧 Cloudflare 쪽
문제이므로, 그 구간을 눈으로 확인할 수 있다는 점에 값이 있습니다. VM2에서 실제 결과를 얼마간 모아
본 뒤에 이 job을 경보에 연결할지, 예를 들어 두 job이 함께 실패할 때에만 울리는 규칙을 둘지 다시
판단합니다. `probes.json` 대시보드에는 `probe 경로` 변수가 있어서 두 job을 따로 볼 수 있습니다. 두
job의 `instance`가 같은 공개 URL이므로, 이 변수가 없으면 두 경로가 한 줄로 뭉쳐서 보입니다.

### 오리진 인증서 검증

VM1이 들고 있는 `/etc/ssl/cloudflare/cert.pem`은 Cloudflare Origin CA가 서명한 것이라 공인 신뢰
저장소로는 검증되지 않습니다. `insecure_skip_verify`로 넘기면 만료된 인증서까지 성공으로 보이므로,
그 대신 해당 루트 인증서를 `tls_config.ca_file`로 지정합니다. 파일은
`monitoring/blackbox/cloudflare-origin-ca.pem`이며 RSA 루트와 ECC 루트를 이어 붙였습니다. 오리진
인증서를 다시 발급할 때 키 형식을 바꾸면 서명 주체가 달라지는데, 두 루트를 함께 두면 그때 설정을
고치지 않아도 됩니다. 파일 앞의 주석 문단에 내려받은 URL과 SHA-256 지문을 적어 두었습니다. 공개
루트 인증서이므로 비밀이 아닙니다.

compose는 이 파일을 blackbox exporter 컨테이너에 따로 mount합니다. 설정 파일 하나만 mount하던
이전 상태에서는 컨테이너 안에 CA 파일이 없어서 오리진 probe가 전부 실패합니다.

덕분에 감시 범위가 넓어졌습니다. 이전에는 `probe_ssl_earliest_cert_expiry`가 Cloudflare edge
인증서의 만료 시각만 보여 주었고, VM1이 들고 있는 origin 인증서의 만료는 어떤 규칙으로도 감지되지
않았습니다. 이제는 그 origin 인증서를 직접 봅니다. 갱신 주체도 Cloudflare가 아니라 사람이므로,
경보가 울리면 Cloudflare 대시보드의 SSL/TLS 항목에서 Origin Server 인증서를 다시 발급하고 VM1의
`cert.pem`과 `key.pem`을 교체한 뒤 `nginx -s reload`를 수행합니다.

### 외부 probe의 한계

공개 도메인 probe는 오리진 경유든 Cloudflare 경유든 모두 VM2 안에서 실행됩니다. 따라서 **VM2 자체가
죽으면 probe도 함께 멈추고, `OriginEndpointDown` 경보는 울리지 않습니다.** 이 구성으로 감지할 수
있는 것은 VM2가 살아 있는 상태에서 발생한 장애, 예를 들어 VM1 Nginx의 중단이나 애플리케이션 응답
실패입니다. VM2가 통째로 사라지는 상황은 이 구성의 범위 밖입니다.

VM2 장애를 감지하려면 VM2 밖에서 동작하는 독립된 probe가 있어야 합니다. 오사카의 VM4나 외부
무료 감시 서비스를 후보로 볼 수 있지만, 어느 쪽도 아직 구성하지 않았습니다. **독립 외부 probe는
남은 과제입니다.**

오리진 probe로 옮기면서 생긴 한계도 있습니다. 이 probe는 Cloudflare를 건너뛰므로, Cloudflare 쪽
설정이 잘못되어 공개 도메인이 실제로는 닿지 않는 상황을 경보로 잡지 못합니다. 그 구간은
`blackbox-http-external` job의 결과를 대시보드에서 비교해서 확인합니다.

### 규칙 단위 시험

새로 추가하거나 고친 규칙에는 `promtool`의 단위 시험을 붙였습니다. 시험 파일은 네 개이며,
저장소의 `monitoring/` 디렉터리에서 다음과 같이 실행합니다.

| 시험 파일 | 다루는 규칙 |
|---|---|
| `prometheus/tests/blackbox-and-containers.yml` | `OriginEndpointDown`, `GatewayNotReady`, `InternalEndpointDown`, TLS 인증서 두 규칙, 컨테이너 두 규칙입니다. Cloudflare 경유 job의 probe가 계속 실패해도 어떤 경보도 울리지 않는다는 점과, TLS 경보가 오리진 job의 인증서만 본다는 점을 함께 확인합니다. |
| `prometheus/tests/remote-exporters.yml` | `PostgresDown`, `NginxDown`입니다. |
| `prometheus/tests/logging.yml` | `LogShippingDropping`, `LogShippingWriteFailing`입니다. |
| `prometheus/tests/gateway-upstreams.yml` | `GatewayUpstreamHighServerErrorRate`와 `GatewayHighServerErrorRate`입니다. |

```bash
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v3.7.2 \
  test rules /etc/prometheus/tests/blackbox-and-containers.yml \
             /etc/prometheus/tests/remote-exporters.yml \
             /etc/prometheus/tests/logging.yml \
             /etc/prometheus/tests/gateway-upstreams.yml
```

이 시험은 규칙이 의도한 시점에 발화하는지와, 조건을 나눈 규칙들이 같은 장애로 겹쳐서 울리지
않는지를 확인합니다. `remote-exporters.yml`은 여기에 더해 `up`이 1인데 `pg_up`이 0인 구간에서
`TargetDown`이 함께 울리지 않는다는 점과, exporter를 설치하지 않아 시계열이 전혀 없을 때 두
규칙이 조용하다는 점을 확인합니다. 지표가 실제로 들어오는지까지 검증하지는 않습니다.

`logging.yml`은 네 가지를 더 확인합니다. 첫째, Alloy는 `reason`마다 값이 0인 시계열을 항상
노출하므로 시계열이 존재한다는 사실만으로 발화하면 안 됩니다. 둘째, 정상 구간의 `status_code`는
204이므로 `status_code!~"2.."` 조건이 그 값을 걸러야 합니다. 셋째, Alloy 컨테이너가 사라진 구간에서는
`TargetDown` 하나만 울리고 로그 전송 규칙 두 개는 조용해야 합니다. 넷째, 값이 한 번만 크게
늘고 그 뒤로 멈추는 구간에서도 두 규칙이 반드시 발화해야 하고, 증가가 창에서 빠져나가면 스스로
해소되어야 합니다. 네 번째가 이전 형태에서 놓치던 상황입니다.

`gateway-upstreams.yml`은 업스트림 둘 가운데 한쪽에만 5xx가 몰릴 때 그 업스트림 하나만
발화하는지를 확인합니다. 전체 비율은 5% 기준 아래로 두어서 `GatewayHighServerErrorRate`가 함께
울리지 않는다는 점도 같이 확인합니다. 이 시험이 성립하려면 `prometheus.yml`의 `labeldrop`이
있어야 합니다. 그 설정이 없으면 세 업스트림의 시계열이 `service="gateway"` 하나로 뭉쳐서
업스트림별 기대 결과가 나오지 않습니다.

---

## 로그 수집

로그 수집기는 Grafana Alloy입니다. 설정 파일은 `alloy/config.alloy` 하나이고, 컨테이너 안에서는
`/etc/alloy/config.alloy`로 읽힙니다. Promtail을 쓰던 `loki/promtail-config.yml`은 없앴습니다.
필요하면 git 이력에서 꺼내 볼 수 있습니다.

Alloy는 Docker API로 컨테이너 목록을 가져와서 각 컨테이너의 로그를 읽고, 호스트의 `/var/log/*log`를
따로 tail합니다. 두 경로가 붙이는 label은 아래와 같으며, 이 이름과 값은 Promtail 시절과 같습니다.

| 수집 경로 | 붙는 label |
|---|---|
| 컨테이너 로그 | `job="docker"`, `host="vm2"`, `container`, `service`, `stream`, 그리고 compose로 띄운 컨테이너에는 `compose_project` |
| 호스트 시스템 로그 | `job="varlogs"`, `host="vm2"`, `filename` |

`container`는 Docker API가 돌려주는 이름에서 맨 앞의 `/`를 떼어 낸 값입니다. `service`는 compose가
붙이는 서비스 이름이며, compose label이 없는 컨테이너에서는 컨테이너 이름으로 채웁니다. 수동
`docker run`으로 기동한 `wegis_server`가 여기에 해당하고, 그 컨테이너의 `service`는
`wegis_server`가 됩니다.

label 이름을 그대로 유지해야 하는 이유는 의존하는 곳이 저장소 밖에도 있기 때문입니다. `grafana/dashboards/BNGdrasil/`
아래의 대시보드 여덟 개가 `service`와 `host`와 `stream`으로 질의하고, Bantheon 어드민의 Explore
링크가 `{service="..."}`와 `{job=~".+"}` 형태로 Grafana를 엽니다. label을 하나라도 바꾸면 두 곳이
함께 빈 화면을 보여 줍니다.

Grafana의 Explore 화면에서 다음과 같이 조회합니다.

```logql
{job="docker"}                               # 모든 컨테이너 로그
{job="docker", container="vm2-gateway"}      # 특정 컨테이너
{job="docker"} |= "ERROR"                    # 오류만
{job="docker", stream="stderr"}              # 표준 오류로 나간 줄만
{service="wegis_server"}                     # compose label이 없는 컨테이너
{job="varlogs", host="vm2"}                  # 호스트 시스템 로그
```

Loki의 보존 기간은 168시간이며 compactor가 그 기간을 넘긴 로그를 지웁니다.

### service label을 채우는 방식을 바꾼 이유

Promtail 설정은 compose label이 없는 컨테이너의 `service`를 pipeline의 template stage로 채웠습니다.
Alloy에도 같은 stage가 있고 `alloy convert`도 그 stage를 그대로 옮겨 주지만, 그 결과를 쓰지
않았습니다. Alloy의 template stage가 읽는 값은 파이프라인의 extracted map이고, relabel이 만든
label은 그 map에 들어 있지 않습니다. 즉 stage 방식은 비교할 두 값이 모두 비어 있는 상태에서
동작합니다.

그래서 fallback을 relabel 단계로 옮겼습니다. compose service label과 컨테이너 이름을 `;`로 이어
붙인 뒤, 앞부분이 비어 있을 때에만 정규식이 맞도록 했습니다. relabel의 replace는 정규식이 맞지
않으면 아무 일도 하지 않으므로, compose label이 있는 컨테이너는 이 규칙을 그냥 지나갑니다.
컨테이너 이름 앞의 `/`도 같은 규칙에서 함께 떼어 냅니다.

바뀐 것은 구현 방식이고 결과로 붙는 label은 같습니다. 아래의 "전환을 검증한 방법"에 두 수집기를
같은 조건에서 나란히 띄워 비교한 결과를 적어 두었습니다.

### Docker API 접근 범위

Promtail은 `/var/run/docker.sock`을 읽기 전용으로 mount했습니다. 읽기 전용 mount는 소켓 파일의
권한만 제한할 뿐이고 그 소켓으로 보내는 요청의 method를 제한하지 않습니다. 즉 컨테이너 생성,
삭제, `exec`까지 포함한 Docker API 전체를 호출할 수 있는 권한이었습니다. 수집기를 바꾸는 시점에 이
범위를 다시 판단하기로 했던 항목이며, 이번에 결정했습니다.

세 가지를 놓고 비교했습니다.

| 선택지 | 보안 | 운영 복잡도 | label 계약 |
|---|---|---|---|
| 소켓을 Alloy에 직접 mount | Docker API 전체를 호출할 수 있습니다. | 추가 구성이 없습니다. | 그대로 지켜집니다. |
| docker-socket-proxy를 거칩니다 | 조회 계열 경로만 통과하고 쓰기 method는 막힙니다. | 컨테이너가 하나 늘어납니다. | 그대로 지켜집니다. |
| 소켓 없이 로그 파일을 tail | Docker API를 전혀 쓰지 않습니다. | 추가 구성이 없습니다. | 지킬 수 없습니다. |

**docker-socket-proxy를 거치는 쪽을 골랐습니다.**

세 번째 선택지를 먼저 걸렀습니다. `/var/lib/docker/containers/*/*-json.log`를 직접 tail하면 경로에서
얻을 수 있는 정보가 컨테이너 ID뿐입니다. 컨테이너 이름도, compose가 붙인 service와 project label도
Docker API를 거치지 않고는 알 수 없습니다. 즉 `container`, `service`, `compose_project`를 만들 수
없고, 앞에서 적은 label 계약이 깨집니다. 대시보드 여덟 개와 어드민 Explore 링크가 동시에 빈 화면을
보여 주게 되므로 이 선택지는 성립하지 않습니다.

남은 둘 가운데 프록시를 고른 이유는 Alloy와 cAdvisor의 성격이 다르기 때문입니다. Alloy는 컨테이너가
찍어 내는 로그, 즉 외부 입력이 섞여 들어오는 데이터를 해석하고, HTTP 화면과 설정 다시 읽기
경로까지 가지고 있습니다. 그 구성 요소가 장악되었을 때 Docker API 전체를 부를 수 있는 상태와,
컨테이너 목록과 로그만 읽을 수 있는 상태는 피해 범위가 다릅니다. 컨테이너 하나가 늘어나는 대가로
그 차이를 사는 편이 낫다고 판단했습니다.

프록시는 HAProxy 하나만 실행하며 `tecnativa/docker-socket-proxy:v0.5.0`으로 태그를 고정했고,
`linux/arm64` manifest가 있는 것을 확인했습니다. 허용하는 권한은 `CONTAINERS`와 `NETWORKS` 둘뿐이며 `POST`는 0입니다.
`POST=0`이면 프록시가 GET과 HEAD 말고는 전부 막으므로 컨테이너 생성과 삭제와 `exec`이 모두
차단됩니다. 나머지 위험한 항목도 기본값이 0이지만, 나중에 누가 늘리려 할 때 의도가 드러나도록
compose에 명시적으로 적어 두었습니다.

`NETWORKS`를 연 이유는 실제로 기동해서 확인한 내용입니다. Alloy의 `discovery.docker`는 컨테이너마다
붙는 네트워크 label을 만들 때 `GET /networks`를 호출하고, 그 권한이 없으면 아래 오류를 남기면서
대상 목록 갱신 자체가 실패합니다. 네트워크 목록 조회는 읽기 전용이므로 권한을 하나 더 여는 대가가
작다고 보았습니다.

```
level=error msg="Unable to refresh target groups" component_id=discovery.docker.containers
  err="error while computing network labels: Error response from daemon: 403 Forbidden"
```

이 구성으로 프록시가 실제로 무엇을 막는지 요청을 하나씩 보내서 확인했습니다.

| 요청 | 응답 |
|---|---|
| `GET /containers/json` | 200 |
| `GET /networks` | 200 |
| `GET /version`, `GET /_ping` | 200 (프록시의 기본 허용 범위입니다) |
| `GET /images/json` | 403 |
| `GET /info` | 403 |
| `GET /secrets` | 403 |
| `POST /containers/create` | 403 |
| `POST /containers/<id>/exec` | 403 |

#### 프록시를 전용 네트워크로 분리했습니다

프록시를 `api-network`에 두면 그 네트워크의 모든 컨테이너가 `docker-socket-proxy:2375`를 부를
수 있습니다. `api-network`에는 gateway와 auth-server와 wegis 같은 애플리케이션 컨테이너가 함께
붙어 있고, 그 가운데 하나가 장악되면 Docker API 조회 경로가 그대로 열립니다. `CONTAINERS=1`은
컨테이너 목록만이 아니라 inspect까지 허용하므로, 다른 컨테이너의 환경 변수를 그 경로로 읽을 수
있습니다. 애플리케이션 컨테이너에는 그 권한이 필요하지 않습니다.

그래서 `internal: true`인 전용 네트워크를 만들고 프록시와 Alloy만 붙였으며, 프록시는
`api-network`에서 뗐습니다. compose가 project 이름을 붙여서 `bnbong_docker-socket`이라는 이름으로
만듭니다. `internal: true`는 이 네트워크에 외부로 나가는 경로를 만들지 않습니다. 프록시는
호스트의 소켓 파일만 읽으면 되므로 바깥으로 나갈 일이 없습니다.

Alloy는 두 네트워크에 함께 붙습니다. Loki로 로그를 보내고 Prometheus가 12345번 포트를 긁어야
하므로 `api-network`가 필요하고, 컨테이너 목록과 로그를 읽으려면 `docker-socket`이 필요합니다.

임시 project 이름으로 스택을 실제로 띄워서 확인했습니다.

| 확인 내용 | 결과 |
|---|---|
| `api-network`의 앱 컨테이너에서 `docker-socket-proxy:2375` 호출 | 이름이 해석되지 않습니다 (`bad address`). |
| 같은 자리에서 프록시의 IP로 직접 호출 | 연결되지 않고 시간 초과로 끝납니다. |
| Prometheus 컨테이너에서 프록시 호출 | 이름이 해석되지 않습니다. |
| Alloy에서 프록시의 `GET /_ping` 호출 | `HTTP/1.1 200 OK`입니다. |
| Alloy의 healthcheck와 오류 로그 | `healthy`이고 오류 줄이 없습니다. |
| Loki의 label 목록 | `service`, `container`, `host`, `job`, `stream`, `compose_project`가 모두 그대로입니다. |
| `up{job="alloy"}` | 1입니다. |

**cAdvisor는 소켓을 그대로 mount합니다.** 프록시로 옮기지 않은 이유는 cAdvisor가 이미 root로
동작하면서 호스트의 `/`와 `/sys`와 `/var/lib/docker`를 읽기 때문입니다. Docker API만 좁혀도 실제
권한 수준이 달라지지 않습니다. 그래서 이번 변경의 결과는 "소켓을 든 컨테이너가 둘에서 하나로
줄었다"가 아니라 "로그 수집기가 소켓을 놓았다"입니다. cAdvisor의 권한을 더 줄이는 일은 남은
과제로 두었습니다.

### positions와 전환 시점의 중복과 유실

Promtail은 어디까지 읽었는지를 `promtail_positions` volume의 `/var/lib/promtail/positions.yaml`에
기록했습니다. Alloy는 같은 정보를 `--storage.path`가 가리키는 디렉터리 아래에 컴포넌트별로 나누어
저장합니다. 그 경로를 `alloy_data`라는 전용 volume으로 잡아 두었으므로 컨테이너를 다시 만들어도
읽은 위치가 남습니다.

두 수집기의 기록 형식이 다르기 때문에 전환 시점을 따로 다루어야 합니다. Alloy에는 Promtail의
positions 파일을 가져오는 `legacy_positions_file` 옵션이 있는데, `v1.19.2`에서 이 옵션을 받는 것은
`loki.source.file`뿐입니다. `loki.source.docker`에 같은 옵션을 적고 설정을 검사하면 아래와 같이
거부됩니다.

```
Error: /etc/alloy/config.alloy:6:3: unrecognized attribute name "legacy_positions_file"
```

그래서 두 경로의 대응이 다릅니다.

| 수집 경로 | 전환 시점의 동작 |
|---|---|
| 호스트 시스템 로그 | `legacy_positions_file`로 Promtail의 위치를 그대로 물려받아 이어서 읽습니다. |
| 컨테이너 로그 | 물려받을 수단이 없어서 각 컨테이너의 로그를 처음부터 다시 읽습니다. |

컨테이너 로그를 처음부터 다시 읽는다는 사실이 곧 중복 적재를 뜻하지는 않습니다. Docker가 기록한
원래 시각이 그대로 보존되므로, 다시 보낸 줄은 Loki가 보기에 stream label과 시각과 내용이 모두
같은 줄입니다. Loki는 그런 줄을 중복으로 보고 버립니다. 실제로 시험해서 확인한 내용이며 수치는
아래에 있습니다.

다만 두 가지를 주의해야 합니다.

첫째, `loki-config.yml`은 `reject_old_samples`를 켜 두었고 기준은 168시간입니다. 컨테이너가 7일보다
오래 돌고 있었다면 그 이전 구간의 로그는 Loki가 거절합니다. 거절된 줄은 Alloy의
`loki_write_dropped_entries_total{reason="ingester_error"}`로 세어지고 `LogShippingDropping` 경보가
울릴 수 있습니다. 그러나 그 로그는 Promtail이 이미 넣어 둔 것이므로 실제로 잃는 데이터는 없습니다.
전환 직후에 이 경보가 한 번 울렸다가 잦아든다면 정상입니다.

둘째, 다시 읽는 양이 한 번에 몰립니다. VM2의 Docker는 json-file 드라이버의 기본 설정을 쓰므로
컨테이너 로그 파일에 크기 상한이 없습니다. 전환하기 전에 아래 명령으로 크기를 확인하십시오. 합이
수 GB 수준이면 `loki-config.yml`의 `ingestion_rate_mb`(현재 10)에 걸려
`reason="rate_limited"`로 줄이 버려질 수 있습니다.

```bash
sudo du -ch /var/lib/docker/containers/*/*-json.log | tail -1
```

#### 재전송을 허용하는 근거와 배포 후 확인 기준

전환할 때 컨테이너 로그를 처음부터 다시 읽는 동작은 허용합니다. 근거는 세 가지입니다. 첫째, 다시
보낸 줄은 stream label과 시각과 내용이 모두 같으므로 Loki가 중복으로 보고 버립니다. 로컬 시험에서
Alloy가 576줄을 다시 보냈지만 Loki에 남은 줄 수는 그대로였습니다. 둘째, 7일을 넘긴 구간은 Loki가
거절하는데, 그 로그는 Promtail이 이미 넣어 둔 것이라 실제로 잃는 데이터가 없습니다. 셋째, 수집
속도 제한에 걸릴 가능성은 전환 전에 컨테이너 로그 파일의 크기를 확인해서 미리 판단할 수 있습니다.

전환 배포를 마친 뒤에는 아래 네 가지를 차례로 확인하십시오. 확인 시점은 배포가 끝나고 30분 뒤가
적당합니다. `increase`의 창이 10분이므로 그 정도 시간이 지나야 일시적인 증가와 지속적인 증가를
구분할 수 있습니다.

| 확인 항목 | 질의 또는 명령 | 정상으로 볼 값 |
|---|---|---|
| 수집기가 살아 있는가 | `up{job="alloy"}` | 1입니다. |
| 로그가 들어오고 있는가 | `sum(rate(loki_write_sent_entries_total{job="alloy"}[5m]))` | 0보다 큽니다. 컨테이너가 조용한 시간대라면 `{job="docker"}`로 Loki를 직접 조회해서 최근 줄이 있는지 봅니다. |
| 밀어넣기가 실패하고 있는가 | `sum by (status_code) (rate(loki_write_request_duration_seconds_count{job="alloy",status_code!~"2.."}[5m]))` | 0입니다. 정상 구간의 `status_code`는 204뿐입니다. |
| 버린 줄이 있는가 | `sum by (reason) (increase(loki_write_dropped_entries_total{job="alloy"}[10m]))` | 전환 직후를 제외하면 0입니다. |

`LogShippingDropping` 경보가 전환 직후에 울렸을 때 정상과 비정상을 가르는 기준은 `reason` label과
지속 시간입니다.

- `reason="ingester_error"`가 전환 직후에만 나타났다가 30분 안에 잦아들면 정상입니다. 7일을 넘긴
  로그를 Loki가 거절한 결과이며, 그 로그는 Promtail이 이미 넣어 두었습니다. `sudo docker logs
  vm2-loki --tail 100`에 `entry too far behind` 또는 `reject_old_samples`가 함께 보이면 이 경우가
  맞습니다.
- `reason="rate_limited"` 또는 `reason="stream_limited"`가 나타나면 수집 속도 제한에 걸린 것입니다.
  다시 읽는 양이 한꺼번에 몰려서 생긴 일이라면 몇 분 안에 잦아듭니다. 그러지 않고 계속 늘어난다면
  `loki/loki-config.yml`의 `ingestion_rate_mb`와 `ingestion_burst_size_mb`를 올려야 합니다. 이 경우의
  로그는 실제로 잃습니다.
- 전환한 지 한 시간이 지났는데도 값이 계속 늘어나거나, `reason`이 위의 세 가지가 아니라면
  비정상입니다. 전환과 무관한 문제이므로 경보의 `action` 항목대로 조치하십시오.

`LogShippingWriteFailing`은 아직 유실이 없는 앞 단계입니다. 전환 직후에 이 경보만 잠깐 울렸다가
해소되었다면, Loki가 다시 읽는 요청을 잠시 거절했다가 받아들인 것이므로 정상입니다.

### Promtail 잔여물 정리

배포 워크플로가 `vm2-promtail` 컨테이너를 멈추고, 모든 확인을 통과한 뒤에 컨테이너와 구 설정 파일을
함께 지웁니다. 그러나 `promtail_positions` volume은 자동으로 지우지 않습니다. Alloy가 그 안의
`positions.yaml`을 한 번 가져가야 하고, Alloy 스스로는 원본을 지우지 않으므로 가져갔는지를 사람이
확인한 뒤에 손으로 지우는 절차가 남기 때문입니다.

1. 배포한 뒤에 Alloy 로그에서 가져오기가 끝났는지 확인합니다. 아래 줄이 보이면 끝난 것입니다.

   ```bash
   sudo docker logs vm2-alloy 2>&1 | grep -i legacy
   # successfully converted legacy positions file to the new format
   #   path=/var/lib/alloy/data/loki.source.file.system/positions.yml
   #   legacy_path=/var/lib/promtail/positions.yaml
   ```

   Alloy는 이 파일을 읽어서 `--storage.path` 아래의 positions로 옮기기만 하고 원본은 지우지
   않습니다. 그래서 가져오기가 끝난 뒤에도 `promtail_positions` volume 안에는 `positions.yaml`이
   그대로 남아 있으며, 아래 4번에서 사람이 직접 지워야 합니다. 이 mount는 compose에서 `:ro`로
   걸어 두었습니다. 읽기 전용이어도 가져오기는 똑같이 성공하고 원본 파일도 그대로 남는다는 사실을
   `docker:27-dind` 안에서 Promtail 3.5.7부터 전환하는 절차로 다시 확인했습니다. Alloy 로그에
   `successfully converted legacy positions file to the new format`이 남았고, volume 안의
   `positions.yaml`은 내용까지 그대로였습니다. 두 번째 기동부터는
   `will not convert the legacy positions file as the new positions file already exists`가 대신
   보이며, 그 상태가 정상입니다. `grafana/alloy:v1.19.2`를 named volume만 써서 세 번 기동해 확인한
   내용이며, v1.19.2 소스의 `ConvertLegacyPositionsFile`에도 원본을 지우거나 고쳐 쓰는 경로가
   없습니다. 다만 파일이 있는데 읽지 못하면 Alloy는 로그를 처음부터 다시 읽는 상황을 피하려고
   기동 자체를 거부합니다.

2. 로그 수집이 정상인지 확인합니다. 아래 두 조회가 모두 결과를 돌려주어야 합니다.

   ```bash
   curl -sG 'http://127.0.0.1:3100/loki/api/v1/label/service/values' | jq '.data'
   curl -sG 'http://127.0.0.1:3100/loki/api/v1/query' --data-urlencode 'query={job="varlogs"}' | jq '.data.result | length'
   ```

3. 1번과 2번을 확인한 뒤에 compose에서 `promtail_positions` 관련 두 줄을 지웁니다. `alloy` 서비스의
   volume 목록에 있는 `promtail_positions:/var/lib/promtail` 한 줄과, 파일 아래쪽 `volumes:` 블록의
   `promtail_positions:` 한 줄입니다. 그다음 배포를 한 번 더 실행합니다.

4. 마지막으로 VM2에서 volume 자체를 지웁니다. 이 명령은 되돌릴 수 없으므로 3번까지 끝낸 뒤에
   실행하십시오.

   ```bash
   sudo docker volume ls | grep promtail
   sudo docker volume rm bnbong_promtail_positions
   ```

   `grafana/promtail` 이미지도 함께 지우려면 `sudo docker image rm grafana/promtail:3.5.7`을
   실행합니다. 되돌릴 일이 생기면 이미지를 다시 받으면 되므로 순서에 제약이 없습니다.

### 전환을 검증한 방법

운영에 적용하기 전에 로컬에서 임시 project 이름과 임시 포트로 이 compose를 띄워서 확인했습니다.
저장소 파일은 고치지 않고 override 파일을 따로 두었습니다.

label 계약은 같은 조건에서 Alloy와 Promtail 3.5.7을 나란히 띄우고 각각 다른 Loki에 보내서
비교했습니다. compose label이 있는 컨테이너와, compose label 없이 `docker run --name wegis_server`로
띄운 컨테이너와, 호스트 시스템 로그를 모두 포함했습니다. 결과는 label 이름과 값이 모두 같았습니다.

positions 전환은 세 구간으로 나누어 시험했습니다. Promtail이 도는 동안 각 경로에 100줄을 넣고,
Promtail을 멈춘 뒤 공백 구간에 50줄을 더 넣고, Alloy를 띄운 뒤에 다시 50줄을 넣었습니다. 세 구간
모두 Loki에서 정확히 기록한 만큼만 나왔고 중복된 줄은 없었습니다. 공백 구간의 50줄도 빠지지
않았습니다.

이어서 Alloy의 컨테이너 positions를 지우고 다시 띄워서, 컨테이너 로그를 처음부터 다시 읽는 상황을
일부러 만들었습니다. Alloy는 576줄을 다시 읽어 Loki로 보냈지만 Loki에 남은 줄 수는 그대로였습니다.
위에서 적은 중복 제거가 실제로 동작한다는 뜻입니다.

대시보드의 LogQL 패널 질의도 이 임시 스택의 Loki에 그대로 던져서 결과가 나오는 것을 확인했습니다.

배포 워크플로의 원격 스크립트 자체도 `docker:27-dind` 안에서 실제로 실행해 보았습니다. Promtail
3.5.7이 로그를 보내고 있는 상태를 먼저 만든 다음, 워크플로에서 그대로 뽑아낸 적용 단계와 정리
단계와 복구 단계를 차례로 돌려서 아래 세 가지 경로를 확인했습니다.

| 경로 | 만드는 방법 | 확인한 결과 |
|---|---|---|
| 성공 | 그대로 실행합니다. | 적용 단계가 0으로 끝나고 로그 종단 확인이 다섯 번째 시도에서 통과했습니다. 정리 단계가 Promtail 컨테이너와 구 설정 파일과 전환 표식을 모두 치웠습니다. |
| 실패 뒤 복구 | docker-socket-proxy의 `CONTAINERS`를 0으로 두어 Alloy가 컨테이너 목록을 가져오지 못하게 만듭니다. | 적용 단계가 로그 종단 확인에서 실패하고, 복구 단계가 Promtail을 되살린 다음 Alloy를 멈췄습니다. 전환 표식도 사라졌습니다. |
| 복구 중 Promtail 기동 불가 | 성공한 배포 뒤에 구 설정 파일과 사본을 모두 잘못된 내용으로 바꿉니다. | 복구 단계가 1로 끝나면서 Alloy를 건드리지 않았습니다. 그 뒤에도 Alloy가 컨테이너 로그와 `/var/log` 파일을 Loki로 계속 보내는 것을 질의로 확인했습니다. 전환 표식이 남아서 다음 배포가 미완료 전환으로 감지했습니다. |

같은 환경에서 `promtail_positions` mount에 `:ro`를 붙여도 `legacy_positions_file` 변환이 정상으로
끝나는 것과, 전환이 끝난 호스트에서 배포를 다시 실행해도 결과가 같은 것도 함께 확인했습니다.

확인하지 못한 것도 적어 둡니다. 이 시험은 개발 기기의 Docker에서 수행했으므로 운영 VM2의 실제
로그 양과 컨테이너 수명에서 어떻게 동작하는지는 확인하지 않았습니다. 특히 위에서 적은 7일 초과
로그의 거절과 수집 속도 제한은 운영 규모에서만 드러납니다.

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

로그가 Loki에 들어오지 않을 때에는 수집기의 지표를 먼저 봅니다. Alloy는 포트를 게시하지 않으므로
같은 네트워크의 Prometheus 컨테이너를 거쳐서 읽습니다.

```bash
# Loki로 보낸 줄 수와 버린 줄 수
sudo docker exec vm2-prometheus wget -q -O- http://alloy:12345/metrics \
  | grep -E '^loki_write_(sent|dropped)_entries_total|^loki_source_docker_target_entries_total'

# 응답 코드별 요청 수. 정상이면 204만 늘어납니다
sudo docker exec vm2-prometheus wget -q -O- http://alloy:12345/metrics \
  | grep '^loki_write_request_duration_seconds_count'

sudo docker logs vm2-alloy --tail 100
```

Alloy가 컨테이너 목록을 가져오지 못할 때에는 프록시를 함께 확인합니다. 아래 요청이 컨테이너 목록
JSON을 돌려주어야 합니다.

```bash
sudo docker exec vm2-prometheus wget -q -O- 'http://docker-socket-proxy:2375/containers/json'
sudo docker logs vm2-docker-socket-proxy --tail 50
```

컨테이너가 실행 중이라는 사실만으로 그 구성 요소가 정상이라고 판단하지 않습니다. 예를 들어
2026-09-18 실사에서 `vm2-promtail`은 created 상태에 머물러 있었고, 그래서 Loki에 들어간 컨테이너
로그가 없었습니다. Grafana의 로그 조회 화면이 비어 있던 이유가 여기에 있습니다. 같은 일이 다시
일어나지 않도록 Prometheus에 `alloy` job을 두고 배포 워크플로의 필수 job 목록에도 넣었습니다.

---

## 남은 과제

이 문서의 각 항목에 흩어져 있는 미완료 사항을 한곳에 모았습니다. 자세한 사정은 괄호 안의 항목에
적어 두었습니다.

| 과제 | 상태 |
|---|---|
| Discord 통지 활성화 | webhook URL을 발급받지 않아 `alerting` profile을 켜지 않았습니다. 설정과 compose 서비스는 준비를 마쳤습니다. ("통지 경로") |
| VM1과 VM3의 원격 exporter 설치 | `vm1-nginx`와 `vm3-postgres` job은 정의만 두었고 대상 파일을 만들지 않았습니다. node-exporter는 두 호스트에서 `docker run`으로 띄운 컨테이너로 돌고 있으며, 2026-09-20 실사에서 두 target 모두 정상 수집되는 것을 확인했습니다. compose가 관리하지 않으므로 systemd 유닛으로 전환할지는 아직 정하지 않았습니다. ("원격 exporter 수집 활성화") |
| VM2 밖의 독립 probe | 공개 도메인 probe가 VM2 안에서 돌기 때문에 VM2 자체의 중단은 감지되지 않습니다. ("외부 probe의 한계") |
| Cloudflare 경유 probe의 경보 연결 | `blackbox-http-external` job은 대시보드 표시용으로만 남겨 두었습니다. VM2에서 실제 결과를 얼마간 모아 본 뒤에 경보로 연결할지 다시 판단합니다. ("오리진 probe와 Cloudflare 경유 probe") |
| 오리진 probe의 운영 확인 | 자체 CA 환경으로만 재현했습니다. VM1의 실제 인증서가 RSA 루트로 검증되는지와 vhost 다섯 곳이 오리진에서 redirect 없이 200을 돌려주는지는 VM2에서 한 번 확인해야 합니다. ("오리진 인증서 검증") |
| 컨테이너 메모리 한도 지정 | `mem_limit`이 없어서 `ContainerMemoryNearLimit`이 한 번도 발화하지 않습니다. VM2의 가용 메모리가 약 10GB이고 현재 컨테이너 사용량 합계가 약 1.2GB이므로 급한 과제는 아니며, 이번 변경에서도 넣지 않았습니다. ("알림 규칙") |
| blackbox exporter의 실행 사용자 낮추기 | HTTP probe만 쓰므로 root로 돌 이유가 없지만 이번 범위에서 바꾸지 않았습니다. ("컨테이너 실행 사용자와 파일 권한") |
| cAdvisor의 Docker API 권한 좁히기 | 로그 수집기는 프록시를 거치게 했으나 cAdvisor는 소켓을 그대로 mount합니다. ("Docker API 접근 범위") |
| 즉시 종료하는 컨테이너의 재시작 감지 | cAdvisor는 housekeeping 주기 안에 표본을 잡지 못한 컨테이너의 시계열을 만들지 않으므로, `ContainerRestartLoop`이 그 구간을 보지 못합니다. Docker의 재시작 횟수를 노출하는 exporter가 따로 필요합니다. ("알림 규칙") |
| `promtail_positions` volume 정리 | Alloy가 위치를 가져간 것을 확인한 뒤에 사람이 지웁니다. ("Promtail 잔여물 정리") |
| Overlock의 지표 수집 | `/metrics` 노출 여부를 확인하지 못했고 네트워크도 `api-network`가 아닙니다. ("Overlock과 Wegis의 수집 상태") |
| 운영 환경에서의 경보 도달 확인 | 규칙은 `promtool`로 검증했으나 실제 지표로 경보가 발생하고 통지가 도착하는 것은 확인하지 않았습니다. ("아직 확인하지 않은 부분") |

---

## 관련 문서

| 문서 | 다루는 내용 |
|---|---|
| [remote-exporters/README.md](remote-exporters/README.md) | VM1과 VM3에 호스트 exporter를 설치하는 절차와 스크립트를 설명합니다. |
| [prometheus/targets-examples/README.md](prometheus/targets-examples/README.md) | 원격 exporter의 file_sd 대상 파일과 두 디렉터리의 배포 방식 차이를 설명합니다. |
| [../README.md](../README.md) | 저장소 전체 구조와 Terraform 사용 절차를 설명합니다. |
| [../vm2-deployment/README.md](../vm2-deployment/README.md) | core compose와 애플리케이션 배포 절차를 설명합니다. |
| [../backup/README.md](../backup/README.md) | 백업 체계와 백업 지표의 출력 형식을 설명합니다. |
| [../docs/github-actions-setup.md](../docs/github-actions-setup.md) | 배포 워크플로의 전체 구조와 secret 구성, 최초 준비 절차를 설명합니다. |
