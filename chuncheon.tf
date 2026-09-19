# ========================================
# Chuncheon Region VM Instances
# ========================================

# VM1: Frontend & Proxy (Public Subnet)
resource "oci_core_instance" "vm1_frontend" {
  provider            = oci.chuncheon
  availability_domain = data.oci_identity_availability_domains.chuncheon_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_chuncheon
  display_name        = var.vm_configs.vm1.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm1.ocpus
    memory_in_gbs = var.vm_configs.vm1.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.chuncheon_public_subnet.id
    assign_public_ip = true
    display_name     = "vm1-vnic"
    hostname_label   = "vm1"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.chuncheon_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm1.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/scripts/user_data_vm1.sh", {
      domain_name       = var.domain_name
      postgres_user     = var.postgres_user
      postgres_password = var.postgres_password
      jwt_secret_key    = var.jwt_secret_key
    }))
  }

  # boot volume 보존. 인스턴스를 삭제해야 하는 상황에서도 boot volume을 남긴다.
  # VM1은 Nginx 설정과 정적 사이트 산출물이 boot volume 위에만 존재한다.
  # oracle/oci provider 5.47.0에서 preserve_boot_volume은 ForceNew 속성이 아니며
  # terminate 요청에만 사용되므로, 값 변경은 in-place update로 처리된다.
  # 다만 apply 전에 plan 출력이 replace가 아닌 update인지 반드시 확인한다.
  preserve_boot_volume = true

  lifecycle {
    # cloud-init(user_data)은 최초 부팅에만 실행되므로, 실행 중인 인스턴스의 구성은
    # scripts/ 아래 배포 스크립트가 담당한다. 반면 OCI provider는 metadata가 바뀌면
    # 인스턴스를 replace한다. user_data뿐 아니라 ssh_authorized_keys 변경도 같은
    # 교체를 유발하므로, metadata 전체를 무시한다. 키 교체나 재부트스트랩이 필요하면
    # 배포 스크립트나 OCI 콘솔로 처리한다.
    ignore_changes = [
      source_details[0].source_id,
      metadata,
    ]

    # 운영 데이터가 있는 인스턴스다. 교체나 삭제 계획이 나오면 apply 전에 실패시킨다.
    # count를 쓰는 VM5, VM6에는 넣지 않는다. 그쪽은 state 정리 대상이기 때문이다.
    prevent_destroy = true
  }
}

# VM2: Core APIs (Public Subnet)
resource "oci_core_instance" "vm2_core_apis" {
  provider            = oci.chuncheon
  availability_domain = data.oci_identity_availability_domains.chuncheon_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_chuncheon
  display_name        = var.vm_configs.vm2.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm2.ocpus
    memory_in_gbs = var.vm_configs.vm2.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.chuncheon_public_subnet.id
    assign_public_ip = true
    display_name     = "vm2-vnic"
    hostname_label   = "vm2"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.chuncheon_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm2.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/scripts/user_data_vm2.sh", {
      domain_name       = var.domain_name
      postgres_user     = var.postgres_user
      postgres_password = var.postgres_password
      jwt_secret_key    = var.jwt_secret_key
      vm3_private_ip    = oci_core_instance.vm3_database.private_ip
    }))
  }

  # boot volume 보존. 인스턴스를 삭제해야 하는 상황에서도 boot volume을 남긴다.
  # VM2는 /opt/bnbong 아래의 배포 산출물과 컨테이너 볼륨이 boot volume 위에만 존재한다.
  # oracle/oci provider 5.47.0에서 preserve_boot_volume은 ForceNew 속성이 아니며
  # terminate 요청에만 사용되므로, 값 변경은 in-place update로 처리된다.
  # 다만 apply 전에 plan 출력이 replace가 아닌 update인지 반드시 확인한다.
  preserve_boot_volume = true

  lifecycle {
    # cloud-init(user_data)은 최초 부팅에만 실행되므로, 실행 중인 인스턴스의 구성은
    # scripts/ 아래 배포 스크립트가 담당한다. 반면 OCI provider는 metadata가 바뀌면
    # 인스턴스를 replace한다. user_data뿐 아니라 ssh_authorized_keys 변경도 같은
    # 교체를 유발하므로, metadata 전체를 무시한다. 키 교체나 재부트스트랩이 필요하면
    # 배포 스크립트나 OCI 콘솔로 처리한다.
    ignore_changes = [
      source_details[0].source_id,
      metadata,
    ]

    # 운영 데이터가 있는 인스턴스다. 교체나 삭제 계획이 나오면 apply 전에 실패시킨다.
    # count를 쓰는 VM5, VM6에는 넣지 않는다. 그쪽은 state 정리 대상이기 때문이다.
    prevent_destroy = true
  }

  depends_on = [oci_core_instance.vm3_database]
}

# VM3: Database (Private Subnet)
resource "oci_core_instance" "vm3_database" {
  provider            = oci.chuncheon
  availability_domain = data.oci_identity_availability_domains.chuncheon_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_chuncheon
  display_name        = var.vm_configs.vm3.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm3.ocpus
    memory_in_gbs = var.vm_configs.vm3.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.chuncheon_private_subnet.id
    assign_public_ip = false
    display_name     = "vm3-vnic"
    hostname_label   = "vm3"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.chuncheon_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm3.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/scripts/user_data_vm3.sh", {
      postgres_user     = var.postgres_user
      postgres_password = var.postgres_password
    }))
  }

  # boot volume 보존. 인스턴스를 삭제해야 하는 상황에서도 boot volume을 남긴다.
  # VM3는 호스트 PostgreSQL과 mongod의 데이터 디렉터리가 boot volume 위에만 존재한다.
  # oracle/oci provider 5.47.0에서 preserve_boot_volume은 ForceNew 속성이 아니며
  # terminate 요청에만 사용되므로, 값 변경은 in-place update로 처리된다.
  # 다만 apply 전에 plan 출력이 replace가 아닌 update인지 반드시 확인한다.
  preserve_boot_volume = true

  lifecycle {
    # cloud-init(user_data)은 최초 부팅에만 실행되므로, 실행 중인 인스턴스의 구성은
    # scripts/ 아래 배포 스크립트가 담당한다. 반면 OCI provider는 metadata가 바뀌면
    # 인스턴스를 replace한다. user_data뿐 아니라 ssh_authorized_keys 변경도 같은
    # 교체를 유발하므로, metadata 전체를 무시한다. 키 교체나 재부트스트랩이 필요하면
    # 배포 스크립트나 OCI 콘솔로 처리한다.
    ignore_changes = [
      source_details[0].source_id,
      metadata,
    ]

    # 운영 데이터가 있는 인스턴스다. 교체나 삭제 계획이 나오면 apply 전에 실패시킨다.
    # count를 쓰는 VM5, VM6에는 넣지 않는다. 그쪽은 state 정리 대상이기 때문이다.
    prevent_destroy = true
  }
}

