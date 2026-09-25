# Talos control plane firewall: runbook and change record

## Overview

The Talos node stays at `192.168.80.30` on the LAN, and its own ingress firewall protects the control plane ports. There is one rule per protected port, and the default action stays accepting:

| Port | Allowed from |
|---|---|
| TCP 50000 (Talos API) | the hypervisor `192.168.80.20`, the operator's PC `192.168.80.10` and the node itself |
| TCP 6443 (Kubernetes API) | the same three, plus the pod range `10.244.0.0/16` and the service range `10.96.0.0/12` |
| TCP 10250 (kubelet) | the node itself and the pod range |
| TCP 2379-2380 (etcd) | the node itself |

Traffic to those ports from any other source is dropped. Tailscale clients and the CI runner reach the node through the subnet router on the hypervisor, which masquerades their traffic, so the node sees `192.168.80.20`.

What does not change: the node's address, the LoadBalancer addresses `192.168.80.240` and `192.168.80.253`, the Cilium pools and L2 policy, the data firewall on the hypervisor, and the Tailscale advertise list, which **must keep `192.168.80.30/32`**: it is how a Tailscale client reaches the node. Give the PC a DHCP reservation for `192.168.80.10` in the router; the firewall names that address.

Two properties of the Talos firewall decide this design, and both were found the hard way (see the cutover record):

- **A port must appear in exactly one rule.** Rules are evaluated in name order and each one drops the sources it does not list, so a second rule over the same port drops what the first one allows. A rule over a wide port range locks the operator out.
- **Pods reach the node's own address** (the Kubernetes API through the `kubernetes` service, the kubelet), and their source is a pod address. That traffic is not covered by the pod-to-pod exception of the default block mode, so with a default `block` the pods lose the API on the next restart, and every other port a pod uses on the node would need its own rule. A default `block` was set aside for that reason.

After the firewall, the five database LXCs are renumbered to `10.10.20.10`, `.20`, `.30`, `.40` and `.50`, one container per pull request.

The work is four stages, each its own pull request (stage 4 is five). A stage merges only after the previous stage's gate passed. Two facts drive the timing:

- A merge that touches `terraform/**` or `ansible/**` runs the Deploy workflow (`terraform apply -auto-approve`, then the Ansible playbooks). Merging the firewall pull request is the action that changes the live node.
- ArgoCD polls every 180 s. After a merge that changes DNS, force a sync of `private-dns` and `cluster-dns` instead of waiting.

## Stage 1: Backup

Nothing is merged and nothing changes. Take the backups before the firewall pull request, and keep them outside the VM:

```bash
talosctl --nodes 192.168.80.30 etcd snapshot ./etcd-$(date +%F).snapshot
talosctl --nodes 192.168.80.30 get machineconfig persistent -o jsonpath='{.spec}' > ./machineconfig-before-firewall.yaml
# on the hypervisor: OS and ZFS disks only, the media disk is backup = false on purpose.
# Check `df -h /var/lib/vz` first: the two disks together can be larger than the free space of the
# backup storage, and filling the hypervisor's root filesystem is worse than not having the copy.
vzdump 100 --mode snapshot --compress zstd --storage <backup-storage>
```

The machine secrets are in the Terraform state (R2 bucket `homelab-tfstate`, key `terraform.tfstate`); confirm the bucket still holds the current object. Also record the running pods, to compare after the change:

```bash
kubectl get pods -A --no-headers | awk '$4=="Running"{print $1"/"$2}' | sort > pods-running-before.txt
```

Gate: both files exist and the snapshot is non-empty (`ls -l`); `talosctl apply-config --dry-run --file ./machineconfig-before-firewall.yaml` reports no changes; `vzdump` reported success or was skipped for lack of space, in which case the etcd snapshot and the saved configuration are the safety net for a change that touches configuration only; `talosctl --nodes 192.168.80.30 version` works from the hypervisor and from the PC.

## Stage 2: Protection rules

Pull request 2 adds the four rules of the overview to the node's machine configuration. Read its `terraform plan` before merging: only the Talos machine configuration changes. Any change to the VM stops the window. If `terraform plan` cannot refresh the VM (for instance because the media disk is down), apply the configuration from the hypervisor instead: the saved configuration plus the four documents, `talosctl apply-config --dry-run --file <file>` first, then without `--dry-run`.

Gate, after Deploy:

```bash
talosctl --nodes 192.168.80.30 get nftableschain                    # lists the ingress chain
talosctl --nodes 192.168.80.30 version                              # from the hypervisor, the PC and a Tailscale node
kubectl get nodes                                                   # from the hypervisor, the PC and a Tailscale node
# on the hypervisor, while the PC runs `kubectl get nodes` through its Tailscale route:
tcpdump -ni vmbr0 host 192.168.80.30 and tcp port 6443              # the source is 192.168.80.20
```

The `tcpdump` line proves the masquerade: if the source is a Tailscale address instead of `192.168.80.20`, stop, because Tailscale clients and the CI runner would be cut.

Then prove the drops, from an address that is not allowed (a phone on Wi-Fi without Tailscale, or a temporary address on the hypervisor: `ip addr add 192.168.80.99/24 dev vmbr0 label vmbr0:t99`, then `nc -zv -w3 -s 192.168.80.99 192.168.80.30 <port>`, then `ip addr del 192.168.80.99/24 dev vmbr0`): `6443`, `50000`, `10250`, `2379` and `2380` all fail, and the hypervisor and the PC reach `6443` and `50000`.

**Rollback:** revert the pull request so Deploy re-applies the previous configuration, or from the hypervisor apply the saved configuration with `talosctl apply-config --file ./machineconfig-before-firewall.yaml`; proof: `talosctl --nodes 192.168.80.30 version` from the hypervisor answers and `nc -zv -w3 -s 192.168.80.99 192.168.80.30 10250` connects again.

## Stage 3: Restart check

An established connection hides a missing rule: a running pod keeps its open connection to the API, and only a new one is filtered. So restart the node, and check that everything comes back through the firewall. Do it in a window: the whole cluster is down while the VM restarts.

```bash
# on the hypervisor
qm shutdown 100 --timeout 240      # or qm stop 100 if the guest does not answer
qm start 100
```

Gate, after the node is `Ready` (about a minute):

- CoreDNS is `1/1` on both pods: `kubectl get pods -n kube-system -l k8s-app=kube-dns`. It is the first thing that fails when pods cannot reach the API.
- `kubectl get pods -A` shows the same pods `Running` as before (compare with `pods-running-before.txt`); `kubectl get pv,pvc -A` shows every volume `Bound`.
- The drops of Stage 2 still hold, and the hypervisor and the PC still reach `6443` and `50000`.
- Ingress and DNS: from a LAN device, `curl -k -s -o /dev/null -w '%{http_code}' --resolve argocd.internal.cristianpuenguenan.online:443:192.168.80.240 https://argocd.internal.cristianpuenguenan.online/` returns the same status as before (the gateway needs the SNI, so a bare `Host` header returns `000`), and `dig @192.168.80.253 postgres.internal.cristianpuenguenan.online` answers over UDP and TCP.
- Cluster egress and databases: a pod runs `nc -vz -w4 postgres.internal.cristianpuenguenan.online 5432` and pulls an image.
- Tailscale: a node that accepts routes runs `kubectl get nodes` and `talosctl --nodes 192.168.80.30 version`.
- CI: re-run the Deploy workflow from the Actions tab; it completes, including the Talos configuration apply.

**Rollback:** if a pod or the API cannot be reached after the restart, apply the saved configuration from the hypervisor (`talosctl apply-config --file ./machineconfig-before-firewall.yaml`); if the Talos API is unreachable even from the hypervisor, use the offline procedure of the recovery section below.

## Stage 4: Renumber the database LXCs

After Stage 3 is verified. One pull request and one short window per container, in this order: `qdrant` 123 to `10.10.20.30`, `redis` 124 to `10.10.20.40`, `mysql` 125 to `10.10.20.50`, `mongodb` 122 to `10.10.20.20`, `postgresql` 121 to `10.10.20.10`. The old addresses are `.33`, `.34`, `.35`, `.32` and `.31` in the same subnet, so no new address collides with an old one. The subnet, bridge, gateway, vmids and domains do not change.

Per container:

1. Take a backup on the hypervisor and record the vmid, the old address and the backup id:

   ```bash
   vzdump <vmid> --mode stop --compress zstd --storage <backup-storage>
   ```

2. Read the pull request's `terraform plan`. The container must change in place. Any destroy or replace stops the window, because a replace destroys the data disk; the fallback is in `docs/data-vnet-cutover.md`, database windows, step 3.
3. Merge. Deploy applies the new address. Force the ArgoCD sync of `cluster-dns` and `private-dns`.
4. Checks:

   ```bash
   nc -vz 10.10.20.<n> <port>                                     # from the hypervisor
   dig <name>.internal.cristianpuenguenan.online                  # from a Tailscale node: the new address
   nc -vz -w4 <name>.internal.cristianpuenguenan.online <port>    # from a pod
   ss -ltn                                                        # inside the container: the engine listens on the new address
   ```

5. Check that the engine still accepts its credentials from the node `192.168.80.30` and from the hypervisor `10.10.20.1`, which is what Tailscale traffic looks like after masquerading.

### Window: qdrant

- vmid 123, `10.10.20.33` to `10.10.20.30`, port 6333.

**Rollback:** revert the pull request so Deploy restores `10.10.20.33`, force the DNS sync, or restore the backup of step 1; proof: `dig qdrant.internal.cristianpuenguenan.online` answers `10.10.20.33` and `nc -vz 10.10.20.33 6333` opens.

### Window: redis

- vmid 124, `10.10.20.34` to `10.10.20.40`, port 6379.

**Rollback:** revert the pull request so Deploy restores `10.10.20.34`, force the DNS sync, or restore the backup of step 1; proof: `dig redis.internal.cristianpuenguenan.online` answers `10.10.20.34` and `nc -vz 10.10.20.34 6379` opens.

### Window: mysql

- vmid 125, `10.10.20.35` to `10.10.20.50`, port 3306. Kimai reaches it by that domain, so check it after the merge.

**Rollback:** revert the pull request so Deploy restores `10.10.20.35`, force the DNS sync, or restore the backup of step 1; proof: `dig mysql.internal.cristianpuenguenan.online` answers `10.10.20.35` and `nc -vz 10.10.20.35 3306` opens.

### Window: mongodb

- vmid 122, `10.10.20.32` to `10.10.20.20`, port 27017.

**Rollback:** revert the pull request so Deploy restores `10.10.20.32`, force the DNS sync, or restore the backup of step 1; proof: `dig mongodb.internal.cristianpuenguenan.online` answers `10.10.20.32` and `nc -vz 10.10.20.32 27017` opens.

### Window: postgresql

- vmid 121, `10.10.20.31` to `10.10.20.10`, port 5432. Last, because most workloads depend on it; afterwards `dig postgres.internal.cristianpuenguenan.online` answers `10.10.20.10`.

**Rollback:** revert the pull request so Deploy restores `10.10.20.31`, force the DNS sync, or restore the backup of step 1; proof: `dig postgres.internal.cristianpuenguenan.online` answers `10.10.20.31` and `nc -vz 10.10.20.31 5432` opens.

## Backup and recovery

- **Etcd snapshot:** `talosctl --nodes 192.168.80.30 etcd snapshot <file>`, kept outside the VM.
- **Machine configuration:** `talosctl --nodes 192.168.80.30 get machineconfig persistent -o jsonpath='{.spec}' > <file>` before the firewall (the plain `-o yaml` output wraps the configuration in resource metadata and cannot be applied; without the resource id the output holds the configuration twice).
- **Disks:** `vzdump 100 --mode snapshot` covers the OS and ZFS disks. The media disk is `backup = false` on purpose (its size once froze the VM) and is never touched.
- **Secrets:** the Terraform state in the R2 bucket holds the Talos machine secrets.
- **Recovery order:**
  1. From the hypervisor, whose address the rules always allow, apply the saved configuration with `talosctl apply-config`.
  2. If the Talos API is unreachable even from the hypervisor (a wrong rule), edit the persisted configuration offline, on the hypervisor:

     ```bash
     qm stop 100
     L=$(losetup -fP --show /dev/pve/vm-100-disk-1)       # the OS disk; the partition labelled STATE is xfs
     mkdir -p /mnt/talos-state && mount -t xfs ${L}p3 /mnt/talos-state
     cp /mnt/talos-state/config.yaml ./config-before-recovery.yaml
     cp ./machineconfig-before-firewall.yaml /mnt/talos-state/config.yaml
     umount /mnt/talos-state && losetup -d $L
     qm start 100
     ```

     Check the partition first with `lsblk -f $L` (the `STATE` label; the number can differ).
  3. Only if etcd is damaged, `talosctl bootstrap --recover-from=<snapshot>`.
  4. If the node is unreachable from every address and the offline edit is not possible, boot the Talos ISO and apply a permissive configuration.

## Cutover record

Executed on 2026-09-24 and 2026-09-25, from the hypervisor with `talosctl apply-config`, because Deploy could not run: the media disk (`sdb`) had dropped, `media-vg` was not found and `terraform plan` of `terraform/infra` failed at the refresh of the VM (`can't get size of '/dev/media-vg/vm-100-disk-0'`).

- Stage 1: etcd snapshot (`64184352` bytes, revision `4274082`) and the persisted machine configuration saved on the hypervisor and on the operator's PC; `apply-config --dry-run` of the saved configuration reported no changes. `vzdump` was skipped: the OS and ZFS disks use about 133 GB and the backup storage had 52 GB free.
- First attempt, with rules per service (Talos API, Kubernetes API, Gateway, DNS) and a default `block`: the drops and the allowed sources worked, and `tcpdump` showed the source `192.168.80.20` for the PC's `kubectl` through Tailscale. Everything looked healthy because the pods kept their established connections.
- The media disk came back as `sdc` while the LV still mapped the dead `sdb`, so the VM was restarted (`qm stop`, `vgchange -an/-ay media-vg`, `qm start`). After the restart CoreDNS stayed `0/1`: new connections from pods to the API (`10.96.0.1:443`, which is the node's `6443`) were dropped by the firewall, with either default action, because the port rule did not list the pod range.
- A rule over `1-65535` for the pod range then locked out every source, the hypervisor included (each rule drops what it does not list, and rules go in name order). Recovery: `qm stop 100`, mount the `STATE` partition of the OS disk on the hypervisor and replace `config.yaml` with the corrected configuration.
- Final state: one rule per port (`50000`, `6443`, `10250`, `2379-2380`), default action accepting. From an address that is not allowed, `6443`, `50000`, `10250`, `2379` and `2380` time out; the hypervisor reaches `6443` and `50000`; CoreDNS is `1/1`; the same pods run as before the change; the gateway returns `200`; `nslookup` answers.
- Not run: the Deploy workflow re-run, blocked by the media disk.
