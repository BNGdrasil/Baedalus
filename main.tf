terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }

  # state backend (DATA-03)
  #
  # 현재는 작업자 장비의 terraform.tfstate를 그대로 사용한다. remote backend는
  # 이번 범위에서 도입하지 않았고, 도입하려면 저장 위치의 암호화, 버전 관리,
  # 접근 권한, 잠금 지원을 먼저 확인해야 한다. 암묵적 기본값에 기대지 않도록
  # local backend를 명시한다.
  #
  # state 백업 절차
  #   1. apply 전후에 `make backup-state`를 실행해 state-backups/ 아래에
  #      시각이 붙은 사본을 남긴다.
  #   2. state에는 OCI 자원 주소와 민감한 변수 값이 들어 있으므로 사본을
  #      공개 저장소에 올리지 않는다. .gitignore에 *.tfstate가 포함되어 있다.
  #   3. state를 잃으면 현재 관리 중인 자원의 주소를 되찾을 수 없고, 이후
  #      apply가 이미 존재하는 자원을 다시 만들려고 시도한다. 일반 정리 명령에서
  #      state를 삭제하지 않는다.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# Provider for Chuncheon Region (Korea)
provider "oci" {
  alias            = "chuncheon"
  tenancy_ocid     = var.tenancy_ocid_chuncheon
  user_ocid        = var.user_ocid_chuncheon
  fingerprint      = var.fingerprint_chuncheon
  private_key_path = var.private_key_path_chuncheon
  region           = var.region_chuncheon
}

# Provider for Osaka Region (Japan)
provider "oci" {
  alias            = "osaka"
  tenancy_ocid     = var.tenancy_ocid_osaka
  user_ocid        = var.user_ocid_osaka
  fingerprint      = var.fingerprint_osaka
  private_key_path = var.private_key_path_osaka
  region           = var.region_osaka
}

# Data sources for availability domains - Chuncheon
data "oci_identity_availability_domains" "chuncheon_ads" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
}

# Data sources for availability domains - Osaka
data "oci_identity_availability_domains" "osaka_ads" {
  provider       = oci.osaka
  compartment_id = var.compartment_id_osaka
}

# Data sources for Ubuntu images - Chuncheon
data "oci_core_images" "chuncheon_ubuntu" {
  provider                 = oci.chuncheon
  compartment_id           = var.compartment_id_chuncheon
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Data sources for Ubuntu images - Osaka
data "oci_core_images" "osaka_ubuntu" {
  provider                 = oci.osaka
  compartment_id           = var.compartment_id_osaka
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}
