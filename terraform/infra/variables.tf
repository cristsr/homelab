variable "proxmox_endpoint" {
  description = "Proxmox VE API URL (https://host:8006/)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token, format 'user@realm!tokenid=uuid'"
  type        = string
  sensitive   = true
}

variable "proxmox_node_name" {
  description = "Proxmox node name where the VM is created"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version to use (must exist in the Image Factory)"
  type        = string
  default     = "v1.14.0"
}

variable "talos_schematic_id" {
  description = "Schematic ID generated at https://factory.talos.dev (extensions: qemu-guest-agent, tailscale, zfs)"
  type        = string
  default     = "4dc4594391d715ab33e9c2ae96950b98049cc9e7cb24443d0568983914de5b11"
}

variable "vm_id" {
  description = "Numeric VM ID in Proxmox"
  type        = number
  default     = 100
}

variable "vm_name" {
  description = "VM name and Talos node hostname"
  type        = string
  default     = "talos"
}

variable "memory_mib" {
  description = "VM memory in MiB"
  type        = number
  default     = 24576
}

variable "vcpu" {
  description = "VM vCPUs"
  type        = number
  default     = 8
}

variable "disk_size_gb" {
  description = "Talos installation disk size (GB)"
  type        = number
  default     = 120
}

variable "zfs_disk_size_gb" {
  description = "Dedicated disk size (vdb) for the OpenEBS ZFS LocalPV zpool (GB)"
  type        = number
  default     = 100
}

variable "media_disk_size_gb" {
  description = "Dedicated disk size (vdc) for the media library's OpenEBS ZFS LocalPV zpool (GB)"
  type        = number
  default     = 1024
}

variable "proxmox_datastore_id" {
  description = "Proxmox datastore where the disks and downloaded ISO live"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Proxmox bridge the VM's NIC connects to"
  type        = string
  default     = "vmbr0"
}

variable "vm_static_ip" {
  description = "Static IP of the Talos node on the LAN"
  type        = string
}

variable "vm_mac_address" {
  description = "Fixed MAC address of the Talos node's NIC - reserve var.vm_static_ip to this MAC in the router's DHCP"
  type        = string
  default     = "02:00:00:00:00:30"
}

variable "vm_ip_prefix" {
  description = "CIDR prefix of the static IP"
  type        = number
  default     = 24
}

variable "vm_gateway" {
  description = "LAN gateway"
  type        = string
}

variable "vm_dns_servers" {
  description = "DNS servers for the Talos node"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name"
  type        = string
  default     = "talos"
}
