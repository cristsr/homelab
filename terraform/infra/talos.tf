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
  # Se aplica contra la IP DHCP de modo mantenimiento (local.maintenance_ip),
  # no la estatica final: el nodo todavia no la tiene en este punto.
  node = local.maintenance_ip

  # El cambio de hostname (stableHostname -> estatico) no se puede aplicar en
  # caliente - Talos exige reboot para reprocesar esa parte de la identidad
  # de red. Unico nodo del cluster: implica downtime breve de todo mientras
  # reinicia.
  apply_mode = "reboot"

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = "factory.talos.dev/installer/${var.talos_schematic_id}:${var.talos_version}"
        }
        # Talos >= 1.12 activa features.stableHostname por defecto (genera un
        # hostname pseudo-random atado a la identidad de la maquina, ej.
        # talos-zsu-wum) - conviven mal con un machine.network.hostname
        # explicito ("static hostname is already set in v1alpha1 config" si
        # no se desactiva primero).
        features = {
          stableHostname = false
        }
        network = {
          hostname = var.vm_name
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
        kernel = {
          modules = [
            { name = "zfs" }
          ]
        }
      }
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    }),
    # Particiona el disco dedicado a ZFS (virtio1, ver proxmox.tf) sin
    # formatearlo - "!system_disk" matchea el unico disco que no es el de
    # instalacion de Talos (virtio0/vda). El partition label resultante
    # (r-openebs-zfs) lo consume storage.tf via /dev/disk/by-partlabel/.
    # A diferencia de UserVolumeConfig, Talos exige minSize o maxSize
    # explicito para RawVolumeConfig (rechaza el patch si falta) - maxSize
    # igual al tamano real del disco dedicado para que ocupe el disco entero.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "RawVolumeConfig"
      name       = "openebs-zfs"
      provisioning = {
        diskSelector = {
          match = "!system_disk"
        }
        maxSize = "${var.zfs_disk_size_gb}GiB"
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
