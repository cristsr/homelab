# Proxmox no usa libvirt: todo pasa por su API REST (:8006), sin SSH. El
# certificado es autofirmado (instalacion default), de ahi insecure = true.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true
}

# Sin bloque de configuracion propio: cada resource/data source de Talos
# recibe explicitamente su client_configuration/node, no hay endpoint global.
provider "talos" {}
