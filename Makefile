.PHONY: help init plan apply destroy fmt validate clean

# 기본 타겟
help: ## 도움말 표시
	@echo "사용 가능한 명령어:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# Terraform 명령어
init: ## Terraform 초기화
	terraform init

plan: ## 배포 계획 확인
	terraform plan

apply: ## 인프라 생성/업데이트
	terraform apply

destroy: ## 인프라 삭제
	terraform destroy

fmt: ## Terraform 코드 포맷팅
	terraform fmt -recursive

validate: ## Terraform 코드 검증
	terraform validate

# 유틸리티 명령어
clean: ## Terraform 상태 파일 정리
	rm -rf .terraform
	rm -f .terraform.lock.hcl
	rm -f *.tfstate
	rm -f *.tfstate.backup

# 배포 관련 명령어
deploy: ## 애플리케이션 배포 (서버 IP 필요)
	@if [ -z "$(SERVER_IP)" ]; then \
		echo "사용법: make deploy SERVER_IP=<서버_IP>"; \
		exit 1; \
	fi
	./scripts/deploy.sh $(SERVER_IP)

# 상태 확인
output: ## Terraform 출력 값 확인
	terraform output

show: ## 현재 상태 확인
	terraform show

# 개발 도구
lint: fmt validate ## 코드 포맷팅 및 검증
	@echo "코드 검사 완료"

# 환경 설정
setup: ## 초기 환경 설정
	@if [ ! -f terraform.tfvars ]; then \
		cp terraform.tfvars.example terraform.tfvars; \
		echo "terraform.tfvars 파일이 생성되었습니다. 설정을 확인하세요."; \
	else \
		echo "terraform.tfvars 파일이 이미 존재합니다."; \
	fi
