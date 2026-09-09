# Descarga el ISO de Talos (con el schematic de extensiones) directo a
# Proxmox via su API download-url - no pasa por la maquina donde corre
# Terraform ni requiere SSH al hipervisor.
resource "proxmox_download_file" "talos_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.proxmox_node_name
  url          = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
  file_name    = "talos-${var.talos_version}-${var.talos_schematic_id}.iso"
}

# VM del nodo Talos. OVMF/q35 (no BIOS legacy, a diferencia del hipervisor
# Fedora anterior): pensado para el passthrough de GPU futuro (RTX 2060),
# que en Proxmox no tiene el problema de arranque silencioso que se
# encontro con libvirt/SeaBIOS en el host viejo.
resource "proxmox_virtual_environment_vm" "talos_node" {
  name      = var.vm_name
  node_name = var.proxmox_node_name
  vm_id     = var.vm_id

  bios    = "ovmf"
  machine = "q35"

  agent {
    enabled = true # requiere la extension qemu-guest-agent del schematic
    wait_for_ip {
      ipv4 = true
    }
  }

  cpu {
    cores = var.vcpu
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mib
  }

  efi_disk {
    datastore_id = var.proxmox_datastore_id
    type         = "4m"
  }

  # Disco de instalacion de Talos (equivalente al vda/root de antes).
  disk {
    interface    = "virtio0"
    datastore_id = var.proxmox_datastore_id
    size         = var.disk_size_gb
  }

  # Disco dedicado para el zpool de OpenEBS ZFS LocalPV (equivalente al
  # vdb/openebs_data_disk de antes) - separado del disco de instalacion a
  # proposito, mismo razonamiento que con LVM: es solo para PVCs.
  disk {
    interface    = "virtio1"
    datastore_id = var.proxmox_datastore_id
    size         = var.zfs_disk_size_gb
  }

  cdrom {
    file_id   = proxmox_download_file.talos_iso.id
    interface = "ide3"
  }

  # Arranca del disco si ya tiene bootloader (post-instalacion); si esta
  # vacio (primer boot) cae al ISO de Talos, que arranca en modo
  # mantenimiento y espera el machine config via la API.
  boot_order = ["virtio0", "ide3"]

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }
}

# IP que el nodo tiene en modo mantenimiento, ANTES de aplicar el machine
# config (via DHCP - todavia no tiene la IP estatica que le vamos a asignar).
# ipv4_addresses/network_interface_names vienen en el mismo orden por
# interfaz. El kernel de Talos trae varias interfaces virtuales sin IP
# (bond0, dummy0, teql0, tunl0, sit0, ip6tnl0 - lista vacia, confirmado
# contra la VM real) ademas de "lo" - se descartan ambos casos y se toma la
# unica interfaz real con al menos una IPv4.
locals {
  maintenance_ip = [
    for idx, ips in proxmox_virtual_environment_vm.talos_node.ipv4_addresses :
    ips[0] if length(ips) > 0 && proxmox_virtual_environment_vm.talos_node.network_interface_names[idx] != "lo"
  ][0]
}

# Secrets del cluster (PKI de etcd/Kubernetes) - se generan una sola vez y
# quedan en el state. Sensible: el backend remoto (R2) ya maneja esto igual
# que cualquier otro secreto en el tfstate.
resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "this" {
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://${var.vm_static_ip}:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [var.vm_static_ip]
  endpoints            = [var.vm_static_ip]
}

resource "talos_machine_configuration_apply" "this" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this.machine_configuration
  # Se aplica contra la IP DHCP de modo mantenimiento, no la estatica final
  # (var.vm_static_ip) - el nodo todavia no la tiene en este punto. Tras
  # instalar a disco y reiniciar, queda en var.vm_static_ip (usado por los
  # recursos de abajo: bootstrap, kubeconfig, client_configuration).
  node = local.maintenance_ip

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda"
          # Fija el installer al schematic con extensiones (qemu-guest-agent
          # + tailscale + zfs) para que un `talosctl upgrade` futuro no
          # vuelva a una imagen vainilla sin ellas.
          image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
        }
        network = {
          interfaces = [
            {
              interface = "ens18"
              addresses = ["${var.vm_static_ip}/${var.vm_ip_prefix}"]
              routes = [
                { network = "0.0.0.0/0", gateway = var.vm_gateway }
              ]
            }
          ]
          nameservers = var.vm_dns_servers
        }
        # Requerido por la extension zfs: el modulo del kernel no se carga
        # solo por estar la extension instalada.
        kernel = {
          modules = [
            { name = "zfs" }
          ]
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none" # Cilium reemplaza el CNI, igual que k0s antes
          }
        }
        proxy = {
          disabled = true # Cilium reemplaza kube-proxy via eBPF
        }
      }
    })
  ]

  depends_on = [proxmox_virtual_environment_vm.talos_node]
}

resource "talos_machine_bootstrap" "this" {
  node                 = var.vm_static_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.this]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = var.vm_static_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}

# Handoff a Ansible/CI: kubeconfig y talosconfig quedan en disco para que
# site.yaml (localhost) y cualquier `talosctl` manual los usen. Reemplaza al
# viejo local_file.ansible_inventory (que era SSH, ya no aplica).
resource "local_file" "kubeconfig" {
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = "${path.module}/generated/kubeconfig"
  file_permission = "0600"
}

resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/generated/talosconfig"
  file_permission = "0600"
}
