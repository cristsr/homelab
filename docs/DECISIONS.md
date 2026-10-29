# Architecture Decisions (ADR)

Log of the main technical decisions made in the homelab. Each entry explains the context that motivated the decision, the alternatives evaluated, and the consequences.

---

## ADR-001: k0s as Kubernetes distribution

**Status**: Superseded by [ADR-014](#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv) — replaced MicroK8s
**Date**: 2026-04

### Context

The homelab started with **MicroK8s**. Over time, frictions arose that made it incompatible with a clean GitOps setup:

- MicroK8s installs and manages its own addons (DNS, ingress, storage) that create abstractions over the real components, hindering direct control with ArgoCD.
- It is distributed via **snap**, which generates non-standard paths for CNI binaries (`/snap/microk8s/...`) that break Cilium's configuration.
- Disabling `kube-proxy` to hand it over to Cilium eBPF is not a clean or documented process in MicroK8s.
- Version updates via snap can happen outside the operator's control.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **MicroK8s** | Non-standard paths, opaque addons, snap, kube-proxy hard to disable |
| **k3s** | Installs Traefik and extra components by default, requires flags to disable |
| **RKE2** | More oriented to enterprise production, unnecessary overhead for single-node |

### Decision

**k0s**: single binary with no dependencies, 100% declarative configuration via `/etc/k0s/k0s.yaml`, `kube-proxy` is disabled with `--disable-components=kube-proxy`, standard CNI paths, stable systemd service.

### Consequences

- Cilium can manage all the network plumbing without path conflicts.
- Node configuration is reproducible via a Jinja2 template in Ansible.
- The MicroK8s addon ecosystem is lost (positive: total control over each component is gained).

---

## ADR-002: Agent Gateway as ingress

**Status**: Superseded by [ADR-026](#adr-026-agent-gateway-removed-mcp-served-by-envoy-gateway) — replaced APISIX
**Date**: 2026-05

### Context

**Apache APISIX** was the homelab's first ingress. The main friction was its configuration model:

- Routes are managed through the **Admin API** (HTTP calls to the control panel), not with declarative YAML resources in Git.
- Although APISIX has its own CRDs (`ApisixRoute`, `ApisixUpstream`), they are an abstraction layer over its Admin API and do not follow the standard Kubernetes Gateway API.
- This means ArgoCD manages the ArgoCD resources but doesn't really control the route configuration, breaking the GitOps principle of "everything in Git".
- The homelab has MCP servers that need a gateway that natively understands AI workloads and MCP protocols.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **APISIX** | Config via Admin API, no native Gateway API, friction with GitOps |
| **Nginx Ingress** | Legacy Ingress API, no Gateway API, no MCP support |
| **Envoy Gateway** | Native Gateway API but no AI/MCP support |
| **Istio Gateway** | Too much overhead for single-node |

### Decision

**Agent Gateway**: implements the **Kubernetes Gateway API** (`Gateway`, `HTTPRoute` as native resources), all configuration is declarative YAML managed by ArgoCD, it has native support for AI workloads and the MCP protocol.

### Consequences

- All route configuration lives in Git and is synced by ArgoCD.
- MCP servers (SonarQube MCP, OpenMemory) are exposed with standard HTTPRoutes with path rewriting.
- Agent Gateway is a young project with a smaller community than APISIX or Nginx; it may have breaking changes.

---

## ADR-003: Cilium as CNI

**Status**: Accepted
**Date**: 2026-04

### Context

A CNI is needed that meets three requirements simultaneously:

1. **kube-proxy replacement**: eliminate iptables overhead using eBPF.
2. **Expressive NetworkPolicies**: ability to restrict traffic between pods with more granular rules than Kubernetes' native ones.
3. **Network observability**: visibility into L3/L4/L7 flows without instrumenting applications.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **Flannel** | L2/L3 only, no NetworkPolicy, no observability |
| **Calico** | Native NetworkPolicy, but no full eBPF or Hubble |
| **Weave** | Project under reduced maintenance |

### Decision

**Cilium** with `kubeProxyReplacement: true`:

- The entire network data plane via **eBPF** (no iptables).
- **Hubble** for real-time network flow observability with a UI.
- `CiliumNetworkPolicy` for more expressive network rules (e.g., filtering by namespace label + specific port).
- **Sidecar-less service mesh** available if mTLS is needed in the future.

### Consequences

- Requires Linux kernel ≥ 4.19 (not a problem on Ubuntu 22.04 with kernel 5.x+).
- Initial configuration is more complex (CNI bin paths, `k8sServiceHost`, routing modes).
- Cilium manages kube-proxy, DNS, and NetworkPolicy, reducing the number of independent components.

---

## ADR-004: Longhorn as storage

**Status**: Superseded by [ADR-013](#adr-013-replacing-longhorn-with-openebs-local-pv-lvm)
**Date**: 2026-04

### Context

On single-node, a StorageClass is needed that allows persistent PVCs for databases (PostgreSQL, MongoDB, Redis, Qdrant, OpenBao). The requirements are: snapshots, optional backups, and two distinct retention policies (`Delete` for ephemeral data, `Retain` for databases).

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **local-path-provisioner** | No snapshots, no backups, no UI, single policy |
| **Rook-Ceph** | Excessively complex for single-node, high resource consumption |
| **OpenEBS** | More complex to configure, smaller community |

### Decision

**Longhorn** installed via Helm:

- Two StorageClasses: `longhorn` (ReclaimPolicy: Delete) and `longhorn-retain` (ReclaimPolicy: Retain) for databases.
- Web UI to inspect volumes, snapshots, and replicas.
- Replicas set to 1 (single-node cannot replicate to another node).
- Schedulable snapshots for database backups.

### Consequences

- Requires `open-iscsi` installed on the node (managed by Ansible as a prerequisite).
- Longhorn's processes (manager, engine image, replica) consume node resources (~200MB RAM).
- On single-node, redundancy is limited: a disk failure = data loss. Mitigated with snapshots.

---

## ADR-005: Cloudflare Tunnel for external access

**Status**: Accepted
**Date**: 2026-04

### Context

The homelab's services need to be accessible from the Internet (ArgoCD, Grafana, SonarQube, etc.) without compromising the security of the home network. The home network is behind a router with NAT and no fixed public IP, which makes opening ports fragile (IP changes) and implies exposing the node directly to inbound Internet traffic.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **Port forwarding on the router** | Requires a static public IP, exposes the node directly to the Internet, DDNS is fragile |
| **Tailscale / WireGuard VPN** | Requires a VPN client on the accessing device, doesn't work for public web access without a client |
| **VPS as reverse proxy** | Additional monthly cost, extra latency, another system to maintain |

### Decision

**Cloudflare Tunnel** (`cloudflared`): the agent establishes an encrypted **outbound** connection from the cluster to Cloudflare. All inbound traffic flows through that connection without needing to open ports on the router or have a fixed IP.

Additional benefits:
- The domain's DNS (`*.cristianpuenguenan.online`) is already managed on Cloudflare, unifying DNS + tunnel + TLS certificates on a single platform.
- Cloudflare transparently acts as WAF and DDoS protection.
- The tunnel token is managed as a secret in OpenBao and synced via ExternalSecret, so `cloudflared` starts up without plain-text credentials.

### Consequences

- No port is opened on the router; the node is not directly accessible from the Internet.
- External access depends on Cloudflare's availability (practically 100% uptime).
- For LAN access without going through Cloudflare, Agent Gateway remains directly accessible at `192.168.80.20:443`.

---

## ADR-006: OpenBao as secrets backend


**Status**: Accepted
**Date**: 2026-04

### Context

The cluster needs a centralized system to manage secrets (API tokens, database credentials, TLS keys) that meets two requirements: secrets **must not live in plain text in Git** and must be able to sync automatically with Kubernetes Secrets when a pod needs them.

The simplest alternative — putting secrets directly as Kubernetes Secrets in the repository — is incompatible with GitOps because it would require encrypting them in the repo (SOPS, sealed-secrets) or accepting the risk of exposure.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **Sealed Secrets** | Secrets encrypted in Git but tied to the cluster's key; if the cluster dies, the original secrets are lost |
| **SOPS + age/GPG** | Valid encryption in Git, but requires manual decryption or CI/CD to apply; no dynamic API for rotation |
| **HashiCorp Vault** | Reference solution but with BSL (Business Source License) since 2023; OpenBao is its community fork under the MPL-2.0 license |
| **Doppler / Infisical** | External SaaS; introduces a third-party dependency for the cluster's critical secrets |

### Decision

**OpenBao** (community fork of HashiCorp Vault, MPL-2.0 license) deployed in the cluster via Helm:

- KV v2 as the main engine: all cluster secrets live in `secret/` with versioning.
- **Kubernetes auth**: pods authenticate with their ServiceAccount, without hardcoded credentials.
- **External Secrets Operator** syncs automatically from OpenBao to Kubernetes Secrets; pods only see native Kubernetes Secrets.
- The unseal key is managed with **Static Seal** (AES-256) encrypted with `ansible-vault` in the repository.

### Consequences

- No production secret lives in plain text in Git.
- After every restart of the `openbao-0` pod, the vault becomes sealed and requires manual unseal with the AES-256 key. This is the main operational friction point.
- External Secrets Operator adds an extra component, but fully decouples secret management from its consumption.
- Being an active fork of Vault, the API is 100% compatible: Vault's documentation is valid for OpenBao.

> **Update (ADR-015)**: the unseal key and the rest of the credentials no longer live encrypted in the repository with `ansible-vault` — they live in `secrets/homelab.env`, plain and gitignored, loaded into OpenBao with a manual script.

---

## ADR-007: Ansible for node provisioning

**Status**: Accepted
**Date**: 2026-04

### Context

The node needs to be provisioned **before** Kubernetes exists: installing k0s, kubectl, Helm, Helmfile, Longhorn prerequisites, and creating the initial secrets the cluster needs on first boot. This bootstrapping cannot be done with GitOps because ArgoCD doesn't exist yet.

Additionally, the bootstrap secrets (GitHub PAT, Cloudflare tokens, OpenBao key) cannot live in plain text in the repository.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **Bash scripts** | Not idempotent, complicated secret management, hard to maintain |
| **Terraform** | Oriented toward provisioning cloud infrastructure, not configuring an existing physical/VM node |
| **Cloud-init** | Only runs once on first boot, not re-runnable |

### Decision

**Ansible** with a structure of separate playbooks:

- `site.yaml`: main playbook, idempotent, installs and configures the entire node from scratch.
- `vault-populate.yaml`: writes the infrastructure secrets into OpenBao KV once the cluster is active.
- `teardown.yaml`: cleanly destroys the cluster for reinstalls.
- `ansible-vault` encrypts sensitive secrets in `group_vars/all.yaml`; the vault password file (`.vault-pass`) is in `.gitignore`.

### Consequences

- The node's complete state is reproducible by running a single command (`ansible-playbook site.yaml`).
- Sensitive secrets are encrypted in the repository, safe to version.
- Requires Python and Ansible installed on the node before running (minimal manual bootstrapping dependency).
- The playbook runs locally on the node (`ansible_connection: local`); it doesn't require SSH from an external host.

> **Update (ADR-008)**: since the node now runs inside a VM, Ansible moved from `ansible_connection: local` to SSH against the VM. Ansible's role did not change — it remains solely responsible for configuring the node once it exists; what changed is *which* node exists first (now created by Terraform).

---

## ADR-008: libvirt VM provisioned with Terraform

**Status**: Superseded by [ADR-014](#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv)
**Date**: 2026-08-30

### Context

The node ran directly on the laptop's hardware (bare-metal, single host). This tied the entire cluster lifecycle to the host's operating system: reinstalling the node meant reinstalling the whole machine, and there was no way to take snapshots or roll back the node's own state (only the cluster's, via `teardown.yaml`). The README itself already anticipated this possibility ("deployed... on a single physical/virtual node").

ADR-007 had evaluated and rejected Terraform for provisioning, but for a specific reason: "Terraform is oriented toward provisioning cloud infrastructure, not configuring an **existing** physical/VM node". That reason stopped applying as soon as it was decided to run the node inside a VM: there really is infrastructure to create there (disk, network, libvirt domain), which is exactly Terraform's domain.

### Options considered

| Option | Reason for rejection |
|--------|-------------------|
| **Stay on bare-metal** | No snapshots or rollback at the node level; reinstalling = reinstalling the entire host OS |
| **Vagrant + libvirt** | Extra layer (Ruby/Vagrantfile) over libvirt without adding anything over Terraform; worse state tracking than a `.tfstate` |
| **Bash scripts + virt-install** (prototype explored in `~/vmconfig` during this session) | Not declarative, no state, no plan/diff before applying changes |

### Decision

**Terraform with the `dmacvicar/libvirt` provider** (`terraform/` directory) creates the VM: dedicated pool, base volume (pristine download of Fedora Cloud, never booted directly) + copy-on-write overlay volume per VM, `libvirt_cloudinit_disk` with a static IP, and the libvirt domain itself.

Ansible **does not change role** (ADR-007 remains in effect): it remains solely responsible for installing k0s and doing the initial bootstrap — only the transport changes, from `ansible_connection: local` to SSH against the VM.

**Network**: the host only has WiFi active (no ethernet cable available), and bridging a VM over WiFi is fragile on most drivers/APs. NAT libvirt was chosen (`192.168.122.0/24`, existing `default` network) + port-forward from `192.168.80.20:80/443` to the VM configured with firewalld (`ansible/host-network.yaml`, runs against the host, not the VM). Cloudflare Tunnel (ADR-005) is not affected because it's an outbound connection from inside the VM.

### Consequences

- `terraform.tfstate` local becomes a critical artifact with no remote backend — a known single point of failure accepted for now (single-operator homelab); out of scope for this decision.
  > **Update (ADR-009)**: no longer applies — the state now lives in a remote backend (Cloudflare R2), a non-optional requirement for running Terraform from an ephemeral CI runner.
- New dependency on the host: libvirt/KVM, in addition to Terraform.
- It is now possible to take VM snapshots as a disaster recovery mechanism at the node level — something bare-metal never offered.
- Direct LAN access depends on firewalld's port-forward rules on the host (one more component that can fail); WAN access via Cloudflare Tunnel has no additional overhead.
- `libvirt_domain.k0s_node` has `autostart = true`: unlike bare-metal (where `k0scontroller` started on its own with the host), now the VM must start on its own after a host reboot for the cluster to become available again.

### Findings from the real deployment (not obvious in advance)

- **Legacy BIOS + `i440fx`, not UEFI**: on this host, OVMF/UEFI (with or without secure-boot, with or without SMM) leaves the VM hung silently — no output on serial console or framebuffer, CPU at 99% in a spin-loop inside the firmware. Legacy BIOS boots reliably with the same Fedora Cloud template. Nothing in k0s/Cilium/Longhorn requires UEFI, so `terraform/main.tf` sets `os.type_machine = "pc"` with no firmware block.
- **The `dmacvicar/libvirt` provider's `memory` is in KiB by default**, not MiB — without an explicit `memory_unit = "MiB"`, each VM was created with just a few MB of RAM instead of GB (the real root cause of the boot hang, more than the firmware). See the comment in `terraform/main.tf` next to the `libvirt_domain` block.
- This provider's schema (resolved to v0.9.9 with the `~> 0.8` constraint) is a complete rewrite compared to earlier versions documented in the community: it maps libvirt's XML almost 1:1 with nested attributes (`disks = [...]`, `os = {...}`), not the classic `disk {}`/`network_interface {}` blocks. If the provider is updated, review `terraform providers schema -json` before touching `main.tf`.

---

## ADR-009: CI/CD with GitHub Actions hosted + Tailscale + Cloudflare R2

**Status**: Accepted
**Date**: 2026-08-31

### Context

Terraform and Ansible were run manually from the hypervisor itself (local `qemu:///system`, `hypervisor` inventory group with `ansible_connection: local`). The operator no longer wanted to run these tools on the homeserver and asked for a real CI/CD flow with GitHub Actions.

A **hosted** GitHub Actions runner lives in GitHub's public cloud: it has no network route to a home LAN without NAT/public IP. In addition, `terraform apply` running on an ephemeral runner can't depend on a local `terraform.tfstate` — it would be lost on every job. These two problems (connectivity + state) are what this decision solves.

During investigation, a previous note in project memory (not reflected in code) claiming the existence of a native `"github"` backend in Terraform was discarded — it was confirmed against HashiCorp's official documentation that **no such backend exists**; corrected here.

### Options considered

**Runner → hypervisor connectivity:**

| Option | Reason for rejection |
|--------|------------------|
| **Self-hosted runner on the homeserver** | Exactly what the operator wanted to stop doing — goes back to running everything on the host itself |
| **SSH port exposed on the router** | Exposes the LAN to the Internet; GitHub Actions IP ranges change frequently, doesn't work for a stable allowlist |
| **Cloudflare Tunnel dedicated to SSH (outside the cluster)** | Viable, but adds a second `cloudflared` at the host level just for this — more surface to maintain than Tailscale |

**State backend:**

| Option | Reason for rejection |
|--------|------------------|
| **Local state on the runner** | Lost on every job (ephemeral runner) — not a real option, not a preference |
| **HCP Terraform (Terraform Cloud) free tier** | Official and simple backend, but introduces an additional account/platform outside the already-used stack (Cloudflare) |

### Decision

- **Hosted GitHub Actions runners**, with no self-hosted runner on the homeserver.
- **Tailscale**: the physical hypervisor joins the tailnet (`tailscale up --ssh`); each CI job spins up an ephemeral node via `tailscale/github-action@v4` authenticated with an OAuth client, tagged `tag:ci`, with an ACL that only allows `tag:ci` → the hypervisor's tag over SSH (port 22). No port is opened on the router.
- **`terraform/provider.tf`** moves from `qemu:///system` to `qemu+ssh://...` (variables `hypervisor_ssh_host`/`hypervisor_ssh_user`/`hypervisor_ssh_keyfile`, no default). This also unifies manual execution: the operator no longer runs Terraform on the host either, always remotely via SSH — same code path as CI.
- **Ansible inventory** (`terraform/templates/inventory.yaml.tftpl`): the `hypervisor` group stops being `ansible_connection: local` and moves to real SSH; the `k0s` group (VM on libvirt's internal NAT network, only reachable from the hypervisor itself) uses `ProxyCommand` to jump through the hypervisor.
- **Remote state in Cloudflare R2** (S3-compatible) via Terraform's native `s3` backend with a custom endpoint — reuses the Cloudflare account already used for DNS/Tunnel instead of adding a new platform. Native locking with `use_lockfile = true` (Terraform ≥ 1.10), no DynamoDB.
- **Automatic pipeline scope** (`.github/workflows/deploy.yml`, push to `master`): `terraform apply` + `ansible-playbook site.yaml` + `ansible-playbook host-network.yaml` + `vault-populate.yaml` + `load-extra-secrets.yaml`, behind the `prod` Environment (manual approval required). Only `teardown.yaml` (destructive, interactive) stays out of the pipeline.
- `.github/workflows/terraform-plan.yml` runs `terraform plan` and comments the result on every PR touching `terraform/**`, with no approval gate (doesn't mutate infrastructure).

### Consequences

- The homeserver no longer has terraform/ansible running on it: it only receives inbound SSH connections via Tailscale.
- New external dependency: Tailscale (tailnet + OAuth client) and a Cloudflare R2 account/bucket.
- Infrastructure secrets grow (`TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET`, `HOMESERVER_SSH_PRIVATE_KEY`, `R2_ACCOUNT_ID`/`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`, `ANSIBLE_VAULT_PASSWORD`) — all as GitHub Secrets, none in the repo.
- The manual flow documented in `docs/INSTALL.md` continues to work the same, now also remote (same `qemu+ssh://` URI used by CI) instead of local to the hypervisor.

**Update (2026-09-06):** `load-extra-secrets.yaml` stops being a "manual one-off" and starts running on every automatic deploy, alongside `vault-populate.yaml`. Reason: it was never run even once since the cluster has existed (being manual, it was forgotten), leaving several services (`redis`, `postgresql` app, `mongodb` app, `grafana`, `sonarqube-db`) without their secrets since day 1. `ansible/extra-secrets.yaml` moves from living outside Git (`.gitignore`, plain text) to versioned and encrypted with `ansible-vault` (same pattern as `group_vars/all.yaml`) — edited with `ansible-vault edit ansible/extra-secrets.yaml`. For a change to propagate without manual steps: the corresponding `ExternalSecret` must have a short `refreshInterval` (`1m`, not the default `1h`) and the Deployment/StatefulSet consuming it must be covered by Reloader (`autoReloadAll: true` already covers plain resources; Grafana needed the explicit annotation because it doesn't re-read its admin secret live).

**Update (2026-09-07): ArgoCD's sync had been broken since May 13, without anyone noticing.** While investigating for another reason, it was found that `argocd-cm` has `timeout.reconciliation: 0s` (completely disables periodic polling — the original intent, per `docs/TODO.md`, was to leave it as a 600s *fallback*, not turn it off) and that the GitHub webhook configured on the repo (`https://argocd.cristianpuenguenan.online/api/webhook`, active since 2026-05-13) returns 404 on every delivery: the URL points to the public domain, but no `HTTPRoute` serves it there — ArgoCD only had a private route. With both things broken at once, ArgoCD never detected a new commit unless someone refreshed it by hand from the UI; Applications were found up to 15+ commits behind.

Fix: **`platform/argocd/httproute-webhook.yaml`**, a new `HTTPRoute` against the `public` Gateway, hostname `argocd.cristianpuenguenan.online`, exposing *only* the `/api/webhook` path (the rest of ArgoCD remains without a public route) — the payload is signed (HMAC) against `webhook.github.secret`, already mixed into `argocd-secret` by `webhook-externalsecret.yaml` since this was implemented (`docs/TODO.md` #3), so exposing the path is safe without additional changes. And `timeout.reconciliation` moves from `0s` to `600s` (`bootstrap/argocd/values.yaml`) — the webhook still triggers the sync instantly in the normal case, but a delivery failure no longer leaves the cluster silently out of sync for months.

**Update (2026-09-07): Agent Gateway had been crash-looping for over a day, a different and also pre-existing cause.** The `agentgateway` pod (namespace `networking`) never reached `Ready` — its logs showed an informer indefinitely waiting for the `tcproutes.gateway.networking.k8s.io` CRD, which doesn't exist in the cluster: `gitops/apps/platform/networking/gateway-api-crds.yaml` installed the `standard` channel (v1.6.1) of Gateway API, which doesn't include `TCPRoute`/`UDPRoute`/`TLSRoute` (those live in the `experimental` channel, a superset of `standard` — same base CRDs with no schema changes). Fix: change `path: config/crd/standard` → `path: config/crd/experimental`, same `targetRevision`. This is what left Agent Gateway's 3 routes (`mcp`, `openmemory-api`, `agentgateway`) at `503` during the entire ADR-012 domain migration — confirmed the error was identical on `.internal` and on the new domain, so it wasn't a regression from that migration.

**Update (2026-09-09, see ADR-015):** `vault-populate.yaml` and `load-extra-secrets.yaml` leave the automatic pipeline — loading secrets into OpenBao becomes 100% manual (`scripts/load-secrets-to-openbao.sh`), never runs in CI. The `ANSIBLE_VAULT_PASSWORD` secret is no longer used (there's no more `ansible-vault` in the repo); the preflight now takes its 6 credentials from GitHub Actions secrets/vars injected as step env vars (`ARGOCD_GITHUB_PAT`, `OPENBAO_STATIC_SEAL_KEY` already existed as secrets for Terraform; `ARGOCD_WEBHOOK_SECRET`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARED_TOKEN` are added as new secrets and `ARGOCD_REPO_URL` as a variable — see `docs/CI_CD_HYPERVISOR_SETUP.md`).

## ADR-010: Cilium Gateway API for generic ingress, Agent Gateway only for MCP

**Status**: Accepted — reduces Agent Gateway's scope (see [ADR-002](#adr-002-agent-gateway-as-ingress)); the Cilium Gateway API half is superseded by [ADR-023](#adr-023-envoy-gateway-replaces-cilium-gateway-api-for-generic-ingress) and the Agent Gateway half by [ADR-026](#adr-026-agent-gateway-removed-mcp-served-by-envoy-gateway)
**Date**: 2026-09-05

### Context

ADR-002 adopted Agent Gateway as the sole ingress for two reasons: (a) being native Gateway API (vs. APISIX's Admin API) and (b) native support for AI workloads and the MCP protocol. Reviewing actual usage in the repo: of the 13 existing `HTTPRoute`s, only 2 truly serve MCP servers (SonarQube MCP, OpenMemory) — the rest is generic HTTP traffic (ArgoCD, Grafana, Longhorn, OpenBao, Hubble, Headlamp, Flow API, Portfolio, SonarQube UI) that doesn't use any of Agent Gateway's differentiating features, just standard `Gateway`/`HTTPRoute`.

Cilium (already deployed as the cluster's CNI) implements its own Gateway API controller on top of Envoy/eBPF, with Gateway API v1.6.1 conformance, but with no understanding of the MCP protocol at all: it doesn't do MCP server multiplexing, tool namespacing, or virtual MCP — Agent Gateway does that natively (confirmed against agentgateway.dev's official documentation). Keeping Agent Gateway as the sole gateway means sustaining a young project, with a smaller community, for traffic that doesn't leverage its differentiator.

### Options considered

| Option | Reason for rejection |
|--------|-------------------|
| **Keep only Agent Gateway** | Sustains a second proxy/CRD for traffic that Cilium can already serve just as well via standard Gateway API |
| **Migrate everything to Cilium, retire Agent Gateway** | Loses the only real differentiating capability (multiplexing/virtual MCP) that is still planned to be used/explored in the future |

### Decision

**Hybrid**: two `Gateway`s coexisting in the `networking` namespace, each with its own purpose:

- **Cilium Gateway API** (`gatewayClassName: cilium`, `Gateway` `main`) serves generic HTTP traffic — 10 of the current 13 `HTTPRoute`s.
- **Agent Gateway** (`gatewayClassName: agentgateway`, `Gateway` `agentgateway-mcp`) is retained only for routes that depend on MCP servers (SonarQube MCP, OpenMemory) and its own admin UI.

The Gateway API CRDs were already installed by a separate Application (`gateway-api-crds`, not part of either the Cilium or Agent Gateway chart), so both controllers share them without duplication.

### Consequences

- `bootstrap/cilium/values.yaml` sets `gatewayAPI.enabled` to `true` — Cilium automatically creates the `GatewayClass cilium` and, for each `Gateway`, a `Service` `cilium-gateway-<name>`.
- The Cloudflare tunnel (remote config, outside Git) must be manually re-pointed to the migrated hostnames toward Cilium's new Service — there's no way to version that change.
- The door stays open to keep experimenting with MCP protocol features (new servers, virtual MCP) without having to reintroduce Agent Gateway from scratch.
- Internal TLS (an HTTPS listener on either Gateway) remains unresolved — neither one has an HTTPS listener or references the wildcard certificate; technical debt pre-existing to ADR-002, neither introduced nor resolved by this change.

## ADR-011: Segment public access (Cloudflare) vs private access (LAN + Tailscale)

**Status**: Accepted
**Date**: 2026-09-06

### Context

Of the cluster's 13 routes, most are administration/observability tools (ArgoCD, Grafana, Headlamp, Hubble, Longhorn, OpenBao, SonarQube UI, Agent Gateway admin UI, OpenMemory UI/API, SonarQube MCP) that should never have been reachable from the Internet — only `portfolio` (personal site) and `api.cristianpuenguenan.online` (`/webhooks`, consumed by external services) are truly public.

What is exposed to the Internet or not is decided in the Cloudflare dashboard (Zero Trust → Public Hostnames) — but see the 2026-09-06 update below: here it was assumed there was one entry per route, when in reality there's a single wildcard, and the real fix did require moving `HTTPRoute`s. In addition, a real private access path was missing: while investigating, `ansible/host-network.yaml` (LAN → VM port forward) was already broken — it forwarded to the VM's port 80/443, but nothing was listening there (both Gateways' Services are `LoadBalancer` with no assigned IP, with no MetalLB or other controller resolving them; only their random `NodePort`s existed).

### Decision

- **Cilium L2 Announcements + LB IPAM** (native since Cilium 1.20, no separate MetalLB install): two `CiliumLoadBalancerIPPool`s of one IP each (`192.168.122.240` and `192.168.122.250`, deliberately non-consecutive within libvirt's NAT subnet) + `CiliumL2AnnouncementPolicy` on the VM's `eth0`. Each `Gateway` fixes its IP with `spec.addresses` (standard Gateway API v1 field) — but the **Agent Gateway controller doesn't translate it** into a real request in the `Service` it generates (confirmed against the cluster: without the `io.cilium/lb-ipam-ips` annotation, unlike Cilium which does add it). With a shared pool and no filter, Cilium LB IPAM gave the first free IP to `agentgateway-mcp` without it requesting one, stepping on the IP that belonged to Cilium's Gateway. Solution: a 1-IP pool per `Service`, selected by `serviceSelector` (`io.kubernetes.service.name`/`.namespace`, Cilium's special metadata) instead of relying on `spec.addresses`.
- **`ansible/host-network.yaml`** rewritten: instead of a forward to the VM's IP, two sets of rules — `80/443` → Cilium's IP, `8080/8443` → Agent Gateway's IP (real port 80/443 there). Covers the physical LAN (devices without Tailscale).
- **Tailscale subnet router**: the hypervisor (already on the tailnet, so far only for CI SSH) starts advertising `192.168.122.0/24` (`tailscale up --advertise-routes=192.168.122.0/24`, approved once in the Tailscale admin) — any of the user's devices on their tailnet reaches the Gateways' IPs directly, without going through the host's forward, from anywhere (not just at home).
- **Cloudflare dashboard**: see the 2026-09-06 update below — this original point (removing 11 routes from a list) assumed a model that doesn't exist.

### Consequences

- Accepted risk: `192.168.122.240` and `192.168.122.250` fall within libvirt's *configured* DHCP range (`.2`–`.254`), even though today only the VM uses that network (`.10`). It would collide if more VMs are added to the same NAT network without first reducing libvirt's DHCP range.
- Private access without Split DNS for now: accessed by direct IP (with the correct `Host` header) or by adding entries to the local `hosts` file. Tailscale Split DNS remains a future improvement, not resolved here.
- LAN access "without Tailscale" (devices the user doesn't control or doesn't want to add to the tailnet) is limited to whoever has physical access to the home LAN — everyone else, including the user himself away from home, comes in via Tailscale.

**Update (2026-09-06):** this ADR's starting point was incorrect — Cloudflare doesn't have a Public Hostname entry per route, it has a single wildcard (`*.cristianpuenguenan.online`) pointing to a single destination. Real unanticipated consequence: with that model, **any** `HTTPRoute` that exists against the Gateway the wildcard points to is automatically public — there's no list to edit to "remove" a route. The correct fix is not managing a list (the user explicitly didn't want that, rightly so), but structural: a **third `Gateway`, `public`** (`platform/networking/cilium-gateway/gateway-public.yaml`), with no fixed LAN IP (its only consumer is `cloudflared`, via `ClusterIP`), where *only* the `portfolio` and `flow-api` `HTTPRoute`s live (moved there, `parentRefs` updated). Cloudflare's wildcard is re-pointed once to `cilium-gateway-public.networking.svc.cluster.local:80`. What's public is now decided by where the `HTTPRoute` lives in code, not by a separate list — adding a new route to `main`/`agentgateway-mcp` never accidentally exposes it to the Internet.

**Update (2026-09-06): private DNS.** The `main`/`agentgateway-mcp` routes could only be reached by direct IP or manual `hosts` file. `platform/networking/private-dns/` was added — a self-hosted `CoreDNS` (official `coredns/coredns` image, not `dnsmasq`: there's no well-maintained `dnsmasq` image, and CoreDNS is already the server Kubernetes uses internally) with the `hosts` plugin serving a static A record for each private route, `fallthrough` + `forward` to the real public DNS (`1.1.1.1`/`1.0.0.1`) for everything else — it never becomes a black hole if something uses it by mistake. Fixed IP `192.168.122.253` via the same Cilium L2 Announcements mechanism already used for the Gateways (`CiliumLoadBalancerIPPool` with `serviceSelector`). It lives **inside** the cluster, not on the hypervisor: if the cluster is down these hostnames wouldn't be useful anyway (they point to services on that same down cluster), so it doesn't add a new failure point — and it is **not** used as the primary DNS for the whole LAN, it only resolves `cristianpuenguenan.online` (Tailscale Split DNS and the port 53 forward in `ansible/host-network.yaml` scope it to that). Reloader (`autoReloadAll`) restarts the pod only when the `Corefile` `ConfigMap` changes — adding a new route is just a `git push`.

**Update (2026-09-06): LAN access was still broken, a different cause.** After fixing the fixed IPs, `ansible/host-network.yaml`'s port-forward still didn't work from real LAN devices (confirmed with a real phone — even a `ping` wasn't enough proof, real HTTP/DNS was needed). Troubleshooting with `tcpdump` on the LAN interface and `virbr0` simultaneously: the `SYN` reached the hypervisor, firewalld applied the DNAT correctly (confirmed by inspecting `nft list ruleset` — the `nat_PRE_FedoraServer_allow` table with the correct rules, zone dispatch verified), but the packet **never went out toward `virbr0`** — the hypervisor replied with `ICMP port unreachable` in its own name. Real cause: the `table ip libvirt_network` (managed by `libvirtd`, not firewalld) has a `guest_input` chain that by design **rejects any new inbound connection toward the virtual NAT network**, even after DNAT — it only lets through traffic from already-established connections (libvirt's standard protection for NAT networks, so VMs behind NAT don't receive unsolicited connections). Validated by inserting a test `accept` rule before the `reject` — the same `curl` that gave `000` started giving a real `404` (connection + DNAT + Gateway response, only the correct `Host` header was missing).

Persistent solution: `ansible/host-network.yaml` installs `/etc/libvirt/hooks/network` (`ansible/templates/libvirt-network-hook.sh.j2`) — a hook that libvirt invokes on every event of its `default` network; on the `started` event (including after a hypervisor reboot, when libvirt regenerates `guest_input` from scratch) it re-inserts the 6 `accept` exceptions needed (one per IP:port combination of the 3 fixed-IP Services: `main`, `agentgateway-mcp`, `private-dns`). Libvirt's `<portForward>` element couldn't be used (it exists, but it's for `passt` interfaces of an individual VM, not for traditional bridged `<forward mode='nat'>` networks like this one) — the hook pattern is the supported one for this case.

**Update (2026-09-06): own domain for private stuff (`cristianpuenguenan.internal`).** With everything above working, a confusing `404` still appeared when testing a private route without the internal DNS configured on the device: `argocd.cristianpuenguenan.online` resolves the same way against Cloudflare's real public record (the wildcard), landing on the `public` Gateway — a `404` that looks like an app bug but is actually "you never reached the private CoreDNS". Fix: the 11 `main`/`agentgateway-mcp` `HTTPRoute`s move to `*.cristianpuenguenan.internal` (`.internal` is not a TLD delegated in public DNS, it can never collide), and the `Corefile` in `platform/networking/private-dns/configmap.yaml` serves that domain instead of `.online`. `portfolio`/`api` (`public` Gateway) remain on `.online`, unchanged. With this, without the private DNS configured, the private hostname simply doesn't resolve (NXDOMAIN) — an unambiguous "DNS not configured" error, not an ambiguous `404`.

## ADR-012: TLS for internal routes with a private cluster CA

**Status**: Accepted — the Agent Gateway plain-HTTP exception and its proxy hop no longer apply; see [ADR-026](#adr-026-agent-gateway-removed-mcp-served-by-envoy-gateway)
**Date**: 2026-09-06

### Context

Private routes served everything over plain HTTP (port 80). In addition, "physical LAN without Tailscale" access required permanent maintenance (hosts file per device, explicit `:8080` ports, firewall exceptions) for a use case that in practice isn't used: all of the user's real devices are on the tailnet.

Hard constraint for TLS: `.internal` is a reserved TLD — the CA/Browser Forum prohibits public CAs from issuing certificates for it. Let's Encrypt is not an option for `*.cristianpuenguenan.internal`.

### Decision

- **Private CA inside the cluster** (`platform/networking/cert-manager/internal-tls.yaml`), replicating the pattern already existing for Hubble's PKI: `selfSigned` Issuer → `Certificate` `internal-root-ca` (isCA, 10 years) → `ClusterIssuer` `internal-ca` → leaf. No dependency on any external CA; renewal is automatic via cert-manager.
- **Single wildcard** `*.cristianpuenguenan.internal` (+ apex) in the `wildcard-internal-tls` secret (namespace `networking`), referenced by `main`'s `https` listener (TLS terminate). A single certificate to renew, not 11.
- **HTTP→HTTPS 301 redirect on `main`**: port 80 is restricted (`allowedRoutes` only namespace `networking`) to a catch-all `HTTPRoute` with a `RequestRedirect` filter. `main`'s 8 content routes set `sectionName: https` in their `parentRefs` — without that they would attach to both listeners and still serve content over HTTP.
- **`agentgateway-mcp` stays on plain HTTP** (documented exception): its controller (v1.1.0) silently ignores HTTPS listeners — it doesn't create the listener in `status`, nor port 443 on the Service, nor reports any error/event. The 3 MCP routes (`mcp`, `openmemory-api`, `agentgateway` UI) are served over the private tailnet's port 80; the transport is already encrypted by WireGuard at the Tailscale layer. Reevaluate when Agent Gateway supports TLS termination.
- **Tailscale as the only supported path** for devices: the physical LAN without Tailscale is declared out of scope (the HTTPS redirect points to internal IPs unreachable from the LAN — an explicit failure, not a degraded one). The forward-ports and the libvirt hook are kept because Tailscale→cluster traffic that crosses the hypervisor still needs them.

### Consequences

- The CA must be trusted by hand once per tailnet device (`docs/OPERATIONS.md` §11.5) — acceptable because the user controls all devices; a visitor on the LAN cannot use these routes in any way.
- If the `internal-root-ca` secret is lost, the regenerated CA won't be trusted by devices until the installation is repeated (today there's no specific backup of the secret; the certificate lasts 10 years).
- The public plane doesn't change: Cloudflare keeps terminating TLS at the edge for `portfolio`/`api`; `wildcard-home-tls` (Let's Encrypt) is still issued but not referenced.
- The URLs of Agent Gateway's 3 routes remain `http://` (port 80): `http://mcp.cristianpuenguenan.internal/sonarqube`, `http://openmemory-api...`, `http://agentgateway...` — the rest of the private ones are `https://`.
- Apps unchanged: ArgoCD already ran `--insecure` (TLS delegated to the edge is the expected pattern); Grafana/Headlamp don't use `secure` cookies.

**Update (2026-09-06): Agent Gateway's 3 routes also move to HTTPS.** The exception above ("`agentgateway-mcp` stays on plain HTTP") still left those 3 URLs without client-facing TLS, not just as an internal exception — and Agent Gateway's controller still doesn't support HTTPS listeners, so there was no way to resolve it there directly. Solution: **`main` acts as a TLS proxy toward `agentgateway-mcp`**, no different from how it already proxies to any other backend — a new `HTTPRoute` (`platform/networking/cilium-gateway/httproute-agentgateway-proxy.yaml`) with `parentRefs: [{name: main, sectionName: https}]`, the 3 hostnames, and `backendRefs` pointing directly to the `Service agentgateway-mcp:80` (same `networking` namespace, no `ReferenceGrant`). No path matching or rewrite: Agent Gateway keeps doing its own routing/rewrite/multiplexing internally with its usual `HTTPRoute`s (`mcp-sonarqube`, `openmemory`, `agentgateway-ui`), which didn't change — only who delivers the traffic to it changed. With this, there are 11 routes again (not 8) with `sectionName: https` against `main`.

Consequence: `agentgateway-mcp` no longer needs its own LAN IP. It moves to a `ClusterIP` `Service` (`gateway.controller.service.type` in `platform/networking/agentgateway/agentgateway.yaml`) — the `Gateway`'s `spec.addresses: 192.168.122.250` is removed (it was already dead config, see above: the controller never translated it into a real request) and its `CiliumLoadBalancerIPPool` in `lb-ippool.yaml` is deleted (orphaned with no `Service LoadBalancer` claiming it). Private DNS (`private-dns/configmap.yaml`) moves `mcp`/`agentgateway`/`openmemory-api`.internal from `.250` to `.240`, and the forward-port/firewall rules pointing to `.250` (which pointed to nothing) are cleaned up from `ansible/host-network.yaml` and the libvirt hook. The access plane becomes symmetric: all 11 private routes come in through `192.168.122.240:443`, with no client-visible transport exceptions.

**Update (2026-09-07): the own CA is dropped — real Let's Encrypt via a `cristianpuenguenan.online` subdomain.** The private CA (`internal-root-ca`) worked, but required manual installation on every tailnet device (`certutil -addstore`, once per device — tedious and easy to forget on a new one), and exposes an underlying risk not obvious at decision time: a device that trusts a private root CA trusts **any** certificate signed by that CA, for **any** domain — if the `internal-root-ca` secret's private key were leaked, someone could forge a valid certificate for any site (bank, `google.com`, etc.) and that device would accept it without warning. Decision: replace it with a real certificate.

`.internal` still can't be used with a public CA (still a reserved TLD, no change to that restriction) — but the user already owns `cristianpuenguenan.online`, which already has a working Let's Encrypt `ClusterIssuer` via DNS-01 (`letsencrypt-prod-cloudflare-dns01`, the same one issuing `wildcard-home-tls`). The DNS-01 challenge **doesn't require the name to resolve to anything real** — it only requires a `_acme-challenge.*` TXT record to be creatable via Cloudflare's API, something cert-manager already does. That allows requesting a real wildcard for a dedicated subdomain, `*.internal.cristianpuenguenan.online`, without ever publishing an A/AAAA record for it.

Migration executed in 3 phases to avoid risking the cluster (access to admin routes was never cut):

1. **Additive**: new `Certificate` `wildcard-internal-online` (same Issuer as `wildcard-home-tls`) → secret `wildcard-internal-online-tls`; second HTTPS listener on `main` (`https-online`, with its own `hostname` and `certificateRefs` — **Cilium/Envoy doesn't support multiple `certificateRefs` on the same listener**, two listeners with disjoint `hostname`s on the same port 443 is the supported pattern for serving 2 certs by SNI); the 11 `HTTPRoute`s receive the new hostname in addition to the old one (and a second `parentRef` where they attach directly to `main`); `private-dns` resolves both domains. Nothing on the old `.internal` was touched.
2. **Actual enablement**: a second Tailscale Split DNS entry was added (same `192.168.122.253` nameserver, restricted to `internal.cristianpuenguenan.online`) — without this, the new hostname didn't resolve for any tailnet device.
3. **Decommission**: once confirmed live from a real device (valid TLS, nothing installed, `curl`/browser without `-k`), the old hostname and listener were removed, and `platform/networking/cert-manager/internal-tls.yaml` was deleted entirely (selfSigned Issuer + CA + `internal-ca` ClusterIssuer).

**Finding during validation, correction to what was documented above about "never resolves publicly":** the **public** wildcard `*.cristianpuenguenan.online` does DNS-match `argocd.internal.cristianpuenguenan.online` and the rest — DNS wildcard rules (RFC 1034 §4.3.3) apply at any subdomain depth as long as there's no explicit record blocking an intermediate level (`internal.cristianpuenguenan.online` has none). Confirmed live: `nslookup argocd.internal.cristianpuenguenan.online 1.1.1.1` responds with Cloudflare's IPs. This is **not a real breach**: when actually connecting to that IP with that hostname, the TLS handshake fails at Cloudflare's edge (`SEC_E_ILLEGAL_MESSAGE`, fatal alert) because that hostname was never registered as a valid "Hostname" in Cloudflare's SSL config — DNS resolution is public, the connection is not. Different from `.internal` (which gave a clean `NXDOMAIN`), but functionally equivalent in security.

Consequences:
- Zero installation per device, forever — the certificate is trusted by any browser out of the box.
- Certificate Transparency: anyone can see on `crt.sh` that `*.internal.cristianpuenguenan.online` exists — it reveals that there's a private administration zone (it doesn't reveal specific hostnames, those are never issued individually), something that with `.internal` (reserved TLD) wasn't even remotely possible. Accepted risk: it's only reconnaissance, not access.
- A single `ClusterIssuer` for both wildcards (public and private) — same Cloudflare token, no new credentials.
- Slightly higher risk of human error than before: `.internal` and `.online` were visually impossible to confuse; `internal.cristianpuenguenan.online` vs. `cristianpuenguenan.online` differ by a single label — a badly built `HTTPRoute` (parentRef to the `public` Gateway instead of `main`, or the hostname without the `internal.` prefix) would expose an admin route to the Internet. Mitigated by consistent naming convention and diff review, not by automatic control.

---

## ADR-013: Replacing Longhorn with OpenEBS Local PV LVM

**Status**: Superseded by [ADR-014](#adr-014-migration-from-k0slibvirtfedora-to-talos-linuxproxmox-ve-and-from-openebs-lvm-to-openebs-zfs-localpv) — the LVM engine chosen here was replaced by ZFS when migrating to Talos (see ADR-014); the reasoning in this entry (why not Longhorn) remains valid.
**Date**: 2026-09-08

### Context

ADR-004 rejected OpenEBS for "more complex to configure, smaller community" and adopted Longhorn with replicas=1 (no real redundancy gain on single-node). That same Longhorn mechanism — volumes exposed via iSCSI (`iscsid`, `ansible/tasks/longhorn-prereqs.yaml`) — turned out to be the most likely cause of a real `k0s reset` hang during a teardown (2026-09-07, documented in session memory and in `ansible/tasks/graceful-shutdown.yaml`): if the kubelet dies before the CSI driver unmounts and logs out of those sessions, "busy" mounts/sessions remain that hang the internal `umount` of the reset.

A cluster teardown/rebuild cycle (with no production workloads yet) was used as an opportunity to review the decision: on a single node, Longhorn's network + replica + iSCSI layer buys nothing (replicaCount was already fixed at 1) and does cost failure surface and throughput/latency compared to a purely local engine.

### Options considered

OpenEBS Local PV engines evaluated to replace Longhorn (see full trade-off table discussed with the operator):

| Option | Reason for rejection / choice |
|--------|------------------------------|
| **Local PV Hostpath** | Maximum performance and zero additional provisioning, but no snapshots, no online resize, no thin-provisioning |
| **Local PV ZFS** | Requires ZFS (DKMS/kmod) on a Fedora host that doesn't include it by default — more new pieces to maintain |
| **Mayastor (NVMe-oF)** | Designed for multi-node replication; overkill for a single node, adds nothing over Local PV |
| **Local PV LVM** (chosen) | Requires a dedicated LVM Volume Group (didn't exist) — in exchange, gives snapshots, thin-provisioning, and online resize with performance close to the disk's native one |

### Decision

**OpenEBS Local PV LVM** (standalone `lvm-localpv` chart from `https://openebs.github.io/lvm-localpv`, not the `openebs/openebs` umbrella package with NDM/Mayastor — only the engine actually used is installed):

- New dedicated disk (`vdb`, raw, no qcow2 `backing_store`) on the VM via Terraform (`libvirt_volume.openebs_data_disk`, `terraform/variables.tf` `openebs_disk_size_bytes`), separate from the root disk so the VG doesn't compete with the OS filesystem.
- Volume Group `vg-openebs` created by Ansible (`ansible/tasks/openebs-prereqs.yaml`, idempotent via `pvcreate`/`vgcreate`), replacing the `iscsi-initiator-utils`/`iscsid` prerequisite.
- Same two-StorageClass split as Longhorn, renamed 1:1 to minimize the diff on consumers: `openebs-lvm` (default, `Delete`) and `openebs-lvm-retain` (`Retain`, databases). `provisioner: local.csi.openebs.io`, `parameters: {storage: "lvm", volgroup: "vg-openebs"}`.
- Namespace `openebs` (replaces `longhorn-system`).
- The chart's own ServiceMonitor (`lvmNode.serviceMonitor.enabled: true`) instead of the manual ServiceMonitor Longhorn had.

### Consequences

- **No web UI**: Longhorn had its own UI (HTTPRoute + DNS `longhorn.internal...`); LVM-LocalPV has no equivalent. Removed with no replacement — volume inspection is now via `kubectl get lvmvolumes -n openebs` / `lvs`/`vgs` on the node.
- **No replicas** (same as before: Longhorn was already running with `replicaCount: 1`, not a real regression): a failure of the `vdb` disk is total data loss. Mitigable with manual LVM snapshots (`lvcreate --snapshot`), no automation yet — same backup debt that already existed with Longhorn.
- The VM's disk footprint goes from 120GiB to 120+100GiB (root + dedicated VG).
- The shutdown cycle is simplified: without iSCSI in the mix, `ansible/tasks/graceful-shutdown.yaml` no longer needs to wait for "detached volumes" or force a logout — normal Kubernetes draining is enough, because LVM-LocalPV mounts the LVs directly (no NBD/iSCSI layer).
- ADR-004's original argument against OpenEBS ("more complex to configure") is now accepted in exchange for single-node performance: the standalone single-engine (LVM) chart is in practice simpler to operate than Longhorn with its UI, its manager, and its per-replica engine-image.

---

## ADR-014: Migration from k0s/libvirt/Fedora to Talos Linux/Proxmox VE, and from OpenEBS LVM to OpenEBS ZFS LocalPV

**Status**: Accepted
**Date**: 2026-09-09

### Context

ADR-008 had already documented several sources of fragility of the libvirt/KVM VM on a generalist host: the silent hang with UEFI/OVMF firmware (mitigated by forcing legacy BIOS), the `dmacvicar/libvirt` provider's `memory`-in-KiB-by-default footgun, and the dependency on NAT (`192.168.122.0/24`) because bridging over WiFi is fragile. On top of this, Ansible remained responsible for provisioning the node's operating system over SSH (ADR-007): every drift in packages, configuration, or host state fell outside Terraform/GitOps's declarative control, and was the project's largest surface of non-reproducible failures (including ADR-013's root cause: Longhorn's iSCSI hanging `k0s reset` during teardown).

Moving to a dedicated hypervisor (Proxmox VE) with real LAN connectivity via bridge (`vmbr0`) resolves ADR-008's network limitation. And Talos Linux — immutable Kubernetes, with no SSH or shell, configured 100% via a declarative API (`talosctl`/machine config) — completely eliminates the Ansible-over-SSH layer that provisioned the node: there's no longer an operating system to maintain, patch, or that could drift from the declared state.

### Decision

**Talos Linux on Proxmox VE**, with Terraform split into two independent stages (two state files, see `terraform/infra/versions.tf` and `terraform/cluster/versions.tf`):

- **`terraform/infra`** (providers `bpg/proxmox` + `siderolabs/talos`): downloads the Talos ISO generated by the [Image Factory](https://factory.talos.dev) with a schematic that includes the `qemu-guest-agent` and `zfs` extensions (`terraform/infra/variables.tf`, `talos_schematic_id`); creates the VM on Proxmox with two disks — one for the Talos installation and one dedicated, unformatted, for the OpenEBS zpool (`terraform/infra/proxmox.tf`); applies the machine config (includes `RawVolumeConfig` to partition the ZFS disk) and bootstraps the cluster (`terraform/infra/talos.tf`).
- **`terraform/cluster`** (providers `kubernetes` + `helm`): namespaces, `helm_release` for Cilium and ArgoCD, and the cluster's initial secrets (`terraform/cluster/*.tf`) — replaces what Ansible (`site.yaml`) + Helmfile (`bootstrap/helmfile.yaml`) used to do.
- **Network**: the VM moves from libvirt's internal NAT (`192.168.122.0/24`) to a real static IP on the homelab's LAN (`192.168.80.0/24`, Proxmox's `vmbr0` bridge) with a fixed MAC reserved in the router's DHCP (`terraform/infra/variables.tf`, `vm_mac_address`) — the firewalld port-forward ADR-008 required is no longer needed (`ansible/host-network.yaml`, removed).
- **Ansible** is reduced to what can't be solved declaratively within Talos or Terraform: `preflight.yaml` (validates credentials before CI spends time provisioning). `site.yaml`, `teardown.yaml`, `host-network.yaml`, and any task that installs packages or configures the node no longer exist — Talos has no shell (`nsenter`+`chroot` into the host fails with "can't execute 'sh'").
  > **Update (ADR-015)**: populating OpenBao stopped being an Ansible playbook (`vault-populate.yaml`/`load-extra-secrets.yaml`) — it's a standalone script (`scripts/load-secrets-to-openbao.sh`) that runs manually, never in CI.
- **Storage: OpenEBS LVM (ADR-013) → OpenEBS ZFS LocalPV** (`zfs-localpv` 2.11.1, `platform/storage/openebs/`): ADR-013's choice of LVM assumed a host where Ansible could run `pvcreate`/`vgcreate` over SSH — impossible on Talos, which exposes no shell and doesn't allow installing arbitrary packages on the host. ZFS is viable because the kernel module loads declaratively via the schematic's `zfs` extension and `machine.kernel.modules` (`terraform/infra/talos.tf`); the zpool is created with a Kubernetes `Job` (`kubernetes_job_v1.openebs_zpool_create`, `terraform/cluster/storage.tf`) that runs the ZFS tools *inside* a privileged container mounting the host's `/dev`, since Talos doesn't ship `zfs`/`blkid` on the host and doesn't run `udev` (the real device is resolved via `blkid -t PARTLABEL=`, not `/dev/disk/by-partlabel/`). New StorageClasses: `openebs-zfs` (default) and `openebs-zfs-retain`.
- **Rename**: the VM and cluster move from `talos-01` to `talos` (a single node, numeric suffix without an object).

### Consequences

- **Less drift surface**: there's no node operating system to maintain/patch/drift — Talos updates by replacing the whole image (`talosctl upgrade`), not with `apt`/`dnf`.
- **CI/CD (ADR-009) changes variables, not shape**: `TF_VAR_proxmox_endpoint`, `TF_VAR_proxmox_api_token`, `TF_VAR_talos_schematic_id`, `TF_VAR_vm_static_ip`, `TF_VAR_vm_gateway` replace the libvirt/Fedora variables in `.github/workflows/deploy.yml` and `terraform-plan.yml`. The flow of two sequential `terraform apply`s (infra → cluster) and the manual approval gate don't change.
- **Troubleshooting tools change**: there's no more `ssh`/`journalctl`/`k0s ctr` against the node — the equivalent is `talosctl` (logs, dashboard, `talosctl upgrade`) against the node's IP, with the `talosconfig` generated by `terraform/infra/talos.tf` (`local_file.talosconfig`).
- **Pending debt identified during this review**: several manifests under `platform/networking/` (Gateway, `CiliumLoadBalancerIPPool`, internal DNS) remained hardcoded to the old libvirt subnet (`192.168.122.x`) after the migration — fixed to `192.168.80.x` as part of this ADR. `docs/ARCHITECTURE.md`, `docs/INSTALL.md`, and `docs/OPERATIONS.md` still described k0s/libvirt/Fedora — updated together with this ADR.
- **Storage with no replicas** (same as with LVM/Longhorn): still a single copy, local to the node — not a regression from this migration, it's a decision already accepted in ADR-004/013.

---

## ADR-015: Loading secrets into OpenBao moves out of CI/CD, always manual

**Status**: Accepted
**Date**: 2026-09-09

### Context

`vault-populate.yaml` and `load-extra-secrets.yaml` ran automatically on every push to `master` (`.github/workflows/deploy.yml`), writing infrastructure and application credentials into OpenBao (`ansible/group_vars/all.yaml`, encrypted with `ansible-vault` and committed; `ansible/extra-secrets.yaml`, plain and gitignored). The operator decided that loading real secrets into the cluster must **never** depend on a CI runner, no matter how controlled the pipeline is — he wants to always run it by hand. He also asked to remove the Ansible dependency specifically for this task (Ansible remains in use for `preflight.yaml`).

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| Keep Ansible but only invoke it by hand | The operator explicitly asked not to depend on Ansible for this — prefers a script without that dependency |
| Two separate secret files (infra encrypted with vault + apps plain) | The operator preferred unifying into a single plain file — simpler to maintain, at the cost of losing the encrypted-in-git backup of the 5 infra secrets |

### Decision

- **`secrets/homelab.env`** (gitignored) + `secrets/homelab.env.example` (committed): a single file with all credentials, infra and apps, `KEY=value` format. Replaces `ansible/group_vars/all.yaml` (deleted, no more `ansible-vault` in the repo) and `ansible/extra-secrets.yaml.example` (deleted).
- **`scripts/load-secrets-to-openbao.sh`**: standalone bash, no Ansible. Waits for OpenBao/`openbao-init`, does a port-forward, and writes each KV path via `curl`+`jq`. Replaces `vault-populate.yaml`, `load-extra-secrets.yaml`, and `tasks/openbao-kv-write.yaml` (all three deleted). Run by hand, never in CI.
- **`.github/workflows/deploy.yml`**: the steps that ran those playbooks are removed. The credential preflight (`ansible/preflight.yaml`, still in Ansible) now takes its values from GitHub Actions secrets/vars injected as step env vars, instead of `group_vars/all.yaml` + `ANSIBLE_VAULT_PASSWORD`.
- ArgoCD Applications that depend on those secrets (ArgoCD webhook, `cloudflared`, databases, SonarQube, OpenMemory, Flow) stay `Progressing`/`Degraded` until the operator manually runs the script — expected behavior, not a pipeline failure (sync-waves already order OpenBao before its consumers, and `ExternalSecret` retries via `refreshInterval`).

### Consequences

- No real secret can end up in the cluster from an accidental push to `master` — it requires an explicit manual action from the operator.
- The encrypted-in-git backup of the 5 infra secrets that used to live in `group_vars/all.yaml` is lost: if the local `secrets/homelab.env` is lost without a separate backup, those tokens need to be regenerated/rotated.
- A single language (bash) for the whole script instead of Ansible's YAML+Jinja — easier to read end to end, at the cost of losing the structured error handling/retries Ansible gave for free (reimplemented by hand with `set -euo pipefail` + wait loops).

> **Update (2026-09-09, same day):** the first version of this ADR had the CI preflight validate all 6 secrets (including `cloudflare_api_token`, `cloudflared_token`, `argocd_webhook_secret`), requiring 3 new GitHub Actions secrets just for that. When reviewing before deploying, it was confirmed that **CI doesn't consume those 3 values in any step** — only `scripts/load-secrets-to-openbao.sh` uses them, and it already validates them on its own before writing to OpenBao. The CI preflight was scoped down to what Terraform actually needs (`argocd_github_pat`, `openbao_static_seal_key`, plus `argocd_repo_url` for the repo access check) — no longer necessary to create those 3 secrets on GitHub. A real bug was also fixed along the way: `lookup('env', 'VAR') | default('x')` in Ansible doesn't fall back to the default when the env var exists but is empty (which is what happens if a GitHub secret isn't configured) — `default('x', true)` is needed.

---

## ADR-016: Data services outside the cluster, in Proxmox LXC — a single multi-database PostgreSQL

**Status**: Accepted
**Date**: 2026-09-13

### Context

The cluster ran five data services inside Kubernetes: two PostgreSQL instances managed by **CloudNative-PG** (the `homelab` app's and one dedicated to SonarQube), **MongoDB** via the Percona PSMDB Operator, **Qdrant**, and **Redis** — in total two operators, six ArgoCD Applications, and several OpenEBS ZFS PVCs with a single copy (`openebs-zfs-retain`).

On a single-node cluster that buys none of the advantages of running data in Kubernetes: no replicas, no live migration, no multitenancy to isolate. What it does add is surface — two operators and their CRDs to maintain, per-service NetworkPolicies, PVCs competing with the apps for the node's zpool — and, worst of all, **the data's lifecycle becomes tied to the cluster's**: every `talosctl upgrade`, teardown, or cluster rebuild (ADR-014 itself migrated the entire platform) risks exactly what should outlive it.

Proxmox VE is already the project's hypervisor; an LXC is the natural way to run a stateful service that needs nothing from Kubernetes.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| **Keep the data in the cluster** | Keeps coupling the data's lifecycle to the cluster's; operators and PVCs consume the single node without giving anything in return (single-node = no replicas) |
| **A full VM per service** | Four VMs with their own kernel for lightweight services — unnecessary RAM/disk overhead compared to a system container |
| **One LXC per service, PostgreSQL separated by consumer** | Duplicates instance, RAM, disk, and backups of the same engine for two small databases, without gaining real isolation (same hypervisor, same Proxmox host) |

### Decision

**Four Debian 13 LXCs** created declaratively by Terraform (`terraform/infra/lxc.tf`) — `vmbr0` bridge, `local-lvm` datastore, static LAN IP. Proxmox doesn't support cloud-init for LXC (cicustom is QEMU-exclusive), so the containers are delivered **with no engine installed**: installing each engine and its credentials (`TF_VAR_*` from `secrets/homelab.env`) is left as follow-up provisioning, logged as debt in its own story:

| LXC | vmid | IP | Engine |
|-----|------|----|-------|
| `postgresql` | 121 | `192.168.80.31` | PostgreSQL 17, `homelab` and `sonarqube` databases |
| `mongodb` | 122 | `192.168.80.32` | MongoDB 8.0 |
| `qdrant` | 123 | `192.168.80.33` | Qdrant v1.x |
| `redis` | 124 | `192.168.80.34` | Redis 8 |

- **A single multi-database PostgreSQL** replaces the two previously separate instances (`homelab`'s and SonarQube's): one engine to update and back up, two logical databases.
- Consumers reach them by hostname through `private-dns`, with four new records in the Corefile: `postgres.internal.cristianpuenguenan.online`, `mongodb.internal...`, `qdrant.internal...`, `redis.internal...`. SonarQube points to `jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube`; OpenMemory to `qdrant.internal.cristianpuenguenan.online:6333`; Flow's URLs already live in OpenBao (`secret/apps/flow`) as plain values — only updated there. Reloader restarts the Deployments affected by the env change.
- The CloudNative-PG and Percona PSMDB operators, the instance manifests, and the six ArgoCD Applications that deployed them **disappear from the repository**, along with the namespaces that hosted them. On merge, the root app prunes the deleted Applications and their finalizers cascade to the CNPG/PSMDB clusters, Services, and NetworkPolicies.
- The SonarQube database credentials' ExternalSecret is kept: it still feeds `SONAR_JDBC_USERNAME`/`SONAR_JDBC_PASSWORD`, now against the shared external instance.

### Consequences

- Data survives cluster upgrades, teardowns, and rebuilds — the cluster goes back to being ephemeral by design, as the GitOps approach intends.
- **A single shared point of failure**: an upgrade or restart of the PostgreSQL LXC affects `homelab` and `sonarqube` at the same time. Accepted at homelab scale (one operator, two small databases); if a database ever needed real isolation, it gets split into its own LXC.
- Backups move from `kubectl exec` on pods to standard network tools (`pg_dump`/`mongodump` pointing to the `*.internal` hostnames), with container-level Proxmox backup (`vzdump`) as a complement.
- The cluster frees up ~35Gi of the OpenEBS zpool and the RAM/CPU of the operators and instances; the LXC disks live on `local-lvm` on the Proxmox host, outside the cluster.
- Kubernetes NetworkPolicies stopped applying: the databases' perimeter becomes the homelab LAN (the LXCs live on `vmbr0`) — the same trust already assumed by the Cilium Gateways on that network.
- **Installing the engines inside the LXCs remains pending** (logged debt): until that provisioning happens, SonarQube and OpenMemory have no working database — a window accepted by the operator, the data starts from scratch anyway.

---

## ADR-017: Replacing OpenBao with 1Password as secrets backend

**Status**: Accepted
**Date**: 2026-09-16

### Context

Deploying OpenBao on its own external LXC (`secrets_lxc`, 192.168.80.35) as the successor to the in-cluster OpenBao (see ADR-016) was completed. In the process, several real problems came to light, never exercised before because the playbook had never been run end to end:

- `ansible/openbao.yaml` requested `-recovery-shares=1 -recovery-threshold=1` on init, flags that only apply with an auto-unseal `seal` configured (not the case, plain Shamir seal) — they were silently ignored and init fell back to the default of 5 shares / threshold 3, breaking the single-key design.
- The Quadlet's `Environment=BAO_LOCAL_CONFIG={...}` had raw, unescaped JSON: systemd interprets double quotes as part of its own quoting syntax, so the container received the JSON with the quotes stripped.
- The image's entrypoint injects `-dev-listen-address=0.0.0.0:8200` any time the command is literally `server`, regardless of whether `-dev` is active — that duplicated the listener's bind and blew up with "address already in use".
- `ExecStartPost` unsealed immediately on container start, without waiting for the server to actually be listening ("connection refused"), and was also fatal on the very first boot (before `bao operator init` existed), which brought down the whole unit before it could even initialize.
- The bind-mounted storage ended up `root:root` but the process drops privileges to a non-root user (`openbao`, uid 100/gid 1000) — permission denied.
- `bao write auth/kubernetes/config` tried to auto-detect the CA cert from an in-cluster pod's standard filesystem, which doesn't exist outside the cluster.
- The LXCs are `unprivileged` with no `features { nesting, fuse }` — Podman can't mount overlayfs via fuse-overlayfs without that, also affecting the data LXCs.

All of these bugs were fixed and OpenBao ended up working end to end (init with a single key, auto-unseal via a Podman secret on every start, Kubernetes auth configured). But the operator, after seeing how much ceremony a functional vault requires in a single-operator homelab (seal/unseal, Shamir, auth backend, policies, roles), decided it's not worth maintaining: he prefers to delegate all of that to a managed service.

### Options considered

| Option | Reason for rejection |
|--------|------------------|
| Keep OpenBao with auto-unseal via AWS KMS (`seal "awskms"`) | Solves only the unseal (stops being a raw key in a Podman secret) for ~$1/month, but doesn't eliminate the rest of the ceremony (init, auth backend, policies, roles) — a partial improvement, not the simplification the operator wants. |
| Cloudflare as KMS/secret store | Doesn't exist: Cloudflare has no KMS service comparable to AWS KMS, and its "Secrets Store" is exclusive to Workers/Pages bindings, with no external API that ESO could consume. |
| 1Password Connect (self-hosted) | Requires running an additional server (API + sync) — more infrastructure to maintain, not less. Rejected in favor of Service Accounts. |

### Decision

- **1Password** as the secrets backend, dedicated **"Homelab"** vault, via a **Service Account** with read-only access to that single vault (no Connect server — no additional infrastructure to run).
- `ClusterSecretStore` uses the `onepasswordSDK` provider (`platform/secret-management/external-secrets/cluster-secret-store.yaml`), authenticated with the Service Account token stored in the Kubernetes Secret `onepassword-service-account-token` (namespace `secret-management`).
- The repo's 10 `ExternalSecret`s move to `secretStoreRef.name: onepassword` — `remoteRef.key`/`property` doesn't change: 1Password matches the item title to `key` and the field label to `property`, and the same strings already used by Vault's KV tree (`argocd`, `devtools/openmemory`, `infra/cloudflare`, etc.) were kept to minimize the diff.
- `scripts/migrate-openbao-to-1password.sh` replaces `migrate-openbao-secrets.sh` and `load-secrets-to-openbao.sh`: it walks the in-cluster OpenBao's KV tree (which stays alive, see ADR-016) and creates/updates one item per path in the "Homelab" vault via `op item create`/`op item edit`. Manual, never in CI — same criterion as ADR-015.
- LXC 125 (`openbao`, 192.168.80.35) is destroyed: the resource is removed from `terraform/infra/lxc.tf`, `ansible/openbao.yaml`, `ansible/templates/openbao.container.j2`, the `secrets_lxc` inventory group, and references to `OPENBAO_STATIC_SEAL_KEY` in Terraform/CI/preflight (left over from the old in-cluster OpenBao's static seal mechanism, already retired).
- 3 orphaned `ExternalSecret`s (`mongodb-app-secret`, `postgresql-app-secret`, `redis-secret`, namespace `infra`) left over from the ADR-016 refactor with no manifest in git were cleaned up — the broken `ClusterSecretStore` (see below) never pruned them.

### Consequences

- All of the Vault-family ceremony disappears: no init, no seal/unseal, no Kubernetes auth backend to configure, no policies or roles.
- Now depends on 1Password's API (SaaS) availability for ExternalSecrets to sync — before, that dependency was 100% self-hosted (the LXC). With `deletionPolicy: Retain` on all ExternalSecrets, a 1Password outage doesn't delete already-synced Kubernetes Secrets, it only freezes updates.
- 1Password's Service Account has stricter rate limits than a Connect server (which caches locally) — shouldn't matter for the 1h/1m refresh interval these ExternalSecrets already use, but it's a limit to keep in mind if many more secrets are added.
- Total self-hosted control over the secrets backend is traded away for operational simplicity — a conscious trade-off for a single-operator homelab.

---

## ADR-018: Application secrets move from 1Password to SOPS + age, in-cluster

**Status**: Accepted
**Date**: 2026-09-16

### Context

The day of the migration to 1Password (see ADR-017), the account's quota was completely exhausted: `op service-account ratelimit` showed `account read_write 1000/1000, resets in 12 hours`. The immediate cause was structural — 6 `ExternalSecret`s had been left at `refreshInterval: 1m` (inherited from when they pointed to the self-hosted OpenBao, where a local read cost nothing) — but it exposed the underlying problem: 1Password Individual/Family has a shared account limit of only 1,000 requests/24h (Business: 50,000; Teams: 5,000 — confirmed in the official documentation). Any amount of debugging, a sync spike, or simply growing the number of secrets puts that limit at risk again.

The operator decided to remove the dependency on a rate-limited external API for secrets that run inside the cluster, in favor of local encryption with no request limit.

### Decision

- **SOPS + age** for secrets consumed inside the cluster: each value is encrypted with `age`'s public key and committed encrypted to the repo — no external service, no rate limit, the `git diff` of a rotated secret is readable (only the encrypted blob changes).
- **sops-secrets-operator** (`isindir/sops-secrets-operator`, Helm chart) runs in the `sops` namespace and translates each `SopsSecret` (CRD, encrypted) into a real Kubernetes `Secret` — same pattern as External Secrets Operator, but without calling any external API on every reconcile. ArgoCD applies the `SopsSecret` as is, encrypted; it never needs to know about SOPS (unlike the alternative **KSOPS**, which requires a plugin running inside `argocd-repo-server` — rejected for needing to touch ArgoCD's image/sidecars).
- **9 of the 10** `ExternalSecret`s migrate to `SopsSecret` (`*.sops.yaml`, `spec.enforceOwnership: true` because the destination `Secret` already existed, owned by External Secrets Operator). **`argocd-webhook-secret` stays on 1Password**: it uses `creationPolicy: Merge` on `argocd-secret`, which has other fields managed by ArgoCD itself (`server.secretkey`, `admin.password`) — SopsSecret takes full ownership of the `Secret`, with no field merging, so migrating it risked stepping on those fields and breaking login. Low volume (1h refresh), not worth the risk.
- `ansible/data-services.yaml`'s credentials (consumed by CI, not by the cluster) stay on 1Password via `1password/load-secrets-action` (see PR #23) — it's a one-off read per CI run, not continuous polling, it didn't contribute to the quota exhaustion.
- **Backup of the age private key**: a document in 1Password's "Homelab" vault (`sops-age-homelab-key`) — a single, manual read for disaster recovery, not an active backend, so it doesn't compete for quota.

### Consequences

- The cluster no longer depends on the availability or rate limit of an external API for its secrets — only on the `age` key mounted in the operator.
- **The age private key is now the master key of the whole system**: if it's lost without the 1Password backup, no secret encrypted in the repo is recoverable. Unlike 1Password (where the account manages recovery), here the responsibility of not losing that key is entirely the operator's.
- The 1Password UI for rotating secrets by hand is lost — rotating a value is now `sops decrypt`, edit, `sops encrypt -i`, commit. More friction, but with no request limit.
- 1Password stays as a "hybrid" backend: it remains the source of truth for `argocd-webhook-secret` and `data-services.yaml`'s credentials, plus the age key backup — not eliminated entirely, scoped down to the low-volume cases where it poses no risk.

> **Update (2026-09-16, same day):** `ansible/data-services.yaml`'s credentials also migrated to SOPS (`ansible/data-services.env`, consumed via `sops exec-env` in CI) — see PR #26. The only consumer left on 1Password was `argocd-webhook-secret`, fully retired in ADR-019 below the same day, after confirming in the External Secrets controller logs that the `ClusterSecretStore` kept returning `rate limit exceeded` well past the expected reset window — the 1Password account turned out not to be reliable even for the single low-volume consumer that remained.

---

## ADR-019: The GitHub webhook is retired (and with it, the last use of 1Password) — back to polling

**Status**: Accepted
**Date**: 2026-09-16

### Context

`argocd-webhook-secret` (`platform/argocd/webhook-externalsecret.yaml`) was the last remaining consumer of the `onepassword` `ClusterSecretStore` after ADR-018. While reviewing the cluster's general state after deploying `data-services.yaml`, it was found that the `ClusterSecretStore` had been in `SecretSyncedError` for hours with `rate limit exceeded` in the External Secrets controller logs — the 1Password account still hadn't reset its quota well past the expected window (~11-12h since exhaustion). With the store broken, `argocd-secret` never received `webhook.github.secret`, so any GitHub webhook delivery (`https://argocd.cristianpuenguenan.online/api/webhook`, active since the ADR-011/`docs/TODO.md` #3 incident) failed HMAC verification. Polling via `timeout.reconciliation: 600s` kept working as a safety net, so the cluster never stopped syncing — but keeping a broken, low-value external integration with no other consumer left wasn't justified.

### Decision

- `platform/argocd/webhook-externalsecret.yaml`, `platform/argocd/httproute-webhook.yaml`, and the `onepassword` `ClusterSecretStore` (`platform/secret-management/external-secrets/cluster-secret-store.yaml`) are removed — with this, 1Password no longer has **any** active integration in the cluster or in CI. It only remains as a manual, offline backup of the `age` private key (see ADR-018), which isn't an integration, it's a document.
- The webhook registered on GitHub is removed (`gh api -X DELETE repos/cristsr/homelab/hooks/<id>`) and the orphaned `onepassword-service-account-token` Secret (namespace `secret-management`, never managed by Terraform/GitOps, loaded by hand at the time).
- `timeout.reconciliation` goes back to `180s` (the original value from before the webhook, `docs/TODO.md` #3) — it's no longer a safety fallback behind a webhook that fires in seconds, it's the only sync mechanism now, so the interval is once again what determines the real latency between a push and the sync.
- Explicitly **temporary**: if near-instant sync is wanted again later, the webhook needs to be reimplemented with a secret that doesn't depend on a rate-limited external backend (for example, a normal `SopsSecret` with a `creationPolicy` that doesn't step on the fields ArgoCD manages in `argocd-secret`, or generating the webhook secret with Terraform instead of syncing it).

### Consequences

- 1Password is now completely out of the cluster's and CI's critical path — ADR-017 and ADR-018 are fully closed, there's no more "hybrid" backend.
- Slower sync after a push: up to 180s instead of seconds. Acceptable for a single-operator homelab; documented as this decision's conscious trade-off.
- If `timeout.reconciliation` is mistakenly set back to `0s`, the cluster stops syncing completely and silently (same incident as ADR-011/`docs/TODO.md` #3) — there's no webhook to compensate for it this time. Watch this value on any future change to `bootstrap/argocd/values.yaml`.

---

## ADR-020: In-cluster workloads cannot use `*.internal.cristianpuenguenan.online` hostnames to connect to the data LXCs

**Status**: Accepted. Superseded by ADR-024 for the five database names.
**Date**: 2026-09-16

### Context

While loading real credentials and reviewing why `sonarqube-sonarqube-0` kept failing (`HikariPool: Connect timed out` against `postgres.internal.cristianpuenguenan.online:5432`), it was found that this hostname resolves, **from inside the cluster**, to Cloudflare public IPs (nothing listens there on port 5432) — not to the LXC's real IP (`192.168.80.31`). Cause: `private-dns` (`platform/networking/private-dns/`) is a CoreDNS running as its own Deployment, designed as a **Tailscale Split DNS** resolver for external clients (the operator's laptop, etc. — see ADR-011/012); the cluster's pods use `kube-system`'s CoreDNS (Cilium's), which never knows about that zone and ends up forwarding the query to public DNS, where the `*.cristianpuenguenan.online` wildcard (proxied by Cloudflare) responds with IPs that have nothing relevant running. `openmemory` had the same bug with `QDRANT_HOST=qdrant.internal.cristianpuenguenan.online`.

### Decision

- `workloads/sonarqube/sonarqube.yaml` (`SONAR_JDBC_URL`) and `platform/devtools/openmemory/deployment.yaml` (`QDRANT_HOST`) move to using the LXC's direct IP (`192.168.80.31`/`192.168.80.33`) instead of the `*.internal` hostname.
- The `*.internal.cristianpuenguenan.online` hostnames for the data LXCs (`postgres`, `mongodb`, `qdrant`, `redis`) keep existing in `private-dns` and remain valid — only for manual access via Tailscale (`psql`/`mongosh`/etc. from your machine), never for a cluster pod to use as a connection target.
- `kube-system`'s CoreDNS was not modified to also serve this zone to pods (rejected alternative): more invasive, affects DNS resolution for the whole cluster, and the LXCs' IPs are already static (Terraform), so hardcoding them doesn't introduce a real maintenance problem.

### Consequences

- If a data LXC's IP ever changes, it has to be updated in two places: `ansible/inventory.yaml` and the in-cluster consumer's manifest (`sonarqube.yaml`, openmemory's `deployment.yaml`) — `private-dns` is no longer the single source of truth for those IPs.
- Any new workload that needs to connect to a data LXC from inside the cluster must use the direct IP from day one, not the `*.internal` hostname (that pattern is only for admin HTTPRoutes served by the Gateway, not for a pod's outbound connections).

---

## ADR-021: The media library disk moves off `local-lvm` onto its own physical disk

**Status**: Accepted
**Date**: 2026-09-19

### Context

The Talos VM's three main disks (OS, OpenEBS ZFS config pool, media library) all lived thin-provisioned on Proxmox's `local-lvm` (a single ~140GB LVM-thin pool on the host's boot SSD). The media library disk alone was declared at `1024GiB` — combined with the other thin volumes, the pool's virtual overcommit (~1.4TB provisioned on ~140GB physical) depended entirely on real usage staying low. It didn't: normal media downloads plus `discard=ignore` on the virtio disks (freed guest-side blocks were never returned to the host) drove `local-lvm` to `0` bytes available. QEMU's response to a full backing pool is `io-error` on the disk and a full VM pause (`qmpstatus: io-error`, `cpu: 0`) until manually resumed — this repeated several times over one session, each one taking down the whole node (CNI/kubelet/API server all freeze with the VM), which looked from outside like random network flakiness.

Two SMART-tested spare disks were evaluated as a fix: a Toshiba HDWD110 (1TB, real wear present — reallocated sectors, pending sectors, 9 mechanical start failures — but no interface errors, acceptable for re-downloadable media) and a Seagate ST1000DM010 (failed to even complete SMART identification after 33 SATA link resets across a hotplug, a reseat, a real power-cycle, and a full server reboot — discarded as defective hardware, unrelated to the connection).

### Decision

- The Toshiba disk is wiped (it carried an old NTFS "Games" partition, confirmed no longer needed) and added to Proxmox as its own volume group (`media-vg`, plain LVM — no thin-provisioning, so it can't silently overcommit like `local-lvm` did) with a single `920GiB` LV.
- The media library's ZFS pool (`media-pool`) is migrated live with `zpool add` (new disk as a second vdev) followed by `zpool remove` on the old vdev (ZFS's online device-removal evacuates the ~51GB of real data onto the new disk automatically) — zero data-loss, zero Kubernetes-level changes, the pool keeps its name and the PVC/PV binding never notices.
- The old `virtio2` disk (on `local-lvm`) is detached and deleted once empty, freeing that space back to `local-lvm` for the OS/ZFS-config/DB-LXC disks that still share it.
- `discard=on` is set on all three of the VM's Proxmox-managed disks (previously `ignore`) so guest-side deletes actually return space to whichever host pool backs them, going forward.
- Terraform (`proxmox.tf`, `variables.tf`) is updated to match: `virtio2`'s `datastore_id` becomes a new `media_datastore_id` variable (`media-vg`) instead of `proxmox_datastore_id`, and `media_disk_size_gb` drops from `1024` to `920` (the real physical capacity — this disk is never meant to be thin-provisioned again). `media-vg` itself (the `pvesm add lvm` that created it) is a manual, one-time Proxmox-host step, not Terraform-managed — same pattern as other day-0 hypervisor bootstrap steps in `docs/CI_CD_HYPERVISOR_SETUP.md`.

### Consequences

- The media library no longer shares a failure domain with the OS/ZFS-config/DB disks: it can fill up on its own without freezing the rest of the VM (Proxmox will still pause the VM if `media-vg` itself fills, since it's still an unprotected single disk with no autoextend — just no longer able to starve the other three by proxy).
- `local-lvm` went from `0` bytes free (incident state) to ~80GB free just from releasing the old media disk — meaningful headroom for the OS/config/DB disks, none of which are individually oversized.
- The Toshiba disk carries real, monitored wear (`Current_Pending_Sector`, `Number of Mechanical Start Failures` — see `work/hardware-reports/` for the full SMART data, gitignored/not committed) — it's approved for media only, never for anything transactional. If those counters keep climbing, the disk needs replacing before it fails outright.
- `local-lvm` still has no `thin_pool_autoextend_threshold` protection and is still overcommitted relative to physical capacity (OS 120G + ZFS-config 100G declared on ~140GB real, plus 5 DB LXC disks) — lower risk than before (nothing on it is anywhere near 1TB anymore), but not eliminated. Not addressed in this change.


## ADR-022: Tailscale runs on the hypervisor, not as a Talos extension

**Status**: Accepted
**Date**: 2026-09-20

### Context

The Talos image included the `tailscale` system extension, but no `ExtensionServiceConfig` was ever provided for it, so `ext-tailscale` sat in `Waiting for extension service config` forever. Talos waits for every service in `startAllServices`, and that phase has a 70-minute boot timeout: after it expired the boot sequence was marked failed and the node rebooted itself, in a loop (68 VM reboots between 2026-09-17 and 2026-09-20, every ~71 minutes). Cilium and every workload restarted with each reboot, which looked like a Cilium problem from outside.

### Decision

- Tailscale keeps running on the hypervisor as the subnet router advertising the `/32` routes (Proxmox, Talos VM, data LXCs). It has to stay reachable while the Talos VM is down, rebooting or being rebuilt, and Terraform/CI reach the Proxmox and Talos APIs through it before the VM exists.
- The `tailscale` extension is removed from the Talos schematic (`0d4ffb8ade43a79a8960e60a41c6fac75df764f253d572c0204535c1c6d2b828`: `qemu-guest-agent` + `zfs`). The running node was moved to it with `talosctl upgrade`, and `TALOS_SCHEMATIC_ID` in the `prod` GitHub environment was updated to match.

### Consequences

- `startAllServices` completes in seconds; the 70-minute reboot loop is gone.
- The node is not a tailnet member. If per-node Tailscale identity is ever needed (multi-node), use the Tailscale Kubernetes operator rather than a Talos extension.
- Any Talos extension added to the schematic must ship its `ExtensionServiceConfig` in the same change, or the same boot-timeout loop returns.

## ADR-023: Envoy Gateway replaces Cilium Gateway API for generic ingress

**Status**: Accepted — supersedes the "Cilium Gateway API" half of [ADR-010](#adr-010-cilium-gateway-api-for-generic-ingress-agent-gateway-only-for-mcp); Agent Gateway's half is superseded by [ADR-026](#adr-026-agent-gateway-removed-mcp-served-by-envoy-gateway)
**Date**: 2026-09-20

### Context

Cilium's Gateway API implementation serves `HTTPRoute`s but exposes almost nothing to tune: no rate limiting, no per-Gateway timeouts/retries, no client-IP detection behind Cloudflare, no HTTP/3, no request authorization. The public Gateway is the only internet-facing path and had none of those guards.

### Decision

- **Envoy Gateway v1.9.0** (`gatewayClassName: envoy`) serves the same two Gateways, `main` and `public`, under the same names, so no `HTTPRoute` changed. Agent Gateway keeps the MCP routes; Cilium stays as CNI and L2 announcer.
- Three Argo CD Applications, chained by sync wave: `envoy-gateway-crds` (2, the `gateway.envoyproxy.io` CRDs only), `envoy-gateway` (3, controller), `envoy-gateway-config` (4, `platform/networking/envoy-gateway/`, replaces `cilium-gateway`). The chart's bundled CRDs are off (`crds.enabled: false`): `gateway-api-crds` keeps owning Gateway API (v1.6.1, the same version Envoy Gateway v1.9.0 is built against, and Agent Gateway needs its experimental channel).
- Each Gateway has its own `EnvoyProxy` with a **fixed Service name** (`envoy-main`, `envoy-public`), because the Cloudflare wildcard and the LB IP pool select by name. The proxy pods and Services live in `envoy-gateway-system`, not in `networking`.
- Policies (`platform/networking/envoy-gateway/policies.yaml`): HTTP/3 on `main`; on `public`, client IP taken from `CF-Connecting-IP`, per-client-IP local rate limit (100 req/s), connect-failure-only retries (safe for the `/webhooks` POSTs) and a 30 s request-received timeout.

### Not done, on purpose

- **No `SecurityPolicy` on `main`.** A CIDR allow-list would allow the whole LAN plus the tailnet, i.e. everything that can already reach `192.168.80.240`, so it blocks nothing while adding lock-out risk. What would protect the UIs is OIDC/JWT, which needs an identity provider the cluster doesn't have yet.
- **No `BackendTLSPolicy`.** No backend speaks TLS today (ArgoCD runs `--insecure`) and Agent Gateway is plain HTTP by design, so `main` still terminates TLS and proxies to it (ADR-012).
- **`gatewayAPI.enabled` was left `true` at cutover**, then set to `false` in its own change once Envoy Gateway was verified (2026-09-23): turning it off is a Cilium Helm upgrade that reloads the BPF datapath, which is what took the Cloudflare tunnels down for 37 minutes on 2026-05-12. `bootstrap/adopt-cilium-gateway-secrets.sh` and its Terraform hook were dropped with it, since they only re-adopted Gateway API resources.

### Consequences

- Cutover is not gradual: `main` and `public` keep their names, and `192.168.80.240` can only belong to one Service, so the switch is a single sync with a short blip on the private UIs and the public site.
- After the sync, the Cloudflare tunnel wildcard must be re-pointed once from `cilium-gateway-public.networking.svc.cluster.local:80` to `envoy-public.envoy-gateway-system.svc.cluster.local:80` (dashboard, outside Git). Until then the public site is down.
- `CiliumNetworkPolicy` selectors that trusted the Cilium proxy as `host` must trust the `envoy-gateway-system` namespace instead (done for `openmemory-ui`).
- One more controller (~2 pods: controller and one proxy per Gateway) on a single node.

---

## ADR-024: Data VNet segmentation and database domains for pods

**Status**: Accepted. Amended by ADR-025: the Talos control plane is reachable only from the hypervisor and the operator's PC
**Date**: 2026-09-24

### Context

The five data LXCs (`postgresql`, `mongodb`, `qdrant`, `redis`, `mysql`, not four as ADR-016 says) shared the flat LAN `192.168.80.0/24` with the router, the hypervisor, Talos and every other LAN device. Any device on the LAN could reach the database ports, and ADR-016 accepted that the databases' perimeter was the LAN. The LXCs also shared the bridge and gateway variables with the Talos VM, so they could not be placed elsewhere.

ADR-020 made pods use each database's direct IP because the cluster's own DNS could not resolve `*.internal` names. That was a design choice, not a technical limit, and it tied every consumer to an address that this change makes move.

### Decision

- The five LXCs move to an isolated subnet `10.10.20.0/24`: Proxmox SDN zone `data` (Simple), VNet `datanet`, gateway `10.10.20.1` held by the hypervisor, SNAT on, no physical NIC (`terraform/infra/sdn.tf`). Addresses keep their last octet: `10.10.20.31` to `10.10.20.35`.
- Talos keeps `192.168.80.30` and gets no second NIC. It reaches the subnet through a static route via the hypervisor `192.168.80.20` (`terraform/infra/talos.tf`).
- The hypervisor is the router and the firewall. An nftables forward chain accepts established traffic, accepts Talos and `tailscale0` towards the subnet on TCP 22, 5432, 27017, 6333, 6379 and 3306, and drops everything else towards it (`ansible/hypervisor-network.yaml`, run by hand, not by the Deploy workflow). The isolation is enforced by these rules, not by the subnet.
- Tailscale keeps the hypervisor as the subnet router (ADR-022) and advertises `10.10.20.0/24` in addition to its other routes; the routes for `192.168.80.240` and `192.168.80.253`, missing until now, are advertised in the same command. Every tailnet node, including the CI runner, may reach the subnet.
- Every consumer reaches a database by its domain. Pods resolve the five names through a `hosts` block added to the `kube-system` CoreDNS Corefile, managed by ArgoCD (`platform/networking/cluster-dns/`, never pruned); tailnet nodes resolve them through `private-dns`. The cluster DNS does not forward the zone to `private-dns`, so no pod depends on another pod to reach its database. An address change touches DNS, Terraform and the Ansible inventory, and no workload manifest.
- The databases move one at a time, in shutdown windows, each merged as its own pull request after a backup and a clean `terraform plan`, following [data-vnet-cutover.md](data-vnet-cutover.md).

### Alternatives considered

| Alternative | Why not |
|---|---|
| A second NIC on Talos in the subnet | More Talos configuration and a second attachment to manage; the route through the hypervisor is enough and keeps one network identity for the node |
| Forwarding `internal.cristianpuenguenan.online` from the cluster DNS to `private-dns` | A pod would depend on another pod to reach its database, and a cluster restart would start with a cycle |
| Keeping pods on direct IPs (ADR-020) | Every address change would edit every consumer's manifest |
| Moving Talos into its own subnet as well | Larger change, needs the Gateway addresses re-homed; left for a second phase |

### Consequences

- A LAN device that is neither Talos nor a tailnet node can no longer reach the databases, including by SSH.
- The Deploy workflow runs Ansible against the LXCs through Tailscale, so the subnet route must be approved before the first LXC moves.
- The `kube-system` CoreDNS ConfigMap is owned by Talos (`config.k8s.io/owning-inventory: talos-bootstrap-manifests-inventory`) and may be restored on a reboot or a Kubernetes upgrade. The cutover runbook checks that the entries survive a reboot and defines what to do if they do not.
- All pods leave Talos with `192.168.80.30`, so the hypervisor firewall cannot tell namespaces apart; per-namespace control needs Cilium network policy.
- The Proxmox UI (`:8006`) and the Talos API (`:50000`) are still open to the LAN.

---

## ADR-025: Talos ingress firewall for the control plane

**Status**: Accepted
**Date**: 2026-09-24

### Context

After ADR-024 the Talos VM (`192.168.80.30`) was the only cluster component left on the flat LAN, and every LAN device could reach the Talos API (`:50000`), the Kubernetes API (`:6443`), the kubelet and the etcd ports of the only cluster node. ADR-024 listed moving Talos into its own subnet as a second phase. That phase was designed (a subnet `10.10.30.0/24` on the hypervisor, the Gateway and the private DNS forwarded with DNAT) and set aside: the same protection of the control plane is reachable with one machine-configuration change, and without changing the node's address, DNAT, SDN DHCP or a window in which the whole cluster is down.

### Decision

- The node stays at `192.168.80.30` on the LAN. Talos's own ingress firewall protects the control plane ports with one `NetworkRuleConfig` per port (`terraform/infra/talos.tf`), and the default action stays accepting.
- The Talos API (TCP 50000) accepts only the hypervisor `192.168.80.20`, the operator's PC `192.168.80.10` (`var.talos_api_allowed_sources`) and the node itself. The Kubernetes API (TCP 6443) accepts the same three plus the pod and service ranges, because pods reach it through the node's address. Tailscale clients and the CI runner reach the node through the hypervisor's subnet router, which masquerades their traffic, so the node sees `192.168.80.20`; the route `192.168.80.30/32` stays in the advertise list.
- The kubelet (TCP 10250) accepts the node itself and the pod range, and etcd (TCP 2379-2380) only the node itself: neither is reachable from the LAN.
- The Gateway and the private DNS need no rule: the default action accepts, so `192.168.80.240`, `192.168.80.253`, the Cilium pools and the L2 announcement policy do not change, and other ports of the node (metrics, Hubble) are not restricted.
- A port appears in exactly one rule: Talos evaluates rules in name order and each one drops the sources it does not list, so overlapping rules cancel each other.
- The rollout applies the rules, proves the drops from an address that is not allowed, and then restarts the node, because an established connection hides a missing rule. The hypervisor is always allowed, so a permissive configuration can be applied from it to roll back. See [talos-firewall-cutover.md](talos-firewall-cutover.md).
- The five database LXCs are renumbered to `10.10.20.10`, `.20`, `.30`, `.40` and `.50` as a later, separate stage, one container per pull request; their domains and vmids do not change.

### Alternatives considered

| Alternative | Why not |
|---|---|
| Default action `block` with allow rules per service | In block mode Talos allows only pod-to-pod traffic, so pods lose the Kubernetes API of the node (their source is a pod address and the destination the node's address) on the next restart, and every other port a pod uses on the node would need its own rule. Found when the node restarted and CoreDNS could not sync |
| A cluster subnet `10.10.30.0/24` with the Gateway and the private DNS forwarded by DNAT on the hypervisor | The same protection with an address change of the node in place, DNAT, SDN DHCP, new Tailscale routes and a window in which the whole cluster is down; the isolation would be a network boundary instead of a firewall, which a home network does not need |
| Routed `/32` addresses with proxy ARP instead of DNAT | Needs no translation, but still needs the node moved to another subnet |
| A second NIC on Talos restricted to the LAN | Keeps the node on the LAN with a second attachment to manage, and the firewall on the first one still has to exist |

### Consequences

- The isolation is enforced by the node's firewall, not by the network: a LAN device that spoofs `192.168.80.20` or `192.168.80.10` would be allowed. The Proxmox UI (`:8006`) is still open to the LAN.
- The PC's address must be stable; a DHCP reservation for `192.168.80.10` in the router keeps it.
- A wrong firewall change can lock the operator out. The hypervisor address is allowed from the first step, and the recovery order is in the runbook: apply a permissive configuration from the hypervisor, then, if needed, the Talos ISO.
- The firewall protects the control plane ports only. Other ports of the node stay reachable from the LAN, as before.
- A rule over a wide port range locks out every source it does not list, the hypervisor included. Recovery then needs the offline edit of the node's `STATE` partition described in the runbook.

---

## ADR-026: Agent Gateway removed, MCP served by Envoy Gateway

**Status**: Accepted — supersedes the "Agent Gateway only for MCP" half of [ADR-010](#adr-010-cilium-gateway-api-for-generic-ingress-agent-gateway-only-for-mcp) and [ADR-002](#adr-002-agent-gateway-as-ingress)
**Date**: 2026-09-29

### Context

Agent Gateway was kept only for two routes, SonarQube MCP and OpenMemory, plus its own admin UI. The features that justified it (MCP federation and per-tool authorization) were never used, and it cost a second controller, a second CRD set, a proxy pod and a plain-HTTP hop behind `main`, because its controller ignores HTTPS listeners. MCP remote transports are ordinary HTTP (Streamable HTTP or SSE), which Envoy Gateway routes as is.

### Decision

- `mcp-sonarqube` and `openmemory` attach to the `main` Gateway (`sectionName: https`) with the same hostnames, prefix, rewrite and backends.
- Each route gets a `BackendTrafficPolicy` with `requestTimeout: 0s` and `connectionIdleTimeout: 1h`; without it Envoy's default 15 s route timeout cuts long streams. No session affinity: both MCP servers run one replica.
- The `agentgateway`, `agentgateway-crds` and `agentgateway-config` Applications, the `platform/networking/agentgateway/` manifests, the admin UI route and the proxy route are deleted in one change; Argo CD prunes the cluster resources.
- The `openmemory` `CiliumNetworkPolicy` admits `envoy-gateway-system` (where Envoy's proxy pods run) instead of `networking`.
- `gateway-api-crds` stays on the `experimental` channel; going back to `standard` is a separate change.

### Alternatives considered

| Alternative | Why not |
|---|---|
| Keep Agent Gateway for future MCP features | Unused since it was installed; it can be reinstalled from Git when a real need appears |
| Envoy AI Gateway | Adds another component for features that are not needed yet |

### Consequences

- One ingress controller. The MCP URLs do not change.
- A short MCP interruption while Argo CD syncs the re-parented routes and prunes Agent Gateway.
- Per-tool authorization and MCP federation are gone; adding them later means introducing a gateway again.

## ADR-027: Hindsight replaces OpenMemory as the agent memory service

**Status**: Accepted — spec-0010
**Date**: 2026-09-29

### Context

OpenMemory (mem0's self-hosted MCP server) is no longer documented upstream, runs from a private image this repo has to keep building, and needs a dedicated Qdrant LXC. mem0's own self-hosted server is maintained but ships no published image, no MCP endpoint and only OpenAI/Gemini embedders out of the box.

### Decision

- Run Hindsight (`vectorize-io/hindsight`, MIT) as `hindsight-api:<version>-slim` in its own `hindsight` namespace. It publishes images, has a Helm chart and a native MCP endpoint, and stores everything in PostgreSQL with pgvector.
- The shared PostgreSQL LXC hosts it: its image changes from `postgres:17` to `pgvector/pgvector:pg17-trixie` (same major version, data directory and glibc; the default `pg17` tag is Debian bookworm, whose older glibc orders text differently and can leave existing text indexes inconsistent), and Ansible creates the `hindsight` role and database and enables `vector` in that database only.
- LLM provider `openrouter`; embeddings through the `openai` provider with `HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL=https://openrouter.ai/api/v1` and `openai/text-embedding-3-small` (1536 dimensions). The reranker is `rrf`, a passthrough that loads no model (there is no `none` provider).
- Authentication with `ApiKeyTenantExtension`; the route lives on the internal `main` Gateway with the same `BackendTrafficPolicy` as the other MCP routes.

### Alternatives considered

| Alternative | Why not |
|---|---|
| mem0 OSS server + a third-party MCP wrapper | No published image, embedder limited to bundled providers, MCP from a small third-party project |
| Cognee | Needs a graph database and targets document ingestion |
| Letta | Agent runtime rather than a memory layer; its Docker image is documented as no longer actively maintained |
| Graphiti/Zep | Requires Neo4j or FalkorDB |

### Consequences

- The embedding dimension is fixed on first start; switching model later means re-embedding.
- Every retained memory is sent to OpenRouter for extraction and embedding.
- Follow-up: once verified, remove OpenMemory, OpenMemory UI and the Qdrant LXC (Terraform, Ansible, DNS, secrets).

**Update (2026-09-30): OpenMemory, OpenMemory UI and the Qdrant LXC removed.** Their Argo CD Applications, manifests, DNS records, secret-loading block and docs are gone. The Qdrant LXC (vmid 123) leaves Terraform, Ansible, DNS, the firewall (port 6333) and the secrets, so Deploy destroys it; its data was not migrated.

## ADR-028: Kaneo replaces Vikunja for task management

**Status**: Accepted — spec-0014
**Date**: 2026-10-04

### Context

Vikunja (spec-0012) and Kaneo (spec-0013) were deployed one after the other for the same job, task management. The owner kept Kaneo, so running both has no purpose and leaves a second database, a second volume and a second secret to maintain.

### Decision

- Remove Vikunja: its Argo CD Application and manifests, its private DNS record, its credentials and secret-loading block, and its documentation. The root Application prunes the namespace on merge.
- Delete its data without a copy: the `vikunja` database and role on the shared PostgreSQL LXC, and the retained volume with its `ZFSVolume`. The tasks cannot be recovered.
- The database and the volume are deleted by hand after the merge, because the playbook has no way to drop anything and both the volume and its storage class are `Retain`.

### Alternatives considered

| Alternative | Why not |
|---|---|
| Keep both task managers | Two tools for one job, with a second database, volume and secret to look after |
| Take a final dump before deleting | Offered to the owner, who chose to delete everything with no copy |
| Add an Ansible task that drops the database and role | It would stay in the playbook as dead code once it had run, and the volume still needs a manual step |

### Consequences

- Vikunja's tasks and attachments are gone for good.
- The pool space of the deleted volume is reclaimed only if removing its `ZFSVolume` destroys the dataset; that was not verified.
- Kaneo is the only task manager left in the cluster.

## ADR-029: Syncs apply only what drifted, and two claims ignore metadata ArgoCD cannot update

**Status**: Accepted
**Date**: 2026-10-04

### Context

`Replace=true` is set on every Application (#56) so that no stray field can block a rollout. A `replace` sends the manifest as written, without `spec.volumeName`, and Kubernetes refuses it for any claim that is already bound (`spec is immutable after creation`).

Two Applications had been failing for that reason:

- `media`: eleven config and library claims were created by hand on 2026-09-17 and 2026-09-18, so they never got the `argocd.argoproj.io/tracking-id` annotation. ArgoCD wanted to add it, did it with a replace, and failed. Its last good sync was 2026-09-18.
- `sonarqube`: the chart bump of 2026-09-30 changed the `chart` label of every object of the release. Everything accepted the replace except the bound claim.

By default a sync applies every object of the Application, so one refused claim fails the whole sync, and ArgoCD does not retry the same revision. Each merge made a new failed attempt.

### Decision

- Add `ApplyOutOfSyncOnly=true` to `media` and `sonarqube`: a sync applies only the objects that drifted, so a claim that is in sync is never replaced.
- In `media`, ignore `metadata.annotations["argocd.argoproj.io/tracking-id"]` on `PersistentVolumeClaim`. The claims that lack it count as in sync and are no longer part of any sync.
- In `sonarqube`, ignore `metadata.labels.chart` on `PersistentVolumeClaim`, which changes on every chart bump and which nothing reads.

### Alternatives considered

| Alternative | Why not |
|---|---|
| `argocd.argoproj.io/sync-options: Replace=false` on each claim | It has no effect: ArgoCD replaces when the Application or the resource asks for it, so the annotation can only turn replace on |
| Annotate the eleven claims by hand | Not GitOps, and it does nothing for `sonarqube`, whose claim drifts again on the next chart bump |
| Remove `Replace=true` from both Applications | Brings back the stuck `Recreate` rollout that #56 fixed |

### Consequences

- The `chart` label of the `sonarqube` claim stays on its old value; nothing depends on it.
- The `media` claims stay without the tracking annotation, so ArgoCD never prunes them, which is the safe side for claims that hold data.
- Other Applications with a bound claim and `Replace=true` fail the same way as soon as anything else in them drifts. They were not changed here.

## ADR-030: The host's RTX 2060 is passed through to the Talos VM for Jellyfin transcoding

**Status**: Accepted
**Date**: 2026-10-10

### Context

Jellyfin played through Chrome with a software AV1 transcode (`libsvtav1`) that ran at 0.92x realtime and pinned the pod's CPU limit, so playback stuttered (#164 raised the limits). The Talos VM has no GPU, so every transcode runs on the CPU. The hypervisor has an RTX 2060 (Turing: NVENC encodes H.264 and HEVC, not AV1), so a transcode would produce H.264 that Chrome plays directly.

### Decision

- Pass the card through to the VM with a `hostpci` block (`var.gpu_pci_id`, empty by default so nothing changes until it is set). The VM already uses `q35` + `ovmf`, which PCIe passthrough needs.
- Talos moves from v1.14.0 to v1.14.2 (the latest stable in the Image Factory; the same release carries the extension versions the schematic resolves to) with a new schematic `42dcbb7542e7f2d53beec866d4687f9306cd2b2da3b049fb4872cfc41942723e`: the previous extensions plus `nonfree-kmod-nvidia-production` and `nvidia-container-toolkit-production`. The `nvidia*` kernel modules and `net.core.bpf_jit_harden=1` are added to the machine config.
- The Kubernetes side landed once the node reported the GPU (merging it first would have left Jellyfin `Pending` on a resource that does not exist): the `nvidia` RuntimeClass and the NVIDIA device plugin (`platform/gpu/nvidia-device-plugin/`, in `kube-system`, with the chart's NFD-label affinity removed because the cluster runs no NFD), and Jellyfin asks for `runtimeClassName: nvidia` and `nvidia.com/gpu: 1`. Its CPU and memory limits go back to 2 cores / 4Gi, since the encode no longer runs on the CPU.

### Consequences

- The hypervisor loses the card: it cannot be used for its console or another VM.
- The change needs steps outside the repo, in this order: enable IOMMU and bind the card to `vfio-pci` on Proxmox; set `GPU_PCI_ID` and `TALOS_SCHEMATIC_ID` in the `prod` GitHub environment; `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<version>` (applying the machine config does not change the installed image). The VM reboots, so the whole single-node cluster is down for a few minutes.
- The schematic carries no extension that needs an `ExtensionServiceConfig` (see ADR-022's rule); if the node loops on `startAllServices` after the upgrade, revert with `talosctl upgrade` to the previous schematic.

---

## ADR-031: Autosubtitle gives Spanish subtitles to imported episodes through Bazarr and Lingarr

**Status**: Accepted
**Date**: 2026-10-28

### Context

Bazarr searches Spanish subtitles for each imported episode, but many anime have none in any provider, and extracting the English track and queuing a Lingarr translation by hand did not scale. Bazarr emits no event when a search ends without a result (its notifications and webhook fire only on success), Lingarr cannot read subtitles embedded in an MKV, and Lingarr's own automation only runs on a schedule with a delay measured in hours.

### Decision

- A small worker, `autosubtitle` (`workloads/autosubtitle/`), written in Python with FastAPI in a single file. Sonarr's webhook (import complete and upgrade) and a daily CronJob wake it through KubeElasti, and it sits at zero replicas with `cooldownPeriod: 1800`. The trigger query is a constant zero because Sonarr's calls never pass through Envoy, so there is no traffic metric to read.
- It works from Bazarr's list of episodes missing Spanish, waits for Bazarr's own search job of each series (polling `GET /api/system/jobs`, the only completion signal Bazarr offers) and asks Bazarr to run the search only if none appears within 180 seconds. For the episodes still missing Spanish it calls Bazarr's translate action on the English dialogue track (the embedded track whose title is not signs or songs); Bazarr extracts it and translates through Lingarr, so the worker mounts no media and calls Lingarr itself never. Bazarr's `translator_type` was switched from `google_translate` to `lingarr` for this.
- A Redis ledger (`autosubtitle:requested:{episodeId}`, set only if absent, expiring after 3 hours, cleared whenever Bazarr holds no translation job) stops an episode from being requested twice, because a queued Bazarr translation job does not name its episode. At most 6 translation jobs are pending or running at once and earlier episodes go first. If Redis is down the worker still waits for the searches but requests nothing.
- The code reaches the pod through a kustomize `configMapGenerator`, on an image of our own that holds only the dependencies (`python:3.12-slim` plus `fastapi`, `uvicorn`, `redis` and `httpx`, pinned), built by a GitHub Actions workflow and published to `ghcr.io/cristsr/autosubtitle-base` with a `major.minor.patch` tag. No maintained image bundles that set, and `tiangolo/uvicorn-gunicorn-fastapi` is deprecated.

### Consequences

- The tag is bumped by hand in the workflow, the Deployment and the CronJob whenever `requirements.txt` or the `Dockerfile` change, because Renovate skips `ghcr.io/cristsr/**`. Editing `worker.py` needs no image build.
- The package must be made public once in GitHub, and Sonarr's webhook is created by hand after the service exists: Sonarr tests a webhook when it saves it, and refuses it while the URL does not resolve. Both steps are in `docs/autosubtitle.md`.
- Bazarr leaves the extracted `.en.ass` beside the video and adds a one-line banner cue to the Spanish `.srt`; the translation is line by line, about 15 minutes for a 25-minute episode, and the gender mix-ups (él/ella) of the translations are not addressed.
- The first image this repo builds, and the first use of kustomize, are introduced here.

## ADR-032: The autosubtitle worker becomes `relay`, a home for arr-stack automations

### Context

`autosubtitle` was named for its one job. The arr stack lacks other automations too, such as refreshing Sonarr's metadata when TheTVDB gets an episode title after Sonarr cached it as "TBA", which blocks the import. A service per automation would repeat the KubeElasti, Secret, ConfigMap and CronJob scaffolding each time.

### Decision

- The service is renamed `relay` (`workloads/relay/`, ArgoCD Application `relay`) and each automation gets its own route prefix: the subtitle run is now `POST /subtitles/run`, and the next one will be `/metadata/...`. Each automation keeps its own lock and ledger.
- Kept on purpose: the image `ghcr.io/cristsr/autosubtitle-base` (it holds only dependencies, and a new name would need a new public package), the Secret `autosubtitle` (renaming it means re-encrypting `secrets.sops.yaml`) and the Redis prefix `autosubtitle:requested:`. They name the subtitles automation or a published artifact, not the service.
- The CronJob is now `relay-subtitles-daily`.
- `POST /metadata/refresh` is the second automation. Sonarr calls it on grab; while a grabbed episode still has a TBA title the service refreshes the series every 5 minutes, at most 5 times, one loop per series, and never when Sonarr already has a `RefreshSeries` queued or running for it. It reuses the Sonarr key of the `lingarr` secret so no secret is re-encrypted.

### Consequences

- Sonarr's webhook must point to `http://relay.media.svc.cluster.local:8080/subtitles/run`. The old Service disappears with the old Deployment, so until the webhook is updated Sonarr's calls fail without a visible error (steps in `docs/relay.md`).
- Merging pushes `workloads/relay/` to the image workflow's paths, so the workflow rebuilds `autosubtitle-base:1.0.0` once with the same pinned dependencies.
