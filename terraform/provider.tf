# Conexion remota por SSH: ni el operador ni CI ejecutan terraform en el
# propio hipervisor (ver ADR-009). Vale tanto para correrlo desde CI (via
# Tailscale) como desde una laptop.
provider "libvirt" {
  uri = "qemu+ssh://${var.hypervisor_ssh_user}@${var.hypervisor_ssh_host}/system?keyfile=${var.hypervisor_ssh_keyfile}&no_verify=1"
}
