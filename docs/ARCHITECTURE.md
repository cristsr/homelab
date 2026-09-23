# Homelab Kubernetes Architecture

## Index

1. [Overview](#1-overview)
2. [Base Infrastructure](#2-base-infrastructure)
3. [Platform Components](#3-platform-components)
4. [Applications and Tools](#4-applications-and-tools)
5. [Databases](#5-databases)
6. [Monitoring](#6-monitoring)
7. [Networking and Access](#7-networking-and-access)
8. [Security and Secrets](#8-security-and-secrets)
9. [GitOps and Deployment Order](#9-gitops-and-deployment-order)
10. [Storage and Resources](#10-storage-and-resources)
11. [Initial Installation Flow](#11-initial-installation-flow)

---

## 1. Overview

Single-node homelab built on Talos Linux (a VM on Proxmox VE) with full GitOps. ArgoCD manages all applications from this repository. Ingress is split between two Gateway API implementations: **Envoy Gateway** for generic HTTP traffic (see [ADR-023](DECISIONS.md#adr-023-envoy-gateway-replaces-cilium-gateway-api-for-generic-ingress)) and **Agent Gateway** retained only for MCP server routes (see [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-for-generic-ingress-agent-gateway-only-for-mcp)). Cloudflare Tunnel exposes selected services to the Internet without opening ports on the router. See [ADR-014](DECISIONS.md#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv) for the full context of the migration from k0s/libvirt/Fedora. Data services (PostgreSQL, MongoDB, Qdrant, Redis) run **outside the cluster**, in Proxmox LXCs (see [ADR-016](DECISIONS.md) and §5).

### Technology stack

| Layer | Technology |
|------|-----------|
| Hypervisor | Proxmox VE (Terraform provider `bpg/proxmox`) |
| Kubernetes | Talos Linux v1.14.0 (immutable, no SSH) |
| CNI / NetworkPolicy | Cilium 1.20.1 (eBPF, kube-proxy replacement) |
| Ingress / Gateway (generic) | Envoy Gateway v1.9.1 |
| Ingress / Gateway (MCP) | Agent Gateway 1.1.0 |
| GitOps | Argo CD 9.5.13 |
| TLS Certificates | cert-manager: Let's Encrypt (public and private, DNS-01 via Cloudflare) |
| Storage | OpenEBS ZFS LocalPV 2.11.1 |
| Databases | PostgreSQL 17, MongoDB 8.0, Qdrant v1.x, Redis 8 on Proxmox LXCs (ADR-016) |
| Internet Tunnel | Cloudflare Tunnel (cloudflared) |
| Monitoring | kube-prometheus-stack + Grafana Operator |
| Secrets | 1Password + External Secrets Operator |
| Runtime security | Tetragon |

### Repository structure

```
homelab/
├── terraform/
│   ├── infra/                   # Talos VM + data LXCs on Proxmox (bpg/proxmox + siderolabs/talos providers)
│   │   ├── proxmox.tf            # VM, disks (installation + dedicated to ZFS), Talos ISO
│   │   ├── lxc.tf                # Four data LXCs: PostgreSQL, MongoDB, Qdrant, Redis
│   │   ├── talos.tf              # machine config, bootstrap, generated kubeconfig/talosconfig
│   │   ├── variables.tf          # Sizing, network, Talos schematic
│   │   ├── outputs.tf            # vm_static_ip, kubeconfig_path, talosconfig_path
│   │   └── generated/            # kubeconfig/talosconfig (gitignored)
│   └── cluster/                  # Kubernetes bootstrap (once the cluster is already up)
│       ├── bootstrap.tf          # helm_release: Cilium, ArgoCD
│       ├── namespaces.tf         # Base namespaces
│       ├── secrets.tf            # Initial secrets (repo-creds, in-cluster)
│       ├── storage.tf            # Job that creates the OpenEBS ZFS LocalPV zpool
│       └── variables.tf          # kubeconfig_path, ArgoCD credentials
│
├── ansible/                    # Preflight + provisioning of the data LXCs (Talos has no SSH)
│   ├── tasks/
│   │   ├── preflight-secrets.yaml        # Validates that credentials are not empty
│   │   ├── preflight-remote-checks.yaml  # Remote connectivity checks
│   │   └── install-podman.yaml           # Shared Podman installation + auto-update
│   ├── data-services.yaml      # Brings up postgresql/mongodb/qdrant/redis via Podman Quadlet
│   ├── bootstrap-lxc-ssh.yaml   # Seeds the SSH pubkey on the LXCs via pct exec
│   ├── ansible.cfg             # Ansible configuration
│   ├── inventory.yaml          # localhost + the data LXCs (Talos exposes no SSH/shell on the node)
│   └── preflight.yaml          # Runs before `terraform apply` in CI (fails fast)
│
├── secrets/
│   └── homelab.env.example     # Template for infra and data LXC credentials, the real file is gitignored
│
├── scripts/
│   └── apply-real-secrets.sh    # Loads secrets/homelab.env into the repo's encrypted SopsSecret/env (manual, doesn't run in CI)
│
├── bootstrap/                   # Values/scripts consumed by terraform/cluster/bootstrap.tf
│   ├── cilium/values.yaml       # Cilium values (includes Talos-specific tweaks)
│   ├── argocd/values.yaml       # ArgoCD values (GitOps)
│
├── gitops/                     # ArgoCD applications (App of Apps)
│   ├── root-app.yaml           # Root application pointing to gitops/apps/
│   └── apps/
│       ├── platform/           # Infrastructure ArgoCD Applications
│       │   ├── argocd/         # Additional ArgoCD configuration
│       │   ├── networking/     # cert-manager, cloudflared, agentgateway, envoy-gateway
│       │   ├── storage/        # OpenEBS ZFS LocalPV
│       │   ├── devtools/       # OpenMemory
│       │   ├── observability/  # Prometheus, Grafana, Headlamp
│       │   ├── secret-management/ # 1Password ClusterSecretStore, External Secrets
│       │   └── security/       # Tetragon
│       └── workloads/          # User application ArgoCD Applications
│           ├── flow.yaml
│           ├── portfolio.yaml
│           └── sonarqube/
│
├── platform/                   # Infrastructure manifests and Helm values
│   ├── argocd/
│   ├── networking/
│   ├── storage/
│   ├── devtools/
│   ├── observability/
│   ├── secret-management/
│   └── security/
│
├── workloads/                  # User/business applications
│   ├── flow/                   # Flow API (Deployment, ExternalSecret, HTTPRoute)
│   ├── portfolio/              # Personal site (Deployment, ConfigMap, HTTPRoute)
│   └── sonarqube/              # SonarQube + MCP server (external DB, see §5)
│
└── docs/                       # Project documentation
    ├── ARCHITECTURE.md
    ├── INSTALL.md
    ├── OPERATIONS.md
    ├── DECISIONS.md
    └── CI_CD_HYPERVISOR_SETUP.md
```

---

## 2. Base Infrastructure

### 2.1 Talos Linux (Kubernetes)

**Version**: `v1.14.0` — **Mode**: Single node (control-plane, no separate workers)

- Runs on a VM on Proxmox VE, provisioned by Terraform (`terraform/infra/`, see [ADR-014](DECISIONS.md#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv)).
- Talos is immutable and has no SSH or shell: configuration is 100% declarative via machine config, applied by the Terraform provider `siderolabs/talos` (`terraform/infra/talos.tf`). Ansible no longer provisions the node's operating system.
- The ISO is generated with the [Image Factory](https://factory.talos.dev) from a schematic with the `qemu-guest-agent` and `zfs` extensions (`talos_schematic_id` in `terraform/infra/variables.tf`).
- kube-proxy is disabled (`cluster.proxy.disabled = true`, replaced by Cilium eBPF); the CNI is also disabled at the Talos level (`cluster.network.cni.name = "none"`) so Cilium installs it.
- The control-plane runs workloads (single-node cluster): several charts (ArgoCD, the OpenEBS ZFS Job) need explicit `tolerations` for the `node-role.kubernetes.io/control-plane:NoSchedule` taint.

| Parameter | Value |
|-----------|-------|
| `vm_static_ip` (node) | `192.168.80.x` (real LAN, Proxmox bridge `vmbr0`) |
| Pod CIDR (Cilium `ipam.operator.clusterPoolIPv4PodCIDRList`) | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` (Talos default) |
| Installation disk | `/dev/vda` (`virtio0`) |
| Disk dedicated to ZFS | `/dev/vdb` (`virtio1`, declaratively partitioned with `RawVolumeConfig`, label `r-openebs-zfs`) |

### 2.2 Cilium (CNI)

**Chart**: `cilium/cilium` — **Namespace**: `kube-system` — **Version**: `1.20.1`

Fully replaces kube-proxy with eBPF. Provides pod connectivity, NetworkPolicies, and observability via Hubble.

| Parameter | Value |
|-----------|-------|
| `kubeProxyReplacement` | `true` |
| `k8sServiceHost` | `127.0.0.1` |
| `k8sServicePort` | `6443` |
| `ipam.mode` | `cluster-pool` |
| Pod CIDR | `10.244.0.0/16` |
| `routingMode` | `native` |
| `bpf.masquerade` | `true` |
| `hubble.relay.enabled` | `true` |
| `hubble.ui.enabled` | `true` |
| Daemon run path | `/var/run/cilium` |
| `cgroup.autoMount.enabled` | `false` (Talos already mounts cgroupv2/bpffs) |
| `securityContext.capabilities` | Adjusted without `SYS_MODULE` — Talos doesn't allow workloads to load kernel modules |

### 2.3 Argo CD (GitOps)

**Chart**: `argo/argo-cd` — **Namespace**: `argocd` — **Version**: `9.5.13`

Controls the lifecycle of all applications in the cluster. The `root-app` points to `gitops/apps/` and creates the sub-applications that deploy each component.

| Parameter | Value |
|-----------|-------|
| `server.ingress.enabled` | `false` (managed via HTTPRoute against the Envoy Gateway) |
| `server.insecure` | `true` (TLS terminated at the `main` Gateway with Let's Encrypt — the backend always speaks plain HTTP, see §3.1 TLS) |
| Reconciliation timeout | `180s` (the only sync mechanism since ADR-019 — the GitHub webhook was retired, see `docs/DECISIONS.md`) |
| Default RBAC | `role:readonly` |
| Domain | `argocd.internal.cristianpuenguenan.online` |
| Tolerations | `node-role.kubernetes.io/control-plane:NoSchedule` (single-node cluster, see §2.1) |

### 2.4 Namespaces

Created by `terraform/cluster/namespaces.tf` (`kubernetes_namespace_v1.namespaces`, `for_each` over a fixed list) or with `syncOptions: CreateNamespace=true` in the corresponding ArgoCD Application:

| Namespace | Content |
|-----------|-----------|
| `argocd` | Argo CD |
| `apps` | Flow API, Portfolio |
| `devtools` | OpenMemory |
| `openebs` | OpenEBS ZFS LocalPV |
| `networking` | Envoy Gateway config, Agent Gateway (MCP), cloudflared, cert-manager, private-dns |
| `observability` | Prometheus, Grafana, Alertmanager, Headlamp |
| `secret-management` | 1Password ClusterSecretStore, External Secrets, Reloader |
| `tetragon` | Tetragon |
| `sonarqube` | SonarQube, MCP server |

---

## 3. Platform Components

### 3.1 Ingress: three Gateway APIs, one per audience

See [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-for-generic-ingress-agent-gateway-only-for-mcp), ADR-011, ADR-012, and [ADR-023](DECISIONS.md#adr-023-envoy-gateway-replaces-cilium-gateway-api-for-generic-ingress) in [DECISIONS.md](DECISIONS.md). The three `Gateway`s live in the `networking` namespace. `main` terminates TLS on HTTPS:443 with a real Let's Encrypt certificate (see TLS below); its port 80 only redirects to HTTPS. `agentgateway-mcp` serves plain HTTP:80 internally (its controller doesn't support HTTPS listeners, ADR-012) but has no external IP of its own: its 3 routes still come in over HTTPS, via `main` acting as a TLS proxy to its Service. `public` listens on plain HTTP:80 — the internet-facing TLS is terminated by Cloudflare at the tunnel edge. The separation between `public` and `main` isn't by traffic type but by **audience**: `public` is the only Gateway the Cloudflare wildcard points to — what's public is decided by which `HTTPRoute` lives there, not by a separate list.

#### 3.1.a Envoy Gateway — public (`public`)

**`Gateway`**: `public` (`platform/networking/envoy-gateway/gateway-public.yaml`) — **Generated Service**: `envoy-public` (in `envoy-gateway-system`, fixed name via `EnvoyProxy`) — no fixed LAN IP (only consumed by `cloudflared`, via `ClusterIP`). Policies (`policies.yaml`): client IP from `CF-Connecting-IP`, per-client-IP local rate limit, connect-failure-only retries

The only Gateway reachable from the Internet — the only two routes that need to be:

| Subdomain | Backend | Namespace |
|-----------|---------|-----------|
| `api.cristianpuenguenan.online` | flow:80 (`/flow`, `/webhooks`) | apps |
| `portfolio.cristianpuenguenan.online` | portfolio:80 | apps |

#### 3.1.b Envoy Gateway — private (`main`)

**`GatewayClass`**: `envoy` (`platform/networking/envoy-gateway/gatewayclass.yaml`, controller `gateway.envoyproxy.io/gatewayclass-controller`) — **`Gateway`**: `main` (`platform/networking/envoy-gateway/gateway.yaml`) — **Generated Service**: `envoy-main` — fixed LAN IP `192.168.80.240` (Cilium L2 Announcements, see §7) — listeners: `https` (443, HTTP/3 enabled via `ClientTrafficPolicy`, TLS terminate with `wildcard-internal-online-tls`) and `http` (80, redirect only)

Administration/observability tools — reachable only via LAN/Tailscale, never via the Cloudflare wildcard:

| Subdomain | Backend | Namespace |
|-----------|---------|-----------|
| `argocd.internal.cristianpuenguenan.online` | argocd-server:80 | argocd |
| `grafana.internal.cristianpuenguenan.online` | prometheus-grafana:80 | observability |
| `headlamp.internal.cristianpuenguenan.online` | headlamp:80 | observability |
| `hubble.internal.cristianpuenguenan.online` | hubble-ui:80 | kube-system |
| `openmemory.internal.cristianpuenguenan.online` | openmemory-ui:3000 | devtools |
| `sonarqube.internal.cristianpuenguenan.online` | sonarqube-sonarqube:9000 | sonarqube |

#### 3.1.c Agent Gateway (MCP servers only)

**Chart**: `oci://cr.agentgateway.dev/charts/agentgateway` — **`GatewayClass`**: `agentgateway` — **`Gateway`**: `agentgateway-mcp` (`platform/networking/agentgateway/gateway.yaml`) — single `http` listener (80, plain HTTP — the v1.1.0 controller doesn't support HTTPS listeners, see ADR-012) — **Generated Service**: `agentgateway-mcp`, `ClusterIP` (no fixed LAN IP: the only thing that reaches it is `main`'s internal proxy, see TLS below)

Retained solely for routes that leverage real MCP protocol features (multiplexing, virtual MCP) that Cilium doesn't offer; it still does its own routing/rewrite/multiplexing for these `HTTPRoute`s (unchanged):

| Subdomain | Backend | Namespace |
|-----------|---------|-----------|
| `agentgateway.internal.cristianpuenguenan.online` | agentgateway admin UI | networking |
| `openmemory-api.internal.cristianpuenguenan.online` | openmemory:8765 (MCP server) | devtools |
| `mcp.internal.cristianpuenguenan.online` | mcp-sonarqube:3000 (`/sonarqube`) | sonarqube |

#### TLS

Two separate planes, both with real Let's Encrypt certificates — there's no longer a private CA (see ADR-012 update):

- **Private (`*.internal.cristianpuenguenan.online`)**: a subdomain of a domain we already own, certified by the same `ClusterIssuer` (`letsencrypt-prod-cloudflare-dns01`, DNS-01 via Cloudflare) that issues the public wildcard — `wildcard-internal-online-tls`, referenced by `main`'s HTTPS listener. The DNS-01 challenge doesn't require the subdomain to resolve to a real IP: there's no A/AAAA record for `internal.cristianpuenguenan.online`, so it's still unreachable outside the tailnet (although the *public* wildcard `*.cristianpuenguenan.online` does match these routes by DNS since they're subdomains of it — the actual connection still fails at the Cloudflare edge, which rejects TLS for any hostname without its own configured Hostname/certificate there, see ADR-012 update). `main`'s port 80 only responds with 301 → HTTPS. The 3 `agentgateway-mcp` routes are also HTTPS from the client's perspective: its controller still doesn't support HTTPS listeners (ADR-012), so `main` terminates TLS and forwards over plain HTTP, internally within the cluster, to the `agentgateway-mcp` Service (`platform/networking/envoy-gateway/httproute-agentgateway-proxy.yaml`).
- **Public (`*.cristianpuenguenan.online`)**: internet-facing TLS is terminated by Cloudflare at the tunnel edge; cloudflared speaks HTTP to the `public` Gateway. The `wildcard-home-tls` wildcard issued by cert-manager is still not referenced by any listener in the cluster — it's kept issued for future use, not needed for the current flow.

### 3.2 cert-manager

**Chart**: `jetstack/cert-manager` — **Namespace**: `networking`

Automates the issuance and renewal of TLS certificates.

| Resource | Detail |
|---------|---------|
| ClusterIssuer | `letsencrypt-prod-cloudflare-dns01` (single one, used by both wildcards) |
| Validation method | DNS-01 via Cloudflare API |
| Public certificate | Wildcard `*.cristianpuenguenan.online` + apex → `wildcard-home-tls` |
| Private certificate | Wildcard `*.internal.cristianpuenguenan.online` + apex → `wildcard-internal-online-tls`, used by `main` |
| Token secret | `cloudflare-api-token` in the `networking` namespace (via ExternalSecret) |

### 3.3 OpenEBS Local PV LVM (Storage)

**Chart**: `zfs-localpv` (`https://openebs.github.io/zfs-localpv`, version `2.11.1`) — **Namespace**: `openebs`

See [ADR-013](DECISIONS.md#adr-013-replacing-longhorn-with-openebs-local-pv-lvm) and [ADR-014](DECISIONS.md#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv) in [DECISIONS.md](DECISIONS.md) (replaces Longhorn/ADR-004, and the LVM engine from ADR-013). PVCs are provisioned as ZFS datasets inside a zpool (`zfspv-pool`) on a disk dedicated to the VM (`vdb`/`virtio1`, see `terraform/infra/proxmox.tf`). The zpool is created by a Kubernetes `Job` (`kubernetes_job_v1.openebs_zpool_create`, `terraform/cluster/storage.tf`) — Talos exposes no shell for running ZFS tools on the host. No replication (single copy, local to the node) — the same trade-off Longhorn already accepted with `replicaCount: 1`.

| Parameter | Value |
|-----------|-------|
| `zfsNode.kubeletDir` | Chart default (`/var/lib/kubelet/`) — Talos uses the standard path, unlike k0s |
| `analytics.enabled` | `false` |
| Default StorageClass | `openebs-zfs` |
| ZFS pool | `zfspv-pool` (`compression=zstd`, `ashift=12`, `atime=off`) |

#### StorageClasses

| Name | ReclaimPolicy | Use |
|--------|--------------|-----|
| `openebs-zfs` | Delete | Default |
| `openebs-zfs-retain` | Retain | Databases |

### 3.4 Cloudflared (Internet Tunnel)

**Image**: `cloudflare/cloudflared` — **Namespace**: `networking`

Establishes an encrypted outbound tunnel to Cloudflare without needing to open ports on the router.

Secret: `cloudflared-token` (via ExternalSecret from the `infra/cloudflared` item in 1Password).

### 3.5 Headlamp (Kubernetes UI)

**Chart**: `headlamphq/headlamp` — **Namespace**: `observability`

Web dashboard for inspecting the state of the cluster.

| Parameter | Value |
|-----------|-------|
| Service | ClusterIP:80 |
| Access | `headlamp.internal.cristianpuenguenan.online` via Envoy Gateway |

### 3.6 1Password (Secrets Backend)

Managed secrets backend — dedicated **"Homelab"** vault, with no infrastructure of its own to run in the cluster or on any LXC (see ADR-017).

| Parameter | Value |
|-----------|-------|
| Vault | `Homelab` |
| Authentication | Service Account token (read-only, scoped to that vault) |
| Token | Kubernetes Secret `onepassword-service-account-token`, namespace `secret-management` |
| Item model | One item per ExternalSecret `remoteRef.key`, one field per `remoteRef.property` |

There's no process of its own to initialize, seal/unseal, or policies/roles to maintain — which is exactly what replaced OpenBao (see ADR-017 for the details on why).

### 3.7 External Secrets Operator

**Chart**: `external-secrets/external-secrets` — **Namespace**: `secret-management`

Syncs secrets from 1Password into Kubernetes.

| Resource | Detail |
|---------|---------|
| ClusterSecretStore | `onepassword` — provider `onepasswordSDK`, vault `Homelab` |
| Auth | Service Account token (`onepassword-service-account-token`) |

### 3.8 Reloader

**Chart**: `stakater/reloader` — Namespace per the gitops configuration

Automatically restarts Deployments/StatefulSets when a referenced Secret or ConfigMap changes.

---

## 4. Applications and Tools

### 4.1 Flow API

**Namespace**: `apps`

The homelab's main application.

```
Replicas: 1
Port:     80
Secrets:  flow-secrets via ExternalSecret
```

### 4.2 OpenMemory (MCP + Vector Memory)

**Namespace**: `devtools` — **Image**: `mem0/openmemory-mcp:latest`

Vector memory agent for LLMs. Stores embeddings in Qdrant.

```
Replicas: 1
Port:     8080
Env:      QDRANT_HOST=qdrant.internal.cristianpuenguenan.online (external LXC, §5)
Secrets:  openmemory-secrets (OPENAI_API_KEY) via ExternalSecret
```

### 4.3 SonarQube Community

**Chart**: `SonarSource/sonarqube` — **Namespace**: `sonarqube`

Static code quality analysis.

```
Edition:  Community
Port:     9000
DB:       PostgreSQL on the external LXC (§5): jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube
```

---

## 5. Databases

Data services **don't run in the cluster**: they live on four Proxmox VE LXCs, created by Terraform (`terraform/infra/lxc.tf`) as base Debian 13 — bridge `vmbr0`, datastore `local-lvm`, static LAN IP. See [ADR-016](DECISIONS.md) for the decision and its trade-offs. Installing the engines inside the LXCs is pending (later provisioning); consumers already point to the hostnames that `private-dns` (§7) resolves, same as the private HTTP routes.

### 5.1 The four LXCs

| LXC | vmid | IP | Hostname (`private-dns`) | Engine |
|-----|------|----|--------------------------|-------|
| `postgresql` | 121 | `192.168.80.31` | `postgres.internal.cristianpuenguenan.online` | PostgreSQL 17 — `homelab` and `sonarqube` databases |
| `mongodb` | 122 | `192.168.80.32` | `mongodb.internal.cristianpuenguenan.online` | MongoDB 8.0 |
| `qdrant` | 123 | `192.168.80.33` | `qdrant.internal.cristianpuenguenan.online` | Qdrant v1.x (REST 6333, gRPC 6334) |
| `redis` | 124 | `192.168.80.34` | `redis.internal.cristianpuenguenan.online` | Redis 8 (port 6379) |

A single multi-database PostgreSQL (`homelab` + `sonarqube`) replaces the two separate instances that used to run in the cluster. There are no longer any database operators or CRDs inside Kubernetes — the LXCs' lifecycle is Terraform's responsibility, and their OS is updated like any Debian box, independent of the cluster. The engines in the table are the target state: the containers are created bare and installing each engine is pending later provisioning (see ADR-016).

### 5.2 Consumer endpoints

| Consumer | Endpoint |
|------------|----------|
| SonarQube | `jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube` (`SONAR_JDBC_URL`, credentials via ExternalSecret) |
| OpenMemory | `qdrant.internal.cristianpuenguenan.online:6333` (`QDRANT_HOST`/`QDRANT_PORT`) |
| Flow API | PostgreSQL/MongoDB/Redis URLs in 1Password (item `apps/flow`), as plain values |

Backups and operational tasks on the databases are documented in `docs/OPERATIONS.md` §3.

---

## 6. Monitoring

**Namespace**: `observability`

### Components

| Component | Description |
|-----------|-------------|
| Prometheus | Configurable retention, scrape via ServiceMonitor |
| Grafana | Dashboards, Prometheus datasource |
| Alertmanager | Alerts |
| node-exporter | Host metrics |
| kube-state-metrics | Kubernetes object state |
| Headlamp | Cluster management UI |

---

## 7. Networking and Access

### Segmented access: public (Cloudflare) vs private (LAN + Tailscale)

See ADR-011 in [DECISIONS.md](DECISIONS.md). Only 2 of the 12 routes are truly public (`portfolio`, `api` `/webhooks`) — the rest (ArgoCD, Grafana, Headlamp, Hubble, SonarQube UI, Agent Gateway admin UI, OpenMemory UI/API, SonarQube MCP) are administration tools, accessible only from the home LAN or the user's tailnet. OpenEBS (Longhorn's replacement, see ADR-013) exposes no web UI — there's no equivalent route to administer.

Each Gateway has a fixed LAN IP, assigned via Cilium L2 Announcements (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` in `platform/networking/envoy-gateway/`, `spec.addresses` on each `Gateway`):

| Gateway / Service | Fixed IP |
|---------|---------|
| `envoy-main` (generic routes, including the 3 Agent Gateway ones via proxy) | `192.168.80.240` |
| `private-dns` (CoreDNS, resolves `internal.cristianpuenguenan.online` for LAN/Tailscale) | `192.168.80.253` |

`agentgateway-mcp` no longer has a fixed LAN IP — it's `ClusterIP`, reachable only via `main`'s internal proxy (see TLS in §3.1).

With the VM on Proxmox's real bridge (`vmbr0`, see [ADR-014](DECISIONS.md#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv)), the Gateway IPs are real LAN addresses — any device on the LAN reaches them directly, without the firewalld port-forward that libvirt's NAT used to require (`ansible/host-network.yaml`, removed).

```
Internet (only portfolio + api /webhooks)
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egress from cloudflared, inside the cluster)
              └── envoy-public:80 ──► Backend ClusterIP (portfolio/flow-api, via HTTPRoute)

Homelab's physical LAN — direct access, no port-forward
  ├── 192.168.80.240:443 TLS / :80 redirect (envoy-main,
  │   including the 3 agentgateway-mcp routes, forwarded internally
  │   as plain HTTP to its ClusterIP Service)
  └── 192.168.80.253:53 (private-dns)

Tailscale (devices outside the physical LAN, and the CI runner)
  └── Hypervisor's Tailscale node, /32 routes scoped to Proxmox and the VM
      (see docs/CI_CD_HYPERVISOR_SETUP.md — the full /24 is NOT advertised,
      to avoid forcing all of the operator's LAN traffic through the tunnel)
        ├── 192.168.80.240 (envoy-main)
        └── 192.168.80.253 (private-dns, via Tailscale Split DNS)
```

Which hostname resolves to which Gateway is decided, for public traffic, by the Cloudflare tunnel configuration (Zero Trust → Public Hostnames, managed outside Git); for LAN/Tailscale, `private-dns` (CoreDNS, `platform/networking/private-dns/`) resolves `internal.cristianpuenguenan.online` to the corresponding fixed IP, and the data LXC hostnames (§5) to their LAN IPs — see `docs/OPERATIONS.md` to configure Tailscale Split DNS.

### Exposed ports

| Port | Protocol | Description |
|--------|-----------|-------------|
| 80/443 | TCP | 80 = redirect to HTTPS, 443 = TLS on `envoy-main` (direct LAN IP); includes the 3 `agentgateway-mcp` routes, forwarded internally |
| 53 | UDP/TCP | `private-dns` DNS (direct LAN IP) |

### DNS and subdomains

`portfolio`/`api` resolve via Cloudflare Tunnel (WAN). The rest of the routes have no useful public DNS — they resolve via `private-dns` with Tailscale Split DNS restricted to `internal.cristianpuenguenan.online` (see §11 in `docs/OPERATIONS.md`). The public wildcard `*.cristianpuenguenan.online` technically also matches these subdomains by DNS, but the TLS connection fails at the Cloudflare edge (no Hostname configured there) — there's no real way to reach these routes from outside the tailnet.

---

## 8. Security and Secrets

### Local secrets file

The data LXC credentials used to live in `secrets/homelab.env` (plaintext, gitignored); since ADR-018 they live encrypted in `ansible/data-services.env` (SOPS + age), consumed by CI via `sops exec-env` before running `ansible/data-services.yaml`. In CI, the credentials preflight uses GitHub Actions secrets/vars for what Terraform consumes (see `docs/CI_CD_HYPERVISOR_SETUP.md`).

### Secrets Management in the Cluster (SOPS + age, see ADR-018 and ADR-019)

1. **SOPS + age** is the single source of truth for application secrets (inside and outside the cluster) — each value is encrypted with the `age` public key and committed encrypted to the repo. No external backend, no rate limit.
2. **Terraform** (`terraform/cluster/secrets.tf`) creates ArgoCD's initial secrets (`github-repo-creds`, `in-cluster-secret`).
3. **`sops-secrets-operator`** (namespace `sops`) runs in the cluster with the `age` private key mounted, and translates each `SopsSecret` (CRD, encrypted) into a real Kubernetes `Secret`. ArgoCD applies the `SopsSecret` as-is, encrypted — it never needs to know about SOPS.
4. The **`age` private key** is the only sensitive piece outside the repo: it lives in the Secret mounted by the operator, and its only backup is a manual document in 1Password (`sops-age-homelab-key`, vault "Homelab") — a one-time read for disaster recovery, not an active integration. Since ADR-019, 1Password has no other integration in the cluster or in CI.

#### `SopsSecret` inventory (`*.sops.yaml` in the repo)

```
platform/argocd/repo-credentials.sops.yaml          -> GitHub PAT for ArgoCD
platform/networking/cert-manager/cloudflare-api-token.sops.yaml -> Cloudflare API token (DNS-01)
platform/networking/cloudflared/token.sops.yaml     -> Cloudflare tunnel token
platform/observability/secrets/grafana-admin.sops.yaml -> Grafana admin
platform/devtools/openmemory/secrets.sops.yaml       -> OPENAI_API_KEY, QDRANT_API_KEY, ghcr-pull-secret
workloads/flow/secrets.sops.yaml                     -> database-url, mongodb-url, redis-url
workloads/sonarqube/secrets.sops.yaml                -> DB credentials, monitoring passcode
ansible/data-services.env (dotenv, not a CRD)        -> Postgres/Mongo/Redis/Qdrant credentials, CI only
```

---

## 9. GitOps and Deployment Order

Actual order by `argocd.argoproj.io/sync-wave` (verified in `gitops/apps/**`, not an estimated value):

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── Wave -1: homelab-project (AppProject)
        ├── platform/
        │     ├── Wave 1: openebs, cert-manager, reloader
        │     ├── Wave 2: openebs-config, agentgateway-crds, gateway-api-crds, envoy-gateway-crds, cert-manager-config,
        │     │           external-secrets(-config)
        │     ├── Wave 3: agentgateway, envoy-gateway, cilium-service-mesh, cilium-hubble-pki
        │     ├── Wave 4: argocd-config, observability/secrets, agentgateway-config, tetragon,
        │     │           envoy-gateway-config, private-dns
        │     ├── Wave 5: prometheus, cloudflared, headlamp(-config), hubble-config
        │     ├── Wave 6: grafana-config, service-monitors
        │     ├── Wave 7: hubble-dashboards
        │     ├── Wave 8: openmemory
        │     └── Wave 9: openmemory-ui
        └── workloads/
              ├── Wave 8: sonarqube, sonarqube-config, sonarqube-mcp
              └── Wave 9: flow, portfolio
```

### Implicit dependencies

```
OpenEBS ───────────────────────► Cluster PVCs (Prometheus, Grafana, SonarQube, Alertmanager)

cert-manager (letsencrypt-prod-cloudflare-dns01) ──► wildcard-internal-online-tls ──► main's HTTPS listener
                                                └──► wildcard-home-tls (issued, not referenced — see §3.1 TLS)

1Password (Homelab vault) ──► ExternalSecrets sync ──► all secrets

postgresql LXC (external, §5) ──► SonarQube (sonarqube database), Flow API (homelab database)
qdrant LXC (external, §5) ──────► OpenMemory
mongodb / redis LXCs (external) ─► Flow API (URLs from 1Password, item apps/flow)

private-dns ──► the LXCs' *.internal hostnames resolve for cluster consumers
```

---

## 10. Storage and Resources

### Persistent volumes (estimated)

Databases no longer consume cluster PVCs — they live on the Proxmox LXCs (§5), with disk on the Proxmox host's `local-lvm`.

| Component | Size | StorageClass |
|-----------|---------|-------------|
| Prometheus | 20Gi | openebs-zfs |
| Grafana | 5Gi | openebs-zfs |
| Alertmanager | 1Gi | openebs-zfs |
| SonarQube | 10Gi | openebs-zfs |
| **Total** | **~37Gi** | |

### Minimum VM requirement

- **CPU**: 4 cores (this repo's default: 8 vCPU, `var.vcpu`)
- **RAM**: 8 GB (default: 16 GB, `var.memory_mib`)
- **Disk**: 2 disks — Talos installation (default: 120 GB, `var.disk_size_gb`, `virtio0`) + dedicated to the OpenEBS ZFS zpool (default: 100 GB, `var.zfs_disk_size_gb`, `virtio1`, unformatted)
- **OS**: Talos Linux (ISO generated by the Image Factory, downloaded by `proxmox_download_file.talos_iso`)

The **host** (Proxmox VE) needs additional headroom on top of these numbers for the hypervisor + VM overhead.

---

## 11. Initial Installation Flow

### Phase 0 — Preflight (Ansible)

Validates that the credentials in `secrets/homelab.env` aren't empty/invalid before spending time provisioning infrastructure.

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

### Phase 1 — Talos VM on Proxmox (`terraform/infra`)

Terraform downloads the Talos ISO (Image Factory), creates the VM in Proxmox with two disks, applies the machine config (includes the declarative partitioning of the ZFS disk), bootstraps the cluster, and generates `terraform/infra/generated/{kubeconfig,talosconfig}`. In the same stage it provisions the four data LXCs (§5, `terraform/infra/lxc.tf`).

```bash
cd terraform/infra
terraform init -backend-config=backend.hcl
terraform apply
kubectl --kubeconfig generated/kubeconfig get nodes
```

### Phase 2 — Kubernetes Bootstrap (`terraform/cluster`)

Creates the namespaces, installs Cilium and ArgoCD (`helm_release`), and the Job that creates the OpenEBS ZFS zpool, in order via `depends_on`.

```bash
cd ../cluster
terraform init -backend-config=backend.hcl
terraform apply
```

### Phase 3 — Activate GitOps

```bash
kubectl apply -f gitops/root-app.yaml
```

Follow progress:

```bash
kubectl -n argocd get applications -w
```

### Phase 4 — Load the real secrets (manual, doesn't run in CI)

```bash
cp secrets/homelab.env.example secrets/homelab.env && $EDITOR secrets/homelab.env
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt
./scripts/apply-real-secrets.sh secrets/homelab.env
```

---

## Troubleshooting

**Apps in Unknown — cluster secret:**
```bash
CA_DATA=$(kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
data:
  server: $(echo -n "https://kubernetes.default.svc" | base64 -w0)
  name: $(echo -n "in-cluster" | base64 -w0)
  config: $(echo -n "{\"tlsClientConfig\":{\"insecure\":false,\"caData\":\"${CA_DATA}\"}}" | base64 -w0)
EOF
```

**ClusterSecretStore False:**
```bash
kubectl get clustersecretstore onepassword -o wide
kubectl describe clustersecretstore onepassword
```
Typical causes: the `onepassword-service-account-token` Secret is missing in `secret-management`, the token expired, or it lost access to the "Homelab" vault.

**OpenEBS volume not provisioning (Pending):**
```bash
kubectl get zfsnode -n openebs
kubectl -n openebs logs -l app=openebs-zfs-controller -c openebs-zfs-plugin

# Talos has no shell or ZFS tools on the host: inspect it from a privileged
# pod with /dev mounted (same pattern as
# kubernetes_job_v1.openebs_zpool_create in terraform/cluster/storage.tf) -
# ZFS syscalls/ioctls are kernel-level, shared by all containers on the
# node, without needing to chroot into the host.
kubectl debug node/talos -it --image=alpine:3.20 -- \
  sh -c "apk add --no-cache zfs >/dev/null && zpool status zfspv-pool"
```
