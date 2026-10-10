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
  description = "Schematic ID generated at https://factory.talos.dev (extensions: qemu-guest-agent, zfs, nonfree-kmod-nvidia-production, nvidia-container-toolkit-production)"
  type        = string
  default     = "42dcbb7542e7f2d53beec866d4687f9306cd2b2da3b049fb4872cfc41942723e"
}

variable "gpu_pci_id" {
  description = "PCI address of the host GPU to pass through to the Talos VM, without the function (e.g. \"0000:01:00\" passes the GPU and its audio function). Empty = no passthrough."
  type        = string
  default     = ""
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
  default     = 20480
}

variable "vcpu" {
  description = "VM vCPUs"
  type        = number
  default     = 12
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
  description = "Dedicated disk size (vdc) for the media library's OpenEBS ZFS LocalPV zpool (GB). Sized to the physical media_datastore_id disk, not thin-provisioned like local-lvm - keep this at or below that disk's real capacity."
  type        = number
  default     = 920
}

variable "proxmox_datastore_id" {
  description = "Proxmox datastore where the OS/ZFS-config disks and downloaded ISO live"
  type        = string
  default     = "local-lvm"
}

variable "media_datastore_id" {
  description = "Proxmox datastore for the media library disk - a dedicated physical disk (plain LVM, no thin-provisioning) kept separate from local-lvm so a full media library can't freeze the OS/config/DB disks"
  type        = string
  default     = "media-vg"
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

variable "data_network_bridge" {
  description = "Proxmox SDN VNet the data LXCs join once moved off the LAN"
  type        = string
  default     = "datanet"
}

variable "data_gateway" {
  description = "Gateway of the data subnet, held by the hypervisor"
  type        = string
  default     = "10.10.20.1"
}

variable "data_subnet_cidr" {
  description = "CIDR of the isolated data subnet"
  type        = string
  default     = "10.10.20.0/24"
}

variable "hypervisor_lan_ip" {
  description = "LAN address of the hypervisor, the next hop Talos uses to reach the data subnet"
  type        = string
  default     = "192.168.80.20"
}

variable "talos_api_allowed_sources" {
  description = "Addresses allowed to reach the Talos API and the Kubernetes API through the node's ingress firewall: the hypervisor (Tailscale traffic arrives masqueraded as it) and the operator's PC"
  type        = list(string)
  default     = ["192.168.80.20/32", "192.168.80.10/32"]
}

variable "cluster_internal_sources" {
  description = "Pod range first, then service range: allowed to reach the node's own address (Kubernetes API, kubelet) through the ingress firewall"
  type        = list(string)
  default     = ["10.244.0.0/16", "10.96.0.0/12"]
}
