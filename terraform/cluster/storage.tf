resource "kubernetes_job_v1" "openebs_zpool_create" {
  metadata {
    name      = "openebs-zpool-create"
    namespace = "kube-system"
  }

  spec {
    # Limpiar el job después de que termine exitosamente (opcional, util para que no ensucie)
    ttl_seconds_after_finished = 3600
    backoff_limit              = 3

    template {
      metadata {
        name = "openebs-zpool-create"
      }
      spec {
        # Solo host_pid: es lo unico que necesita el nsenter de mas abajo
        # para entrar al namespace de montaje del host (pid 1). host_network
        # y host_ipc no aportan nada a esta tarea y solo amplian innecesariamente
        # el radio de exposicion de un contenedor privilegiado.
        host_pid       = true
        restart_policy = "OnFailure"

        # Correr unicamente en el nodo que actua de controlplane/storage (Talos)
        node_selector = {
          "node-role.kubernetes.io/control-plane" = ""
        }

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        container {
          name  = "zfs-admin"
          image = "alpine:3.20"
          
          security_context {
            privileged = true
          }

          # Montamos root de Talos en /host para poder hacer chroot
          volume_mount {
            name       = "host-root"
            mount_path = "/host"
          }

          command = [
            "nsenter", 
            "--mount=/proc/1/ns/mnt", 
            "--", 
            "sh", 
            "-c", 
            <<-EOT
            set -e
            # La particion la crea Talos de forma declarativa (RawVolumeConfig
            # "openebs-zfs" en terraform/infra/talos.tf), con partition label
            # r-openebs-zfs - por eso el device es el symlink udev estandar y
            # no un nombre de disco hardcodeado (que puede cambiar segun el
            # hipervisor). Si este path no existe al correr el Job, confirmar
            # el device real con: talosctl get volumestatus r-openebs-zfs
            # (columna LOCATION) y ajustar aqui.
            ZFS_DEVICE=/dev/disk/by-partlabel/r-openebs-zfs

            # Comprobar si el zpool ya existe
            if ! chroot /host zpool list zfspv-pool; then
              echo "Zpool no existe. Creando..."
              chroot /host zpool create -f \
                -o ashift=12 \
                -O mountpoint=/var/openebs/zfspv-pool \
                -O compression=zstd \
                -O atime=off \
                zfspv-pool "$ZFS_DEVICE"
              echo "Zpool creado exitosamente."
            else
              echo "Zpool zfspv-pool ya existe. Omitiendo creación."
            fi
            EOT
          ]
        }

        volume {
          name = "host-root"
          host_path {
            path = "/"
          }
        }
      }
    }
  }

  # Nos aseguramos de que el namespace y la red básica (Cilium) existan
  depends_on = [
    helm_release.cilium,
    kubernetes_namespace_v1.namespaces
  ]
}
