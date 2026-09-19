# GitHub Actions 기반 배포 설정 안내

이 문서는 BNGdrasil의 여러 저장소에 나뉘어 있는 GitHub Actions 워크플로가 어떤 순서로 무엇을
배포하는지 설명하고, 운영자가 최초에 한 번 수행해야 하는 준비 작업을 정리한 것입니다. 배포가
실패했을 때 되돌리는 절차와 이 구조에서 남는 보안 위험도 함께 적었습니다.

이 문서에 적힌 값은 2026-09-18에 관측한 운영 상태를 기준으로 삼습니다. 실제 컨테이너와 이미지의
기준선은 [배포 기준선](deployment-inventory.md)에 있습니다.

---

## 1. 전체 배포 구조

애플리케이션 코드는 각 애플리케이션의 저장소가 배포하고, 서버 측 스크립트와 운영 스택은 이
저장소(Baedalus)가 배포합니다. 두 경로를 한 저장소에 모으지 않은 이유는, 애플리케이션 release가
해당 저장소의 커밋을 기준으로 삼아야 어떤 코드가 올라갔는지 추적할 수 있기 때문입니다.

| 저장소 | 워크플로 | 실행 조건 | 하는 일 |
|---|---|---|---|
| Bidar | `release.yml` | main 브랜치에 push하거나 수동으로 실행합니다 | ARM64 이미지를 build하여 `ghcr.io/bngdrasil/bidar:sha-<짧은 SHA>`로 push하고, 승인을 받은 뒤에 build가 돌려준 digest로 VM2의 `deploy-image.sh`를 호출합니다 |
| Bifrost | `release.yml` | 위와 같습니다 | `ghcr.io/bngdrasil/bifrost:sha-<짧은 SHA>`를 push하고 같은 방식으로 배포합니다 |
| Bantheon | 자체 배포 워크플로 | 저장소의 정의를 따릅니다 | VM1의 Nginx 설정과 정적 사이트를 배포합니다 |
| Baedalus | `terraform.yml` | pull request를 열 때 실행합니다 | Terraform 코드의 포맷과 유효성만 검사합니다 |
| Baedalus | `deploy-monitoring.yml` | 수동으로만 실행합니다 | `monitoring/`을 VM2로 전송하고 관측 스택을 다시 기동합니다 |
| Baedalus | `deploy-backup.yml` | 수동으로만 실행합니다 | `backup/`을 VM3 또는 VM2에 설치합니다 |

### 애플리케이션 release가 진행되는 순서

Bidar와 Bifrost의 `release.yml`은 다음 순서로 동작합니다. 두 저장소의 워크플로는 대상 서비스
이름과 이미지 이름만 다르고 구조는 같습니다.

1. 저장소를 checkout하고 GHCR에 로그인합니다.
2. `linux/arm64` 이미지를 build하여 `ghcr.io/bngdrasil/<이미지>:sha-<짧은 SHA>` 태그로 push합니다.
   VM2가 Ampere 기반 ARM64 인스턴스이므로 아키텍처를 반드시 맞추어야 합니다.
3. `environment: production`으로 지정한 배포 job이 승인 대기 상태로 들어갑니다. 승인자가 승인해야
   다음 단계로 넘어갑니다.
4. 배포 job이 SSH로 VM2에 접속하여 `sudo /opt/bnbong/deploy-image.sh <서비스> <이미지 참조>`를
   실행합니다. `<서비스>`에는 Bidar가 `auth-server`를, Bifrost가 `gateway`를 넘깁니다.

### 이미지 참조의 두 가지 표기

`deploy-image.sh`는 다음 두 표기를 모두 받습니다.

| 표기 | 예시 | 어떤 경우에 사용하는가 |
|---|---|---|
| digest 고정 참조 | `ghcr.io/bngdrasil/bidar@sha256:<64자리 16진수>` | `release.yml`이 build 직후에 넘기는 기본 형식입니다. build 단계가 돌려준 digest를 그대로 사용합니다. |
| 태그 참조 | `ghcr.io/bngdrasil/bidar:sha-1a2b3c4` | 되돌릴 때 실행하는 `workflow_dispatch`와 운영자가 손으로 하는 배포에서 사용합니다. |

평소 release가 digest 표기를 사용하는 이유는, 같은 태그가 registry에서 나중에 다른 이미지로 덮여도
실제로 올라간 이미지가 달라지지 않기 때문입니다. 태그만 넘기면 승인을 기다리는 사이에 같은 태그가
다시 push될 수 있고, 그러면 검토한 이미지와 배포된 이미지가 어긋납니다.

`docker compose`는 `image: <이름>@sha256:...` 표기를 그대로 받으므로, `deploy-image.sh`는 받은
참조를 가공하지 않고 `.env`에 그대로 기록합니다. 따라서 `/opt/bnbong/.env`를 읽으면 현재 어떤
이미지가 올라가 있는지를 digest 수준에서 확인할 수 있습니다.

두 표기 모두 registry와 조직 접두사가 `ghcr.io/bngdrasil/`이어야 하고, digest는 `sha256:` 뒤에
16진수 64자리가 와야 합니다. 형식이 맞지 않으면 스크립트가 종료 코드 2로 끝납니다.

### VM2에서 일어나는 일

`/opt/bnbong/deploy-image.sh`는 저장소의 `vm2-deployment/deploy-image.sh`와 같은 파일입니다.
이 스크립트는 다음 순서로 동작합니다.

1. 인자를 검증합니다. 서비스 이름은 `auth-server`나 `gateway`여야 하고, 이미지 참조는
   `ghcr.io/bngdrasil/`로 시작하는 digest 표기나 태그 표기여야 합니다. 이 검사가 없으면 SSH 접속
   권한을 얻은 쪽이 임의의 registry에서 가져온 이미지를 운영 컨테이너로 올릴 수 있습니다.
2. `flock`으로 잠금을 잡습니다. 두 저장소의 release가 같은 시각에 도착하면 `.env` 갱신과 컨테이너
   교체가 서로 겹치기 때문에, 뒤에 도착한 쪽은 즉시 실패하고 다시 실행하도록 안내합니다.
3. 이미지를 내려받은 다음, 컨테이너를 교체하기 전에 `docker compose config <서비스>`로 해석한
   environment를 점검합니다. 값이 빈 문자열인 키가 하나라도 있으면 그 목록을 출력하고 종료 코드
   1로 중단하며, 이때 컨테이너와 `.env`는 건드리지 않습니다. 필수 변수가 없어서 `compose config`
   자체가 실패하는 경우도 같은 자리에서 잡습니다. 2026-09-19 장애의 직접 원인이 빈 문자열이
   컨테이너로 넘어간 것이었기 때문에 이 점검을 추가했습니다.
4. 교체 직전 컨테이너의 이미지 ID를 `rollback/<컨테이너>:<UTC 시각>` 태그로 남깁니다. 태그가
   아니라 이미지 ID를 대상으로 삼기 때문에, 같은 태그가 registry에서 새 이미지로 덮인 뒤에도 이전
   layer를 되찾을 수 있습니다.
5. `/opt/bnbong/.env`의 `AUTH_SERVER_IMAGE` 또는 `GATEWAY_IMAGE` 줄만 새 값으로 바꿉니다. 받은
   참조를 가공하지 않고 그대로 기록하므로, digest로 호출하면 `.env`에도 digest가 남습니다. 나머지
   줄과 파일 권한은 그대로 유지합니다.
6. `docker compose up -d --no-deps --no-build <서비스>`로 해당 서비스만 교체합니다.
7. health를 확인합니다. 두 서비스 모두 `/health`가 200을 돌려주어야 하고, Gateway는 `/ready`까지
   200이어야 합니다. `/ready`는 데이터베이스 연결과 서비스 등록부를 함께 확인하므로, 이 검사를
   생략하면 프로세스만 살아 있고 의존 자원이 끊긴 상태를 성공으로 오인합니다.
8. 확인에 실패하면 되돌리기 전에 실패한 컨테이너의 `docker logs --tail 80`과 `docker inspect`의
   `State`를 출력하고, 같은 내용을 `/opt/bnbong/deploy-failures/<UTC 시각>-<서비스>.log`에도
   남깁니다. 되돌리면 실패한 컨테이너가 사라져서 원인을 확인할 수 없기 때문입니다. 그다음 `.env`를
   이전 내용으로 되돌리고 이전 이미지로 다시 기동한 뒤에, 같은 기준으로 health를 한 번 더
   확인합니다. 롤백본이 확인을 통과하면 종료 코드 1로, 롤백본까지 실패하면 종료 코드 3으로
   끝냅니다. 종료 코드 3은 서비스가 중단된 상태라는 뜻이므로 사람이 즉시 조치해야 합니다.
   워크플로는 어느 쪽이든 실패로 기록됩니다.
9. 성공하면 시각과 서비스 이름과 이미지 참조와 digest를 `/opt/bnbong/releases.log`에 한 줄로
   남깁니다. digest는 태그로 호출한 경우에 `docker image inspect`의 `RepoDigests`에서 해당
   repository의 항목을 골라 채우고, digest로 호출한 경우에는 받은 참조가 곧 digest이므로 그 값을
   그대로 남깁니다. 마지막으로 `rollback/*` 태그가 컨테이너마다 다섯 개를 넘으면 오래된 것부터
   제거합니다. `docker image prune`은 실행하지 않습니다. 이 호스트에는 다른 stack의 이미지도 있어서
   일괄 정리가 의도하지 않은 이미지까지 지울 수 있기 때문입니다.

---

## 2. 저장소별 secret과 environment

각 저장소의 Settings에서 `production` environment를 만들고, 아래 secret을 그 environment에
등록합니다. 저장소 전체 secret이 아니라 environment secret으로 두어야, 승인을 거치지 않는
워크플로에서 키가 읽히는 상황을 막을 수 있습니다.

| 저장소 | environment | secret 이름 | 값 |
|---|---|---|---|
| Bidar | `production` | `VM2_HOST` | VM2의 공인 IP 주소입니다 |
| Bidar | `production` | `VM2_SSH_PRIVATE_KEY` | 배포 전용 SSH 개인 키의 전체 내용입니다 |
| Bidar | `production` | `VM2_SSH_KNOWN_HOSTS` | VM2의 host key 한 줄입니다 |
| Bifrost | `production` | `VM2_HOST`, `VM2_SSH_PRIVATE_KEY`, `VM2_SSH_KNOWN_HOSTS` | Bidar와 같은 값을 사용합니다 |
| Bantheon | `production` | `VM1_HOST`, `VM1_SSH_PRIVATE_KEY`, `VM1_SSH_KNOWN_HOSTS` | VM1에 대응하는 값입니다 |
| Baedalus | `production` | `VM2_HOST`, `VM2_SSH_PRIVATE_KEY`, `VM2_SSH_KNOWN_HOSTS` | 모니터링과 백업 배포에 사용합니다 |

`deploy-backup.yml`에서 VM3를 대상으로 지정하면 VM2를 경유지로 삼아 접속합니다. VM3의 사설 주소는
저장소 변수 `VM3_PRIVATE_IP`로 지정할 수 있으며, 값을 두지 않으면 기본값인 `10.0.2.134`를
사용합니다. 이때 VM2와 VM3가 모두 같은 배포용 공개 키를 신뢰해야 하고, `VM2_SSH_KNOWN_HOSTS`에는
경유지인 VM2의 host key와 목적지인 VM3의 host key가 모두 들어 있어야 합니다.

---

## 3. 최초 한 번 수행하는 준비 작업

아래 다섯 단계를 순서대로 수행합니다. 3.2와 3.3은 VM에서, 나머지는 로컬 작업 환경과 GitHub
화면에서 수행합니다.

### 3.1. GHCR 패키지를 public으로 전환합니다

VM2는 GHCR에 로그인하지 않은 상태에서 이미지를 내려받습니다. 따라서 `bngdrasil/bidar`와
`bngdrasil/bifrost` 패키지가 public이어야 합니다. 최초 push 직후에는 패키지가 private이므로,
GitHub 조직의 Packages 화면에서 각 패키지의 Package settings를 열고 가시성을 public으로 바꿉니다.

패키지를 private으로 유지하려면 VM2에 읽기 전용 토큰으로 `docker login ghcr.io`를 미리 수행해
두어야 합니다. 이 방식은 토큰 만료 시점마다 배포가 조용히 실패할 수 있으므로, 공개 이미지에 비밀
값이 들어가지 않는다는 점을 확인한 뒤에 public으로 두기를 권장합니다.

### 3.2. 배포 전용 SSH 키를 만들고 등록합니다

운영자가 평소에 사용하는 키를 GitHub Actions에 넣지 않습니다. 키가 유출되었을 때 폐기 범위를
좁히려면 용도마다 키를 분리해야 합니다.

```bash
# 로컬 작업 환경에서 키쌍을 만듭니다. 암호 구절은 두지 않습니다.
# GitHub Actions는 대화형으로 암호 구절을 입력할 수 없습니다.
ssh-keygen -t ed25519 -f ~/.ssh/bngdrasil-deploy -C 'github-actions-deploy' -N ''

# 공개 키를 VM2의 ubuntu 계정에 등록합니다.
ssh-copy-id -i ~/.ssh/bngdrasil-deploy.pub ubuntu@<VM2_PUBLIC_IP>

# host key를 수집하여 VM2_SSH_KNOWN_HOSTS secret의 값으로 사용합니다.
ssh-keyscan -H <VM2_PUBLIC_IP>
```

`~/.ssh/bngdrasil-deploy`의 전체 내용을 `VM2_SSH_PRIVATE_KEY` secret에 붙여 넣습니다. 첫 줄의
`-----BEGIN OPENSSH PRIVATE KEY-----`와 마지막 줄의 `-----END OPENSSH PRIVATE KEY-----`를 모두
포함해야 합니다.

VM3를 백업 배포 대상으로 사용하려면 같은 공개 키를 VM3의 `ubuntu` 계정에도 등록하고, VM3의 host
key를 `VM2_SSH_KNOWN_HOSTS`에 함께 넣습니다.

#### `authorized_keys`에 제한을 거는 선택 사항

`deploy-image.sh`만 호출하면 되는 Bidar와 Bifrost의 키에는 실행할 수 있는 명령을 고정할 수
있습니다. 아래 예시를 `~ubuntu/.ssh/authorized_keys`에 적용하면 해당 키로 접속한 세션은 지정한
명령만 실행하고, 포트 전달과 에이전트 전달과 터미널 할당을 모두 사용할 수 없습니다.

```
restrict,command="sudo /opt/bnbong/deploy-image.sh ${SSH_ORIGINAL_COMMAND#* }" ssh-ed25519 AAAA... github-actions-deploy
```

다만 `SSH_ORIGINAL_COMMAND`를 그대로 넘기면 명령을 고정한 의미가 약해지므로, 실제로 적용할
때에는 인자를 검사하는 짧은 wrapper 스크립트를 `command=`에 지정하는 편이 안전합니다. 이 제한은
필수가 아니며, 모니터링과 백업 배포에 쓰는 키에는 적용할 수 없습니다. 그 두 워크플로는 `rsync`와
여러 원격 명령을 실행하기 때문입니다. 용도가 다른 두 키를 따로 만들어서, 애플리케이션 release용
키에만 이 제한을 적용하는 방법을 고려할 수 있습니다.

### 3.3. `deploy-image.sh`를 설치하고 sudoers를 설정합니다

저장소의 `vm2-deployment/install-deploy-image.sh`가 이 작업을 대신 수행합니다. 스크립트를
`/opt/bnbong/deploy-image.sh`에 권한 755로 두고, `ubuntu` 계정이 그 파일 하나만 비밀번호 없이
sudo로 실행할 수 있도록 `/etc/sudoers.d/bngdrasil-deploy`를 만듭니다.

```bash
scp vm2-deployment/deploy-image.sh vm2-deployment/install-deploy-image.sh ubuntu@<VM2_PUBLIC_IP>:/tmp/
ssh ubuntu@<VM2_PUBLIC_IP> 'sudo bash /tmp/install-deploy-image.sh /tmp/deploy-image.sh'
```

설치 스크립트가 만드는 sudoers 파일의 내용은 다음 한 줄입니다.

```
ubuntu ALL=(root) NOPASSWD: /opt/bnbong/deploy-image.sh
```

이 파일은 `visudo -cf`로 문법을 검사한 뒤에 설치되고, 설치한 다음에 `visudo -c`로 전체 설정을 한
번 더 검사합니다. 문법이 틀린 파일이 `/etc/sudoers.d`에 들어가면 `sudo` 자체가 동작하지 않아서
복구가 어려워지기 때문입니다.

`deploy-image.sh`의 소유자는 root이고 쓰기 권한도 root에게만 있습니다. `ubuntu` 계정이 이 파일을
고칠 수 있으면, 파일 하나에 부여한 `NOPASSWD` 권한이 사실상 제한 없는 root 권한으로 바뀝니다.
스크립트를 새 판으로 바꿀 때에도 반드시 `install-deploy-image.sh`를 다시 실행하여 소유자와 권한을
유지해야 합니다.

설정이 끝나면 아래 명령으로 확인합니다. 인자가 없으므로 종료 코드 2와 함께 사용법이 출력되면
권한 설정이 올바른 것입니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP> 'sudo -n /opt/bnbong/deploy-image.sh; echo "exit=$?"'
```

### 3.4. `.env`에 이미지 변수를 넣습니다

`/opt/bnbong/.env`에 아래 두 줄이 있어야 합니다. `deploy-image.sh`는 줄이 없으면 파일 끝에
추가하지만, 첫 배포 전에 미리 넣어 두면 현재 어떤 이미지가 올라가 있는지를 파일만 보고 알 수
있습니다.

```
AUTH_SERVER_IMAGE=ghcr.io/bngdrasil/bidar:main
GATEWAY_IMAGE=ghcr.io/bngdrasil/bifrost:main
```

`docker-compose.yml`의 기본값도 같은 GHCR 참조이므로, 두 줄을 지우면 특정 release가 아니라 `main`
태그가 올라갑니다. 운영 `.env`에서는 두 줄을 항상 유지합니다.

`.env`의 권한은 600을 유지해야 합니다. `deploy-image.sh`는 임시 파일에 새 내용을 쓴 다음 원본의
권한과 소유자를 복사하여 교체하므로, 정상적으로 동작하는 한 권한이 넓어지지 않습니다. 다만 손으로
편집한 뒤에는 `ls -l /opt/bnbong/.env`로 한 번 확인하는 편이 좋습니다.

### 3.5. `production` environment에 보호 규칙을 설정합니다

각 저장소의 Settings에서 Environments를 열고 `production` environment에 다음 두 가지를
설정합니다.

첫째, Required reviewers에 승인자를 지정합니다. 이 설정이 있어야 배포 job이 승인 대기 상태로
멈춥니다. 승인자를 지정하지 않으면 main에 push하는 즉시 운영 컨테이너가 교체됩니다.

둘째, Deployment branches를 `main`으로 제한합니다. 이 제한이 없으면 임의의 브랜치에서 워크플로를
수동으로 실행하여 검증되지 않은 코드를 배포할 수 있습니다.

Wait time은 두지 않아도 됩니다. 승인자가 지정되어 있으면 사람이 확인하는 시간이 이미 확보되기
때문입니다.

---

## 4. 롤백 절차

### 4.1. 배포 직후 자동으로 되돌아가는 경우

`deploy-image.sh`의 health 확인이 실패하면 스크립트가 실패한 컨테이너의 로그와 `State`를 갈무리한
다음, `.env`를 이전 내용으로 되돌리고 이전 이미지로 컨테이너를 다시 기동하고, 같은 기준으로
health를 한 번 더 확인합니다. 이때 워크플로는 실패로 끝나고, 로그의 마지막 부분에 되돌아간 지점과
확인 명령이 출력됩니다. 롤백본이 확인을 통과했다면 운영자는 서비스가 이전 상태로 돌아왔는지만
확인하면 됩니다.

워크플로가 종료 코드 3으로 끝났다면 롤백본까지 기동하지 못한 것이므로 서비스가 중단된 상태입니다.
`docker-compose.yml`이나 `.env`의 형식이 바뀐 직후의 첫 배포에서 이 상황이 일어날 수 있습니다. 구
이미지가 새 `.env` 형식을 읽지 못하기 때문이며, 이런 전환 배포는 유지보수 창에서 수행해야 합니다.
원인은 `/opt/bnbong/deploy-failures/`에 남은 기록으로 확인합니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP>
cd /opt/bnbong && sudo docker compose ps
curl -i http://127.0.0.1:8000/ready
curl -i http://127.0.0.1:8001/health
```

### 4.2. 배포가 성공한 뒤에 문제를 발견한 경우

health 확인은 통과했지만 실제 동작에 문제가 있는 경우에는 손으로 되돌립니다. 되돌릴 지점은
`rollback/<컨테이너>` 태그로 남아 있으며, 컨테이너마다 다섯 개까지 보관합니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP>

# 1) 되돌릴 지점을 고릅니다. 태그가 UTC 시각이므로 가장 최근 것이 직전 상태입니다.
sudo docker image ls 'rollback/vm2-gateway'

# 2) 최근 배포 이력을 확인합니다.
tail -5 /opt/bnbong/releases.log

# 3) .env의 이미지 변수를 롤백 태그로 바꿉니다.
cd /opt/bnbong
sudo sed -i 's|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=rollback/vm2-gateway:<시각>|' .env

# 4) 해당 서비스만 다시 기동합니다.
sudo docker compose up -d --no-deps --no-build gateway

# 5) 확인합니다.
curl -i http://127.0.0.1:8000/health
curl -i http://127.0.0.1:8000/ready
```

Auth Server를 되돌릴 때에는 위의 `GATEWAY_IMAGE`를 `AUTH_SERVER_IMAGE`로, `gateway`를
`auth-server`로, `vm2-gateway`를 `vm2-auth`로 바꿉니다.

이전 release의 GHCR 참조를 알고 있다면 롤백 태그 대신 그 참조를 직접 지정해도 됩니다. 롤백 태그는
VM2에만 있으므로 호스트를 다시 만들면 사라지지만, GHCR 참조는 registry에 남아 있습니다.
`releases.log`에 digest가 기록되어 있으므로 그 값을 그대로 쓰면 됩니다.

```bash
# .env를 직접 고치는 방법
sudo sed -i 's|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=ghcr.io/bngdrasil/bifrost@sha256:<이전 digest>|' .env
sudo docker compose up -d --no-deps --no-build gateway

# 스크립트를 다시 호출하는 방법. health 확인과 기록까지 함께 수행합니다.
sudo /opt/bnbong/deploy-image.sh gateway ghcr.io/bngdrasil/bifrost:sha-<이전 SHA>
```

### 4.3. 데이터베이스 스키마를 바꾼 배포를 되돌릴 때

이 절차는 컨테이너 이미지만 되돌립니다. 데이터베이스 마이그레이션은 되돌아가지 않습니다. 스키마를
바꾼 배포를 되돌릴 때에는 이전 애플리케이션 판이 새 스키마에서도 동작하는지를 먼저 판단해야
합니다. Bidar의 마이그레이션 절차와 주의 사항은
[vm2-deployment/README.md](../vm2-deployment/README.md)의 마이그레이션 항목에 있습니다.

---

## 5. 보안에서 고려한 사항과 남는 위험

### 배포용 키의 권한 범위

배포용 키는 VM2의 `ubuntu` 계정에 접속할 수 있고, 그 계정은 `deploy-image.sh` 하나에 대해서만
비밀번호 없는 sudo 권한을 가집니다. 다만 `ubuntu` 계정 자체는 `docker` 그룹에 속해 있을 수 있고,
Docker 소켓에 접근할 수 있는 계정은 호스트 파일 시스템을 마운트한 컨테이너를 만들어 사실상 root
권한을 얻을 수 있습니다. 즉 sudoers 제한만으로 권한 상승을 완전히 막지는 못합니다. 이 제한은
실수로 다른 명령을 실행하는 상황을 줄이는 조치이며, 키가 유출되었을 때의 피해를 없애지는
못합니다.

따라서 키 유출에 대비한 실제 방어선은 키 자체를 좁게 쓰고 빠르게 폐기하는 것입니다. 애플리케이션
release용 키와 모니터링 및 백업 배포용 키를 분리하고, 사용하지 않는 키는 `authorized_keys`에서
바로 지웁니다.

### 22번 포트 노출

현재 춘천 public subnet의 SSH 규칙은 `admin_cidr` 변수가 결정하며 기본값이 `0.0.0.0/0`입니다.
GitHub Actions의 runner IP 대역은 넓고 자주 바뀌기 때문에, 배포를 위해 IP를 좁히는 방법은 실용적인
선택이 아닙니다. 대신 다음 두 가지를 확인해야 합니다.

첫째, VM2의 `sshd`가 비밀번호 인증을 받지 않아야 합니다. `PasswordAuthentication no`와
`PermitRootLogin no`를 확인합니다. 둘째, 실패한 접속 시도를 제한하는 장치가 있어야 합니다.
`fail2ban`이나 `sshd`의 `MaxAuthTries` 설정으로 무차별 대입 시도를 줄일 수 있습니다.

`admin_cidr`를 좁히는 작업은 운영자의 관리 접근 경로를 먼저 확인한 뒤에 진행해야 합니다. 확인
없이 좁히면 운영자가 VM에 접속하지 못하게 됩니다. 관련 설명은
[저장소 README](../README.md)의 보안 규칙 변수 항목에 있습니다.

### `restrict` 옵션의 효과와 한계

3.2에 적은 `authorized_keys`의 `restrict` 옵션은 포트 전달과 에이전트 전달과 X11 전달과 터미널
할당을 모두 차단합니다. 배포용 키에는 이 기능이 필요하지 않으므로 차단해 두는 편이 안전합니다.
다만 `command=`로 명령을 고정하지 않으면 임의의 셸 명령을 실행하는 것 자체는 막지 못합니다. 명령
고정까지 적용하려면 인자를 검사하는 wrapper 스크립트가 필요하며, 그 작업은 아직 수행하지
않았습니다.

### GHCR 이미지의 공개 범위

패키지를 public으로 두면 누구나 이미지를 내려받을 수 있습니다. 따라서 이미지 안에 비밀 값이
들어가지 않아야 합니다. Bidar와 Bifrost는 모든 설정을 환경 변수로 받고 그 값은 VM2의
`/opt/bnbong/.env`에만 있으므로, 현재 구조에서는 이미지에 비밀 값이 포함되지 않습니다. 다만
`Dockerfile`에 `ARG`로 비밀을 전달하는 변경이 들어가면 이 전제가 깨지므로, 두 저장소에서
Dockerfile을 바꿀 때마다 확인해야 합니다.

### 감사 기록

`/opt/bnbong/releases.log`에는 성공한 배포만 기록됩니다. 실패한 시도와 롤백은 이 파일에 남지
않으며, GitHub Actions의 실행 이력과 VM2의 `journalctl`에서 확인해야 합니다. 실패 이력까지 한곳에
모으는 작업은 아직 하지 않았습니다.

---

## 6. Terraform을 CI에서 apply하지 않는 이유

`terraform.yml`은 `fmt`와 `validate`까지만 수행하고 `plan`과 `apply`를 두지 않습니다. state가
저장소 바깥의 로컬 파일인 `terraform.tfstate`에만 있어서, runner에는 현재 관리 중인 자원 정보가
전혀 없기 때문입니다. 그 상태로 `plan`을 실행하면 이미 존재하는 자원을 새로 만들겠다는 계획이
나오고, 그 계획을 `apply`하면 운영 인프라가 훼손됩니다.

원격 backend로 state를 옮긴 뒤에 다시 검토합니다. OCI Object Storage의 S3 호환 endpoint를 backend로
사용할 수 있으며, 도입하기 전에 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저
확인해야 합니다. 현재 state에는 VM5와 VM6가 실제 자원과 어긋난 상태로 남아 있으므로, 그 정리를
끝내기 전에는 원격 backend 이전도 시작하지 않습니다. 정리 절차는
[저장소 README](../README.md)의 VM5와 VM6 항목에 있습니다.

---

## 7. 관련 문서

| 문서 | 다루는 내용 |
|---|---|
| [vm2-deployment/README.md](../vm2-deployment/README.md) | VM2 애플리케이션의 배포와 확인과 롤백 절차를 설명합니다 |
| [monitoring/README.md](../monitoring/README.md) | 관측 스택의 구성과 알림 규칙을 설명합니다 |
| [backup/README.md](../backup/README.md) | 반복 백업 체계와 복원 훈련 절차를 설명합니다 |
| [docs/deployment-inventory.md](deployment-inventory.md) | 2026-09-18 기준의 실제 배포 상태를 기록했습니다 |
