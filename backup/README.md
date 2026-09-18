# BNGdrasil 반복 백업 체계

이 디렉터리는 운영 개선 계획의 I02 항목인 반복 백업 체계를 구현한 결과물입니다. 2026년 9월 18일에 수행한 단발 백업은 복원 가능성을 한 번 확인했을 뿐이고, 주기 실행과 실패 알림과 독립 보관은 아직 없었습니다. 여기에 있는 스크립트와 systemd 유닛은 그 빈 자리를 채우기 위한 것입니다.

기준이 되는 운영 사실은 다음과 같습니다. VM3는 systemd가 관리하는 호스트 PostgreSQL 14를 사용하며, `bngdrasil`과 `phishing_data`와 `postgres` 세 데이터베이스를 담고 있습니다. 로컬 peer 인증을 사용하기 때문에 `sudo -u postgres pg_dump`를 비밀번호 없이 실행할 수 있습니다. Redis는 VM3의 `vm3-redis` 컨테이너와 VM2의 `vm2-redis` 컨테이너가 각각 따로 동작합니다. Overlock과 Grafana는 VM2에서 SQLite 파일을 사용합니다. MongoDB는 퇴역 대상이므로 백업 대상에 넣지 않았습니다.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `run.sh` | PostgreSQL, Redis, SQLite, 보존 정책, 독립 보관 전송을 차례로 실행하고 단계별 실패를 집계합니다. systemd 유닛이 이 파일을 실행합니다. `RUN_POSTGRESQL=false`를 지정하면 PostgreSQL 단계를 건너뛰고, `SHIP_ENABLED=false`를 지정하면 전송 단계를 건너뜁니다. |
| `pg-backup.sh` | 호스트 PostgreSQL의 각 데이터베이스를 custom format으로 덤프하고 검증합니다. |
| `redis-backup.sh` | Redis 스냅샷을 받아 `redis-check-rdb`로 검증합니다. 컨테이너 모드와 호스트 모드를 모두 지원합니다. |
| `sqlite-backup.sh` | SQLite 온라인 백업 API로 복사한 뒤 `PRAGMA integrity_check`로 확인합니다. |
| `retention.sh` | 독립 보관 위치로 보낸 성공본만 일 7세대, 주 4세대, 월 3세대로 남기고 나머지를 정리합니다. 아직 보내지 못한 성공본은 삭제하지 않습니다. |
| `ship.sh` | 성공한 백업을 암호화하여 VM3 밖의 보관 위치로 전송하고, 원격에서 체크섬을 다시 확인한 뒤에 전송 완료 표시를 남깁니다. |
| `notify.sh` | 성공과 실패를 webhook 또는 syslog로 알립니다. |
| `verify-restore.sh` | 일회용 PostgreSQL에 최신 덤프를 복원하고 테이블 수와 행 수를 기록합니다. |
| `install.sh` | VM3에 설치하고 systemd timer를 활성화합니다. 여러 번 실행해도 결과가 같습니다. |
| `env.example` | `/etc/bngdrasil-backup/env`의 템플릿입니다. 변수 이름과 설명만 담고 있습니다. |
| `lib/common.sh` | 잠금, 로그, JSON 출력, metric 출력 같은 공통 함수를 담고 있습니다. |
| `systemd/` | service 유닛과 timer 유닛을 담고 있습니다. |

설치한 뒤의 경로는 다음과 같이 고정됩니다. 스크립트는 `/opt/bngdrasil-backup`에 두고, 환경 파일은 `/etc/bngdrasil-backup/env`에 두며, 백업 데이터는 `/var/backups/bngdrasil` 아래에 쌓입니다.

## 복구 목표와 실행 주기

이 체계가 목표로 삼는 복구 시점 목표는 다음 표와 같습니다. 두 목표를 구분하는 이유는 로컬 백업과 독립 보관 사본이 서로 다른 고장을 막아 주기 때문입니다. 데이터베이스 내용을 잘못 지운 사고는 로컬 백업으로 복구하지만, VM3 자체를 잃는 사고는 독립 보관 사본이 있어야 복구할 수 있습니다.

| 구분 | 목표 | 실행 주체 | 실패했을 때 울리는 경보 |
|---|---|---|---|
| 로컬 백업 RPO | 6시간 | `bngdrasil-backup.timer`가 00시, 06시, 12시, 18시 10분에 `run.sh`를 실행합니다. | `BackupStale`(8시간) |
| 오프사이트 RPO | 6시간 | `run.sh`가 백업을 마친 직후 마지막 단계에서 `ship.sh`를 실행합니다. `SHIP_ENABLED=true`일 때에만 수행합니다. | `BackupShipStale`(14시간) |
| 전송 재시도 | 2시간 | `bngdrasil-backup-ship.timer`가 홀수 시 40분에 `ship.sh`를 실행하여 아직 보내지 못한 백업만 다시 보냅니다. | `BackupUnshippedPileup`(미전송 4개 초과) |

오프사이트 전송을 백업 직후에 수행하므로 두 목표가 모두 6시간입니다. 전송에 실패하면 그 사실이 `run.sh`의 전체 결과에 반영되어 실행 자체가 실패로 끝납니다. 별도의 전송 timer는 정상 경로가 아니라 재시도 경로이며, 경보 기준 14시간은 6시간 주기에 재시도가 몇 번 실패할 여유를 더한 값입니다.

전송 설정을 갖추지 않은 호스트에서는 `/etc/bngdrasil-backup/env`에 `SHIP_ENABLED=false`를 반드시 지정해야 합니다. 이 값을 지정하지 않으면 매 실행이 전송 단계에서 실패하고, 보존 정책도 전송 완료 표시를 기다리느라 오래된 백업을 정리하지 못합니다.

## 잠금

`run.sh`와 `retention.sh`와 `ship.sh`는 `BK_LOCK_FILE`이 가리키는 같은 잠금 파일을 사용합니다. 기본 경로는 `/var/backups/bngdrasil/state/backup.lock`입니다. 세 스크립트가 같은 백업 디렉터리를 동시에 건드리면 전송 중인 원본을 보존 정책이 지우는 경합이 생기기 때문입니다.

`run.sh`가 잠금을 잡은 상태에서 두 스크립트를 순차로 실행하므로, 두 스크립트는 `BK_LOCK_HELD` 환경 변수를 물려받아 잠금을 다시 얻으려고 하지 않습니다. 이렇게 하여 중첩 실행에서 교착이 생기지 않도록 했습니다. 잠금을 이미 다른 작업이 쥐고 있으면 `BK_LOCK_WAIT_SEC`(기본값 300초)만큼 기다린 뒤 실패합니다. 구성 요소별 백업 스크립트는 예전처럼 `LOCK_DIR` 아래의 개별 잠금을 계속 사용합니다.

## 백업이 동작하는 방식

### PostgreSQL

`pg-backup.sh`는 운영 안내서 4장에서 이미 검증한 명령 패턴을 그대로 따릅니다. 각 데이터베이스마다 `pg_dump --format=custom` 결과를 `.partial` 파일에 쓰고, 파일이 비어 있지 않은지 확인한 다음, `pg_restore --list`로 archive 목록을 읽어 봅니다. 이 세 단계를 모두 통과한 파일만 최종 이름으로 바꾸고 SHA-256 값을 함께 남깁니다. 역할 정의는 `pg_dumpall --globals-only --no-role-passwords`로 따로 보존하므로, 복원할 때에는 비밀번호를 새로 설정해야 합니다.

실행을 시작할 때에는 `flock`으로 잠금을 잡아 같은 작업이 겹쳐 돌지 않게 합니다. `flock`이 없는 환경에서는 디렉터리 잠금으로 대신합니다. 이어서 대상 파티션의 여유 공간을 확인하는데, 마지막 성공 백업 크기의 두 배보다 여유가 적으면 덤프를 시작하지 않고 실패로 끝냅니다. 성공 이력이 없는 첫 실행에서는 `PG_MIN_FREE_BYTES` 값을 기준으로 삼습니다.

실패하면 exit code가 0이 아닌 값이 되고, 그때까지 만든 `.partial` 파일만 지웁니다. 이미 성공한 백업 디렉터리는 어떤 경우에도 이 스크립트가 지우지 않습니다. 실패한 실행 디렉터리에는 `FAILED` 표시 파일을 남기고, 성공한 실행 디렉터리에는 `SUCCESS` 표시 파일을 남깁니다.

### Redis

`redis-backup.sh`는 `redis-cli --rdb`로 복제 스냅샷을 받습니다. 컨테이너 모드에서는 `docker exec`로 컨테이너 안에서 스냅샷을 만든 뒤 `docker cp`로 가져오고, 호스트 모드에서는 호스트의 `redis-cli`로 직접 받습니다. `--rdb`를 쓸 수 없는 상황에서는 `--via-bgsave` 옵션으로 `BGSAVE`를 실행하고 `LASTSAVE` 값이 바뀌기를 기다린 다음 RDB 파일을 복사합니다. 어느 경로를 쓰든 `redis-check-rdb`로 구조를 검증한 뒤에야 최종 파일로 확정합니다.

비밀번호가 설정된 Redis라면 `REDIS_PASSWORD_FILE`에 경로를 지정합니다. 값은 `redis-cli`가 읽는 `REDISCLI_AUTH` 환경 변수로만 전달하며 명령 인자로는 넘기지 않습니다.

### SQLite

`sqlite-backup.sh`는 파일을 그대로 복사하지 않습니다. WAL과 어긋난 사본이 생기지 않도록 python3의 `sqlite3.Connection.backup()`을 사용하고, python3가 없으면 `sqlite3` CLI의 `.backup` 명령을 사용합니다. 복사한 뒤에는 `PRAGMA integrity_check` 결과가 `ok`인지 확인하며, `ok`가 아니면 실패로 처리합니다.

Overlock과 Grafana의 SQLite 파일은 VM2에 있습니다. 따라서 VM3에서 이 스크립트를 실행해도 대상 파일에 닿지 않습니다. VM2에도 같은 방식으로 설치하고 `SQLITE_TARGETS`를 지정하는 방법을 권장합니다.

## 상태 파일과 metric

모든 스크립트는 실행 결과를 `/var/backups/bngdrasil/state/` 아래에 JSON으로 남깁니다. `pg-backup.sh`의 결과는 `postgresql-last-run.json`에 기록되고, 성공했을 때에만 `postgresql-last-success.json`이 함께 갱신됩니다. `run.sh`가 만드는 `last-run.json`과 `last-success.json`은 전체 실행의 집계 결과를 담습니다.

JSON에는 `status`, `started_at`, `finished_at`, `databases`, `sizes`, `checksums`, `error` 항목이 들어갑니다. 실패했을 때에는 `error`에 실패 원인이 문자열로 남고, `last-success.json`은 이전 성공 기록을 그대로 유지합니다.

Prometheus의 node_exporter textfile collector가 읽을 수 있도록 metric 파일도 함께 출력합니다. 기본 경로는 `/var/lib/node_exporter/textfile_collector`이며 `METRICS_DIR`로 바꿀 수 있습니다. 출력하는 metric은 다음과 같습니다.

```
bngdrasil_backup_last_success_timestamp_seconds{component="postgresql"} 1789665747
bngdrasil_backup_last_run_status{component="postgresql"} 0
bngdrasil_backup_last_run_timestamp_seconds{component="postgresql"} 1789665747
```

`retention.sh`와 `ship.sh`는 아직 독립 보관 위치로 보내지 못한 성공본의 개수도 함께 내보냅니다.

```
bngdrasil_backup_unshipped_total{component="postgresql"} 0
```

`component` 라벨에는 `postgresql`, `redis-vm3`, `sqlite-grafana`, `ship`, `all` 같은 값이 들어갑니다. 경보는 `bngdrasil_backup_last_run_status`가 1인 상태와, `bngdrasil_backup_last_success_timestamp_seconds`가 일정 시간 이상 갱신되지 않는 상태를 함께 보는 방식을 권장합니다. 백업이 아예 실행되지 않는 고장은 뒤쪽 조건에서만 드러나기 때문입니다. `ship` component는 전송 주기가 로컬 백업과 다르므로 경보 기준을 따로 두어야 합니다.

## 경보

`monitoring/prometheus/rules/basic.yml`의 `basic-backup` 그룹에 네 가지 규칙을 두었습니다. 각 규칙에는 무엇을 먼저 확인해야 하는지를 적은 `action` annotation이 붙어 있습니다.

| 규칙 | 조건 | 심각도 | 첫 대응 |
|---|---|---|---|
| `BackupStale` | `component`가 `ship`이 아닌 백업의 마지막 성공이 8시간을 넘겼습니다. | critical | `journalctl -u bngdrasil-backup.service`로 실패 단계를 확인하고 `state/last-run.json`의 `failed_steps`를 읽습니다. |
| `BackupShipStale` | `component="ship"`의 마지막 성공이 14시간을 넘겼습니다. | critical | VM2를 경유하는 SSH 연결과 키 권한, VM4 보관 디렉터리의 여유 공간을 점검한 뒤 `ship.sh`를 수동으로 실행합니다. |
| `BackupUnshippedPileup` | 전송하지 못한 성공본이 한 구성 요소에서 4개를 넘었습니다. | warning | 전송 경로를 복구합니다. 전송이 다시 성공하면 다음 정리 실행에서 세대 정책대로 줄어듭니다. |
| `BackupDiskLow` | 백업이 쌓이는 파티션의 여유 공간이 10GiB 미만입니다. | warning | `du -sh /var/backups/bngdrasil/*`로 원인을 찾습니다. 미전송 백업이 원인이면 전송을 먼저 복구합니다. |

`BackupDiskLow`는 `/var/backups`와 `/var`와 `/` 가운데 여유가 가장 적은 파일시스템을 봅니다. `/var/backups`를 별도 파티션으로 분리하면 그 mountpoint가 자동으로 선택됩니다.

## 보존 정책

`retention.sh`는 `SUCCESS` 표시와 `SHIPPED` 표시를 모두 가진 디렉터리만 세대로 계산합니다. 기본값은 일 7세대, 주 4세대, 월 3세대이며 환경 파일에서 조정할 수 있습니다. 같은 날에 여러 번 실행했다면 그날의 가장 최근 성공본만 일 세대로 계산합니다.

독립 보관 사본이 아직 없는 백업을 보존 정책이 지우는 상황을 막기 위해, 미전송 성공본은 세대 계산에서 아예 제외하고 그대로 보존합니다. 전송이 진행 중인 디렉터리에는 `ship.sh`가 `SHIPPING` 표시를 남기며, 이 표시가 있는 디렉터리도 삭제 대상에서 빠집니다. 전송 실패가 이어지면 미전송 백업이 계속 쌓이므로, 그 개수가 `RETENTION_MAX_UNSHIPPED`(기본값 8, 6시간 주기 기준으로 48시간분)를 넘으면 `retention.sh`는 백업을 지우는 대신 exit code 1로 끝나고 `notify.sh`로 경고를 보냅니다. 디스크가 차 가는 상황을 조용히 넘기지 않고 실패로 드러내려는 의도입니다.

전송을 사용하지 않는 호스트에서는 `SHIP_ENABLED=false`를 지정하십시오. 그러면 `RETENTION_REQUIRE_SHIPPED`가 같은 값을 물려받아 전송 완료 표시를 요구하지 않고 예전과 같은 세대 정책으로만 정리합니다.

나머지 안전 장치는 그대로 유지했습니다. 첫째, 성공한 백업이 하나뿐이면 어떤 경우에도 삭제하지 않습니다. 둘째, 해당 구성 요소의 마지막 실행이 성공 상태가 아니면 그 구성 요소의 정리를 통째로 건너뜁니다. 셋째, 실패한 실행 디렉터리는 성공본이 남아 있고 `RETENTION_FAILED_DAYS`를 넘겼을 때에만 정리합니다. `--dry-run` 옵션을 주면 삭제 대상만 출력하고 실제로 지우지 않으며, 상태 파일과 metric도 건드리지 않습니다.

## 독립 보관

`ship.sh`는 성공한 백업 디렉터리를 tar로 묶고 암호화한 다음 rsync로 전송합니다. 암호화하지 않고 보내는 경로는 막아 두었으므로 `SHIP_ENCRYPTION`을 `age` 또는 `gpg`로 지정해야 합니다. 키는 `/etc/bngdrasil-backup/` 아래 권한 600 파일에서만 읽으며, 권한이 그보다 넓으면 전송을 시작하지 않고 실패합니다. 스크립트 안에는 키 값을 두지 않았습니다.

`run.sh`가 백업을 마친 직후 마지막 단계에서 `ship.sh`를 실행하므로, 정상 경로에서는 백업과 전송의 간격이 한 번의 실행 안으로 들어옵니다. 앞 단계 가운데 일부가 실패했더라도 성공한 백업은 보내야 하므로 전송 단계는 실패 여부와 상관없이 실행합니다. 전송이 실패하면 `run.sh`의 전체 결과가 실패가 되고, 2시간 주기의 `bngdrasil-backup-ship.timer`가 아직 보내지 못한 백업만 다시 보냅니다.

전송을 마치면 원격에서 `sha256sum -c`로 체크섬을 다시 계산하여 대조하고, 이 확인을 통과한 경우에만 `SHIPPED` 표시를 남깁니다. 보존 정책이 이 표시를 삭제 허용의 근거로 삼기 때문에, 검증하지 않은 전송을 완료로 기록하면 오프사이트 사본이 없는 백업이 지워질 수 있습니다. 검증에 실패하면 원격에 도착한 불완전한 사본을 지우고 실패로 끝납니다. `SHIP_TARGET`으로 rsync 대상을 직접 지정한 경우에는 검증에 사용할 접속 정보를 `SHIP_VERIFY_SSH_HOST`와 `SHIP_VERIFY_REMOTE_DIR`에 따로 적어야 합니다. `SHIP_VERIFY=0`으로 검증을 끌 수는 있지만, 그때에는 경고를 남기면서 검증 없이 완료로 기록한다는 점을 알고 있어야 합니다.

기본 대상은 VM4입니다. VM4는 오사카 리전에 있고 현재 확인된 연결 수단은 SSH뿐이므로 VM2를 경유하는 설정이 필요합니다. 이 설정은 root 홈의 `~/.ssh/config`가 아니라 `/etc/bngdrasil-backup/ssh/config`에 둡니다. service 유닛이 `ProtectHome=yes`로 실행되어 root 홈에 닿지 않기 때문이며, `ship.sh`가 `ssh -F`로 설정 파일을, `ssh -i`로 개인 키를 명시하므로 홈 디렉터리에 의존하지 않습니다. `install.sh`가 `/etc/bngdrasil-backup/ssh/` 디렉터리를 권한 700으로 만들고 주석 처리한 예시가 담긴 `config` 템플릿을 권한 600으로 만들어 둡니다. 개인 키는 `id_ed25519`라는 이름으로 같은 디렉터리에 두고 권한을 600으로 맞춥니다. `known_hosts`도 같은 디렉터리를 사용합니다. 접속할 호스트는 `SHIP_SSH_HOST`로 지정하며, 그 값은 설정 파일에 정의한 `Host` 별칭과 같아야 합니다. 원격 검증까지 통과한 백업 디렉터리에는 `SHIPPED` 표시 파일을 남기므로 다음 실행에서 같은 백업을 다시 보내지 않습니다. 전송에 실패하면 exit code가 0이 아닌 값이 되지만 로컬의 성공 백업은 그대로 남습니다. 전송 실패 때문에 유일한 정상본을 잃는 일은 없습니다.

VM4를 쓰지 않고 OCI Object Storage를 보관 위치로 삼는 방법도 있습니다. 그 경우에는 전용 버킷과 수명주기 규칙을 먼저 만들고, 쓰기 전용 권한만 가진 계정을 별도로 발급한 다음, `ship.sh`의 rsync 호출 부분을 `oci os object put`으로 바꾸면 됩니다. 암호화는 전송 전에 그대로 수행하며 버킷 자체의 암호화에 의존하지 않습니다. 이 방법은 아직 구성하지 않았고 월 비용과 회수 절차를 확인해야 합니다.

## 알림

`notify.sh`는 `/etc/bngdrasil-backup/env`에서 `NOTIFY_WEBHOOK_URL`을 읽어 Discord 또는 Slack의 incoming webhook으로 메시지를 보냅니다. URL이 없거나 전송에 실패하면 `logger`를 통해 journal에 기록하므로 기록 자체는 반드시 남습니다. `NOTIFY_ON_SUCCESS`를 1로 두면 성공했을 때에도 알립니다. 기본값은 0이므로 실패했을 때에만 알립니다.

systemd 쪽에서는 각 service 유닛에 `OnFailure=bngdrasil-backup-notify@%n.service`를 지정해 두었습니다. 스크립트가 알림을 보내기 전에 죽는 상황에서도 systemd가 실패 사실을 알려 줍니다.

## 설치

설치는 VM3에서 root 권한으로 수행합니다. 이번 작업에서는 실제로 실행하지 않았으므로 아래 절차를 직접 밟아야 합니다.

```sh
# 1) 저장소의 backup 디렉터리를 VM3로 옮깁니다.
scp -r baedalus/backup bngdrasil-vm3:/tmp/bngdrasil-backup-src

# 2) 설치합니다. 여러 번 실행해도 결과가 같습니다.
sudo /tmp/bngdrasil-backup-src/install.sh

# 3) 환경 파일의 값을 채웁니다. 권한은 600을 유지합니다.
sudo vi /etc/bngdrasil-backup/env

# 4) 최초 백업을 수동으로 실행합니다.
sudo /opt/bngdrasil-backup/run.sh

# 5) 결과를 확인합니다.
sudo cat /var/backups/bngdrasil/state/last-run.json
sudo cat /var/backups/bngdrasil/state/postgresql-last-run.json

# 6) 격리 복원이 성공하는지 확인합니다.
sudo /opt/bngdrasil-backup/verify-restore.sh

# 7) timer의 다음 실행 시각을 확인합니다.
systemctl list-timers 'bngdrasil-*'
```

VM2에도 같은 방식으로 설치합니다. VM2에는 호스트 PostgreSQL이 없으므로 `/etc/bngdrasil-backup/env`에 `RUN_POSTGRESQL=false`를 반드시 지정해야 합니다. 이 값을 지정하지 않으면 `run.sh`가 PostgreSQL 단계를 실행하다가 실패하고 전체 결과가 항상 실패로 남습니다. VM2에서 채울 값은 다음과 같습니다.

```sh
RUN_POSTGRESQL=false
REDIS_TARGETS="vm2:container:vm2-redis"
SQLITE_TARGETS="overlock:/var/lib/overlock/overlock.sqlite grafana:/var/lib/docker/volumes/<볼륨>/_data/grafana.db"
```

`install.sh --run-now`를 쓰면 4번부터 6번까지를 설치 직후에 이어서 수행합니다. 이미 있는 `/etc/bngdrasil-backup/env`는 덮어쓰지 않으므로, 값을 채운 뒤에 다시 설치해도 설정을 잃지 않습니다.

## GitHub Actions로 설치하는 방법

`.github/workflows/deploy-backup.yml`이 위 1번과 2번을 대신 수행합니다. GitHub 화면의 Actions 탭에서 `Deploy Backup Scripts`를 열고 `Run workflow`를 누른 다음, `target`으로 `vm3`이나 `vm2`를 고릅니다. `run_now`를 켜면 설치 직후에 `sudo /opt/bngdrasil-backup/run.sh`를 한 번 실행합니다. `production` environment를 사용하므로 승인자가 승인해야 배포가 진행됩니다.

워크플로는 `backup/` 디렉터리를 대상 VM의 `/tmp/bngdrasil-backup-src`로 전송한 뒤 `install.sh`를 실행합니다. 환경 파일인 `/etc/bngdrasil-backup/env`는 덮어쓰지 않으므로, 이미 값을 채워 두었다면 그대로 유지됩니다. 따라서 위 3번은 최초 한 번만 손으로 수행하면 됩니다.

VM3는 춘천 private subnet에 있어서 인터넷에서 직접 닿지 않습니다. 워크플로는 같은 VCN의 VM2를 `ssh -J`의 경유지로 삼아 VM3에 접속합니다. 그러려면 배포용 공개 키가 VM2와 VM3의 `ubuntu` 계정에 모두 등록되어 있어야 하고, `VM2_SSH_KNOWN_HOSTS` secret에 경유지인 VM2의 host key와 목적지인 VM3의 host key가 모두 들어 있어야 합니다. 키와 secret을 준비하는 절차는 [GitHub Actions 배포 설정](../docs/github-actions-setup.md)에 있습니다.

### timer 활성화를 워크플로에 맡기지 않는 이유

워크플로는 `install.sh --no-enable`로 유닛 파일만 설치하고 timer를 활성화하지 않습니다. 설정이 잘못된 상태로 timer가 돌기 시작하면 6시간마다 실패하면서 알림만 쌓이고, 백업이 실제로는 하나도 남지 않는 상황이 이어집니다. 그래서 사람이 최초 실행의 결과를 직접 확인한 다음에 활성화하도록 남겨 두었습니다.

위 4번부터 6번까지가 성공하는 것을 확인했다면 아래와 같이 활성화합니다.

```sh
sudo systemctl enable --now bngdrasil-backup.timer
sudo systemctl enable --now bngdrasil-backup-ship.timer
sudo systemctl enable --now bngdrasil-backup-verify.timer
systemctl list-timers 'bngdrasil-*'
```

## timer 구성

timer는 세 가지를 설치합니다. `bngdrasil-backup.timer`는 6시간 간격으로 백업을 실행하고, `Persistent=true`를 지정했으므로 VM이 꺼져 있어 놓친 실행은 부팅 뒤에 따라잡습니다. `RandomizedDelaySec`으로 실행 시각을 흩어 놓아 다른 작업과 겹칠 가능성을 줄였습니다. `bngdrasil-backup-ship.timer`는 홀수 시 40분마다 전송을 재시도하고, `bngdrasil-backup-verify.timer`는 주 1회 격리 복원 훈련을 수행합니다.

전송 timer의 시각을 홀수 시 40분으로 잡은 이유는 백업 timer가 도는 짝수 시 10분과 겹치지 않게 하려는 것입니다. 두 유닛이 같은 잠금을 쓰기 때문에, 겹치면 재시도 쪽이 잠금을 기다리다가 실패로 끝납니다.

## 최초 실행 뒤에 확인할 것

최초 실행 뒤에는 다음을 순서대로 확인합니다. 첫째, `state/last-run.json`의 `status`가 `success`인지 봅니다. 둘째, `/var/backups/bngdrasil/postgresql/<실행 시각>/`에 데이터베이스 세 개의 `.dump` 파일과 `.sha256` 파일과 `globals-no-role-passwords.sql`이 모두 있는지 봅니다. 셋째, `verify-restore.sh`가 만든 JSON에서 각 데이터베이스의 테이블 수가 실제 운영과 맞는지 봅니다. 백업 시점 기준으로 `bngdrasil`은 사용자 테이블 3개, `phishing_data`는 4개, `postgres`는 0개였습니다. 넷째, metric 파일이 `METRICS_DIR`에 생겼는지, Prometheus가 그 값을 실제로 수집하는지 봅니다. 다섯째, 알림을 일부러 실패시켜 보고 메시지가 도착하는지 봅니다.

## 복원 훈련

`verify-restore.sh`는 운영 데이터베이스에 전혀 접속하지 않습니다. 최신 성공 백업을 골라 일회용 PostgreSQL에 `pg_restore --exit-on-error --no-owner --no-privileges`로 복원하고, 테이블 목록과 각 테이블의 행 수를 JSON으로 남긴 뒤 임시 환경을 지웁니다.

```sh
# 최신 백업을 postgres:14 컨테이너에 복원합니다.
sudo /opt/bngdrasil-backup/verify-restore.sh

# PostgreSQL 17로도 복원되는지 확인합니다. I04 전환의 사전 시험에 해당합니다.
sudo /opt/bngdrasil-backup/verify-restore.sh --pg-version 17

# Docker를 쓰지 않고 호스트의 initdb로 임시 클러스터를 만들어 확인합니다.
sudo /opt/bngdrasil-backup/verify-restore.sh --mode local
```

`--no-owner --no-privileges`는 격리 환경에서 내용을 확인하기 위한 옵션입니다. 실제 재해 복구에서는 역할과 권한을 따로 재구성하고 최소 권한 연결까지 확인해야 합니다. 이 스크립트의 성공은 덤프가 복원된다는 뜻이고, 애플리케이션 전체가 동작한다는 뜻은 아닙니다.

PostgreSQL 14는 2026년 11월 12일에 지원이 끝날 예정이며 10월 말 전환을 내부 목표로 잡고 있습니다. `--pg-version 17`로 정기적으로 확인해 두면 전환 시점에 덤프 호환성 문제를 처음 마주하는 상황을 피할 수 있습니다.

## 로컬 검증 결과

운영 VM에는 설치하지 않았습니다. 대신 개발 장비의 PostgreSQL 14와 더미 데이터로 다음을 확인했습니다. 모든 스크립트가 `bash -n`과 `shellcheck -x`를 통과했습니다. `pg-backup.sh`가 더미 데이터베이스 두 개를 덤프하고 검증한 뒤 JSON과 metric을 출력했습니다. 존재하지 않는 데이터베이스를 지정한 실패 실행에서 exit code가 1이 되었고, `.partial` 파일이 남지 않았으며, `last-success.json`이 이전 성공 기록을 그대로 유지했습니다. 여유 공간 기준을 인위적으로 높였을 때 덤프를 시작하지 않고 실패했습니다. `verify-restore.sh`가 PostgreSQL 14와 PostgreSQL 17 양쪽에서 같은 테이블 수와 행 수를 보고했습니다. 체크섬을 일부러 어긋나게 했을 때 해당 데이터베이스를 복원하지 않고 실패로 기록했습니다. `retention.sh`가 세대 정책대로 정리했고, 성공본이 하나뿐인 상황과 마지막 실행이 실패한 상황에서 삭제를 수행하지 않았습니다.

Ubuntu 22.04 컨테이너의 mawk 환경에서도 용량 계산 함수가 순수 정수를 반환하는지 확인했습니다. mawk는 큰 수의 산술 결과를 `4.88162e+10` 같은 과학적 표기법으로 출력하므로, awk에서는 값을 추출만 하고 곱셈은 bash 정수 연산으로 수행하도록 바꾸었습니다.

R2 리뷰를 반영한 뒤에는 더미 데이터로 다음을 추가로 확인했습니다. 같은 날 00시 10분, 06시 10분, 12시 10분에 만든 미전송 성공본 세 개를 두었을 때 `--dry-run`과 실제 실행 모두 삭제를 한 건도 수행하지 않았고, 같은 세 개에 `SHIPPED` 표시를 붙이자 그날의 가장 최근 성공본만 남기고 두 개를 정리했습니다. 미전송 성공본을 아홉 개로 늘리자 `retention.sh`가 아무것도 지우지 않은 채 exit code 1로 끝나고 알림 대역 스크립트를 호출했습니다. rsync 대역이 실패를 돌려주는 상황에서는 `run.sh`의 전체 결과에 `ship` 단계 실패가 기록되었고 로컬 성공본과 `SUCCESS` 표시가 그대로 남았으며, 재시도 경로로 `ship.sh`를 단독 실행하자 미전송분만 전송하고 `SHIPPED` 표시를 남겼습니다. 원격 체크섬 검증이 실패하는 상황에서는 `SHIPPED` 표시를 만들지 않았습니다. 전송이 진행 중일 때 `retention.sh`를 동시에 실행하면 공용 잠금에 막혀 대기하다가 실패했습니다. 디스크 여유가 부족한 상황에서 `pg-backup.sh`가 덤프를 시작하지 않고 실패하는 기존 동작도 다시 확인했습니다.

이 검사들은 `tests/test_review_regressions.py`에 담겨 있으며 `python3 -m unittest discover -s tests -v`로 실행합니다. macOS의 디렉터리 잠금 경로와 Ubuntu 22.04 컨테이너의 `flock` 경로에서 모두 통과하는 것을 확인했습니다.

`age`와 `gpg`는 개발 장비에 없었으므로 `ship.sh`의 암호화 자체는 확인하지 못했습니다. 대신 스트림을 그대로 흘려보내는 대역 명령을 만들어 tar와 암호화와 rsync로 이어지는 배관과 `SHIPPED` 표시 동작을 확인했습니다. 실제 암호화와 VM4 전송은 설치 시점에 다시 확인해야 합니다. systemd 유닛은 개발 장비에서 `systemd-analyze verify`를 실행할 수 없으므로 문법을 눈으로 점검했습니다.

## 제한 사항

이 체계가 담지 않는 범위를 분명히 적어 둡니다.

- 전체 OS 디스크와 루트 홈과 cron 설정은 백업하지 않습니다. 이 체계는 데이터베이스와 상태 파일만 다룹니다.
- Terraform state와 OCI 설정과 Cloudflare 설정은 대상이 아닙니다. 해당 항목은 I09에서 따로 다룹니다.
- MongoDB는 퇴역 대상이므로 백업하지 않습니다. 중지와 관찰과 삭제를 분리해서 진행하기로 했고, 필요하다면 중지한 데이터 디렉터리의 사본을 그때 따로 만듭니다.
- Loki와 Prometheus의 저장 데이터는 보조 복구용이며 이 체계에 포함하지 않았습니다. 온라인 파일 복사는 일관성을 보장하지 않습니다.
- 서로 다른 구성 요소의 수집 시각이 다르므로 전체 서비스의 트랜잭션 일관성은 보장하지 않습니다.
- Redis의 `vm2-redis`와 VM2의 SQLite 파일은 VM3에서 닿지 않습니다. VM2에 같은 스크립트를 따로 설치하고 `RUN_POSTGRESQL=false`를 지정해야 합니다.
- 복원 훈련은 덤프가 복원된다는 사실까지만 확인합니다. 애플리케이션 로그인과 프록시 동작까지 확인하는 훈련은 별도 절차가 필요합니다.
- **실제 VM 설치와 독립 복원과 알림 수신은 아직 검증하지 않았습니다.** 여기에 적은 검증 결과는 모두 개발 장비의 더미 데이터와 대역 명령으로 얻은 것입니다. 표에 적은 복구 시점 목표도 설계 목표이며, 운영 환경에서 실제로 달성한 값이 아닙니다. VM3와 VM2에 설치한 뒤에 전송 성공, 격리 복원, 경보 통지 수신을 차례로 확인해야 합니다.

## 롤백

설치한 백업 체계를 되돌릴 때에는 timer를 먼저 중지합니다.

```sh
sudo systemctl disable --now bngdrasil-backup.timer
sudo systemctl disable --now bngdrasil-backup-ship.timer
sudo systemctl disable --now bngdrasil-backup-verify.timer
```

유닛 파일까지 제거하려면 `sudo /opt/bngdrasil-backup/install.sh --uninstall`을 실행합니다. 이 명령은 timer를 중지하고 유닛 파일을 지우지만 `/var/backups/bngdrasil`의 백업 데이터와 `/etc/bngdrasil-backup/env`는 그대로 둡니다. 이전 방식으로 돌아가기 위해 백업 데이터를 지우는 일은 하지 않습니다. 새 체계가 성공적으로 실행되는 것을 확인하기 전에는 기존 백업본을 삭제하지 않습니다.
