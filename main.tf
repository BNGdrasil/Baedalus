terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
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
