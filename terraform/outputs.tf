output "vm_static_ip" {
  description = "IP estatica del nodo Talos"
  value       = var.vm_static_ip
}

output "kubeconfig_path" {
  description = "Path al kubeconfig generado"
  value       = abspath(local_file.kubeconfig.filename)
}

output "talosconfig_path" {
  description = "Path al talosconfig generado"
  value       = abspath(local_file.talosconfig.filename)
}
