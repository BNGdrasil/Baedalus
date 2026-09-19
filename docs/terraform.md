# Terraform 운용

Baedalus에서 Terraform을 실행하는 절차와 state를 다루는 규칙을 설명합니다.

## 사용 절차

먼저 자격 증명을 준비합니다. 절차는 [OCI 준비 안내](../OCI_SETUP_GUIDE.md)에 있습니다.

```bash
make setup      # terraform.tfvars가 없으면 예시 파일을 복사합니다
make init       # terraform init
make fmt        # terraform fmt -recursive
make validate   # terraform validate
make plan       # terraform plan
```

`make plan`까지는 언제든 실행해도 안전합니다. `terraform validate`는 자격 증명 없이 구성만 검사하므로, 검증만 하려면 `terraform init -backend=false -input=false`로 초기화한 뒤에 실행합니다. GitHub Actions의 `Terraform Validation` 워크플로도 pull request에서 같은 검사를 수행하며, 포맷이 깨져 있으면 워크플로가 실패합니다.

## apply 전에 확인할 사항

state가 실제 자원과 어긋나 있으면 plan에 의도하지 않은 생성이나 삭제가 섞여 들어갈 수 있습니다. `make apply`를 실행하기 전에는 항상 아래 원칙을 따릅니다.

1. `terraform plan -refresh-only`를 먼저 실행해 실제 자원과 state 사이의 drift를 읽습니다. Terraform 코드에 정의하지 않은 규칙이나 이미 삭제된 자원이 있으면, 일반 apply는 코드에 없는 규칙을 제거하려 하거나 삭제된 자원을 다시 만들려고 시도합니다.
2. drift가 실제 상태를 정확히 반영한 것이 맞다면 `terraform apply -refresh-only`로 state만 갱신합니다. 이 단계는 인프라를 바꾸지 않고 state의 기록만 실제 상태에 맞춥니다.
3. state 사본을 남깁니다.
4. 일반 `terraform plan`을 실행해 의도하지 않은 생성과 삭제와 교체가 없는지 확인합니다.

### 교체 계획이 보이면 즉시 중단합니다

plan 출력을 apply하기 전에 plan을 파일로 저장하고 아래 세 문구를 반드시 검색해야 합니다.

```bash
terraform plan -no-color -out=tfplan | tee plan.txt
grep -nE 'must be replaced|forces replacement|will be destroyed' plan.txt
```

세 문구 중 하나라도 걸리면 그 자리에서 작업을 멈추고, 어떤 속성이 교체나 삭제를 유발했는지 원인을 먼저 규명해야 합니다. `oci_core_instance`의 교체는 기존 인스턴스를 종료한 뒤에 새 인스턴스를 만드는 절차이므로, 운영 중인 VM1과 VM2와 VM3에 이 계획이 나오면 서비스가 중단되고 데이터도 사라집니다. 교체가 정말로 필요하다고 판단한 경우에는 먼저 boot volume 백업과 데이터베이스 덤프를 확보하고, 그다음에 별도의 작업으로 분리해서 진행합니다.

VM1과 VM2와 VM3에는 `lifecycle` 블록에 `prevent_destroy = true`를 넣어 두었습니다. 따라서 교체나 삭제 계획이 잡히면 apply 이전 단계에서 plan 자체가 오류를 내고 멈춥니다. 이 오류는 방어 장치가 정상적으로 동작한 결과이므로, `prevent_destroy`를 지워서 통과시키는 방식으로 대응하면 안 됩니다.

### 2026-09-19 적용 기록

2026-09-19에는 운영자가 아래 순서로 실제 apply를 수행했습니다.

1. `make backup-state`로 state 사본을 남긴 뒤 `terraform init -input=false`를 실행했습니다. `main.tf`에 `backend "local"`을 선언해 두었기 때문에 이 초기화 절차가 필요하며, state의 저장 위치 자체는 바뀌지 않습니다.
2. `terraform plan -refresh-only`로 실제 자원과 state를 대조했습니다. VM5와 VM6가 `has been deleted`로 나와 OCI에 이미 존재하지 않음을 확인했고, 같은 출력에서 Terraform 밖에서 만들어진 drift도 함께 드러났습니다. route table 세 곳의 리전 간 DRG 경로, security list의 중복된 egress 규칙 두 건, VM3에 예정된 유지보수 재부팅 표시가 그것입니다.
3. `terraform apply -refresh-only`로 state만 갱신했습니다. 이 단계에서는 인프라를 바꾸지 않았으며, `terraform state rm`은 사용하지 않았습니다. 이후 `terraform state list`에는 인스턴스 네 개(VM1부터 VM4까지)만 남았습니다.
4. 일반 `terraform plan`을 실행하니 `0 to add, 8 to change, 0 to destroy`가 나왔고 교체와 삭제는 0건이었습니다. 다만 8건 중 route table 세 건은 운영 중인 DRG 경로를 제거하는 내용이었습니다. 아래 "Terraform 밖에서 관리되는 리전 간 DRG 경로"에 적은 대로 `chuncheon_drg_id`와 `osaka_drg_id` 변수와 `dynamic route_rules` 블록을 추가하고 `terraform.tfvars`에 두 OCID를 채운 뒤, plan이 `5 to change`(인스턴스 세 개의 `preserve_boot_volume`, security list 두 곳)로 줄어들었습니다.
5. `terraform apply`를 실행했습니다. 적용 후 `api`와 `admin` 도메인이 모두 200을 반환했고, 로컬에서 VM4로의 SSH와 VM3에서 VM2를 경유한 VM4로의 SSH가 모두 정상 동작함을 확인했습니다.

### 2026-09-19에 확인한 교체 위험과 대응

2026-09-19 보수 작업에서 `scripts/user_data_vm2.sh`와 `user_data_vm3.sh`와 `user_data_vm4.sh`를 수정했습니다. 이 세 파일은 각 인스턴스의 `metadata.user_data`로 들어가는 cloud-init 스크립트이며, OCI provider는 `metadata`가 바뀌면 인스턴스를 교체합니다. 당시 모든 인스턴스가 `preserve_boot_volume = false`였고 VM3는 호스트 PostgreSQL 데이터를 boot volume 위에 두고 있었으므로, 그대로 apply했다면 운영 중인 VM2와 VM3가 파괴되고 데이터베이스도 함께 사라졌을 것입니다.

같은 날 아래 세 가지를 적용해서 이 위험을 막았습니다.

- VM1부터 VM6까지 모든 `oci_core_instance`의 `lifecycle.ignore_changes`에 `metadata`를 추가했습니다. `metadata["user_data"]`만 지정하지 않고 `metadata` 전체를 지정한 이유는, `ssh_authorized_keys`가 바뀌어도 똑같이 교체가 일어나기 때문입니다. cloud-init은 최초 부팅에서 한 번만 실행되므로 실행 중인 인스턴스의 구성에는 영향을 주지 않으며, 구성 변경은 `scripts/` 아래의 배포 스크립트가 담당합니다.
- VM1과 VM2와 VM3에 `prevent_destroy = true`를 넣었습니다. `count`를 사용하는 VM5와 VM6에는 넣지 않았습니다. 그 두 리소스는 오히려 state에서 제거해야 하는 대상이기 때문입니다.
- VM1과 VM2와 VM3의 `preserve_boot_volume`을 `true`로 바꿨습니다. `oracle/oci` provider 5.47.0에서 이 속성은 ForceNew로 선언되어 있지 않고 terminate 요청에서만 사용되므로, 값 변경은 in-place update로 처리됩니다. 다만 provider 버전이 올라가면 동작이 달라질 수 있으므로, apply하기 전에 plan 출력에서 이 속성의 변경이 교체가 아니라 update로 표시되는지 반드시 눈으로 확인해야 합니다.

`ignore_changes = [metadata]`를 넣은 뒤에도 cloud-init 스크립트를 고치는 작업 자체는 계속 의미가 있습니다. 새 인스턴스를 만들 때 그 스크립트가 그대로 사용되기 때문입니다. 반대로 실행 중인 인스턴스에 스크립트 수정 내용을 반영하려면 해당 VM에 접속해서 직접 적용해야 합니다.

### 2026-09-19: Terraform 밖에서 관리되는 리전 간 DRG 경로

같은 날 `terraform apply -refresh-only`로 state를 실제 자원에 맞춘 뒤, 이어서 실행한 `terraform plan`이 route table 세 개에서 리전 간 경로를 제거하겠다고 보고했습니다. 대상은 `chuncheon_private_rt`와 `chuncheon_public_rt`의 `10.1.0.0/16` 경로, 그리고 `osaka_private_rt`의 `10.0.0.0/16` 경로였습니다. 세 경로 모두 콘솔에서 수동으로 만든 DRG를 가리킵니다.

이 경로들은 VM2와 VM4 사이의 통신과 오프사이트 백업 경로를 실제로 담당하고 있으므로, 제거되면 리전 간 연결이 끊어집니다. 원인은 DRG와 RPC가 Terraform 관리 대상이 아니어서 route table 정의에 해당 rule이 빠져 있었다는 점입니다. Terraform은 route table 자체를 관리하므로, 정의에 없는 rule을 잉여 상태로 판단하고 삭제하려고 시도합니다.

대응으로 `network.tf`의 route table 세 곳에 `dynamic "route_rules"` 블록을 넣고, `chuncheon_drg_id`와 `osaka_drg_id` 변수가 비어 있지 않을 때에만 DRG 경로를 생성하도록 했습니다. 두 변수의 기본값은 빈 문자열입니다. 따라서 `chuncheon_drg_id`와 `osaka_drg_id`를 `terraform.tfvars`에 넣지 않으면 plan이 이 경로를 제거합니다.

```hcl
# terraform.tfvars
chuncheon_drg_id = "<춘천 DRG OCID>"
osaka_drg_id     = "<오사카 DRG OCID>"
```

두 OCID는 OCI 콘솔의 Dynamic Routing Gateway 화면에서 조회하거나, `terraform plan` 및 `terraform apply -refresh-only` 출력에 표시된 `network_entity_id` 값에서 그대로 옮겨 적으면 됩니다. 값을 채운 뒤에 plan을 다시 실행하면 route table 세 개가 변경 목록에서 사라집니다.

DRG와 RPC 자원 자체는 이번 작업에서 import하지 않았습니다. 두 자원은 계속 콘솔에서 수동으로 관리합니다. 따라서 콘솔에서 DRG를 다시 만들면 OCID가 바뀌고, 그때는 `terraform.tfvars`의 값도 함께 갱신해야 합니다.

### state 정리 후에 기대되는 plan

VM5와 VM6를 state에서 제거한 뒤에도 plan이 `No changes.`를 보고하지 않을 수 있습니다. security list의 8000번과 8001번 포트 규칙을 `api_client_cidr`로 좁힌 변경이 아직 실제 자원에 반영되어 있지 않다면, 그 규칙이 in-place update로 남아 있게 됩니다. `preserve_boot_volume`을 `true`로 바꾼 변경도 같은 방식으로 세 건의 update로 표시됩니다.

따라서 정리가 끝난 시점에 확인해야 할 기준은 `No changes.`가 아니라 다음 두 가지입니다.

- plan 출력에 `must be replaced`와 `forces replacement`와 `will be destroyed`가 하나도 없습니다.
- 남아 있는 변경이 전부 내용을 설명할 수 있는 in-place update입니다.

설명할 수 없는 변경이 하나라도 섞여 있으면 apply하지 말고 원인을 먼저 확인합니다.

## state 백업

state에는 OCI 자원 주소와 민감한 변수 값이 들어 있습니다. apply 전후에 사본을 남깁니다.

```bash
make backup-state   # state-backups/terraform.tfstate.<UTC 시각>에 사본을 만듭니다
```

state를 잃으면 현재 관리 중인 자원의 주소를 되찾을 수 없고, 이후 apply가 이미 존재하는 자원을 다시 만들려고 시도합니다. `make clean`과 `make clean-all`은 `.terraform` 캐시와 lock 파일만 정리하며 state 파일에는 손대지 않습니다. `.gitignore`가 `*.tfstate`를 제외하고 있으므로 사본이 공개 저장소에 올라가지 않습니다.

backend는 `main.tf`에서 local backend로 명시했습니다. remote backend는 아직 도입하지 않았습니다. 도입하려면 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저 확인해야 합니다.

## VM5와 VM6의 state 정리

`enable_vm5`와 `enable_vm6`가 false이면 두 리소스의 `count`가 0이 됩니다. state에 두 인스턴스가 남아 있는데 실제 OCI 자원이 이미 삭제되어 있다면, `terraform plan -refresh-only`가 두 인스턴스를 `has been deleted`로 보고합니다. 이때는 `terraform apply -refresh-only`를 실행하면 Terraform이 두 인스턴스를 state에서 직접 제거하므로, 실제 자원이 없다는 사실을 Terraform이 스스로 확인하고 반영하게 하는 방법이 됩니다. `moved` 블록으로는 이 정리를 대신할 수 없습니다. `moved`는 같은 구성 안에서 리소스 주소를 옮길 때 쓰는 기능이고, 여기에서 필요한 조치는 관리 대상에서 완전히 제외하는 작업이기 때문입니다.

```bash
# 1) 오사카 compartment에서 두 인스턴스가 실제로 없는지 확인합니다
oci compute instance list \
  --compartment-id <오사카 compartment OCID> \
  --region ap-osaka-1

# 2) state 사본을 만든 뒤 refresh-only로 drift를 확인합니다
make backup-state
terraform plan -refresh-only

# 3) 두 인스턴스가 "has been deleted"로 표시되면 apply로 state를 갱신합니다
terraform apply -refresh-only

# 4) 두 인스턴스가 state에서 사라졌는지 확인합니다
terraform state list | grep -E 'vm5_backup|vm6_playground'

# 5) plan에 교체 계획이 없는지 확인합니다
terraform plan -no-color -out=tfplan | tee plan.txt
grep -nE 'must be replaced|forces replacement|will be destroyed' plan.txt
```

`terraform apply -refresh-only`로도 인스턴스가 state에서 사라지지 않는다면, `terraform state rm oci_core_instance.vm5_backup oci_core_instance.vm6_playground`를 대안으로 사용합니다. 이 명령은 refresh로 해결되지 않을 때에만 사용합니다.

자원이 남아 있다면 1번에서 멈추고 삭제 여부를 먼저 결정합니다. 5번에서 `No changes.`가 나오지 않더라도 곧바로 문제라고 판단하지는 않습니다. 위의 "state 정리 후에 기대되는 plan"에 적은 대로, security list 규칙과 `preserve_boot_volume` 변경이 in-place update로 남아 있을 수 있기 때문입니다. 설명할 수 없는 변경이 보이면 apply하지 말고 원인을 먼저 확인합니다. 2026-09-19에 위 절차로 VM5와 VM6를 state에서 정리했습니다.

## CI에서 plan과 apply를 하지 않는 이유

`Terraform Validation` 워크플로에는 `plan`과 `apply` 단계를 두지 않았습니다. state가 저장소 바깥의 로컬 파일인 `terraform.tfstate`에만 있어서, runner에는 현재 관리 중인 자원 정보가 전혀 없기 때문입니다. 그 상태로 `plan`을 실행하면 이미 존재하는 자원을 새로 만들겠다는 계획이 나옵니다. 그 계획을 그대로 `apply`하면 운영 인프라가 훼손됩니다.

원격 backend로 state를 옮긴 뒤에 다시 검토합니다. OCI Object Storage의 S3 호환 endpoint를 backend로 사용할 수 있으며, 도입하기 전에 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저 확인해야 합니다. 위의 "VM5와 VM6의 state 정리"는 2026-09-19에 끝냈지만, 원격 backend 도입 자체는 아직 시작하지 않았습니다.
