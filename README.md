<p align="center">
    <img align="top" width="30%" src="https://raw.githubusercontent.com/BNGdrasil/.github/main/images/Baedalus.png" alt="Baedalus"/>
</p>

<div align="center">

# Baedalus (Bnbong + daedalus)

**BNGdrasil의 인프라 코드와 운영 도구**

[![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat-square&logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Oracle Cloud](https://img.shields.io/badge/Oracle%20Cloud-F80000?style=flat-square&logo=oracle&logoColor=white)](https://www.oracle.com/cloud/)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat-square&logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat-square&logo=grafana&logoColor=white)](https://grafana.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu%2022.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)](https://ubuntu.com/)

*[BNGdrasil](https://github.com/BNGdrasil) 생태계의 일부입니다*

</div>

---

## 소개

Baedalus는 BNGdrasil의 인프라 코드 저장소입니다. Terraform으로 네트워크와 VM을 정의합니다. cloud-init 부트스트랩 스크립트도 보관합니다. 배포 정의와 관측, 백업 도구를 함께 관리합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `*.tf` | VCN, 서브넷, VM 정의 |
| `scripts/` | 부트스트랩과 배포 스크립트 |
| `vm2-deployment/` | VM2 compose와 배포 |
| `monitoring/` | VM2 관측 스택 설정 |
| `backup/` | 반복 백업과 복원 |
| `docs/` | 인프라 운용 문서 |

## 빠른 시작

자격 증명을 준비하는 절차는 [OCI 준비 안내](OCI_SETUP_GUIDE.md)에 있습니다. 자격 증명이 없어도 아래 검증 명령은 그대로 실행할 수 있습니다.

```bash
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate
```

`terraform apply`는 state와 실제 OCI 자원을 대조하기 전까지 실행하지 않습니다. 대조 절차는 [Terraform 운용](docs/terraform.md)에 적었습니다. apply를 실행할 단계가 되면, plan 출력에 `must be replaced`나 `forces replacement`가 있는지 먼저 확인하고 하나라도 걸리면 중단합니다. 운영 인스턴스가 교체되면 서비스가 중단되고 boot volume 위의 데이터도 사라지기 때문입니다.

## 문서

| 문서 | 내용 |
|---|---|
| [인프라 구성](docs/infrastructure.md) | VM 구성과 네트워크 규칙 |
| [Terraform 운용](docs/terraform.md) | state 백업과 CI 정책 |
| [GitHub Actions 설정](docs/github-actions-setup.md) | 배포 워크플로와 secret |
| [OCI 준비 안내](OCI_SETUP_GUIDE.md) | 계정과 API 키 준비 |
| [VM2 배포](vm2-deployment/README.md) | Gateway와 Auth 배포 |
| [모니터링](monitoring/README.md) | 관측 스택과 알림 규칙 |
| [백업](backup/README.md) | 백업 체계와 복원 훈련 |

## 관련 프로젝트

- [Bidar](https://github.com/BNGdrasil/Bidar): 인증 서버
- [Bifrost](https://github.com/BNGdrasil/Bifrost): API 게이트웨이
- [Bantheon](https://github.com/BNGdrasil/Bantheon): 웹 클라이언트와 VM1 Nginx 설정
