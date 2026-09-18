# ========================================
# Chuncheon Region Configuration
# ========================================

variable "tenancy_ocid_chuncheon" {
  description = "OCID of your Chuncheon tenancy"
  type        = string
}

variable "user_ocid_chuncheon" {
  description = "OCID of the user for Chuncheon region"
  type        = string
}

variable "fingerprint_chuncheon" {
  description = "Fingerprint for Chuncheon API key"
  type        = string
}

variable "private_key_path_chuncheon" {
  description = "Path to private key for Chuncheon region"
  type        = string
}

variable "region_chuncheon" {
  description = "OCI Chuncheon region"
  type        = string
  default     = "ap-chuncheon-1"
}

variable "compartment_id_chuncheon" {
  description = "OCID of the compartment for Chuncheon"
  type        = string
}

# ========================================
# Osaka Region Configuration
# ========================================

variable "tenancy_ocid_osaka" {
  description = "OCID of your Osaka tenancy"
  type        = string
}

variable "user_ocid_osaka" {
  description = "OCID of the user for Osaka region"
  type        = string
}

variable "fingerprint_osaka" {
  description = "Fingerprint for Osaka API key"
  type        = string
}

variable "private_key_path_osaka" {
  description = "Path to private key for Osaka region"
  type        = string
}

variable "region_osaka" {
  description = "OCI Osaka region"
  type        = string
  default     = "ap-osaka-1"
}

variable "compartment_id_osaka" {
  description = "OCID of the compartment for Osaka"
  type        = string
}

# ========================================
# General Configuration
# ========================================

variable "instance_shape" {
  description = "Shape of compute instances (ARM-based)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the application"
  type        = string
  default     = "bnbong.com"
}

# ========================================
# VM Instance Configurations
# ========================================

variable "vm_configs" {
  description = "Configuration for each VM instance"
  type = map(object({
    display_name            = string
    ocpus                   = number
    memory_in_gbs           = number
    boot_volume_size_in_gbs = number
    region                  = string
    subnet_type             = string
  }))
  default = {
    vm1 = {
      display_name            = "vm1-frontend-proxy"
      ocpus                   = 1
      memory_in_gbs           = 6
      boot_volume_size_in_gbs = 50
      region                  = "chuncheon"
      subnet_type             = "public"
    }
    vm2 = {
      display_name            = "vm2-core-apis"
      ocpus                   = 2
      memory_in_gbs           = 12
      boot_volume_size_in_gbs = 50
      region                  = "chuncheon"
      subnet_type             = "public"
    }
    vm3 = {
      display_name            = "vm3-database"
      ocpus                   = 1
      memory_in_gbs           = 6
      boot_volume_size_in_gbs = 80
      region                  = "chuncheon"
      subnet_type             = "private"
    }
    vm4 = {
      display_name            = "vm4-monitoring"
      ocpus                   = 1
      memory_in_gbs           = 6
      boot_volume_size_in_gbs = 80
      region                  = "osaka"
      subnet_type             = "private"
    }
    vm5 = {
      display_name            = "vm5-backup"
      ocpus                   = 2
      memory_in_gbs           = 12
      boot_volume_size_in_gbs = 70
      region                  = "osaka"
      subnet_type             = "private"
    }
    vm6 = {
      display_name            = "vm6-sandbox"
      ocpus                   = 1
      memory_in_gbs           = 6
      boot_volume_size_in_gbs = 50
      region                  = "osaka"
      subnet_type             = "private"
    }
  }
}

# Environment variables for Docker services
variable "postgres_user" {
  description = "PostgreSQL username"
  type        = string
  default     = "bnbong"
}

variable "postgres_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "jwt_secret_key" {
  description = "JWT secret key for authentication"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS management"
  type        = string
  sensitive   = true
  default     = ""
}

# ========================================
# 퇴역 인스턴스 스위치 (I09)
# ========================================
# VM5와 VM6는 운영자 설명상 삭제된 인스턴스다. 기본값을 false로 두어 실수로
# apply했을 때 삭제한 VM이 다시 만들어지지 않게 한다. 자세한 근거와 state 정리
# 절차는 osaka.tf 상단 주석에 적어 두었다.

variable "enable_vm5" {
  description = "퇴역한 VM5(backup)를 다시 만들지 여부. 기본값 false를 유지한다."
  type        = bool
  default     = false
}

variable "enable_vm6" {
  description = "퇴역한 VM6(sandbox)를 다시 만들지 여부. 기본값 false를 유지한다."
  type        = bool
  default     = false
}

# ========================================
# 접근 제어 CIDR (SEC-04)
# ========================================

variable "admin_cidr" {
  description = <<-EOT
    SSH(22번 포트) 접근을 허용할 CIDR이다. 기본값은 현행 설정을 그대로 유지하기
    위해 0.0.0.0/0으로 두었다. 관리 접근 경로를 먼저 확인한 뒤에 좁혀야 하며,
    확인 없이 좁히면 운영자가 VM에 접속하지 못하게 될 수 있다.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "api_client_cidr" {
  description = <<-EOT
    VM2의 Gateway(8000)와 Auth Server(8001)에 접근할 수 있는 CIDR이다.
    실제 호출자는 춘천 public subnet의 VM1 Nginx뿐이므로 해당 subnet으로 제한한다.
  EOT
  type        = string
  default     = "10.0.1.0/24"
}
