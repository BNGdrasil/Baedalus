# VM2 애플리케이션 배포

이 디렉터리는 VM2에서 동작하는 핵심 API의 배포 정의를 담고 있습니다. 배포 대상은 세 가지이며,
Gateway(Bifrost)는 8000번 포트와 `vm2-gateway` 컨테이너를, Auth Server(Bidar)는 8001번 포트와
`vm2-auth` 컨테이너를, Redis는 loopback에만 게시하는 6379번 포트와 `vm2-redis` 컨테이너를
사용합니다.

운영 배치 위치는 `/opt/bnbong`이고 compose project 이름은 `bnbong`입니다. cloud-init
(`../scripts/user_data_vm2.sh`)은 호스트 준비까지만 담당하므로, compose 파일과 애플리케이션
release는 이 디렉터리가 담당합니다.

## 두 가지 배포 경로

배포 경로는 두 가지이며, 평소에는 첫 번째 경로만 사용합니다.

| 경로 | 사용하는 파일 | 어떤 상황에서 사용하는가 |
|---|---|---|
| GHCR 이미지 교체(기본) | `deploy-image.sh` | Bidar와 Bifrost 저장소의 release 워크플로가 GHCR에 올린 이미지를 VM2에서 교체합니다. 평소의 모든 배포가 이 경로를 따릅니다. |
| 소스 현장 build(대체) | `deploy.sh` | GHCR 이미지를 사용할 수 없을 때에만 사용합니다. GitHub Actions가 동작하지 않거나, GHCR에서 이미지를 받지 못하거나, 저장소에 올리지 않은 수정본을 급히 확인해야 하는 상황이 여기에 해당합니다. |

두 경로는 같은 `.env`와 같은 `docker-compose.yml`을 사용하므로 섞어 써도 충돌하지 않습니다. 다만
`deploy.sh`로 현장 build를 하면 `.env`의 이미지 변수가 `bnbong-gateway:<짧은 SHA>` 형태로 바뀌고,
그 이미지는 VM2에만 존재합니다. 다음 GHCR release가 그 값을 다시 GHCR 참조로 덮어씁니다.

전체 CD 구조와 저장소별 secret 구성은
[GitHub Actions 배포 설정](../docs/github-actions-setup.md)에 있습니다.

## 포트 바인딩

VM1 Nginx가 VM2의 private IP인 `10.0.1.60`의 8000번과 8001번 포트로 접근합니다. 그래서 두 포트를
loopback에만 묶을 수 없고, private IP와 loopback 두 곳에만 게시하며 public IP에는 게시하지
않습니다. 바인딩 주소는 `.env`의 `VM2_PRIVATE_IP` 값이 결정합니다. security list 수준의 제한
범위와 그 한계는 [저장소 README](../README.md)의 "SEC-04의 현재 범위"에 정리했습니다.

---

## 1. 사전 준비

Terraform으로 VM2가 만들어져 있고 `terraform output -raw vm2_public_ip`가 주소를 돌려주어야
합니다. VM3의 호스트 PostgreSQL 14가 동작하고 있어야 하고, VM2에 SSH로 접속할 수 있어야 합니다.
그다음 아래 2장의 `.env`를 채우고 3장의 마이그레이션을 적용한 뒤에 배포를 시작합니다.

---

## 2. `.env` 준비

```bash
cp env.template .env   # 기존 .env가 있으면 덮어쓰지 않도록 주의합니다
```

`env.template`에는 각 변수의 용도와 주의 사항을 주석으로 적어 두었고, 변수 목록은 두 앱의
`Settings`가 실제로 읽는 항목에 맞추었습니다. 이 가운데 `AUTH_SERVER_IMAGE`와 `GATEWAY_IMAGE`는
어떤 이미지로 컨테이너가 떠 있는지를 결정하는 값이며, 평소에는 `deploy-image.sh`가 자동으로
갱신하므로 직접 편집하지 않습니다. 두 줄을 지우면 `docker-compose.yml`의 기본값인
`ghcr.io/bngdrasil/bidar:main`과 `ghcr.io/bngdrasil/bifrost:main`이 적용되어, 특정 release가
아니라 `main` 태그가 올라갑니다. 두 앱 모두 읽지 않는 변수를 무시하므로, 설정했다고
착각하기 쉬운 변수는 템플릿에서 아예 제외했습니다.

### 기동을 막는 값

`ENVIRONMENT=production` 기준으로 Bifrost는 `SECRET_KEY`와 `DATABASE_URL`과 `ALLOWED_HOSTS`가,
Bidar는 `JWT_SECRET_KEY`와 `DATABASE_URL`과 `ALLOWED_HOSTS`와 `ALLOWED_ORIGINS`가 비어 있으면
기동 중에 실패합니다. 두 비밀 값은 32자 이상이어야 하고, 예시 값이거나 `changethis`나 `placeholder`
같은 문구를 포함하면 거부됩니다. 새 값은
`python -c "import secrets; print(secrets.token_urlsafe(48))"`로 만들 수 있습니다.

**Bidar와 Bifrost 모두 production에서 `ALLOWED_HOSTS`가 비어 있거나 `*`이면 기동에
실패합니다.** 두 앱에서 동작이 같아졌으므로, `GATEWAY_ALLOWED_HOSTS`와 `AUTH_ALLOWED_HOSTS` 둘 다
비우거나 `*`로 두지 않아야 합니다.

### 네트워크 관련 값

`VM2_PRIVATE_IP`는 8000번과 8001번과 3000번 포트의 바인딩 주소를 결정하며, compose가
`${VM2_PRIVATE_IP:?...}` 형태로 참조하므로 비워 두면 바인딩이 조용히 모든 인터페이스로 넓어지는
대신 compose가 즉시 중단됩니다. `VM3_PRIVATE_IP`는 호스트 PostgreSQL 14와 Redis가 동작하는 VM3의
주소입니다. `FORWARDED_ALLOW_IPS`에는 uvicorn이 `X-Forwarded-*` 헤더를 신뢰할 발신지로 VM1 Nginx의
주소 하나만 넣습니다.

`FORWARDED_ALLOW_IPS`를 `*`로 두면 VM2에 직접 연결한 쪽이 클라이언트 IP를 위조할 수 있고, Bidar의
로그인 제한이 실제 호출자를 구분하지 못합니다.

---

## 3. Bidar 데이터베이스 마이그레이션

**앱을 배포하기 전에 먼저 수행합니다.** Bidar는 `role`을 단일 기준으로 삼고 `is_superuser`를
파생값으로 다루므로, 스키마를 맞추지 않은 데이터베이스에 새 버전을 올리면 권한 판정이 어긋납니다.
절차의 원문은 `bidar/migrations/README.md`에 있으며, 아래는 순서만 옮긴 것입니다. 모든 명령은
VM3에서 실행합니다.

```bash
# 0) 적용 직전 논리 백업
sudo -u postgres pg_dump -Fc -d bngdrasil -f /var/backups/bngdrasil-$(date +%F).dump

# 1) 001 적용. role 컬럼과 check 제약과 인덱스를 추가합니다
sudo -u postgres psql -d bngdrasil -v ON_ERROR_STOP=1 -f migrations/001_add_role_to_users.sql

# 2) preflight 실행. 읽기 전용 감사이며 출력을 반드시 읽습니다
sudo -u postgres psql -d bngdrasil -v ON_ERROR_STOP=1 -f migrations/002_preflight.sql

# 3) preflight 결과가 의도와 맞으면 002를 적용합니다
sudo -u postgres psql -d bngdrasil -v ON_ERROR_STOP=1 -f migrations/002_align_role_and_superuser.sql
```

002에는 값을 되돌리는 자동 롤백이 없습니다. preflight 출력의 5번 항목에서 **적용 후 남을 활성
`super_admin` 계정 수가 0이면, 002를 적용하기 전에** Bidar CLI로 관리자 계정을 먼저 만들어야
합니다. 한 명도 없으면 관리 API에 접근할 수 없습니다.

---

## 4. 배포 실행

### 기본 경로: GHCR 이미지 교체

Bidar나 Bifrost의 main 브랜치에 변경이 들어가면 해당 저장소의 release 워크플로가 ARM64 이미지를
build하여 `ghcr.io/bngdrasil/<이미지>:sha-<짧은 SHA>`로 push합니다. `production` environment의
승인을 받은 뒤에 워크플로가 SSH로 VM2에 접속하여, build가 돌려준 digest로 아래 명령을 실행합니다.

```bash
sudo /opt/bnbong/deploy-image.sh auth-server ghcr.io/bngdrasil/bidar@sha256:<64자리 16진수>
sudo /opt/bnbong/deploy-image.sh gateway     ghcr.io/bngdrasil/bifrost@sha256:<64자리 16진수>
```

되돌릴 때 실행하는 `workflow_dispatch`와 운영자가 손으로 하는 배포는 태그 표기를 사용합니다.

```bash
sudo /opt/bnbong/deploy-image.sh auth-server ghcr.io/bngdrasil/bidar:sha-1a2b3c4
sudo /opt/bnbong/deploy-image.sh gateway     ghcr.io/bngdrasil/bifrost:sha-1a2b3c4
```

평소 release가 digest 표기를 쓰는 이유는, 같은 태그가 registry에서 나중에 다른 이미지로 덮여도
실제로 올라간 이미지가 달라지지 않기 때문입니다. `docker compose`는 `image: <이름>@sha256:...`
표기를 그대로 받으므로, 스크립트는 받은 참조를 가공하지 않고 `.env`에 그대로 기록합니다. 두 표기
모두 접두사가 `ghcr.io/bngdrasil/`이어야 하고, digest는 `sha256:` 뒤에 16진수 64자리가 와야
합니다. 형식이 맞지 않으면 스크립트가 종료 코드 2로 끝납니다.

`/opt/bnbong/deploy-image.sh`는 이 디렉터리의 `deploy-image.sh`와 같은 파일입니다. 이 스크립트는
인자와 이미지 참조 형식을 검증하고, `flock`으로 동시 실행을 막고, 이미지를 내려받고, 교체 직전 컨테이너의 이미지
ID를 `rollback/<컨테이너>:<UTC 시각>` 태그로 남기고, `.env`의 해당 이미지 변수 줄만 갱신한 다음,
`docker compose up -d --no-deps --no-build <서비스>`로 그 서비스만 교체합니다. health 확인에
실패하면 `.env`를 이전 내용으로 되돌리고 이전 이미지로 다시 기동한 뒤에 0이 아닌 코드로
종료합니다. 성공하면 `/opt/bnbong/releases.log`에 시각과 서비스와 이미지와 digest를 남깁니다.

운영자가 같은 명령을 손으로 실행해도 됩니다. GitHub Actions를 거치지 않고 특정 release로 되돌릴
때 이 방법을 사용합니다.

#### 설치와 권한 설정

`deploy-image.sh`는 `/opt/bnbong/deploy-image.sh`에 권한 755로 두고 소유자를 root로 유지해야
합니다. `install-deploy-image.sh`가 이 배치와 sudoers 설정을 함께 수행합니다.

```bash
scp deploy-image.sh install-deploy-image.sh ubuntu@<VM2_PUBLIC_IP>:/tmp/
ssh ubuntu@<VM2_PUBLIC_IP> 'sudo bash /tmp/install-deploy-image.sh /tmp/deploy-image.sh'
```

설치 스크립트는 `/etc/sudoers.d/bngdrasil-deploy`에 아래 한 줄만 기록하고, `visudo -cf`로 문법을
검사한 뒤에 설치합니다. 설치가 끝난 다음에는 `visudo -c`로 전체 설정을 한 번 더 검사합니다.

```
ubuntu ALL=(root) NOPASSWD: /opt/bnbong/deploy-image.sh
```

`ubuntu` 계정이 `deploy-image.sh` 자체를 수정할 수 있으면 이 `NOPASSWD` 권한이 사실상 제한 없는
root 권한으로 바뀝니다. 그래서 파일의 소유자를 root로 두고 쓰기 권한도 root에게만 줍니다.
스크립트를 새 판으로 바꿀 때에도 `install-deploy-image.sh`를 다시 실행하여 권한을 유지합니다.

### 대체 경로: 소스 현장 build

아래 절차는 GHCR 이미지를 사용할 수 없을 때에만 사용합니다. 평소 배포에는 위의 기본 경로를
사용하십시오.

#### 최초 배포

새로 만든 VM2에는 반드시 `chmod +x deploy.sh` 뒤에 `./deploy.sh --bootstrap`으로 먼저 배포해야
합니다. 일반 모드는 `up -d --no-deps`로 지정한 서비스만 교체하므로 Redis 컨테이너를 만들지 않습니다.
따라서 새 VM2에서 일반 모드로 시작하면 Gateway와 Auth Server가 연결할 Redis가 없고 health check의
`vm2-redis` ping도 실패합니다. `--bootstrap`은 `docker compose up -d`로 Redis를 포함한 stack
전체를 한 번 기동합니다. 이 옵션은 개별 서비스 이름과 함께 쓸 수 없으며, `all`도 같은 뜻으로
받습니다.

#### 재배포

```bash
./deploy.sh                   # auth-server와 gateway를 함께 교체합니다
./deploy.sh gateway           # gateway만 교체합니다
./deploy.sh auth-server       # auth-server만 교체합니다
VM2_HOST=1.2.3.4 ./deploy.sh  # Terraform output 대신 주소를 직접 지정합니다
```

일반 모드는 소스를 전송하기 전에 `vm2-redis` 컨테이너가 있는지 확인하고, 없으면
`./deploy.sh --bootstrap`을 안내한 뒤 0이 아닌 코드로 중단합니다.

스크립트는 VM2 주소와 로컬 자료를 확인하고, 대상 서비스의 소스와 `docker-compose.yml`을 전송하고,
교체 직전의 이미지를 롤백 태그로 남긴 뒤 build와 교체를 수행하고, 마지막으로 health check를
실행합니다. 전체 stack을 내리지 않으므로 volume과 나머지 서비스는 그대로 유지됩니다.

**운영 `.env`는 전송하지 않습니다.** 서버에 있는 값이 원본이며, 로컬 파일로 덮어쓰면 운영 비밀이
사라질 수 있습니다. 변수를 추가해야 하면 서버에서 직접 편집합니다.

---

## 5. 배포 후 확인

health check가 통과했더라도 아래 세 가지를 직접 확인합니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP>
cd /opt/bnbong && sudo docker compose ps
curl http://localhost:8000/health   # liveness. 프로세스가 응답할 수 있으면 항상 200입니다
curl http://localhost:8001/health
sudo docker exec vm2-redis redis-cli ping
curl -i http://localhost:8000/ready # readiness. Gateway 전용이며 DB와 등록부를 함께 확인합니다
```

`/ready`는 컨테이너가 살아 있어도 DB나 등록부가 준비되지 않으면 503을 돌려줍니다. 배포 후에는 이
응답이 200이고 상태가 `ready`인지까지 확인해야 합니다. 503이면 본문의 `database`와 `registry`
항목으로 원인을 구분합니다. `database`가 error이면 VM3 PostgreSQL 연결과 `DATABASE_URL`을,
`registry`가 degraded이면 `services` 테이블의 등록 내용을 확인합니다.

마지막으로 외부 진입 경로까지 확인하는 smoke 점검을 수행합니다. VM2의 포트에 직접 닿는 확인만으로는
VM1 Nginx와 Cloudflare를 거치는 실제 사용자 경로를 검증하지 못합니다. 관리자 화면에서 로그인과
목록 조회까지 한 번 해 보면 권한 판정과 토큰 발급 경로도 함께 확인할 수 있습니다.

```bash
curl -i https://api.bnbong.com/health        # VM1 Nginx의 gateway upstream
curl -i https://api.bnbong.com/auth/health   # VM1 Nginx의 auth_server upstream
```

### 전 사용자 재로그인 안내

`JWT_SECRET_KEY`를 새 값으로 교체했다면 기존에 발급한 access 토큰과 refresh 토큰이 모두 무효가
됩니다. **배포 직후 모든 사용자가 다시 로그인해야 합니다.** 관리자 화면도 마찬가지이므로 관리자
계정의 비밀번호를 배포 전에 확인해 두어야 합니다. 마이그레이션으로 `role`이나 `is_active`가 바뀐
계정은 재로그인한 뒤에 권한이 달라질 수 있습니다.

---

## 6. 롤백

`deploy-image.sh`와 `deploy.sh`는 모두 서비스를 교체하기 직전에 실행 중이던 이미지를
`rollback/<컨테이너>:<UTC 시각>` 태그로 남깁니다. `deploy-image.sh`는 태그가 아니라 컨테이너의
이미지 ID를 대상으로 태그를 붙이므로, 같은 태그가 registry에서 새 이미지로 덮인 뒤에도 이전
layer를 되찾을 수 있습니다. 이 태그는 컨테이너마다 다섯 개까지만 보관하고 오래된 것부터
제거합니다.

### 자동 롤백

`deploy-image.sh`의 health 확인이 실패하면 스크립트가 스스로 `.env`를 이전 내용으로 되돌리고 이전
이미지로 컨테이너를 다시 기동한 다음, 0이 아닌 코드로 종료합니다. 호출한 워크플로도 실패로
기록됩니다. 운영자는 서비스가 이전 상태로 돌아왔는지만 확인하면 됩니다.

### 손으로 되돌리는 절차

health 확인은 통과했지만 실제 동작에 문제가 있는 경우에는 아래와 같이 되돌립니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP>

sudo docker image ls 'rollback/vm2-gateway'   # 되돌릴 태그를 고릅니다
tail -5 /opt/bnbong/releases.log              # 최근 배포 이력을 확인합니다

cd /opt/bnbong
sudo sed -i 's|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=rollback/vm2-gateway:<시각>|' .env
sudo docker compose up -d --no-deps --no-build gateway
```

Auth Server를 되돌릴 때에는 `GATEWAY_IMAGE`를 `AUTH_SERVER_IMAGE`로, `gateway`를 `auth-server`로,
`vm2-gateway`를 `vm2-auth`로 바꿉니다. 이전 release의 GHCR 참조를 알고 있다면 롤백 태그 대신 그
참조를 직접 지정해도 됩니다. `releases.log`에 digest가 남아 있으므로 그 값을 그대로 쓸 수
있습니다. 롤백 태그는 VM2에만 있어서 호스트를 다시 만들면 사라지지만, GHCR 참조는 registry에 남아
있습니다.

되돌린 뒤에는 `/health`와 `/ready`를 다시 확인합니다. 데이터베이스 마이그레이션은 이 절차로
되돌아가지 않으므로, 스키마를 바꾼 배포를 되돌릴 때에는 이전 앱 버전이 새 스키마와 호환되는지를
먼저 판단해야 합니다.

---

## 7. 배포 후 정리

새 compose에는 `./bifrost/config` mount가 없습니다. 서비스 등록부의 원본이 PostgreSQL의 `services`
테이블로 옮겨졌고 Bifrost가 JSON 등록부를 읽지 않기 때문입니다. `vm2-gateway`가 정상 기동하고
`/ready`가 200을 돌려주는 것을 확인했다면 운영 VM2에 남은 구형 디렉터리를 삭제해도 됩니다.

```bash
ssh ubuntu@<VM2_PUBLIC_IP> 'ls -la /opt/bnbong/bifrost/config'   # 내용을 먼저 확인합니다
ssh ubuntu@<VM2_PUBLIC_IP> 'rm -rf /opt/bnbong/bifrost/config'   # 확인한 뒤에 삭제합니다
```

`/opt/bnbong/bifrost/.env`도 더 이상 필요하지 않습니다. 새 compose는 gateway의 환경 변수를
`/opt/bnbong/.env` 하나에서 공급하므로, 두 파일의 값이 서로 다르면 어느 쪽이 적용되었는지 판단하기
어려워집니다. 다만 이 파일에는 비밀 값이 들어 있으므로, 삭제하기 전에 `/opt/bnbong/.env`에 필요한
값이 모두 옮겨졌는지 먼저 확인하십시오.

---

## 8. Wegis compose 인수인계

`docker-compose.wegis-server.yml`은 현재 실행 중인 `wegis_server` 컨테이너를 재현하기 위해 정리한
파일이며, **아직 이 파일로 기동해 본 적이 없습니다.** 2026-09-18 실사에서 운영 중인
`wegis_server`에는 compose label이 전혀 없었고 `api-network`에 직접 연결되어 있었습니다. 즉 수동
`docker run`으로 기동되어 있었습니다.

파일을 실제로 적용할 때 네 가지를 확인해야 합니다. 첫째, 컨테이너 이름은 `wegis_server`여야
합니다. Bifrost 등록부가 목적지를 `http://wegis_server:9000`으로 지정하고 있으므로 이름이 달라지면
프록시가 끊깁니다. 둘째, 네트워크는 core compose가 만드는 `api-network`를 external로 사용합니다.
이전 판이 참조하던 `msa-network`는 VM2에 존재하지 않았습니다. 셋째, 접속 정보와 앱 설정은
`./Wegis_server/.env` 하나가 담당하며 모델은 `./Wegis_server/.deploy-assets/models`에서 읽습니다.
넷째, 9000번 포트는 loopback에만 게시합니다. VM1 Nginx는 Wegis에 직접 접근하지 않고 Gateway를
거치기 때문입니다.

기동과 중지는 `make add-service SERVICE=wegis-server`와 `make remove-service SERVICE=wegis-server`로
수행하며, `make restart-service SERVICE=wegis-server`로 재시작합니다.

`make clean`은 중지된 컨테이너와 dangling 이미지만 정리하고 volume에는 손대지 않습니다. volume을
지워야 한다면 대상을 직접 지정하고 백업을 먼저 확인합니다.

---

## 9. legacy 디렉터리와 관련 문서

`legacy/`에는 더 이상 배포 경로에서 사용하지 않는 파일이 있습니다. 과거 배포본을 해석할 때
참고하려고 남겨 두었을 뿐이며, 새 작업에서는 사용하지 않습니다. 보관 사유는
[legacy/README.md](legacy/README.md)에 적었습니다.

GitHub Actions가 수행하는 배포의 전체 구조와 저장소별 secret 구성, 최초 준비 절차는
[../docs/github-actions-setup.md](../docs/github-actions-setup.md)에 있습니다.

저장소 전체 구조와 Terraform 사용 절차는 [../README.md](../README.md)에 있습니다. 2026-09-18 기준의
실제 배포 상태는 [../docs/deployment-inventory.md](../docs/deployment-inventory.md)에,
관측 스택의 구성과 알림 규칙은 [../monitoring/README.md](../monitoring/README.md)에,
반복 백업 체계는 [../backup/README.md](../backup/README.md)에 있습니다.
