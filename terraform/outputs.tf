output "vm_static_ip" {
  description = "IP estatica de la VM del nodo k0s"
  value       = var.vm_static_ip
}

output "vm_mac" {
  description = "MAC address de la NIC de la VM"
  value       = var.vm_mac
}

output "ssh_private_key_path" {
  description = "Path a la llave privada generada para SSH/Ansible"
  value       = abspath(local_file.vm_private_key.filename)
}
