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
  default     = "bnbong.xyz"
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
      display_name            = "vm6-playground"
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
