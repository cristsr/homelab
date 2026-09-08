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
  # /var/lib/libvirt vive en la particion raiz del hipervisor, que en este
  # host tiene solo ~50GB - insuficiente para el disco raiz de la VM (120GB)
  # mas el disco dedicado de OpenEBS (100GB). /home esta en una particion
  # separada con mucho mas espacio libre, asi que el pool completo (ambos
  # discos + la imagen base + el ISO de cloud-init) vive ahi.
  description = "Path en el host donde vive el pool de libvirt dedicado a este modulo"
  type        = string
  default     = "/home/libvirt/images/homelab"
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

variable "openebs_disk_size_bytes" {
  description = "Tamano del disco dedicado (vdb, raw) para el Volume Group LVM de OpenEBS Local PV LVM (bytes)"
  type        = number
  default     = 107374182400 # 100 GiB
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

variable "hypervisor_ssh_host" {
  description = "IP/hostname (Tailscale) del hipervisor fisico, para llegar a libvirt y a la VM (NAT interna) via SSH remoto. Sin default: nunca hardcodear infraestructura de red en el repo."
  type        = string
}

variable "hypervisor_ssh_user" {
  description = "Usuario SSH del hipervisor (debe estar en el grupo libvirt)"
  type        = string
}

variable "hypervisor_ssh_keyfile" {
  description = "Path absoluto, en la maquina donde corre Terraform/Ansible, a la clave privada SSH dedicada para llegar al hipervisor"
  type        = string
}
