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

# Permite reconstruir el kubeconfig desde el state remoto (terraform output
# -raw kubeconfig_raw) sin re-aplicar infra - lo usa terraform-plan.yml para
# poder planear terraform/cluster contra el cluster real.
output "kubeconfig_raw" {
  description = "Contenido del kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "data_service_ips" {
  description = "IP estatica IPv4 de cada contenedor LXC de datos"
  value       = { for name, svc in local.data_services : name => svc.ip }
}
