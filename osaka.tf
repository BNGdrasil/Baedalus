# ========================================
# Osaka Region VM Instances
# ========================================

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
    ignore_changes = [
      source_details[0].source_id,
    ]
  }

  depends_on = [
    oci_core_instance.vm1_frontend,
    oci_core_instance.vm2_core_apis,
    oci_core_instance.vm3_database
  ]
}

# VM5: Backup & Long-term Storage (Private Subnet)
resource "oci_core_instance" "vm5_backup" {
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
    user_data = base64encode(templatefile("${path.module}/scripts/user_data_vm5.sh", {
      postgres_user     = var.postgres_user
      postgres_password = var.postgres_password
      vm3_private_ip    = oci_core_instance.vm3_database.private_ip
    }))
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }

  depends_on = [oci_core_instance.vm3_database]
}

# VM6: Sandbox & Development (Private Subnet)
resource "oci_core_instance" "vm6_playground" {
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
    user_data           = base64encode(file("${path.module}/scripts/user_data_vm6.sh"))
  }

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}
