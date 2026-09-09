resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node_name
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-${var.talos_schematic_id}.iso"
}

resource "proxmox_virtual_environment_vm" "talos_node" {
  name      = var.vm_name
  node_name = var.proxmox_node_name
  vm_id     = var.vm_id

  bios    = "ovmf"
  machine = "q35"

  agent {
    enabled = true
    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.vcpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mib
  }

  efi_disk {
    datastore_id = var.proxmox_datastore_id
    type         = "4m"
  }

  disk {
    interface    = "virtio0"
    datastore_id = var.proxmox_datastore_id
    size         = var.disk_size_gb
  }

  # Disco dedicado al zpool de OpenEBS ZFS LocalPV, separado del disco de
  # instalacion a proposito.
  disk {
    interface    = "virtio1"
    datastore_id = var.proxmox_datastore_id
    size         = var.zfs_disk_size_gb
  }

  cdrom {
    file_id   = proxmox_download_file.talos_iso.id
    interface = "ide3"
  }

  boot_order = ["virtio0", "ide3"]

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}

# IP en modo mantenimiento (via DHCP, antes de aplicar el machine config).
# Descarta "lo" y las interfaces virtuales de Talos sin IPv4.
locals {
  maintenance_ip = [
    for idx, ips in proxmox_virtual_environment_vm.talos_node.ipv4_addresses :
    ips[0] if length(ips) > 0 && proxmox_virtual_environment_vm.talos_node.network_interface_names[idx] != "lo"
  ][0]
}
