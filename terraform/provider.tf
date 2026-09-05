# Conexion remota por SSH: ni el operador ni CI ejecutan terraform en el
# propio hipervisor (ver ADR-009). Vale tanto para correrlo desde CI (via
# Tailscale) como desde una laptop.
#
# socket= es obligatorio: este host usa los daemons modulares de libvirt
# (virtqemud, no el libvirtd monolitico legacy), asi que el socket real es
# /run/libvirt/virtqemud-sock. Sin este parametro, el transporte SSH remoto
# asume el path legacy /run/libvirt/libvirt-sock, que existe como archivo
# huerfano (el socket unit legacy esta "inactive") pero no tiene nada
# escuchando detras -> "connect failed" al conectar via SSH.
provider "libvirt" {
  uri = "qemu+ssh://${var.hypervisor_ssh_user}@${var.hypervisor_ssh_host}/system?keyfile=${var.hypervisor_ssh_keyfile}&no_verify=1&socket=/run/libvirt/virtqemud-sock"
}
