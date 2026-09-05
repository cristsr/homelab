# Pool dedicado, no toca los pools existentes del host (default, images, boot, ...)
resource "libvirt_pool" "homelab" {
  name = "homelab"
  type = "dir"
  target = {
    path = var.pool_path
  }
}

# Importa el qcow2 local ya descargado y limpiado (virt-sysprep) como volumen
# base. Nunca se escribe: k0s_node_disk es un overlay sobre este.
resource "libvirt_volume" "fedora_base" {
  name = "fedora-cloud-base.qcow2"
  pool = libvirt_pool.homelab.name
  type = "file"

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.fedora_cloud_image_url
    }
  }
}

# Disco overlay (copy-on-write) por VM. La plantilla nunca se escribe.
resource "libvirt_volume" "k0s_node_disk" {
  name     = "${var.vm_name}.qcow2"
  pool     = libvirt_pool.homelab.name
  type     = "file"
  capacity = var.disk_size_bytes

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.fedora_base.path
    format = {
      type = "qcow2"
    }
  }
}

# Llave SSH dedicada a este modulo, generada por Terraform. No reutiliza
# ninguna llave del operador para que el repo sea reproducible desde cero.
resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "local_file" "vm_private_key" {
  content         = tls_private_key.vm.private_key_openssh
  filename        = "${path.module}/generated/id_ed25519"
  file_permission = "0600"
}

resource "local_file" "vm_public_key" {
  content         = tls_private_key.vm.public_key_openssh
  filename        = "${path.module}/generated/id_ed25519.pub"
  file_permission = "0644"
}

resource "libvirt_cloudinit_disk" "k0s_seed" {
  name = "${var.vm_name}-seed.iso"
  pool = libvirt_pool.homelab.name

  meta_data = "instance-id: ${var.vm_name}\nlocal-hostname: ${var.vm_name}\n"

  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tpl", {
    hostname       = var.vm_name
    timezone       = var.timezone
    ssh_user       = var.ssh_user
    ssh_public_key = trimspace(tls_private_key.vm.public_key_openssh)
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.yaml.tpl", {
    mac_address = var.vm_mac
    ip_cidr     = "${var.vm_static_ip}/${var.vm_ip_prefix}"
    gateway     = var.vm_gateway
    dns_servers = join(",", var.vm_dns_servers)
  })
}

resource "libvirt_domain" "k0s_node" {
  name        = var.vm_name
  type        = "kvm"
  memory      = var.memory_mib
  memory_unit = "MiB" # sin esto, "memory" se interpreta en KiB: cada VM
                       # creada hasta ahora arrancaba con unos pocos MB de
                       # RAM en vez de GB, y por eso SeaBIOS colgaba siempre
                       # en el mismo punto sin importar que mas se cambiara
  vcpu        = var.vcpu
  autostart = true # unica via de arranque del cluster tras un reboot del host
  running   = true # arrancar inmediatamente al crear (autostart solo aplica en reboots del host)

  cpu = {
    mode = "host-passthrough"
  }

  # BIOS legacy + i440fx: en este host, OVMF/UEFI (con o sin secure-boot)
  # cuelga el arranque en silencio (sin salida en serie ni framebuffer,
  # confirmado empiricamente). BIOS legacy es lo que si arranca de forma
  # confiable con esta plantilla de Fedora Cloud, y nada en el stack
  # (k0s/Cilium/Longhorn) necesita UEFI.
  os = {
    type         = "hvm"
    type_machine = "pc"
  }

  clock = {
    offset = "utc"
    timer = [
      { name = "rtc", tick_policy = "catchup" },
      { name = "pit", tick_policy = "delay" },
      { name = "hpet", present = "no" }, # HPET habilitado cuelga la
                                          # calibracion de timer de SeaBIOS
                                          # bajo KVM en este host (confirmado
                                          # empiricamente)
    ]
  }

  features = {
    acpi = true
    apic = {} # sin esto, un vCPU se queda en spin-loop al 99% CPU esperando
              # una interrupcion que nunca llega a entregarse (confirmado
              # empiricamente: mismo EIP fijo, independiente del vcpu count)
  }

  devices = {
    disks = [
      {
        device = "disk"
        source = {
          volume = {
            pool   = libvirt_pool.homelab.name
            volume = libvirt_volume.k0s_node_disk.name
          }
        }
        target = {
          bus = "virtio"
          dev = "vda"
        }
        driver = {
          name = "qemu"
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        source = {
          file = {
            file = libvirt_cloudinit_disk.k0s_seed.path
          }
        }
        target = {
          bus = "ide" # i440fx no tiene controlador SATA nativo
          dev = "hda"
        }
        driver = {
          name = "qemu"
          type = "raw"
        }
      },
    ]

    interfaces = [
      {
        source = {
          network = {
            network = var.libvirt_network_name
          }
        }
        model = {
          type = "virtio"
        }
        mac = {
          address = var.vm_mac
        }
      },
    ]

    consoles = [
      {
        target = {
          type = "serial"
          port = "0"
        }
      },
    ]
  }
}

# Handoff a Ansible: regenera el inventario apuntando a la VM por SSH.
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.yaml.tftpl", {
    vm_ip              = var.vm_static_ip
    ssh_user           = var.ssh_user
    ssh_key_path       = abspath(local_file.vm_private_key.filename)
    hypervisor_host    = var.hypervisor_ssh_host
    hypervisor_user    = var.hypervisor_ssh_user
    hypervisor_keyfile = var.hypervisor_ssh_keyfile
  })
  filename = "${path.module}/../ansible/inventory.yaml"
}
