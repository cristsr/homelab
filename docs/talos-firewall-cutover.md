# Talos control plane firewall: runbook and change record

## Overview

The Talos node stays at `192.168.80.30` on the LAN, and its own ingress firewall becomes the isolation of the control plane. With the default action set to `block`, only two sources reach the Talos API (`50000`) and the Kubernetes API (`6443`): the hypervisor `192.168.80.20` and the operator's PC `192.168.80.10`. Tailscale clients and the CI runner reach the node through the subnet router on the hypervisor, which masquerades their traffic, so the node sees `192.168.80.20`. The Gateway (`80`, `443`) and the private DNS (`53`, UDP and TCP) are explicitly allowed from the LAN, because the default action is block.

What does not change: the node's address, the LoadBalancer addresses `192.168.80.240` and `192.168.80.253`, the Cilium pools and L2 policy, the data firewall on the hypervisor, and the Tailscale advertise list, which **must keep `192.168.80.30/32`**: it is how a Tailscale client reaches the node. Give the PC a DHCP reservation for `192.168.80.10` in the router; the firewall names that address.

Talos already allows, in block mode, loopback, established and related connections, rate-limited ICMP and traffic between the pod and service subnets, so pods reaching the API need no rule. Cilium runs in native routing, so no VXLAN rule is needed. The kubelet (`10250`) and etcd (`2379`, `2380`) are not reachable from the LAN.

After the firewall, the five database LXCs are renumbered to `10.10.20.10`, `.20`, `.30`, `.40` and `.50`, one container per pull request.

The work is four stages, each its own pull request (stage 4 is five). A stage merges only after the previous stage's gate passed. Two facts drive the timing:

- A merge that touches `terraform/**` or `ansible/**` runs the Deploy workflow (`terraform apply -auto-approve`, then the Ansible playbooks). Merging the firewall pull requests is the action that changes the live node.
- ArgoCD polls every 180 s. After a merge that changes DNS, force a sync of `private-dns` and `cluster-dns` instead of waiting.

## Stage 1: Backup

Nothing is merged and nothing changes. Take the four backups before the first firewall pull request, and keep them outside the VM:

```bash
talosctl --nodes 192.168.80.30 etcd snapshot ./etcd-$(date +%F).snapshot
talosctl --nodes 192.168.80.30 get machineconfig persistent -o jsonpath='{.spec}' > ./machineconfig-before-firewall.yaml
# on the hypervisor: OS and ZFS disks only, the media disk is backup = false on purpose.
# Check `df -h /var/lib/vz` first: the two disks together can be larger than the free space of the
# backup storage, and filling the hypervisor's root filesystem is worse than not having the copy.
vzdump 100 --mode snapshot --compress zstd --storage <backup-storage>
```

The machine secrets are in the Terraform state (R2 bucket `homelab-tfstate`, key `terraform.tfstate`); confirm the bucket still holds the current object.

Gate: both files exist and the snapshot is non-empty (`ls -l`); `talosctl apply-config --dry-run --file ./machineconfig-before-firewall.yaml` reports no changes; `vzdump` reported success or was skipped for lack of space, in which case the etcd snapshot and the saved configuration are the safety net for a change that touches configuration only; `talosctl --nodes 192.168.80.30 version` works from the hypervisor and from the PC.

## Stage 2: Allow rules

Pull request 2 adds the allow rules to the node's machine configuration, with the default action still accepting: `50000` and `6443` from `192.168.80.20/32` and `192.168.80.10/32`, `80` and `443` from `192.168.80.0/24`, and `53` over TCP and UDP from `192.168.80.0/24`. Nothing is blocked yet.

Read the pull request's `terraform plan` before merging: only the Talos machine configuration changes. Any change to the VM stops the window.

Gate, after Deploy:

```bash
talosctl --nodes 192.168.80.30 get nftableschain                    # lists the ingress chain and its rules
talosctl --nodes 192.168.80.30 version                              # from the hypervisor, the PC and a Tailscale node
kubectl get nodes                                                   # from the hypervisor, the PC and a Tailscale node
# on the hypervisor, while a Tailscale node runs `kubectl get nodes`:
tcpdump -ni vmbr0 host 192.168.80.30 and tcp port 6443              # the source is 192.168.80.20
```

The `tcpdump` line proves the masquerade: if the source is the Tailscale address instead of `192.168.80.20`, stop before Stage 3, because the default block would cut Tailscale clients and the CI runner.

**Rollback:** revert the pull request so Deploy re-applies the previous machine configuration; proof: `talosctl --nodes 192.168.80.30 version` from the hypervisor answers and `talosctl get nftableschain` no longer lists the rules.

## Stage 3: Default block

Pull request 3 sets the default ingress action to `block`. This is the step that can lock the operator out, so before merging keep a terminal on the hypervisor with the saved configuration and the permissive command ready:

```bash
talosctl --nodes 192.168.80.30 apply-config --file ./machineconfig-before-firewall.yaml
```

Gate, after Deploy:

- From an address that is not allowed (a phone on Wi-Fi without Tailscale, or a temporary address on the hypervisor: `ip addr add 192.168.80.99/24 dev vmbr0 label vmbr0:t99`, then `nc -zv -w3 -s 192.168.80.99 192.168.80.30 <port>`, then `ip addr del 192.168.80.99/24 dev vmbr0`): `nc -vz -w3 192.168.80.30 6443`, `nc -vz -w3 192.168.80.30 50000` and `nc -vz -w3 192.168.80.30 10250` all fail, and so do `2379` and `2380`.
- From the hypervisor and from the PC: `talosctl --nodes 192.168.80.30 health`, `kubectl get nodes,pods -A` and `nc -vz -w3 192.168.80.30 6443` succeed, the node is `Ready` and every pod that was `Running` is `Running`.
- Data: `kubectl get pv,pvc -A` shows every volume `Bound`, and both ZFS pools are `ONLINE`.
- Ingress and DNS: from a LAN device, `curl -k -s -o /dev/null -w '%{http_code}' --resolve argocd.internal.cristianpuenguenan.online:443:192.168.80.240 https://argocd.internal.cristianpuenguenan.online/` (the gateway needs the SNI, so a bare `Host` header returns `000`) returns the same status as before, and `dig @192.168.80.253 postgres.internal.cristianpuenguenan.online` answers.
- Cluster egress and databases: a pod runs `nc -vz -w4 postgres.internal.cristianpuenguenan.online 5432` and pulls an image.
- Tailscale: a node that accepts routes runs `kubectl get nodes` and `talosctl --nodes 192.168.80.30 version`.
- CI: re-run the Deploy workflow from the Actions tab; it completes, including the Talos configuration apply.

If a LoadBalancer port stops answering, the firewall is intercepting traffic that Cilium translates; apply the permissive command above first, then investigate.

**Rollback:** from the hypervisor apply the saved configuration with the permissive command above, then revert the pull request; proof: from a LAN device `curl -k -s -o /dev/null -w '%{http_code}' --resolve argocd.internal.cristianpuenguenan.online:443:192.168.80.240 https://argocd.internal.cristianpuenguenan.online/` (the gateway needs the SNI, so a bare `Host` header returns `000`) and `talosctl --nodes 192.168.80.30 version` answer.

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
- **Machine configuration:** `talosctl --nodes 192.168.80.30 get machineconfig persistent -o jsonpath='{.spec}' > <file>` before the firewall (the plain `-o yaml` output wraps the configuration in resource metadata and cannot be applied); it is what the permissive command applies.
- **Disks:** `vzdump 100 --mode snapshot` covers the OS and ZFS disks. The media disk is `backup = false` on purpose (its size once froze the VM) and is never touched.
- **Secrets:** the Terraform state in the R2 bucket holds the Talos machine secrets.
- **Recovery order:**
  1. From the hypervisor, whose address the rules always allow, apply the saved configuration with `talosctl apply-config`.
  2. Only if etcd is damaged, `talosctl bootstrap --recover-from=<snapshot>`.
  3. If the node is unreachable from every address, boot the Talos ISO and apply a permissive configuration.

## Cutover record

Executed on 2026-09-24, from the hypervisor with `talosctl apply-config` because Deploy could not run: the media disk (`sdb`) had dropped, `media-vg` was not found and `terraform plan` of `terraform/infra` failed at the refresh of the VM (`can't get size of '/dev/media-vg/vm-100-disk-0'`). The configuration applied is the saved one plus the same documents the pull requests add, so the Deploy that follows the merges finds nothing to change.

- Stage 1: etcd snapshot (`64184352` bytes, revision `4274082`) and the persisted machine configuration saved on the hypervisor and on the operator's PC; `apply-config --dry-run` of the saved configuration reported no changes. `vzdump` was skipped: the OS and ZFS disks use about 133 GB and the backup storage had 52 GB free.
- Stage 2: applied without a reboot. `talosctl get nftableschain` lists the `ingress` chain. `tcpdump -ni vmbr0 host 192.168.80.30 and tcp port 6443` while the PC ran `kubectl get nodes` showed the source `192.168.80.20`: Tailscale traffic arrives masqueraded. From the temporary address `192.168.80.99`, `6443` and `50000` timed out and `10250` was still open; from the hypervisor `6443` opened.
- Stage 3: applied without a reboot. From `192.168.80.99`, `6443`, `50000`, `10250`, `2379` and `2380` timed out. `talosctl health` from the hypervisor and `kubectl get nodes` from the PC passed; the node is `Ready`; the same 66 pods are `Running` (one was replaced by a rollout of `forgejo`); the gateway returns `200`; `dig`/`nslookup` answers over UDP and TCP; a pod reached `postgres.internal.cristianpuenguenan.online:5432` and `https://github.com`.
- Not run: the Deploy workflow re-run, blocked by the media disk.
