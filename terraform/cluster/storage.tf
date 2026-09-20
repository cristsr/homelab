resource "kubernetes_job_v1" "openebs_zpool_create" {
  metadata {
    name      = "openebs-zpool-create"
    namespace = "kube-system"
  }

  spec {
    ttl_seconds_after_finished = 3600
    backoff_limit              = 3

    template {
      metadata {
        name = "openebs-zpool-create"
      }
      spec {
        restart_policy = "OnFailure"

        # Runs only on the control-plane node, which also acts as storage.
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

          # Talos has no shell or userspace binaries on the host, so ZFS
          # tooling runs inside this container instead, mounting only /dev.
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

            # Talos doesn't run udev, so /dev/disk/by-partlabel/ doesn't
            # exist; resolve the real device with blkid instead.
            ZFS_DEVICE=$(blkid -o device -t PARTLABEL=r-openebs-zfs)

            if ! zpool list zfspv-pool; then
              echo "Zpool does not exist. Creating on $ZFS_DEVICE..."
              zpool create -f \
                -o ashift=12 \
                -O mountpoint=/var/openebs/zfspv-pool \
                -O compression=zstd \
                -O atime=off \
                zfspv-pool "$ZFS_DEVICE"
              echo "Zpool created successfully."
            else
              echo "Zpool zfspv-pool already exists. Skipping creation."
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

  depends_on = [
    helm_release.cilium,
    kubernetes_namespace_v1.namespaces
  ]
}

# The media library gets a pool of its own so it never consumes zfspv-pool's
# capacity. This duplicates the job above instead of sharing a locals/for_each
# loop deliberately: that job has already run, and folding it into a loop would
# change its address and recreate it.
resource "kubernetes_job_v1" "openebs_media_zpool_create" {
  metadata {
    name      = "openebs-media-zpool-create"
    namespace = "kube-system"
  }

  spec {
    ttl_seconds_after_finished = 3600
    backoff_limit              = 3

    template {
      metadata {
        name = "openebs-media-zpool-create"
      }
      spec {
        restart_policy = "OnFailure"

        # Runs only on the control-plane node, which also acts as storage.
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

          # Talos has no shell or userspace binaries on the host, so ZFS
          # tooling runs inside this container instead, mounting only /dev.
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

            if zpool list media-pool >/dev/null 2>&1; then
              echo "Zpool media-pool already exists. Skipping creation."
            else
              # Talos doesn't run udev, so /dev/disk/by-partlabel/ doesn't
              # exist; resolve the real device with blkid instead. Only
              # needed on first creation - checked after zpool list so an
              # already-imported pool (e.g. one migrated to a disk with no
              # matching partition label, see ADR-021) doesn't fail here.
              ZFS_DEVICE=$(blkid -o device -t PARTLABEL=r-openebs-media)
              echo "Zpool does not exist. Creating on $ZFS_DEVICE..."
              zpool create -f \
                -o ashift=12 \
                -O mountpoint=/var/openebs/media-pool \
                -O compression=zstd \
                -O atime=off \
                media-pool "$ZFS_DEVICE"
              echo "Zpool created successfully."
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

  depends_on = [
    helm_release.cilium,
    kubernetes_namespace_v1.namespaces
  ]
}
