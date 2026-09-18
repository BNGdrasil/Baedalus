# ========================================
# Chuncheon Region Outputs
# ========================================

output "vm1_public_ip" {
  description = "Public IP address of VM1 (Frontend & Proxy)"
  value       = oci_core_instance.vm1_frontend.public_ip
}

output "vm1_private_ip" {
  description = "Private IP address of VM1"
  value       = oci_core_instance.vm1_frontend.private_ip
}

output "vm2_public_ip" {
  description = "Public IP address of VM2 (Core APIs)"
  value       = oci_core_instance.vm2_core_apis.public_ip
}

output "vm2_private_ip" {
  description = "Private IP address of VM2"
  value       = oci_core_instance.vm2_core_apis.private_ip
}

output "vm3_private_ip" {
  description = "Private IP address of VM3 (Database)"
  value       = oci_core_instance.vm3_database.private_ip
}

# ========================================
# Osaka Region Outputs
# ========================================

output "vm4_private_ip" {
  description = "Private IP address of VM4 (Monitoring)"
  value       = oci_core_instance.vm4_monitoring.private_ip
}

# VM5, VM6는 퇴역했고 enable_vm5 / enable_vm6 기본값이 false이므로 아래 출력은
# 평소에 null이 된다. 다시 활성화했을 때만 주소가 나온다.
output "vm5_private_ip" {
  description = "Private IP address of VM5 (Backup). 퇴역 상태에서는 null이다."
  value       = one(oci_core_instance.vm5_backup[*].private_ip)
}

output "vm6_private_ip" {
  description = "Private IP address of VM6 (Sandbox). 퇴역 상태에서는 null이다."
  value       = one(oci_core_instance.vm6_playground[*].private_ip)
}

# ========================================
# Instance IDs
# ========================================

output "instance_ids" {
  description = "OCIDs of all compute instances"
  value = {
    vm1_frontend   = oci_core_instance.vm1_frontend.id
    vm2_core_apis  = oci_core_instance.vm2_core_apis.id
    vm3_database   = oci_core_instance.vm3_database.id
    vm4_monitoring = oci_core_instance.vm4_monitoring.id
    vm5_backup     = one(oci_core_instance.vm5_backup[*].id)
    vm6_playground = one(oci_core_instance.vm6_playground[*].id)
  }
}

# ========================================
# Network Information
# ========================================

output "chuncheon_vcn_id" {
  description = "OCID of Chuncheon VCN"
  value       = oci_core_vcn.chuncheon_vcn.id
}

output "osaka_vcn_id" {
  description = "OCID of Osaka VCN"
  value       = oci_core_vcn.osaka_vcn.id
}

# ========================================
# Connection Strings
# ========================================

output "ssh_connections" {
  description = "SSH connection commands for all VMs"
  value = {
    vm1      = "ssh ubuntu@${oci_core_instance.vm1_frontend.public_ip}"
    vm2      = "ssh ubuntu@${oci_core_instance.vm2_core_apis.public_ip}"
    vm3      = "ssh -J ubuntu@${oci_core_instance.vm2_core_apis.public_ip} ubuntu@${oci_core_instance.vm3_database.private_ip}"
    vm4_note = "VM4 (Osaka, 미구성 예비) requires VCN peering or a separate jump host - IP: ${oci_core_instance.vm4_monitoring.private_ip}. VM5/VM6는 퇴역했다."
  }
}

output "service_urls" {
  description = "Service access URLs"
  value = {
    main_site       = "https://${var.domain_name}"
    api_gateway     = "https://api.${var.domain_name}"
    monitoring_note = "Grafana는 VM2에서 동작하며 VM1 Nginx가 https://monitoring.${var.domain_name}로 프록시한다"
  }
}

# ========================================
# Resource Summary
# ========================================

output "resource_summary" {
  description = "Summary of deployed resources"
  value = {
    # 실제 운영 대상은 VM1~VM3이며 VM4는 미구성 예비 자원이다.
    # VM5, VM6는 퇴역했으므로 아래 집계에서 제외한다.
    total_vms = 4
    chuncheon_vms = {
      vm1 = "${var.vm_configs.vm1.ocpus} OCPU, ${var.vm_configs.vm1.memory_in_gbs}GB RAM, ${var.vm_configs.vm1.boot_volume_size_in_gbs}GB Storage"
      vm2 = "${var.vm_configs.vm2.ocpus} OCPU, ${var.vm_configs.vm2.memory_in_gbs}GB RAM, ${var.vm_configs.vm2.boot_volume_size_in_gbs}GB Storage"
      vm3 = "${var.vm_configs.vm3.ocpus} OCPU, ${var.vm_configs.vm3.memory_in_gbs}GB RAM, ${var.vm_configs.vm3.boot_volume_size_in_gbs}GB Storage"
    }
    osaka_vms = {
      vm4 = "${var.vm_configs.vm4.ocpus} OCPU, ${var.vm_configs.vm4.memory_in_gbs}GB RAM, ${var.vm_configs.vm4.boot_volume_size_in_gbs}GB Storage (미구성 예비)"
      vm5 = "퇴역"
      vm6 = "퇴역"
    }
    total_resources = {
      ocpus      = var.vm_configs.vm1.ocpus + var.vm_configs.vm2.ocpus + var.vm_configs.vm3.ocpus + var.vm_configs.vm4.ocpus
      ram_gb     = var.vm_configs.vm1.memory_in_gbs + var.vm_configs.vm2.memory_in_gbs + var.vm_configs.vm3.memory_in_gbs + var.vm_configs.vm4.memory_in_gbs
      storage_gb = var.vm_configs.vm1.boot_volume_size_in_gbs + var.vm_configs.vm2.boot_volume_size_in_gbs + var.vm_configs.vm3.boot_volume_size_in_gbs + var.vm_configs.vm4.boot_volume_size_in_gbs
    }
  }
}
