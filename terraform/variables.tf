variable "fedora_cloud_image_url" {
  description = "URL directa al qcow2 de Fedora Cloud Base (ver https://fedoraproject.org/cloud/download). No tiene default a proposito: cada release/build cambia de nombre."
  type        = string
}

variable "vm_name" {
  description = "Nombre del dominio libvirt y hostname de la VM"
  type        = string
  default     = "homelab"
}

variable "pool_path" {
  description = "Path en el host donde vive el pool de libvirt dedicado a este modulo"
  type        = string
  default     = "/var/lib/libvirt/images/homelab"
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

variable "disk_size_bytes" {
  description = "Tamano del disco overlay de la VM (bytes)"
  type        = number
  default     = 128849018880 # 120 GiB
}

variable "libvirt_network_name" {
  description = "Red libvirt NAT existente a usar (virbr0)"
  type        = string
  default     = "default"
}

variable "vm_mac" {
  description = "MAC fija de la NIC de la VM. Necesaria para que el network-config (match: macaddress + set-name) enlace de forma confiable con la interfaz real."
  type        = string
  default     = "52:54:00:12:34:56"
}

variable "vm_static_ip" {
  description = "IP estatica de la VM dentro de la red NAT (192.168.122.0/24)"
  type        = string
  default     = "192.168.122.10"
}

variable "vm_ip_prefix" {
  description = "Prefijo CIDR de la IP estatica"
  type        = number
  default     = 24
}

variable "vm_gateway" {
  description = "Gateway de la red NAT (IP del host en virbr0)"
  type        = string
  default     = "192.168.122.1"
}

variable "vm_dns_servers" {
  description = "Servidores DNS para la VM"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_user" {
  description = "Usuario creado via cloud-init para SSH/Ansible"
  type        = string
  default     = "fedora"
}

variable "timezone" {
  description = "Timezone de la VM"
  type        = string
  default     = "UTC"
}
