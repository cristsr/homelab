variable "proxmox_endpoint" {
  description = "URL de la API de Proxmox VE (https://host:8006/)"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token de Proxmox, formato 'user@realm!tokenid=uuid'"
  type        = string
  sensitive   = true
}

variable "proxmox_node_name" {
  description = "Nombre del nodo Proxmox donde se crea la VM"
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Version de Talos Linux a usar (debe existir en el Image Factory)"
  type        = string
  default     = "v1.14.0"
}

variable "talos_schematic_id" {
  description = "ID del schematic generado en https://factory.talos.dev (extensiones: qemu-guest-agent, tailscale, zfs)"
  type        = string
  default     = "4dc4594391d715ab33e9c2ae96950b98049cc9e7cb24443d0568983914de5b11"
}

variable "vm_id" {
  description = "ID numerico de la VM en Proxmox"
  type        = number
  default     = 100
}

variable "vm_name" {
  description = "Nombre de la VM y hostname del nodo Talos"
  type        = string
  default     = "homelab"
}

variable "memory_mib" {
  description = "Memoria de la VM en MiB"
  type        = number
  default     = 16384
}

variable "vcpu" {
  description = "vCPUs de la VM"
  type        = number
  default     = 8
}

variable "disk_size_gb" {
  description = "Tamano del disco de instalacion de Talos (GB)"
  type        = number
  default     = 120
}

variable "zfs_disk_size_gb" {
  description = "Tamano del disco dedicado (vdb) para el zpool de OpenEBS ZFS LocalPV (GB)"
  type        = number
  default     = 100
}

variable "proxmox_datastore_id" {
  description = "Datastore de Proxmox donde viven los discos y el ISO descargado"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Bridge de Proxmox al que se conecta la NIC de la VM"
  type        = string
  default     = "vmbr0"
}

variable "vm_static_ip" {
  description = "IP estatica del nodo Talos en la LAN"
  type        = string
}

variable "vm_mac_address" {
  description = "MAC fija de la NIC del nodo Talos - reservar var.vm_static_ip a esta MAC en el DHCP del router"
  type        = string
  default     = "02:00:00:00:00:30"
}

variable "vm_ip_prefix" {
  description = "Prefijo CIDR de la IP estatica"
  type        = number
  default     = 24
}

variable "vm_gateway" {
  description = "Gateway de la LAN"
  type        = string
}

variable "vm_dns_servers" {
  description = "Servidores DNS para el nodo Talos"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "cluster_name" {
  description = "Nombre del cluster Talos/Kubernetes"
  type        = string
  default     = "homelab"
}
