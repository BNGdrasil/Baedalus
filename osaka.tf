# ========================================
# Osaka Region VM Instances
# ========================================
#
# 퇴역 정리 (I09)
#   VM5와 VM6는 운영자 설명상 이미 삭제된 인스턴스다. 정의를 파일에서 완전히
#   지우는 대신 `count = var.enable_vmN ? 1 : 0` 형태로 바꾸고 기본값을 false로
#   두었다. 그 이유는 다음과 같다.
#     - terraform.tfstate에는 두 인스턴스가 아직 RUNNING 상태로 남아 있다.
#       실제 OCI 자원과 state를 대조하기 전에는 무엇이 남아 있는지 확정할 수 없다.
#     - 정의만 삭제하면 이후에 다시 확인할 근거가 사라지고, 되살려야 할 때
#       작성 내용을 복원하기 어렵다.
#     - 기본값 false는 실수로 apply했을 때 삭제한 VM이 다시 생성되는 사고를 막는다.
#   실제 state 정리 절차
#     1. OCI 콘솔이나 CLI로 vm5-backup, vm6-sandbox 인스턴스와 boot volume의
#        잔존 여부를 확인한다.
#     2. 자원이 없으면 `terraform state rm oci_core_instance.vm5_backup`과
#        `terraform state rm oci_core_instance.vm6_playground`로 state에서만 제거한다.
#     3. 자원이 남아 있으면 삭제 여부를 먼저 결정하고 plan을 검토한다.
#   이 저장소의 어떤 작업도 apply를 실행하지 않는다.
#
#   VM4는 미구성 예비 자원이므로 정의를 그대로 유지한다. Docker와 /opt/bnbong이
#   없고 애플리케이션 DB도 구성되어 있지 않으므로, replica나 DR 자원으로 계산하지 않는다.

# VM4: Monitoring & Observability (Private Subnet)
resource "oci_core_instance" "vm4_monitoring" {
  provider            = oci.osaka
  availability_domain = data.oci_identity_availability_domains.osaka_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_osaka
  display_name        = var.vm_configs.vm4.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm4.ocpus
    memory_in_gbs = var.vm_configs.vm4.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.osaka_private_subnet.id
    assign_public_ip = false
    display_name     = "vm4-vnic"
    hostname_label   = "vm4"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.osaka_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm4.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/scripts/user_data_vm4.sh", {
      vm1_private_ip = oci_core_instance.vm1_frontend.private_ip
      vm2_private_ip = oci_core_instance.vm2_core_apis.private_ip
      vm3_private_ip = oci_core_instance.vm3_database.private_ip
    }))
  }

  preserve_boot_volume = false

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
  }

  depends_on = [
    oci_core_instance.vm1_frontend,
    oci_core_instance.vm2_core_apis,
    oci_core_instance.vm3_database
  ]
}

# VM5: Backup & Long-term Storage (Private Subnet) — 퇴역. 기본 비활성.
# cloud-init 스크립트는 scripts/legacy/user_data_vm5.sh로 옮겼다.
resource "oci_core_instance" "vm5_backup" {
  count = var.enable_vm5 ? 1 : 0

  provider            = oci.osaka
  availability_domain = data.oci_identity_availability_domains.osaka_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_osaka
  display_name        = var.vm_configs.vm5.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm5.ocpus
    memory_in_gbs = var.vm_configs.vm5.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.osaka_private_subnet.id
    assign_public_ip = false
    display_name     = "vm5-vnic"
    hostname_label   = "vm5"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.osaka_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm5.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/scripts/legacy/user_data_vm5.sh", {
      postgres_user     = var.postgres_user
      postgres_password = var.postgres_password
      vm3_private_ip    = oci_core_instance.vm3_database.private_ip
    }))
  }

  preserve_boot_volume = false

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
  }

  depends_on = [oci_core_instance.vm3_database]
}

# VM6: Sandbox & Development (Private Subnet) — 퇴역. 기본 비활성.
# cloud-init 스크립트는 scripts/legacy/user_data_vm6.sh로 옮겼다.
resource "oci_core_instance" "vm6_playground" {
  count = var.enable_vm6 ? 1 : 0

  provider            = oci.osaka
  availability_domain = data.oci_identity_availability_domains.osaka_ads.availability_domains[0].name
  compartment_id      = var.compartment_id_osaka
  display_name        = var.vm_configs.vm6.display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.vm_configs.vm6.ocpus
    memory_in_gbs = var.vm_configs.vm6.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.osaka_private_subnet.id
    assign_public_ip = false
    display_name     = "vm6-vnic"
    hostname_label   = "vm6"
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.osaka_ubuntu.images[0].id
    boot_volume_size_in_gbs = var.vm_configs.vm6.boot_volume_size_in_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(file("${path.module}/scripts/legacy/user_data_vm6.sh"))
  }

  preserve_boot_volume = false

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
  }
}
