# Baedalus

Baedalus는 BNGdrasil 프로젝트의 인프라를 코드로 관리하는 저장소입니다. 다음 네 가지를 한곳에서
다룹니다.

- Oracle Cloud Infrastructure(OCI)의 네트워크와 컴퓨트 인스턴스를 Terraform으로 정의합니다.
- 각 VM의 cloud-init 부트스트랩 스크립트를 `scripts/`에 둡니다. 이 스크립트는 호스트 준비까지만
  담당하며 애플리케이션 release는 다루지 않습니다.
- VM2에서 동작하는 애플리케이션(Bifrost 게이트웨이, Bidar 인증 서버, Redis)의 배포 정의를
  `vm2-deployment/`에 둡니다.
- VM2의 관측 스택과 VM3의 반복 백업 체계를 각각 `monitoring/`과 `backup/`에 둡니다.
- GitHub Actions로 배포를 수행하는 워크플로와 그 서버 측 스크립트를 `.github/workflows/`와
  `vm2-deployment/`에 둡니다. 전체 구조와 최초 준비 절차는
  [GitHub Actions 배포 설정](docs/github-actions-setup.md)에 있습니다.

문서에 적힌 값은 2026-09-18에 운영 서버를 읽기 전용으로 관측한 결과를 기준으로 삼습니다. 실제
컨테이너와 이미지와 마운트의 기준선은 [배포 기준선](docs/deployment-inventory.md)에 있습니다.

---

## 실제 운영 VM 구성

Terraform 정의에는 VM1부터 VM6까지 여섯 대가 들어 있지만, 실제로 운영에 쓰이는 VM은 VM1과 VM2와
VM3 세 대뿐입니다. 설계 문서에 적힌 여섯 대 구성과 현재 상태를 혼동하지 않아야 합니다.

| VM | 리전, subnet | private IP | 현재 상태와 역할 |
|---|---|---|---|
| VM1 | 춘천 public | 10.0.1.133 | 운영 중입니다. Nginx가 단일 진입점을 맡고 정적 사이트를 서비스합니다. |
| VM2 | 춘천 public | 10.0.1.60 | 운영 중입니다. Bidar, Bifrost, Wegis, Overlock, Redis, 관측 스택이 동작합니다. |
| VM3 | 춘천 private | 10.0.2.134 | 운영 중입니다. 호스트 PostgreSQL 14와 호스트 mongod와 Redis 컨테이너가 있습니다. |
| VM4 | 오사카 private | 10.1.2.111 | 미구성 예비 자원입니다. SSH로 접속은 되지만 Docker와 `/opt/bnbong`이 없습니다. |
| VM5 | 오사카 private | state상 10.1.2.3 | 퇴역 이력이 있습니다. `enable_vm5` 기본값이 false입니다. |
| VM6 | 오사카 private | state상 10.1.2.229 | 퇴역 이력이 있습니다. `enable_vm6` 기본값이 false입니다. |

VM4는 replica나 재해 복구 자원으로 계산하지 않습니다. 빈 자원을 유지하는 비용과 복구 이점을
비교한 뒤에 유지 여부를 결정해야 합니다.

VM5와 VM6는 운영자 설명상 삭제한 인스턴스이며 OCPU를 다른 인스턴스로 합쳤다고 합니다. 다만
로컬 `terraform.tfstate`에는 두 인스턴스가 여전히 `RUNNING` 상태로 남아 있습니다. 즉 state와
실제 OCI 자원이 어긋나 있으므로, 실제 자원을 조회해 state와 맞추기 전에는 apply하지 않습니다.
정리 절차는 아래 "VM5와 VM6의 state 정리"에 적었습니다.

---

## 디렉터리 구조

```
baedalus/
├── main.tf                     provider 정의, availability domain과 image data source
├── variables.tf                변수 정의. enable_vm5, enable_vm6, admin_cidr, api_client_cidr 포함
├── network.tf                  VCN, subnet, route table, security list
├── chuncheon.tf                VM1, VM2, VM3 인스턴스 정의
├── osaka.tf                    VM4 인스턴스 정의와 비활성 상태의 VM5, VM6 정의
├── outputs.tf                  IP 주소, SSH 명령, 자원 요약 출력
├── Makefile                    init, plan, fmt, validate, backup-state 등 자동화 명령
├── terraform.tfvars.example    tfvars 템플릿. 실제 값은 추적하지 않습니다
├── scripts/                    VM별 cloud-init 스크립트와 정적 사이트 배포 스크립트
│   └── legacy/                 더 이상 호출하지 않는 스크립트 보관소
├── vm2-deployment/             VM2 애플리케이션 release(compose, deploy.sh, env.template)
│   └── legacy/                 대체된 서비스 등록 방식의 보관소
├── monitoring/                 VM2 관측 스택(Prometheus, Grafana, Loki, Promtail, exporter)
├── backup/                     VM3와 VM2의 반복 백업 스크립트와 systemd 유닛
├── docs/                       배포 기준선 문서와 GitHub Actions 배포 설정 안내
└── .github/workflows/          Terraform 검증과 모니터링, 백업 배포 워크플로
```

---

## Terraform 사용 절차

먼저 자격 증명을 준비합니다. 절차는 [OCI 준비 안내](OCI_SETUP_GUIDE.md)에 있습니다.

```bash
make setup      # terraform.tfvars가 없으면 예시 파일을 복사합니다
make init       # provider plugin을 내려받습니다
make fmt        # terraform fmt -recursive
make validate   # terraform validate
make plan       # 변경 계획을 확인합니다
```

`make plan`까지는 언제든 실행해도 안전합니다. `terraform validate`는 자격 증명 없이도 구성만
검사하며, GitHub Actions의 `Terraform Validation` 워크플로도 pull request에서 같은 검사를
수행합니다. 포맷이 깨져 있으면 워크플로가 실패합니다.

### CI에서 plan과 apply를 하지 않는 이유

`Terraform Validation` 워크플로에는 `plan`과 `apply` 단계를 두지 않았습니다. state가 저장소 바깥의
로컬 파일인 `terraform.tfstate`에만 있어서, runner에는 현재 관리 중인 자원 정보가 전혀 없기
때문입니다. 그 상태로 `plan`을 실행하면 이미 존재하는 자원을 새로 만들겠다는 계획이 나오고, 그
계획을 그대로 `apply`하면 운영 인프라가 훼손됩니다.

원격 backend로 state를 옮긴 뒤에 다시 검토합니다. OCI Object Storage의 S3 호환 endpoint를
backend로 사용할 수 있으며, 도입하기 전에 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금
지원을 먼저 확인해야 합니다. 아래 "VM5와 VM6의 state 정리"를 끝내기 전에는 이전 작업도 시작하지
않습니다.

### apply는 state 대조를 마친 뒤에 실행합니다

**현재 상태에서 `make apply`를 실행하면 안 됩니다.** state에 남아 있는 VM5와 VM6가 실제 자원과
어긋나 있어서, plan에 의도하지 않은 생성이나 삭제가 섞여 들어갈 수 있습니다. 아래 순서를 먼저
끝내야 합니다.

1. OCI 콘솔이나 CLI로 `vm5-backup`과 `vm6-sandbox` 인스턴스, 그리고 남은 boot volume의 잔존
   여부를 조회합니다.
2. state 사본을 남깁니다.
3. state를 실제 자원과 맞춥니다.
4. `terraform plan`에 의도하지 않은 생성과 삭제와 교체가 없는지 확인합니다.

### state 백업

state에는 OCI 자원 주소와 민감한 변수 값이 들어 있습니다. apply 전후에 사본을 남깁니다.

```bash
make backup-state   # state-backups/terraform.tfstate.<UTC 시각>에 사본을 만듭니다
```

state를 잃으면 현재 관리 중인 자원의 주소를 되찾을 수 없고, 이후 apply가 이미 존재하는 자원을
다시 만들려고 시도합니다. `make clean`과 `make clean-all`은 `.terraform` 캐시와 lock 파일만
정리하며 state 파일에는 손대지 않습니다. `.gitignore`가 `*.tfstate`를 제외하고 있으므로 사본을
공개 저장소에 올리지 않습니다.

backend는 `main.tf`에서 local backend로 명시했습니다. remote backend는 아직 도입하지 않았으며,
도입하려면 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저 확인해야 합니다.

---

## VM5와 VM6의 state 정리

`enable_vm5`와 `enable_vm6`가 false이면 두 리소스의 `count`가 0이 됩니다. 그런데 state에는 두
인스턴스가 남아 있으므로 plan에는 destroy하겠다는 내용이 표시됩니다. `moved` 블록으로는 이 표시를
없앨 수 없습니다. `moved`는 같은 구성 안에서 리소스 주소를 옮길 때 쓰는 기능이고, 여기에서 필요한
것은 관리 대상에서 제외하는 조치이기 때문입니다.

```bash
# 1) 오사카 compartment에서 두 인스턴스가 실제로 없는지 확인합니다
oci compute instance list \
  --compartment-id <오사카 compartment OCID> \
  --region ap-osaka-1

# 2) 남은 boot volume도 함께 확인합니다
oci bv boot-volume list \
  --compartment-id <오사카 compartment OCID> \
  --availability-domain <AD 이름> \
  --region ap-osaka-1

# 3) 자원이 없다면 state 사본을 만든 뒤 state에서만 제거합니다
make backup-state
terraform state rm oci_core_instance.vm5_backup oci_core_instance.vm6_playground

# 4) plan이 No changes.를 보고하는지 확인합니다
terraform plan
```

자원이 남아 있다면 3번에서 멈추고 삭제 여부를 먼저 결정합니다. 다른 변경이 보이면 apply하지 말고
원인을 먼저 확인합니다. 이 저장소의 작업에서는 위 절차를 아직 실행하지 않았습니다.

---

## 보안 규칙 변수

security list의 접근 범위를 두 변수로 조정합니다.

| 변수 | 기본값 | 적용 대상과 주의점 |
|---|---|---|
| `admin_cidr` | `0.0.0.0/0` | 춘천 public subnet의 SSH(22번 포트) 출처입니다. 기본값은 현행 설정을 그대로 유지한 값이므로, 관리 접근 경로를 확인한 뒤에 좁혀야 합니다. 확인 없이 좁히면 운영자가 VM에 접속하지 못하게 됩니다. |
| `api_client_cidr` | `10.0.1.0/24` | VM2의 Gateway(8000)와 Auth Server(8001)에 접근할 수 있는 출처입니다. 실제 호출자는 춘천 public subnet의 VM1 Nginx뿐입니다. |

### SEC-04의 현재 범위

`api_client_cidr`로 8000과 8001의 출처를 좁혔지만, 같은 security list에는 VCN 전체
(`10.0.0.0/16`)에 모든 프로토콜을 허용하는 "Internal communication" 규칙이 그대로 남아 있습니다.
**따라서 이번 제한으로 차단되는 것은 외부 인터넷에서 오는 직접 접근까지입니다.** 같은 VCN 안의
VM은 여전히 VM2의 모든 포트에 도달할 수 있으며, 예를 들어 춘천 private subnet의 VM3에서 VM2의
8000 포트로 연결할 수 있습니다.

이 내부 규칙은 아직 바꾸지 않았습니다. VM1과 VM2와 VM3 사이에 실제로 필요한 포트와 방향을 먼저
검증하지 않은 상태에서 좁히면 운영 중인 통신을 끊을 수 있기 때문입니다. 후속 작업에서 필요한
포트만 남기는 형태로 분해합니다.

---

## 비용

이 구성은 OCI Always Free 자원만 사용하도록 설계했습니다. 다만 **무료라고 단정할 수 없습니다.**
Always Free 한도는 계정과 리전과 가입 시점에 따라 다르고, 무료 평가판 기간이 끝난 뒤 자원이
유료로 전환되는 경우도 있습니다. 실제 청구 금액과 Always Free 조건과 home region을 계정마다 직접
확인해야 하며, 이 확인은 아직 끝나지 않았습니다. OCI 콘솔의 Cost Analysis와 Budgets에서 현재
사용량을 조회하고 예산 알림을 설정해 두기를 권장합니다.

---

## 하위 문서

| 문서 | 다루는 내용 |
|---|---|
| [OCI_SETUP_GUIDE.md](OCI_SETUP_GUIDE.md) | OCI 계정과 API 키와 `terraform.tfvars`를 준비하는 절차를 설명합니다. |
| [docs/github-actions-setup.md](docs/github-actions-setup.md) | 저장소별 배포 워크플로의 역할과 secret 구성, 최초 준비 절차, 롤백 절차를 설명합니다. |
| [docs/deployment-inventory.md](docs/deployment-inventory.md) | 2026-09-18 기준의 실제 배포 기준선입니다. 컨테이너, 이미지, 네트워크, 마운트를 기록했습니다. |
| [vm2-deployment/README.md](vm2-deployment/README.md) | VM2의 Gateway와 Auth Server를 배포하고 확인하고 되돌리는 절차를 설명합니다. |
| [monitoring/README.md](monitoring/README.md) | VM2 관측 스택의 구성과 알림 규칙과 접근 방법을 설명합니다. |
| [backup/README.md](backup/README.md) | VM3와 VM2의 반복 백업 체계와 복원 훈련 절차를 설명합니다. |
| [scripts/legacy/README.md](scripts/legacy/README.md) | 더 이상 호출하지 않는 부트스트랩 스크립트의 보관 사유를 적었습니다. |
| [vm2-deployment/legacy/README.md](vm2-deployment/legacy/README.md) | 대체된 서비스 등록 방식의 보관 사유를 적었습니다. |

관련 저장소는 다음과 같습니다. [Bifrost](https://github.com/BNGdrasil/Bifrost)가 API 게이트웨이를,
[Bidar](https://github.com/BNGdrasil/Bidar)가 인증 서버를,
[Bantheon](https://github.com/BNGdrasil/Bantheon)이 웹 클라이언트와 VM1 Nginx 설정을 담당합니다.
