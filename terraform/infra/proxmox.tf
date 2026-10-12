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
    discard      = "on"
    cache        = "none"
  }

  # Dedicated disk for the OpenEBS ZFS LocalPV pool, kept separate from the install disk.
  disk {
    interface    = "virtio1"
    datastore_id = var.proxmox_datastore_id
    size         = var.zfs_disk_size_gb
    discard      = "on"
    cache        = "none"
  }

  # Media library's ZFS LocalPV pool. Lives on its own physical disk
  # (media_datastore_id, plain LVM - no thin-provisioning) instead of local-lvm:
  # that pool is shared with the OS/ZFS-config disks and the DB LXCs, and a media
  # library growing past what was thin-provisioned once froze the whole VM
  # (Proxmox pauses on ENOSPC). See docs/DECISIONS.md for the incident.
  disk {
    interface    = "virtio2"
    datastore_id = var.media_datastore_id
    size         = var.media_disk_size_gb
    discard      = "on"
    cache        = "none"
    backup       = false
    replicate    = false
  }

  # GPU for Jellyfin's NVENC transcoding. The host must already have IOMMU on and
  # the card bound to vfio-pci (see docs/DECISIONS.md); a VM with this set won't
  # start otherwise.
  dynamic "hostpci" {
    for_each = var.gpu_pci_id == "" ? [] : [var.gpu_pci_id]
    content {
      device = "hostpci0"
      id     = hostpci.value
      pcie   = true
      rombar = true
    }
  }

  cdrom {
    file_id   = proxmox_download_file.talos_iso.id
    interface = "ide3"
  }

  boot_order = ["virtio0", "ide3"]

  # Fixed MAC so a static IP can be reserved via DHCP for the maintenance-mode boot.
  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = var.vm_mac_address
  }

  operating_system {
    type = "l26"
  }
}

# Maintenance-mode IP (via DHCP, before the machine config is applied),
# skipping "lo" and any interfaces without an IPv4 address.
locals {
  maintenance_ip = [
    for idx, ips in proxmox_virtual_environment_vm.talos_node.ipv4_addresses :
    ips[0] if length(ips) > 0 && proxmox_virtual_environment_vm.talos_node.network_interface_names[idx] != "lo"
  ][0]
}
