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

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
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

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
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

  preserve_boot_volume = false

  lifecycle {
    ignore_changes = [
      source_details[0].source_id,
    ]
  }
}

