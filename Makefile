.PHONY: help init plan apply destroy fmt validate clean clean-all backup-state output show deploy-all

# Colors
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m # No Color

# Default target
help:
	@echo "$(GREEN)BNGdrasil Infrastructure Management$(NC)"
	@echo "사용 가능한 명령어:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'

# Setup
setup:
	@echo "$(GREEN)Setting up infrastructure environment...$(NC)"
	@if [ ! -f terraform.tfvars ]; then \
		cp terraform.tfvars.example terraform.tfvars; \
		echo "$(YELLOW)terraform.tfvars 파일이 생성되었습니다.$(NC)"; \
		echo "$(YELLOW)파일을 편집하여 OCI 자격 증명을 설정하세요.$(NC)"; \
	else \
		echo "$(YELLOW)terraform.tfvars 파일이 이미 존재합니다.$(NC)"; \
	fi
	@chmod +x scripts/*.sh
	@echo "$(GREEN)Setup completed!$(NC)"

# Terraform Core Commands
init:
	@echo "$(GREEN)Initializing Terraform...$(NC)"
	terraform init

plan:
	@echo "$(GREEN)Planning infrastructure changes...$(NC)"
	terraform plan

apply:
	@echo "$(GREEN)Applying infrastructure changes...$(NC)"
	@echo "$(YELLOW)This will create/update infrastructure across both regions$(NC)"
	terraform apply

destroy:
	@echo "$(RED)WARNING: This will destroy ALL infrastructure!$(NC)"
	@echo "$(YELLOW)Press Ctrl+C to cancel, or Enter to continue...$(NC)"
	@read dummy
	terraform destroy

# Code Quality
fmt:
	@echo "$(GREEN)Formatting Terraform code...$(NC)"
	terraform fmt -recursive

validate:
	@echo "$(GREEN)Validating Terraform configuration...$(NC)"
	terraform validate

lint: fmt validate
	@echo "$(GREEN)Linting completed!$(NC)"

# State Management
output:
	@echo "$(GREEN)Terraform Outputs:$(NC)"
	@terraform output

show:
	@echo "$(GREEN)Current Terraform State:$(NC)"
	terraform show

state-list:
	@echo "$(GREEN)All managed resources:$(NC)"
	terraform state list

# Specific Outputs
show-ips:
	@echo "$(GREEN)VM IP Addresses:$(NC)"
	@terraform output -json | jq -r '.vm1_public_ip.value, .vm2_public_ip.value, .vm3_private_ip.value, .vm4_private_ip.value'

show-ssh:
	@echo "$(GREEN)SSH Connection Commands:$(NC)"
	@terraform output -json ssh_connections | jq -r 'to_entries[] | "\(.key): \(.value)"'

# Deployment
deploy-vm1:
	@if [ -z "$$(terraform output -raw vm1_public_ip 2>/dev/null)" ]; then \
		echo "$(RED)Error: Infrastructure not deployed yet. Run 'make apply' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Deploying to VM1 (Frontend)...$(NC)"
	./scripts/deploy.sh $$(terraform output -raw vm1_public_ip) ubuntu

deploy-vm2:
	@if [ -z "$$(terraform output -raw vm2_public_ip 2>/dev/null)" ]; then \
		echo "$(RED)Error: Infrastructure not deployed yet. Run 'make apply' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Deploying to VM2 (Core APIs)...$(NC)"
	./scripts/deploy.sh $$(terraform output -raw vm2_public_ip) ubuntu

deploy-all:
	@echo "$(GREEN)Deploying applications to all VMs...$(NC)"
	@make deploy-vm1
	@make deploy-vm2
	@echo "$(GREEN)All deployments completed!$(NC)"

# Monitoring
ssh-vm1:
	@ssh ubuntu@$$(terraform output -raw vm1_public_ip)

ssh-vm2:
	@ssh ubuntu@$$(terraform output -raw vm2_public_ip)

ssh-vm3:
	@ssh -J ubuntu@$$(terraform output -raw vm2_public_ip) ubuntu@$$(terraform output -raw vm3_private_ip)

ssh-vm4:
	@ssh -J ubuntu@$$(terraform output -raw vm2_public_ip) ubuntu@$$(terraform output -raw vm4_private_ip)

# VM5, VM6는 퇴역했습니다. 접속 대상이 없으므로 ssh 타겟도 제거했습니다.

# Logs
logs-vm1:
	@ssh ubuntu@$$(terraform output -raw vm1_public_ip) 'cd /opt/bnbong && docker-compose logs -f'

logs-vm2:
	@ssh ubuntu@$$(terraform output -raw vm2_public_ip) 'cd /opt/bnbong && docker-compose logs -f'

# Health Checks
health:
	@echo "$(GREEN)Checking VM health...$(NC)"
	@echo "VM1 (Frontend):"
	@ssh ubuntu@$$(terraform output -raw vm1_public_ip) 'systemctl is-active bnbong-vm1.service || echo "Service not running"'
	@echo ""
	@echo "VM2 (Core APIs):"
	@ssh ubuntu@$$(terraform output -raw vm2_public_ip) 'systemctl is-active bnbong-vm2.service || echo "Service not running"'

# Cleanup
clean:
	@echo "$(YELLOW)Cleaning Terraform cache and lock files...$(NC)"
	@rm -rf .terraform
	@rm -f .terraform.lock.hcl
	@echo "$(GREEN)Clean completed!$(NC)"

# DATA-03: clean-all이 *.tfstate와 백업을 함께 지우던 동작을 제거했습니다.
# state를 잃으면 현재 관리 중인 OCI 자원의 주소를 되찾을 수 없고, 이후 apply가
# 이미 존재하는 자원을 다시 만들려고 시도합니다. state 파일은 일반 정리 대상이
# 아니며, 정말 폐기해야 한다면 아래 backup-state로 사본을 만든 뒤 수동으로 처리합니다.
clean-all: clean
	@echo "$(YELLOW)clean-all은 .terraform 캐시와 lock 파일만 정리합니다.$(NC)"
	@echo "$(YELLOW)Terraform state는 삭제하지 않습니다. DATA-03을 참고하세요.$(NC)"

backup-state:
	@echo "$(GREEN)Backing up Terraform state...$(NC)"
	@ts=$$(date -u +%Y%m%dT%H%M%SZ); \
	mkdir -p state-backups; \
	cp terraform.tfstate state-backups/terraform.tfstate.$$ts; \
	echo "Saved: state-backups/terraform.tfstate.$$ts"

# Documentation
docs:
	@echo "$(GREEN)Generating infrastructure documentation...$(NC)"
	@terraform-docs markdown table . > TERRAFORM.md 2>/dev/null || echo "$(YELLOW)terraform-docs not installed. Skipping.$(NC)"

# Resource Summary
summary:
	@echo "$(GREEN)Infrastructure Summary:$(NC)"
	@terraform output -json resource_summary | jq .

# Quick Deploy
quick-deploy: setup init plan apply deploy-all
	@echo "$(GREEN)Quick deploy completed!$(NC)"
