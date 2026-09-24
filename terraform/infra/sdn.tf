# Isolated subnet for the data LXCs. It has no physical NIC: the hypervisor is
# its gateway, so anything that reaches it crosses the hypervisor's forward
# rules (ansible/hypervisor-network.yaml). SNAT lets the containers pull
# images and updates without a route from the LAN back into them.

resource "proxmox_sdn_zone_simple" "data" {
  id    = "data"
  nodes = [var.proxmox_node_name]
}

resource "proxmox_sdn_vnet" "data" {
  id   = var.data_network_bridge
  zone = proxmox_sdn_zone_simple.data.id
}

resource "proxmox_sdn_subnet" "data" {
  vnet    = proxmox_sdn_vnet.data.id
  cidr    = var.data_subnet_cidr
  gateway = var.data_gateway
  snat    = true
}

# SDN objects stay pending in Proxmox until this applies them.
resource "proxmox_sdn_applier" "data" {
  depends_on = [
    proxmox_sdn_zone_simple.data,
    proxmox_sdn_vnet.data,
    proxmox_sdn_subnet.data,
  ]
}
