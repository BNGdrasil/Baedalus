terraform {
  required_version = ">= 1.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

# Configure the Oracle Cloud Infrastructure provider
provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Data sources
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                   = var.instance_shape
  sort_by                 = "TIMECREATED"
  sort_order              = "DESC"
}

# VCN and Networking
resource "oci_core_vcn" "bnbong_vcn" {
  compartment_id = var.compartment_id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "bnbong-vcn"
  dns_label      = "bnbong"
}

resource "oci_core_internet_gateway" "bnbong_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.bnbong_vcn.id
  display_name   = "bnbong-internet-gateway"
}

resource "oci_core_route_table" "bnbong_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.bnbong_vcn.id
  display_name   = "bnbong-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.bnbong_igw.id
  }
}

resource "oci_core_security_list" "bnbong_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.bnbong_vcn.id
  display_name   = "bnbong-security-list"

  # SSH access
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP access
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS access
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false

    tcp_options {
      min = 443
      max = 443
    }
  }

  # All outbound traffic
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

resource "oci_core_subnet" "bnbong_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.bnbong_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "bnbong-subnet"
  dns_label      = "bnbongsubnet"

  security_list_ids = [oci_core_security_list.bnbong_security_list.id]
  route_table_id    = oci_core_route_table.bnbong_route_table.id
  dhcp_options_id   = oci_core_vcn.bnbong_vcn.default_dhcp_options_id
}

# Compute Instance
resource "oci_core_instance" "bnbong_server" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "bnbong-server"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.bnbong_subnet.id
    assign_public_ip = true
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/user_data.sh", {
      domain_name = var.domain_name
    }))
  }

  # Prevent the instance from being destroyed and recreated
  lifecycle {
    prevent_destroy = true
  }
}

# Public IP
resource "oci_core_public_ip" "bnbong_public_ip" {
  compartment_id = var.compartment_id
  display_name   = "bnbong-public-ip"
  lifetime       = "RESERVED"
  private_ip_id  = oci_core_instance.bnbong_server.private_ip
}

# Outputs
output "public_ip" {
  description = "Public IP address of the instance"
  value       = oci_core_public_ip.bnbong_public_ip.ip_address
}

output "instance_id" {
  description = "Instance ID"
  value       = oci_core_instance.bnbong_server.id
}
