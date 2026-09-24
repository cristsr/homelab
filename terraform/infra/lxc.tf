# Data and secrets-service LXC containers, on the same Proxmox node as the
# Talos VM. Created with no engine installed (only disk, CPU/memory and a
# static-IP network); installing each engine is left for a later
# provisioning step.

locals {
  data_services = {
    postgresql = {
      vmid       = 121
      ip         = "192.168.80.31"
      bridge     = var.network_bridge
      gateway    = var.vm_gateway
      memory_mib = 1024
      cores      = 1
      disk_gb    = 15
    }
    mongodb = {
      vmid       = 122
      ip         = "192.168.80.32"
      bridge     = var.network_bridge
      gateway    = var.vm_gateway
      memory_mib = 1024
      cores      = 1
      disk_gb    = 10
    }
    qdrant = {
      vmid       = 123
      ip         = "192.168.80.33"
      bridge     = var.network_bridge
      gateway    = var.vm_gateway
      memory_mib = 1024
      cores      = 1
      disk_gb    = 10
    }
    redis = {
      vmid       = 124
      ip         = "192.168.80.34"
      bridge     = var.network_bridge
      gateway    = var.vm_gateway
      memory_mib = 512
      cores      = 1
      disk_gb    = 5
    }
    mysql = {
      vmid       = 125
      ip         = "192.168.80.35"
      bridge     = var.network_bridge
      gateway    = var.vm_gateway
      memory_mib = 1024
      cores      = 1
      disk_gb    = 15
    }
  }
}

resource "proxmox_download_file" "data_vztmpl" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = var.proxmox_node_name
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  file_name    = "debian-13-standard_13.6-1_amd64.tar.zst"
}

resource "proxmox_virtual_environment_container" "data_service" {
  for_each = local.data_services

  node_name    = var.proxmox_node_name
  vm_id        = each.value.vmid
  unprivileged = true

  # Each engine runs as a Podman container inside the LXC. Without
  # nesting+fuse, an unprivileged LXC can't mount Podman's overlayfs and the
  # service ends up in a restart loop.
  features {
    nesting = true
    fuse    = true
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory_mib
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    size         = each.value.disk_gb
  }

  initialization {
    hostname = each.key

    dns {
      servers = var.vm_dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = each.value.gateway
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = each.value.bridge
  }

  operating_system {
    template_file_id = proxmox_download_file.data_vztmpl.id
    type             = "debian"
  }
}
