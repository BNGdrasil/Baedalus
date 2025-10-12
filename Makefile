.PHONY: help init plan apply destroy fmt validate clean output show deploy-all

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
	@terraform output -json | jq -r '.vm1_public_ip.value, .vm2_public_ip.value, .vm3_private_ip.value, .vm4_private_ip.value, .vm5_private_ip.value, .vm6_private_ip.value'

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
	./scripts/deploy.sh $$(terraform output -raw vm1_public_ip) vm1

deploy-vm2:
	@if [ -z "$$(terraform output -raw vm2_public_ip 2>/dev/null)" ]; then \
		echo "$(RED)Error: Infrastructure not deployed yet. Run 'make apply' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Deploying to VM2 (Core APIs)...$(NC)"
	./scripts/deploy.sh $$(terraform output -raw vm2_public_ip) vm2

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

ssh-vm5:
	@ssh -J ubuntu@$$(terraform output -raw vm2_public_ip) ubuntu@$$(terraform output -raw vm5_private_ip)

ssh-vm6:
	@ssh -J ubuntu@$$(terraform output -raw vm2_public_ip) ubuntu@$$(terraform output -raw vm6_private_ip)

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

clean-all: clean
	@echo "$(RED)WARNING: This will delete ALL Terraform state files!$(NC)"
	@echo "$(YELLOW)Press Ctrl+C to cancel, or Enter to continue...$(NC)"
	@read dummy
	@rm -f *.tfstate
	@rm -f *.tfstate.backup
	@echo "$(GREEN)All files cleaned!$(NC)"

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
