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
                { network = "0.0.0.0/0", gateway = var.vm_gateway },
                # Data subnet: reached through the hypervisor, which filters who may cross.
                { network = var.data_subnet_cidr, gateway = var.hypervisor_lan_ip }
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
    # Ingress firewall allow rules. The default action is set in its own
    # document; while it is still accepting, these only prepare the block.
    # Loopback, established connections, ICMP and pod/service traffic are
    # allowed by Talos itself in block mode.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "apid-ingress"
      portSelector = {
        ports    = [50000]
        protocol = "tcp"
      }
      ingress = [for source in var.talos_api_allowed_sources : { subnet = source }]
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "kubernetes-api-ingress"
      portSelector = {
        ports    = [6443]
        protocol = "tcp"
      }
      ingress = [for source in var.talos_api_allowed_sources : { subnet = source }]
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "gateway-ingress"
      portSelector = {
        ports    = [80, 443]
        protocol = "tcp"
      }
      ingress = [{ subnet = var.lan_cidr }]
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "dns-tcp-ingress"
      portSelector = {
        ports    = [53]
        protocol = "tcp"
      }
      ingress = [{ subnet = var.lan_cidr }]
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "NetworkRuleConfig"
      name       = "dns-udp-ingress"
      portSelector = {
        ports    = [53]
        protocol = "udp"
      }
      ingress = [{ subnet = var.lan_cidr }]
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
    # Partitions the ZFS config disk without formatting it - the resulting
    # partition label is what storage.tf looks up to create the zpool. The
    # selector pins a device path instead of matching "!system_disk": a CEL
    # match takes the *first* disk that satisfies it, so with more than one
    # non-system disk the choice would fall to an ordering this config doesn't
    # control. The path follows the virtio disk order declared in proxmox.tf.
    # The media disk (/dev/vdc) has no volume here: ZFS takes the whole raw
    # device itself (ADR-021), so there is nothing for Talos to partition.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "RawVolumeConfig"
      name       = "openebs-zfs"
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"/dev/vdb\""
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
