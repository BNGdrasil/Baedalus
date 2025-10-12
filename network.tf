# ========================================
# Chuncheon Network Configuration
# ========================================

# VCN for Chuncheon Region
resource "oci_core_vcn" "chuncheon_vcn" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "chuncheon-vcn"
  dns_label      = "chuncheon"
}

# Internet Gateway for Chuncheon
resource "oci_core_internet_gateway" "chuncheon_igw" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-internet-gateway"
  enabled        = true
}

# NAT Gateway for Chuncheon Private Subnet
resource "oci_core_nat_gateway" "chuncheon_nat" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-nat-gateway"
}

# Route Table for Public Subnet - Chuncheon
resource "oci_core_route_table" "chuncheon_public_rt" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-public-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.chuncheon_igw.id
  }
}

# Route Table for Private Subnet - Chuncheon
resource "oci_core_route_table" "chuncheon_private_rt" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-private-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.chuncheon_nat.id
  }
}

# Security List for Public Subnet - Chuncheon
resource "oci_core_security_list" "chuncheon_public_sl" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-public-security-list"

  # SSH
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 443
      max = 443
    }
  }

  # API Gateway
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 8000
      max = 8000
    }
  }

  # Auth Server
  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 8001
      max = 8001
    }
  }

  # Internal communication (all VCN traffic)
  ingress_security_rules {
    protocol  = "all"
    source    = "10.0.0.0/16"
    stateless = false
  }

  # All outbound traffic
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# Security List for Private Subnet - Chuncheon
resource "oci_core_security_list" "chuncheon_private_sl" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  display_name   = "chuncheon-private-security-list"

  # Allow all traffic from VCN
  ingress_security_rules {
    protocol  = "all"
    source    = "10.0.0.0/16"
    stateless = false
  }

  # Allow traffic from Osaka VCN (for cross-region communication)
  ingress_security_rules {
    protocol  = "all"
    source    = "10.1.0.0/16"
    stateless = false
  }

  # All outbound traffic
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# Public Subnet - Chuncheon
resource "oci_core_subnet" "chuncheon_public_subnet" {
  provider       = oci.chuncheon
  compartment_id = var.compartment_id_chuncheon
  vcn_id         = oci_core_vcn.chuncheon_vcn.id
  cidr_block     = "10.0.1.0/24"
  display_name   = "chuncheon-public-subnet"
  dns_label      = "chpublic"

  security_list_ids = [oci_core_security_list.chuncheon_public_sl.id]
  route_table_id    = oci_core_route_table.chuncheon_public_rt.id
  dhcp_options_id   = oci_core_vcn.chuncheon_vcn.default_dhcp_options_id
}

# Private Subnet - Chuncheon
resource "oci_core_subnet" "chuncheon_private_subnet" {
  provider                   = oci.chuncheon
  compartment_id             = var.compartment_id_chuncheon
  vcn_id                     = oci_core_vcn.chuncheon_vcn.id
  cidr_block                 = "10.0.2.0/24"
  display_name               = "chuncheon-private-subnet"
  dns_label                  = "chprivate"
  prohibit_public_ip_on_vnic = true

  security_list_ids = [oci_core_security_list.chuncheon_private_sl.id]
  route_table_id    = oci_core_route_table.chuncheon_private_rt.id
  dhcp_options_id   = oci_core_vcn.chuncheon_vcn.default_dhcp_options_id
}

# ========================================
# Osaka Network Configuration
# ========================================

# VCN for Osaka Region
resource "oci_core_vcn" "osaka_vcn" {
  provider       = oci.osaka
  compartment_id = var.compartment_id_osaka
  cidr_blocks    = ["10.1.0.0/16"]
  display_name   = "osaka-vcn"
  dns_label      = "osaka"
}

# NAT Gateway for Osaka (no public subnet needed)
resource "oci_core_nat_gateway" "osaka_nat" {
  provider       = oci.osaka
  compartment_id = var.compartment_id_osaka
  vcn_id         = oci_core_vcn.osaka_vcn.id
  display_name   = "osaka-nat-gateway"
}

# Route Table for Private Subnet - Osaka
resource "oci_core_route_table" "osaka_private_rt" {
  provider       = oci.osaka
  compartment_id = var.compartment_id_osaka
  vcn_id         = oci_core_vcn.osaka_vcn.id
  display_name   = "osaka-private-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.osaka_nat.id
  }
}

# Security List for Private Subnet - Osaka
resource "oci_core_security_list" "osaka_private_sl" {
  provider       = oci.osaka
  compartment_id = var.compartment_id_osaka
  vcn_id         = oci_core_vcn.osaka_vcn.id
  display_name   = "osaka-private-security-list"

  # Allow all traffic from local VCN
  ingress_security_rules {
    protocol  = "all"
    source    = "10.1.0.0/16"
    stateless = false
  }

  # Allow traffic from Chuncheon VCN (for cross-region communication)
  ingress_security_rules {
    protocol  = "all"
    source    = "10.0.0.0/16"
    stateless = false
  }

  # All outbound traffic
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# Private Subnet - Osaka
resource "oci_core_subnet" "osaka_private_subnet" {
  provider                   = oci.osaka
  compartment_id             = var.compartment_id_osaka
  vcn_id                     = oci_core_vcn.osaka_vcn.id
  cidr_block                 = "10.1.2.0/24"
  display_name               = "osaka-private-subnet"
  dns_label                  = "osaprivate"
  prohibit_public_ip_on_vnic = true

  security_list_ids = [oci_core_security_list.osaka_private_sl.id]
  route_table_id    = oci_core_route_table.osaka_private_rt.id
  dhcp_options_id   = oci_core_vcn.osaka_vcn.default_dhcp_options_id
}

