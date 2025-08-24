# Baedalus

Infrastructure of bnbong cloud-nation

이 프로젝트는 Oracle Cloud Infrastructure(OCI)를 기반으로 Terraform을 활용한 Infrastructure as Code(IaC) 프로젝트입니다. 클라우드 인프라를 코드로 관리하여 일관성 있고 재현 가능한 인프라 환경을 구축합니다.

## 주요 구성 요소

### 인프라 구성

- **VCN (Virtual Cloud Network)**: 10.0.0.0/16 CIDR 블록으로 구성된 가상 네트워크
- **서브넷**: 10.0.1.0/24 CIDR 블록의 공개 서브넷
- **인터넷 게이트웨이**: 외부 인터넷 연결
- **보안 리스트**: SSH(22), HTTP(80), HTTPS(443) 포트 허용
- **라우팅 테이블**: 인터넷 게이트웨이를 통한 외부 트래픽 라우팅

### 컴퓨트 리소스

- **Ubuntu 22.04 인스턴스**: Canonical Ubuntu 운영체제 기반
- **VM.Standard.A1.Flex**: ARM 기반 가상 머신 스펙
- **고정 공개 IP**: 예약된 공개 IP 주소 할당

### 자동화 스크립트

- **user_data.sh**: 인스턴스 초기화 시 Docker, Docker Compose 설치 및 기본 설정
- **deploy.sh**: 애플리케이션 배포 자동화 스크립트

## 사전 요구사항

- Terraform >= 1.0
- Oracle Cloud Infrastructure 계정
- OCI CLI 설정 또는 API 키
- SSH 키 페어

## 빠른 시작

### 1. 환경 설정

```bash
# Makefile을 사용한 초기 설정
make setup

# 또는 수동으로 설정
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 파일을 편집하여 OCI 인증 정보 입력
```

### 2. 인프라 배포

```bash
# Makefile을 사용한 배포
make init
make plan
make apply

# 또는 직접 Terraform 명령어 사용
terraform init
terraform plan
terraform apply
```

### 3. 애플리케이션 배포

```bash
# Makefile을 사용한 배포
make deploy SERVER_IP=<서버_IP>

# 또는 직접 스크립트 실행
./scripts/deploy.sh <서버_IP> [SSH_USER]
```

## Makefile 사용법

이 프로젝트는 Makefile을 통해 자주 사용하는 명령어들을 간편하게 실행할 수 있습니다.

```bash
# 사용 가능한 명령어 확인
make help

# 코드 포맷팅 및 검증
make lint

# 인프라 삭제
make destroy

# 상태 확인
make output
make show
```

## 파일 구조

```
infra/
├── main.tf                 # 메인 Terraform 구성 파일
├── variables.tf            # 변수 정의
├── terraform.tfvars.example # 환경 변수 예시 파일
├── scripts/
│   ├── deploy.sh          # 애플리케이션 배포 스크립트
│   └── user_data.sh       # 인스턴스 초기화 스크립트
├── .github/workflows/
│   └── terraform.yml      # GitHub Actions CI/CD
├── Makefile               # 자동화 명령어
├── .gitignore            # Git 무시 파일 목록
├── CONTRIBUTING.md       # 기여 가이드라인
├── CHANGELOG.md          # 변경 이력
├── SECURITY.md           # 보안 정책
└── README.md             # 프로젝트 문서
```

## 출력 값

- `public_ip`: 인스턴스의 공개 IP 주소
- `instance_id`: 생성된 인스턴스의 OCID

## CI/CD

GitHub Actions를 통해 다음 작업이 자동화됩니다:

- Terraform 코드 포맷팅 검사
- Terraform 코드 유효성 검증
- Pull Request 시 배포 계획 자동 생성

## 보안 고려사항

- SSH 키는 안전하게 관리하고 공개 저장소 업로드 X
- OCI 인증 정보는 환경 변수나 안전한 방법으로 관리
- 프로덕션 환경에서는 보안 그룹 규칙을 더 엄격하게 설정

## 라이선스

이 프로젝트는 개인 학습 및 개발 목적으로 사용됩니다.
