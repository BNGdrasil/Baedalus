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
  # SEC-04: 기본값은 현행 설정과 같은 0.0.0.0/0이다. 관리 접근 경로(고정 IP,
  # 사무실 대역, bastion 등)를 확인한 뒤 var.admin_cidr로 좁힌다. 확인 전에
  # 값을 바꾸면 운영자가 VM에 접속하지 못할 수 있다.
  ingress_security_rules {
    protocol  = "6"
    source    = var.admin_cidr
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
  # SEC-04: 8000/8001을 0.0.0.0/0에 열어 두면 Cloudflare와 VM1 Nginx를 건너뛰고
  # VM2에 직접 연결할 수 있다. 그렇게 되면 Nginx의 요청 제한과 헤더 정리를
  # 우회하며, 앱이 X-Forwarded-* 헤더를 신뢰하는 경우 클라이언트 IP도 위조된다.
  # 실제 호출자는 춘천 public subnet의 VM1뿐이므로 그 대역으로 제한한다.
  ingress_security_rules {
    protocol  = "6"
    source    = var.api_client_cidr
    stateless = false
    tcp_options {
      min = 8000
      max = 8000
    }
  }

  # Auth Server
  ingress_security_rules {
    protocol  = "6"
    source    = var.api_client_cidr
    stateless = false
    tcp_options {
      min = 8001
      max = 8001
    }
  }

  # Internal communication (all VCN traffic)
  #
  # SEC-04 범위 주의: 이 규칙이 VCN 전체(10.0.0.0/16)에 모든 프로토콜을 허용하므로,
  # 위에서 8000과 8001을 var.api_client_cidr로 좁힌 효과는 **외부 인터넷 차단까지**다.
  # 같은 VCN 안의 VM은 이 규칙을 통해 여전히 VM2의 모든 포트에 접근할 수 있다.
  # 예를 들어 춘천 private subnet(10.0.2.0/24)의 VM3에서 VM2의 8000 포트로 연결할 수 있다.
  # 규칙 자체는 이번 변경에서 바꾸지 않았다. VM1과 VM2, VM3 사이에 실제로 필요한
  # 포트와 방향을 먼저 검증하지 않은 상태에서 좁히면 운영 중인 통신을 끊을 수 있다.
  # 후속 작업에서 필요한 포트만 남기는 형태로 분해한다.
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

