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

현재 상태에서 `make apply`를 실행하면 안 됩니다. state에 남아 있는 VM5와 VM6가 실제 자원과 어긋나 있어서, plan에 의도하지 않은 생성이나 삭제가 섞여 들어갈 수 있습니다. 아래 순서를 먼저 끝내야 합니다.

1. OCI 콘솔이나 CLI로 `vm5-backup`과 `vm6-sandbox` 인스턴스, 그리고 남은 boot volume의 잔존 여부를 조회합니다.
2. state 사본을 남깁니다.
3. state를 실제 자원과 맞춥니다.
4. `terraform plan`에 의도하지 않은 생성과 삭제와 교체가 없는지 확인합니다.

## state 백업

state에는 OCI 자원 주소와 민감한 변수 값이 들어 있습니다. apply 전후에 사본을 남깁니다.

```bash
make backup-state   # state-backups/terraform.tfstate.<UTC 시각>에 사본을 만듭니다
```

state를 잃으면 현재 관리 중인 자원의 주소를 되찾을 수 없고, 이후 apply가 이미 존재하는 자원을 다시 만들려고 시도합니다. `make clean`과 `make clean-all`은 `.terraform` 캐시와 lock 파일만 정리하며 state 파일에는 손대지 않습니다. `.gitignore`가 `*.tfstate`를 제외하고 있으므로 사본이 공개 저장소에 올라가지 않습니다.

backend는 `main.tf`에서 local backend로 명시했습니다. remote backend는 아직 도입하지 않았습니다. 도입하려면 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저 확인해야 합니다.

## VM5와 VM6의 state 정리

`enable_vm5`와 `enable_vm6`가 false이면 두 리소스의 `count`가 0이 됩니다. 그런데 state에는 두 인스턴스가 남아 있으므로 plan에는 destroy하겠다는 내용이 표시됩니다. `moved` 블록으로는 이 표시를 없앨 수 없습니다. `moved`는 같은 구성 안에서 리소스 주소를 옮길 때 쓰는 기능이고, 여기에서 필요한 조치는 관리 대상에서 제외하는 작업이기 때문입니다.

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

자원이 남아 있다면 3번에서 멈추고 삭제 여부를 먼저 결정합니다. 다른 변경이 보이면 apply하지 말고 원인을 먼저 확인합니다. 이 저장소의 작업에서는 위 절차를 아직 실행하지 않았습니다.

## CI에서 plan과 apply를 하지 않는 이유

`Terraform Validation` 워크플로에는 `plan`과 `apply` 단계를 두지 않았습니다. state가 저장소 바깥의 로컬 파일인 `terraform.tfstate`에만 있어서, runner에는 현재 관리 중인 자원 정보가 전혀 없기 때문입니다. 그 상태로 `plan`을 실행하면 이미 존재하는 자원을 새로 만들겠다는 계획이 나옵니다. 그 계획을 그대로 `apply`하면 운영 인프라가 훼손됩니다.

원격 backend로 state를 옮긴 뒤에 다시 검토합니다. OCI Object Storage의 S3 호환 endpoint를 backend로 사용할 수 있으며, 도입하기 전에 저장 위치의 암호화와 버전 관리와 접근 권한과 잠금 지원을 먼저 확인해야 합니다. 위의 "VM5와 VM6의 state 정리"를 끝내기 전에는 이전 작업도 시작하지 않습니다.
