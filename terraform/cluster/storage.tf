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

          # Talos no tiene shell/binarios de userspace en el host (por diseno -
          # nsenter+chroot al host falla con "can't execute 'sh'"), asi que las
          # herramientas de ZFS corren DENTRO del contenedor contra el device
          # del host, montando solo /dev (no todo el host root). El kernel
          # module zfs ya esta cargado por Talos (kernel.modules en talos.tf) -
          # las syscalls/ioctls de ZFS son a nivel de kernel, compartido por
          # todos los containers del nodo, sin importar el namespace.
          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }

          command = [
            "sh",
            "-c",
            <<-EOT
            set -e
            apk add --no-cache zfs util-linux >/dev/null

            # La particion la crea Talos de forma declarativa (RawVolumeConfig
            # "openebs-zfs" en terraform/infra/talos.tf) con partition label
            # r-openebs-zfs. Talos no corre udev, asi que /dev/disk/by-partlabel/
            # no existe - se resuelve el device real con blkid (confirmado:
            # PARTLABEL=r-openebs-zfs -> /dev/vdb1 en este cluster).
            ZFS_DEVICE=$(blkid -o device -t PARTLABEL=r-openebs-zfs)

            # Comprobar si el zpool ya existe
            if ! zpool list zfspv-pool; then
              echo "Zpool no existe. Creando en $ZFS_DEVICE..."
              zpool create -f \
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
          name = "dev"
          host_path {
            path = "/dev"
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
