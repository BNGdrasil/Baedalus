# scripts/legacy

Terraform과 배포 경로에서 더 이상 호출하지 않는 스크립트를 모아 둔 디렉터리다. 과거 배포본을
해석할 때 참고하기 위해 남겨 두었을 뿐이므로, 새 작업에서는 사용하지 않는다.

| 파일 | 보관 사유 |
|---|---|
| `deploy_services.sh` | 애플리케이션 DB를 VM4(오사카)에 있다고 가정하고, `gateway/`와 `auth-server/`라는 옛 디렉터리 이름을 참조하며, VM2의 `/opt/bnbong/.env`를 기본 비밀번호로 덮어썼다. 실제 DB는 VM3의 호스트 PostgreSQL이고 소스 디렉터리는 `bifrost/`와 `bidar/`이다. VM2 배포는 `vm2-deployment/deploy.sh`가 담당한다. |
| `user_data_vm5.sh` | VM5는 운영자 설명상 삭제된 인스턴스다. `osaka.tf`의 VM5 정의도 `enable_vm5` 기본값 false로 비활성화했다. |
| `user_data_vm6.sh` | VM6도 같은 이유로 퇴역했다. `enable_vm6` 기본값은 false다. |

VM5·VM6을 다시 만들 일이 생기면 Terraform 변수부터 되돌린 다음 이 스크립트를 `scripts/`로
옮겨야 한다. Terraform state에는 두 인스턴스가 아직 RUNNING으로 남아 있으므로, 실제 OCI
자원을 조회해 state와 맞춘 뒤에 판단한다.
