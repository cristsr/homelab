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
  # Maintenance-mode DHCP IP: the node doesn't have its final static IP yet.
  node = local.maintenance_ip

  config_patches = [
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
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
        kernel = {
          modules = [
            { name = "zfs" }
          ]
        }
      }
      cluster = {
        # Single-node cluster: without this the control-plane taint leaves everything Pending.
        allowSchedulingOnControlPlanes = true
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
    # Talos manages the hostname via this dedicated document, not the legacy
    # machine.network.hostname field. `auto` must stay "off": the strategic
    # merge patch only overwrites keys, it never removes them.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = var.vm_name
    }),
    # Partitions the dedicated ZFS disk without formatting it, matching any
    # disk that isn't the Talos install disk. The resulting partition label
    # is what storage.tf looks up to create the zpool.
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
