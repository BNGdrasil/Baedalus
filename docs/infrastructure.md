# 인프라 구성

Baedalus가 관리하는 OCI 자원의 현재 상태와 네트워크 접근 규칙을 설명합니다.

문서에 적힌 운영 상태는 2026-09-18에 운영 서버를 읽기 전용으로 관측한 결과를 기준으로 삼습니다.

## 운영 VM 구성

Terraform 정의에는 VM1부터 VM6까지 여섯 대가 들어 있습니다. 그러나 실제로 운영에 쓰이는 VM은 VM1과 VM2와 VM3 세 대뿐입니다. 설계 문서에 적힌 여섯 대 구성과 현재 상태를 혼동하지 않아야 합니다.

| VM | 리전, subnet | private IP | 현재 상태와 역할 |
|---|---|---|---|
| VM1 | 춘천 public | 10.0.1.133 | 운영 중입니다. Nginx가 단일 진입점을 맡고 정적 사이트를 서비스합니다. |
| VM2 | 춘천 public | 10.0.1.60 | 운영 중입니다. Bidar, Bifrost, Wegis, Overlock, Redis, 관측 스택이 동작합니다. |
| VM3 | 춘천 private | 10.0.2.134 | 운영 중입니다. 호스트 PostgreSQL 14와 호스트 mongod와 Redis 컨테이너가 있습니다. |
| VM4 | 오사카 private | 10.1.2.111 | 미구성 예비 자원입니다. SSH로 접속은 되지만 Docker와 `/opt/bnbong`이 없습니다. |
| VM5 | 오사카 private | 정리 전 state상 10.1.2.3 | 퇴역했습니다. `enable_vm5` 기본값이 false이며, 2026-09-19에 state에서도 정리했습니다. |
| VM6 | 오사카 private | 정리 전 state상 10.1.2.229 | 퇴역했습니다. `enable_vm6` 기본값이 false이며, 2026-09-19에 state에서도 정리했습니다. |

VM4는 replica나 재해 복구 자원으로 계산하지 않습니다. 빈 자원을 유지하는 비용과 복구 이점을 비교한 뒤에 유지 여부를 결정해야 합니다. `variables.tf`의 `vm_configs`에는 VM4의 display name이 `vm4-monitoring`으로 적혀 있지만, 실제 관측 스택은 VM2에서 동작합니다.

VM5와 VM6는 운영자 설명상 삭제한 인스턴스이며, OCPU를 다른 인스턴스로 합쳤다고 합니다. 로컬 `terraform.tfstate`에는 한동안 두 인스턴스가 `RUNNING` 상태로 남아 있어서 state와 실제 OCI 자원이 어긋나 있었습니다. 2026-09-19에 `terraform plan -refresh-only`로 두 인스턴스가 OCI에 실제로 존재하지 않음(`has been deleted`)을 확인했고, 이어서 `terraform apply -refresh-only`로 state를 갱신해 두 인스턴스를 state에서도 제거했습니다. 이제 `terraform state list`에는 VM1부터 VM4까지 네 개의 인스턴스만 남아 있습니다. 정리 절차는 [Terraform 운용](terraform.md)에 적었습니다.

### 인스턴스 교체 방지 설정

`oci_core_instance`는 `metadata`가 바뀌면 교체됩니다. 교체는 기존 인스턴스를 종료한 뒤에 새 인스턴스를 만드는 절차이므로, 운영 중인 VM에 적용되면 서비스가 중단되고 boot volume 위의 데이터도 사라집니다. 이 사고를 막기 위해 2026-09-19에 아래 설정을 넣었습니다.

| 설정 | 적용 대상 | 목적 |
|---|---|---|
| `lifecycle.ignore_changes`에 `metadata` 추가 | VM1부터 VM6까지 전부 | cloud-init 스크립트나 SSH 공개 키를 고쳐도 교체 계획이 생기지 않게 합니다. |
| `prevent_destroy = true` | VM1, VM2, VM3 | 교체나 삭제 계획이 잡히면 apply 이전에 plan이 오류를 내고 멈춥니다. |
| `preserve_boot_volume = true` | VM1, VM2, VM3 | 인스턴스를 종료해야 하는 상황에서도 boot volume과 그 안의 데이터를 남깁니다. |

`count`를 사용하는 VM5와 VM6에는 `prevent_destroy`를 넣지 않았습니다. 그 두 리소스는 state에서 제거해야 하는 대상이므로, 삭제를 막으면 정리 작업이 오히려 진행되지 않기 때문입니다. cloud-init은 최초 부팅에서 한 번만 실행되므로, 실행 중인 인스턴스의 구성은 `scripts/` 아래의 배포 스크립트가 담당합니다. 자세한 경위와 apply 전 점검 절차는 [Terraform 운용](terraform.md)에 적었습니다.

## 네트워크

`network.tf`가 두 리전의 VCN과 subnet과 라우팅을 정의합니다.

| 자원 | CIDR | 설명 |
|---|---|---|
| 춘천 VCN | `10.0.0.0/16` | Internet Gateway와 NAT Gateway를 함께 둡니다. |
| 춘천 public subnet | `10.0.1.0/24` | VM1과 VM2가 속합니다. |
| 춘천 private subnet | `10.0.2.0/24` | VM3가 속하며 NAT Gateway로만 외부에 나갑니다. |
| 오사카 VCN | `10.1.0.0/16` | NAT Gateway만 둡니다. |
| 오사카 private subnet | `10.1.2.0/24` | VM4와 퇴역한 VM5, VM6가 속합니다. |

### 리전 간 연결

춘천 VCN과 오사카 VCN은 DRG(Dynamic Routing Gateway)와 RPC(Remote Peering Connection)로 연결되어 있습니다. 두 자원은 OCI 콘솔에서 수동으로 만들었으며 Terraform이 관리하지 않습니다. 이 연결을 통해 VM2와 VM4가 통신하고 오프사이트 백업 경로가 동작합니다.

route table에 들어가는 경로는 Terraform이 관리합니다. 다음 세 rule이 리전 간 통신을 담당합니다.

| route table | 목적지 CIDR | next hop |
|---|---|---|
| `chuncheon_public_rt` | `10.1.0.0/16` (오사카 VCN) | 춘천 DRG |
| `chuncheon_private_rt` | `10.1.0.0/16` (오사카 VCN) | 춘천 DRG |
| `osaka_private_rt` | `10.0.0.0/16` (춘천 VCN) | 오사카 DRG |

세 rule은 `chuncheon_drg_id`와 `osaka_drg_id` 변수 값을 next hop으로 사용하며, 변수가 비어 있으면 생성되지 않습니다. 두 변수를 `terraform.tfvars`에 채우지 않은 상태로 apply하면 실제로 동작하고 있는 리전 간 경로가 제거됩니다. 2026-09-19의 refresh 작업에서 이 위험을 확인했고, 같은 날 두 변수에 실제 DRG OCID를 채운 뒤 apply해서 해소했습니다. 자세한 경위는 [Terraform 운용](terraform.md)에 적었습니다.

DRG와 RPC 자체는 아직 import하지 않았습니다. 따라서 콘솔에서 DRG를 다시 만들면 OCID가 바뀌고, 그때는 두 변수 값도 함께 갱신해야 합니다.

## 보안 규칙 변수

security list의 접근 범위를 두 변수로 조정합니다.

| 변수 | 기본값 | 적용 대상과 주의점 |
|---|---|---|
| `admin_cidr` | `0.0.0.0/0` | 춘천 public subnet의 SSH(22번 포트) 출처입니다. 기본값은 현행 설정을 그대로 유지한 값이므로, 관리 접근 경로를 확인한 뒤에 좁혀야 합니다. 확인 없이 좁히면 운영자가 VM에 접속하지 못하게 됩니다. |
| `api_client_cidr` | `10.0.1.0/24` | VM2의 Gateway(8000)와 Auth Server(8001)에 접근할 수 있는 출처입니다. 실제 호출자는 춘천 public subnet의 VM1 Nginx뿐입니다. |

## SEC-04의 현재 범위

`api_client_cidr`로 8000번과 8001번 포트의 출처를 좁혔습니다. 그러나 같은 security list에는 VCN 전체(`10.0.0.0/16`)에 모든 프로토콜을 허용하는 "Internal communication" 규칙이 그대로 남아 있습니다. 따라서 이번 제한으로 차단되는 범위는 외부 인터넷에서 오는 직접 접근까지입니다. 같은 VCN 안의 VM은 여전히 VM2의 모든 포트에 도달할 수 있습니다. 예를 들어 춘천 private subnet의 VM3에서 VM2의 8000번 포트로 연결할 수 있습니다.

이 내부 규칙은 아직 바꾸지 않았습니다. VM1과 VM2와 VM3 사이에 실제로 필요한 포트와 방향을 먼저 검증하지 않은 상태에서 좁히면 운영 중인 통신을 끊을 수 있기 때문입니다. 후속 작업에서 필요한 포트만 남기는 형태로 분해합니다.

## 비용

이 구성은 OCI Always Free 자원만 사용하도록 설계했습니다. 다만 무료라고 단정할 수 없습니다. Always Free 한도는 계정과 리전과 가입 시점에 따라 다르고, 무료 평가판 기간이 끝난 뒤에 자원이 유료로 전환되는 경우도 있습니다. 실제 청구 금액과 Always Free 조건과 home region을 계정마다 직접 확인해야 하며, 이 확인은 아직 끝나지 않았습니다. OCI 콘솔의 Cost Analysis와 Budgets에서 현재 사용량을 조회하고 예산 알림을 설정해 두기를 권장합니다.
