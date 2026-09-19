# OCI 준비 안내

이 문서는 Baedalus의 Terraform 구성을 실행하기 위해 필요한 준비물만 다룹니다. 계정을 만들고 API
키를 발급하고 `terraform.tfvars`를 채우는 절차까지가 범위입니다. 인프라를 실제로 적용하는 절차와
운영 중인 자원을 다루는 주의 사항은 [저장소 README](README.md)에 있습니다.

실제 OCID와 지문과 비밀번호는 이 문서에 적지 않습니다. 아래 예시는 모두 형식을 보여 주기 위한
자리표시자입니다.

---

## 1. 준비물

다음 소프트웨어가 필요합니다.

- Terraform 1.0 이상. 저장소의 GitHub Actions 워크플로는 1.5.7을 사용합니다.
- Git과 SSH 클라이언트.
- OCI CLI. 필수는 아니지만 인스턴스와 boot volume의 잔존 여부를 조회할 때 사용합니다.

계정은 두 개가 필요합니다. 춘천 리전(`ap-chuncheon-1`)을 home region으로 하는 계정 하나와, 오사카
리전(`ap-osaka-1`)을 home region으로 하는 계정 하나입니다. 계정을 만들 때 home region을 나중에
바꿀 수 없으므로 가입 화면에서 정확히 선택해야 합니다.

계정 확인 과정에서 신용카드 정보를 입력하게 됩니다. Always Free 한도 안에서는 청구가 발생하지
않는다고 안내되지만, 한도는 계정과 리전과 가입 시점에 따라 다릅니다. 가입한 뒤 콘솔의 Cost
Analysis에서 실제 사용량을 확인하고 Budgets에서 예산 알림을 설정해 두기를 권장합니다.

---

## 2. Compartment 생성

두 계정에서 각각 다음을 수행합니다.

1. 콘솔에서 **Identity & Security**로 이동한 다음 **Compartments**를 엽니다.
2. **Create Compartment**를 누르고 이름과 설명을 입력합니다.
3. 만들어진 compartment의 OCID를 복사해 둡니다. `compartment_id_chuncheon`과
   `compartment_id_osaka`에 넣을 값입니다.

---

## 3. API 키 발급

Terraform provider가 사용할 API 키를 리전별로 따로 만듭니다.

```bash
mkdir -p ~/.oci
cd ~/.oci

# 춘천 계정용 키
openssl genrsa -out chuncheon_api_key.pem 2048
openssl rsa -pubout -in chuncheon_api_key.pem -out chuncheon_api_key_public.pem
chmod 600 chuncheon_api_key.pem

# 오사카 계정용 키
openssl genrsa -out osaka_api_key.pem 2048
openssl rsa -pubout -in osaka_api_key.pem -out osaka_api_key_public.pem
chmod 600 osaka_api_key.pem
```

공개 키를 콘솔에 등록합니다.

1. 콘솔 오른쪽 위의 프로필 메뉴에서 **User Settings**를 엽니다.
2. **API Keys**에서 **Add API Key**를 누릅니다.
3. **Paste Public Key**를 선택하고 `*_api_key_public.pem`의 내용을 붙여 넣습니다.
4. 등록을 마치면 화면에 지문(fingerprint)이 표시됩니다. 이 값을 복사해 둡니다.
5. 같은 화면에서 사용자 OCID를, 프로필 메뉴의 **Tenancy**에서 tenancy OCID를 복사해 둡니다.

개인 키 파일은 저장소에 넣지 않습니다. `.gitignore`가 `*.pem`을 제외하고 있지만, 파일을
`~/.oci` 밖으로 옮기지 않는 편이 안전합니다.

---

## 4. VM 접속용 SSH 키

API 키와는 별개로 VM에 접속할 SSH 키가 필요합니다.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/bngdrasil_vm_key -C "bngdrasil"
cat ~/.ssh/bngdrasil_vm_key.pub
```

출력된 공개 키 한 줄을 `terraform.tfvars`의 `ssh_public_key`에 넣습니다. 이 값은 cloud-init이
각 인스턴스의 `ubuntu` 계정에 등록합니다.

---

## 5. terraform.tfvars 작성

예시 파일을 복사한 뒤 값을 채웁니다. `make setup`도 같은 일을 하며, 이미 파일이 있으면
덮어쓰지 않습니다.

```bash
cp terraform.tfvars.example terraform.tfvars
```

채워야 하는 값은 다음과 같습니다.

| 변수 | 값의 출처 |
|---|---|
| `tenancy_ocid_chuncheon`, `tenancy_ocid_osaka` | 프로필 메뉴의 Tenancy 화면에 있는 OCID입니다. |
| `user_ocid_chuncheon`, `user_ocid_osaka` | User Settings 화면에 있는 사용자 OCID입니다. |
| `fingerprint_chuncheon`, `fingerprint_osaka` | API Key를 등록한 뒤 표시되는 지문입니다. |
| `private_key_path_chuncheon`, `private_key_path_osaka` | 3단계에서 만든 개인 키 파일의 경로입니다. |
| `compartment_id_chuncheon`, `compartment_id_osaka` | 2단계에서 만든 compartment의 OCID입니다. |
| `ssh_public_key` | 4단계에서 출력한 공개 키 한 줄입니다. |
| `postgres_password` | VM3 PostgreSQL 계정의 비밀번호입니다. |
| `jwt_secret_key` | 32자 이상이어야 합니다. 예시 문구를 그대로 두면 애플리케이션이 기동에 실패합니다. |

`region_chuncheon`, `region_osaka`, `instance_shape`, `domain_name`, `postgres_user`에는 기본값이
있으므로 다르게 쓸 때에만 지정합니다.

`terraform.tfvars`는 `.gitignore`가 제외하고 있습니다. 파일에 실제 비밀 값이 들어가므로 저장소에
올리지 않아야 하고, 사본을 만들 때에도 권한을 600으로 유지하는 편이 좋습니다.

---

## 6. 준비 확인

값을 다 채웠으면 자격 증명 없이 구성만 검사한 다음, provider 인증까지 확인합니다.

```bash
make fmt        # terraform fmt -recursive
make validate   # terraform validate
make init       # provider plugin을 내려받습니다
make plan       # 자격 증명이 올바르면 계획이 출력됩니다
```

`Error 401`이 나오면 지문과 사용자 OCID와 개인 키 경로가 서로 맞는지 확인합니다. 지문은 다음
명령으로 개인 키에서 다시 계산할 수 있으며, 이 값이 콘솔에 표시된 지문과 같아야 합니다.

```bash
openssl rsa -pubout -outform DER -in ~/.oci/chuncheon_api_key.pem \
  | openssl md5 -c
```

`plan`이 정상적으로 출력되었다고 해서 바로 `apply`로 넘어가면 안 됩니다. 이 저장소가 관리하는
자원 중 일부는 state와 실제 OCI 자원이 어긋나 있습니다. apply 전에 밟아야 하는 대조 절차는
[저장소 README](README.md)의 "Terraform 사용 절차"와 "VM5와 VM6의 state 정리"에 있습니다.

---

## 7. 다음 단계

계정 준비가 끝난 뒤의 작업은 다음 문서로 이어집니다.

- VM2의 애플리케이션을 배포하려면 [vm2-deployment/README.md](vm2-deployment/README.md)를 따릅니다.
- 관측 스택을 다루려면 [monitoring/README.md](monitoring/README.md)를 읽습니다.
- 백업 체계를 설치하려면 [backup/README.md](backup/README.md)를 따릅니다.
