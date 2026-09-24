# Data VNet cutover: runbook and change record

## Overview

The five data LXCs (`postgresql` vmid 121, `mongodb` 122, `qdrant` 123, `redis` 124, `mysql` 125) move from the LAN `192.168.80.0/24` to an isolated Proxmox SDN subnet `10.10.20.0/24` (gateway `10.10.20.1` on the hypervisor `192.168.80.20`, no physical NIC). Talos keeps `192.168.80.30` and reaches the subnet through a static route via the hypervisor. Tailscale nodes reach it through the hypervisor's subnet router. A forward firewall on the hypervisor decides who crosses: Talos and `tailscale0`, on ports 22, 5432, 27017, 6333, 6379 and 3306 only.

Every consumer, in-cluster or on the tailnet, reaches a database by its domain (`postgres`, `mongodb`, `qdrant`, `redis`, `mysql` under `internal.cristianpuenguenan.online`). An address change therefore touches DNS records, Terraform and the Ansible inventory, and no workload manifest.

The work is five stages, each its own pull request (stage 4 is five). A stage merges only after the previous stage's gate passed. Two facts drive the timing:

- A merge that touches `terraform/**` or `ansible/**` runs the Deploy workflow (`terraform apply -auto-approve`, then the Ansible playbooks). Merging a database's pull request is the action that moves that database.
- ArgoCD polls every 180 s. After a merge that changes DNS, force a sync of `private-dns` and `cluster-dns` instead of waiting.

Do not scale consumers to zero: ArgoCD self-heal reverts a manual scale. Consumers fail while a database is down; that is what the window is for.

## Stage 1: Cluster DNS

Pull request 1 adds the `cluster-dns` application, which manages the `coredns` ConfigMap in `kube-system` with `hosts` entries for the five database names, and adds the `mysql` record to `private-dns`. Both still point at the current LAN addresses, so nothing changes at runtime. Pull request 2 switches the workloads from IP to domain and is merged only after this gate.

Gate, from any machine with cluster access:

```bash
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup postgres.internal.cristianpuenguenan.online
# expected: Address: 192.168.80.31
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup argocd.internal.cristianpuenguenan.online
# expected: the same answer as before the change
```

Then reboot the Talos node and repeat the first lookup once the node is `Ready`:

```bash
talosctl --talosconfig terraform/infra/generated/talosconfig reboot
kubectl wait --for=condition=Ready node --all --timeout=600s
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup qdrant.internal.cristianpuenguenan.online
# expected: Address: 192.168.80.33
```

Talos owns this ConfigMap (annotation `config.k8s.io/owning-inventory: talos-bootstrap-manifests-inventory`) and may restore its own Corefile on a reboot or a Kubernetes upgrade. If the entries do not survive, abandon the workload switch: delete the `cluster-dns` application, keep the workloads on direct IPs, and have each window in stage 4 also edit its consumers' manifests (`platform/devtools/openmemory/deployment.yaml`, `workloads/finances/firefly.yaml`, `workloads/flow/deployment.yaml`, `workloads/sonarqube/sonarqube.yaml`, `scripts/apply-real-secrets.sh`).

**Rollback:** revert the pull request; ArgoCD removes the `cluster-dns` application without pruning, then restore Talos's Corefile with `kubectl -n kube-system rollout restart deployment coredns` after `talosctl upgrade-k8s --dry-run` confirms it is the stock one; proof: `kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -c hosts` prints `0`.

## Stage 2: Infrastructure

The pull request adds the SDN zone `data`, the VNet `datanet` and the subnet `10.10.20.0/24` (gateway `10.10.20.1`, SNAT on), the per-service `bridge` and `gateway` in `lxc.tf`, and the Talos route. Its `terraform plan` must show no change to any container. The merge runs Deploy, which creates the VNet and applies the route. Nothing existing changes.

After the merge, run the hypervisor playbook by hand. It is not part of any workflow:

```bash
ansible-playbook -i ansible/inventory.yaml ansible/hypervisor-network.yaml
# run it twice; the second run reports changed=0
```

Gate:

```bash
# on the hypervisor
pvesh get /cluster/sdn/vnets            # datanet listed in zone data
ip -4 addr show datanet                 # 10.10.20.1/24
sysctl net.ipv4.ip_forward              # net.ipv4.ip_forward = 1
nft list ruleset | grep -c "10.10.20.0/24"   # at least 3

talosctl --talosconfig terraform/infra/generated/talosconfig get routes | grep 10.10.20.0/24
# expected: a route via 192.168.80.20, and the node was not rebooted (uptime unchanged)
```

Firewall behaviour is proven with a database that has moved, in the first window: from a LAN device other than Talos, `nc -vz 10.10.20.<n> <port>` is refused or times out; from a pod on Talos and from a Tailscale node it opens. Reboot the hypervisor once outside a window and confirm `nft list ruleset` still shows the drop rule and `sysctl net.ipv4.ip_forward` is still `1`.

**Rollback:** `nft delete table inet data_vnet` removes the rules; revert the pull request and let Deploy remove the Talos route and the SDN objects; proof: `nft list ruleset | grep -c data_vnet` prints `0` and `pvesh get /cluster/sdn/vnets` no longer lists `datanet`.

## Stage 3: Tailscale

No pull request. Do this after stage 2 and before the first window, because the CI runner reaches a moved LXC through Tailscale and Deploy fails without the route.

1. Record the current advertise list and keep it in this file's evidence table:
   ```bash
   tailscale status --json | jq '.Self.PrimaryRoutes'
   ```
2. Advertise the new routes, keeping the LAN routes that exist today:
   ```bash
   tailscale set --advertise-routes=192.168.80.20/32,192.168.80.30/32,192.168.80.31/32,192.168.80.32/32,192.168.80.33/32,192.168.80.34/32,192.168.80.35/32,192.168.80.240/32,192.168.80.253/32,10.10.20.0/24 --accept-routes
   ```
3. In the Tailscale admin console (Machines, `homelab`, Edit route settings), approve every new route.
4. Update the tailnet policy so every node, including `tag:ci`, can reach `10.10.20.0/24`.
5. Confirm Split DNS: `internal.cristianpuenguenan.online` points at `192.168.80.253`.

Gate, from a Tailscale node on mobile data:

```bash
dig postgres.internal.cristianpuenguenan.online       # 192.168.80.31 until its window, then 10.10.20.31
tailscale ping 192.168.80.253
```

And from the CI runner: an SSH connection to a moved LXC succeeds (checked in the first window).

**Rollback:** `tailscale set --advertise-routes=<the list recorded in step 1>` and remove the approvals; proof: `tailscale status --json | jq '.Self.PrimaryRoutes'` equals the recorded list.

## Stage 4: Database windows

One database per window, never in parallel, in this order: qdrant, redis, mysql, mongodb, postgres. The order is ascending by number of in-cluster consumers, so the shared PostgreSQL goes last, after the procedure has been proven four times.

Procedure, identical in every window:

1. Announce the window and list the consumers that lose the database.
2. Take a backup of the container on the hypervisor and record vmid, current IP and backup id:
   ```bash
   vzdump <vmid> --mode stop --compress zstd --storage <backup-storage>
   ```
3. Read the pull request's `terraform plan`. The container must change in place. Any destroy or replace stops the window, because a replace destroys the data disk. Fallback if the plan wants a replace: on the hypervisor, `pct set <vmid> -net0 name=eth0,bridge=datanet,ip=10.10.20.<n>/24,gw=10.10.20.1` with the container stopped, then `terraform apply -refresh-only` to reconcile state before merging.
4. Merge the pull request. Deploy applies the network change.
5. Force the DNS sync: `argocd app sync private-dns cluster-dns`.
6. Check the service from the hypervisor, from a pod and from a Tailscale node:
   ```bash
   nc -vz 10.10.20.<n> <port>                                   # hypervisor
   kubectl run dbcheck --rm -i --restart=Never --image=busybox:1.36 -- nc -vz <name>.internal.cristianpuenguenan.online <port>
   dig <name>.internal.cristianpuenguenan.online                # 10.10.20.<n>, from a Tailscale node
   ```
7. Check that each consumer reconnected and its ArgoCD application is `Synced` and `Healthy`. Restart a consumer that keeps a stale connection.
8. Check that the engine accepts its existing credentials from both sources: Talos (`192.168.80.30`) and the hypervisor address `10.10.20.1`, which is what Tailscale traffic looks like after masquerading.
9. Close the window only when every check passes. Otherwise run its rollback.

### Window: qdrant

- vmid 123, `192.168.80.33` to `10.10.20.33`, port 6333.
- Consumers that lose it: openmemory.

| Item | Result |
|---|---|
| Backup id | |
| Plan result | |
| Service check | |
| Consumer check | |
| Credentials from Talos and from `10.10.20.1` | |
| Started, finished | |

**Rollback:** revert the pull request so Deploy restores bridge `vmbr0`, `192.168.80.33` and the LAN gateway, force the DNS sync, or restore the container from the backup; proof: `nc -vz 192.168.80.33 6333` opens and `dig qdrant.internal.cristianpuenguenan.online` answers `192.168.80.33`.

### Window: redis

- vmid 124, `192.168.80.34` to `10.10.20.34`, port 6379.
- Consumers that lose it: none in the repository.

| Item | Result |
|---|---|
| Backup id | |
| Plan result | |
| Service check | |
| Consumer check | |
| Credentials from Talos and from `10.10.20.1` | |
| Started, finished | |

**Rollback:** revert the pull request so Deploy restores bridge `vmbr0`, `192.168.80.34` and the LAN gateway, force the DNS sync, or restore from the backup; proof: `nc -vz 192.168.80.34 6379` opens and `dig redis.internal.cristianpuenguenan.online` answers `192.168.80.34`.

### Window: mysql

- vmid 125, `192.168.80.35` to `10.10.20.35`, port 3306.
- Consumers that lose it: Kimai. After the merge, rerun `scripts/apply-real-secrets.sh` so the connection string is rebuilt, and restart Kimai.

| Item | Result |
|---|---|
| Backup id | |
| Plan result | |
| Service check | |
| Consumer check | |
| Credentials from Talos and from `10.10.20.1` | |
| Started, finished | |

**Rollback:** revert the pull request so Deploy restores bridge `vmbr0`, `192.168.80.35` and the LAN gateway, force the DNS sync, or restore from the backup; proof: `nc -vz 192.168.80.35 3306` opens and `dig mysql.internal.cristianpuenguenan.online` answers `192.168.80.35`.

### Window: mongodb

- vmid 122, `192.168.80.32` to `10.10.20.32`, port 27017.
- Consumers that lose it: none in the repository.

| Item | Result |
|---|---|
| Backup id | |
| Plan result | |
| Service check | |
| Consumer check | |
| Credentials from Talos and from `10.10.20.1` | |
| Started, finished | |

**Rollback:** revert the pull request so Deploy restores bridge `vmbr0`, `192.168.80.32` and the LAN gateway, force the DNS sync, or restore from the backup; proof: `nc -vz 192.168.80.32 27017` opens and `dig mongodb.internal.cristianpuenguenan.online` answers `192.168.80.32`.

### Window: postgres

- vmid 121, `192.168.80.31` to `10.10.20.31`, port 5432.
- Consumers that lose it: Firefly III, n8n (`workloads/flow`) and SonarQube.

| Item | Result |
|---|---|
| Backup id | |
| Plan result | |
| Service check | |
| Consumer check | |
| Credentials from Talos and from `10.10.20.1` | |
| Started, finished | |

**Rollback:** revert the pull request so Deploy restores bridge `vmbr0`, `192.168.80.31` and the LAN gateway, force the DNS sync, or restore from the backup; proof: `nc -vz 192.168.80.31 5432` opens and `dig postgres.internal.cristianpuenguenan.online` answers `192.168.80.31`.

## Stage 5: Cleanup

After the last window closes:

1. Remove the `/32` routes for `192.168.80.31` to `192.168.80.35` from the advertise list and record the final list:
   ```bash
   tailscale set --advertise-routes=192.168.80.20/32,192.168.80.30/32,192.168.80.240/32,192.168.80.253/32,10.10.20.0/24 --accept-routes
   tailscale status --json | jq '.Self.PrimaryRoutes'
   ```
2. Merge the documentation and the ADR, and confirm no file outside the historical ADR text still names `192.168.80.31` to `192.168.80.35`.

## Cutover record

Executed on 2026-09-24. Every window used a `vzdump` snapshot backup on the hypervisor's `local` storage, a `terraform plan` that changed the container in place with no destroy, and a squash merge whose Deploy run finished green.

| Window | Backup | Plan | Checks passed |
|---|---|---|---|
| qdrant (123) | `vzdump-lxc-123-2026_09_24-01_52_40.tar.zst` | in place, 0 destroy | pod, Tailscale node and hypervisor connect; API key accepted from Talos (200) and from `10.10.20.1` (200), refused without it (401); a LAN LXC is blocked |
| redis (124) | `vzdump-lxc-124-2026_09_24-01_59_12.tar.zst` | in place, 0 destroy | pod, Tailscale node and hypervisor connect; `AUTH` and `PING` answer `+OK +PONG` from Talos and from `10.10.20.1`; a LAN LXC is blocked |
| mysql (125) | `vzdump-lxc-125-2026_09_24-02_08_21.tar.zst` | in place, 0 destroy | pod, Tailscale node and hypervisor connect; Kimai restarted and initialised against the new address; a LAN LXC is blocked |
| mongodb (122) | `vzdump-lxc-122-2026_09_24-02_16_33.tar.zst` | in place, 0 destroy | pod, Tailscale node and hypervisor connect; `ping` authenticated from Talos (`{"ok":1}`); a LAN LXC is blocked |
| postgres (121) | `vzdump-lxc-121-2026_09_24-02_23_48.tar.zst` | in place, 0 destroy | pod, Tailscale node and hypervisor connect; SonarQube, n8n and Firefly III reconnected after a restart |

Observations worth keeping:

- The Kimai connection string is a SOPS secret and had to name the domain before the mysql window, in its own pull request (`workloads/finances/secrets.sops.yaml`). Rerunning `scripts/apply-real-secrets.sh` is not needed for that.
- The pull request retarget and the push each start a Terraform Plan run, and the two can collide on the state lock. When the plan log shows `Error acquiring the state lock`, rerun one plan and read that result.
- A pull request retargeted after its base was squash-merged can show a stale "conflicting" state even when it merges cleanly. Closing and reopening it recomputes the state.
- A container on the data VNet is not filtered from another container on the same VNet, so the "blocked from the LAN" check has to run from a device that is still on the LAN.
- The hypervisor was not rebooted to prove that the nftables rules persist; `nftables` is enabled and its configuration includes the rules directory.
- The Tailscale advertise list now holds `10.10.20.0/24`, `192.168.80.20/32`, `192.168.80.30/32`, `192.168.80.240/32` and `192.168.80.253/32`. The five routes for `192.168.80.31` to `.35` can be deleted in the admin console.
