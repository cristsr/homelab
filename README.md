# Homelab Kubernetes

Personal homelab infrastructure based on Kubernetes, orchestrated with GitOps. The node runs as a Talos Linux VM on Proxmox VE, provisioned with Terraform.

---

## What is this project

This repository contains the complete configuration to spin up a single-node Kubernetes cluster using **Talos Linux** (immutable, no SSH), with a modern platform stack that includes:

- **GitOps**: ArgoCD manages the entire application lifecycle from Git.
- **Networking**: Cilium as CNI with full kube-proxy replacement via eBPF.
- **Ingress**: Cilium Gateway API for generic traffic, Agent Gateway retained only for MCP servers (see ADR-010).
- **Secrets**: 1Password as the secrets backend, synced with Kubernetes via External Secrets Operator.
- **Storage**: OpenEBS ZFS LocalPV as local storage (see ADR-013 and ADR-014).
- **Monitoring**: Prometheus, Grafana and Headlamp.
- **Databases**: PostgreSQL, MongoDB, Redis and Qdrant in Proxmox LXC, outside the cluster (see ADR-016).
- **Tools**: SonarQube, OpenMemory.
- **External access**: Cloudflare Tunnel to expose services without opening ports.

The VM is created with **Terraform** (provider `bpg/proxmox` + `siderolabs/talos`) in two stages: `terraform/infra` (VM, Talos, disks) and `terraform/cluster` (namespaces, Cilium, ArgoCD, initial secrets). **Ansible** is used only for preflight validations and to provision the data engines on their LXC — Talos has no SSH or shell, so it no longer provisions the node's operating system.

---

## Technology Stack

| Layer | Technology | Version |
|------|-----------|---------|
| VM / Hypervisor | Terraform + Proxmox VE (`bpg/proxmox`) | - |
| Kubernetes | Talos Linux (`siderolabs/talos`) | v1.14.0 |
| CNI | Cilium | 1.20.1 |
| GitOps | Argo CD | 9.5.13 |
| Ingress (generic) | Cilium Gateway API | 1.20.1 |
| Ingress (MCP) | Agent Gateway | 1.1.0 |
| Storage | OpenEBS ZFS LocalPV | 2.11.1 |
| Secrets | 1Password | - |
| Secret Sync | External Secrets Operator | - |
| Monitoring | kube-prometheus-stack / Grafana Operator | - |
| Ingress TLS | cert-manager + Let's Encrypt + Cloudflare DNS-01 | - |
| WAN Tunnel | Cloudflare Tunnel (cloudflared) | - |
| Runtime security | Tetragon | - |
| Databases | PostgreSQL 17, MongoDB 8.0, Qdrant, Redis 8 (Proxmox LXC) | - |

---

## Repository Structure

```
homelab/
├── terraform/
│   ├── infra/                   # Talos VM + data LXC on Proxmox: disk, network, Talos bootstrap
│   │   ├── proxmox.tf           # VM, disks (installation + dedicated to ZFS), Talos ISO
│   │   ├── lxc.tf               # Four data LXC: PostgreSQL, MongoDB, Qdrant, Redis
│   │   ├── talos.tf             # machine config, bootstrap, generated kubeconfig/talosconfig
│   │   └── generated/           # kubeconfig/talosconfig (gitignored)
│   └── cluster/                 # Kubernetes bootstrap on the already-running cluster
│       ├── bootstrap.tf         # helm_release: Cilium, ArgoCD
│       ├── namespaces.tf        # Base namespaces
│       ├── secrets.tf           # Initial secrets (repo-creds, in-cluster)
│       └── storage.tf           # Job that creates the OpenEBS ZFS LocalPV zpool
│
├── ansible/                     # Credentials preflight + data LXC provisioning
│   ├── preflight.yaml           # Validates credentials before running Terraform (fails fast in CI)
│   ├── ansible.cfg              # Ansible configuration
│   └── tasks/                   # Individual tasks
│
├── secrets/
│   └── homelab.env.example      # Template of all credentials (infra + apps)
│
├── scripts/
│   └── apply-real-secrets.sh    # Loads secrets/homelab.env into the repo's encrypted SopsSecret/env - manual, does not run in CI
│
├── bootstrap/                   # Values/scripts consumed by terraform/cluster/bootstrap.tf
│   ├── cilium/values.yaml       # Cilium configuration (includes Talos-specific settings)
│   ├── argocd/values.yaml       # ArgoCD configuration
│   └── adopt-cilium-gateway-secrets.sh  # Idempotency hook for the Cilium chart
│
├── gitops/                      # ArgoCD applications (App of Apps)
│   ├── root-app.yaml            # Root application
│   └── apps/
│       ├── platform/            # ArgoCD Applications for infrastructure
│       └── workloads/           # ArgoCD Applications for user apps
│
├── platform/                    # Infrastructure manifests and Helm values
│   ├── networking/
│   ├── storage/
│   ├── devtools/
│   ├── observability/
│   ├── secret-management/
│   └── security/
│
├── workloads/                   # User/business applications
│   ├── flow/                    # Flow API
│   ├── portfolio/                # Personal site
│   └── sonarqube/                # SonarQube + MCP server
│
└── docs/                        # Project documentation
    ├── ARCHITECTURE.md          # Full architecture
    ├── INSTALL.md                # Step-by-step installation guide
    ├── OPERATIONS.md             # Operations manual and troubleshooting
    ├── DECISIONS.md              # Decision log (ADR)
    └── CI_CD_HYPERVISOR_SETUP.md # Manual hypervisor setup runbook
```

---

## Documentation

All documentation is located in the [`docs/`](./docs/) folder:

- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)**: Detailed description of the architecture, components, networking, security and data flow.
- **[docs/INSTALL.md](./docs/INSTALL.md)**: Prerequisites, Terraform and `secrets/homelab.env` configuration, cluster installation and GitOps activation.
- **[docs/OPERATIONS.md](./docs/OPERATIONS.md)**: Day-to-day operations, secrets management, backups, upgrades, troubleshooting and emergency procedures.
- **[docs/DECISIONS.md](./docs/DECISIONS.md)**: Architecture decision log (ADR): Talos, Proxmox, Agent Gateway, Cilium, OpenEBS, Ansible and CI/CD.
- **[docs/CI_CD_HYPERVISOR_SETUP.md](./docs/CI_CD_HYPERVISOR_SETUP.md)**: Manual hypervisor setup runbook (Tailscale, SSH, sudoers) for CI/CD to work.

---

## Quick Install

> Requires Proxmox VE running on the hypervisor and access to its API.

```bash
# 1. Clone repo
git clone git@github.com:cristsr/homelab.git && cd homelab

# 2. Configure secrets (infra + apps, a single file, never committed)
cp secrets/homelab.env.example secrets/homelab.env
# edit secrets/homelab.env with the real values

# 3. Validate credentials before provisioning (fails fast if something is missing)
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
cd ..

# 4. Install cluster infra (Talos VM on Proxmox)
cd terraform/infra
terraform init -backend-config=backend.hcl
terraform apply

# 5. Bootstrap K8s (Cilium, ArgoCD, ZFS) and base configurations
cd ../cluster
terraform init -backend-config=backend.hcl
terraform apply

# 6. Activate GitOps
cd ../../
kubectl apply -f gitops/root-app.yaml

# 7. Load the secrets into 1Password (vault "Homelab") and the cluster's
#    Service Account token - see docs/INSTALL.md, "Populate 1Password" section.
```

For a detailed guide, see [docs/INSTALL.md](./docs/INSTALL.md).

---

## CI/CD

Terraform and Ansible **do not** run on the homeserver: every push to `master` triggers [`.github/workflows/deploy.yml`](./.github/workflows/deploy.yml) on a GitHub Actions hosted runner, which connects to the hypervisor via Tailscale and applies the change (`ansible-playbook preflight.yaml`, `terraform apply` in `infra` and `cluster`, provisioning of the data LXC, and `kubectl apply -f gitops/root-app.yaml`), behind a manual approval gate (Environment `prod`). The app's secrets live in 1Password and never pass through CI. Every PR touching `terraform/**` triggers [`terraform-plan.yml`](./.github/workflows/terraform-plan.yml), which comments the plan before merging. Full architecture details in [ADR-009](./docs/DECISIONS.md#adr-009-cicd-with-github-actions-hosted--tailscale--cloudflare-r2).

---

## Service Access

| Service | URL | Notes |
|----------|-----|-------|
| ArgoCD | `https://argocd.cristianpuenguenan.online` | Admin / initial password from the `argocd-initial-admin-secret` secret |
| Grafana | `https://grafana.cristianpuenguenan.online` | Credentials in 1Password |
| Headlamp | `https://headlamp.cristianpuenguenan.online` | Requires service token |
| SonarQube | `https://sonarqube.cristianpuenguenan.online` | Credentials in 1Password |
| Agent Gateway | `https://agentgateway.cristianpuenguenan.online` | Admin / admin |
| Hubble | `https://hubble.cristianpuenguenan.online` | No authentication |

---

## Security

- The data LXC credentials live in `secrets/homelab.env`, in plain text and **never versioned** (it is in `.gitignore`), exported before running Ansible by hand.
- Cluster secrets are managed via **1Password** (vault "Homelab") and synced with Kubernetes via **External Secrets Operator**, authenticated with a read-only Service Account token scoped to that vault.
- In CI, the credentials preflight uses GitHub Actions secrets/vars (see [CI_CD_HYPERVISOR_SETUP.md](./docs/CI_CD_HYPERVISOR_SETUP.md)) — never a file from the repo.
- External access is done through **Cloudflare Tunnel**, without needing to open ports on the router.
- **Tetragon** monitors at the kernel level for privilege escalation, access to sensitive files and suspicious syscalls.

---

## Maintenance and Operations

See [docs/OPERATIONS.md](./docs/OPERATIONS.md) for:

- Checking cluster health.
- Managing secrets and ExternalSecrets.
- Performing database backups.
- Updating component versions.
- Troubleshooting by component.
- Emergency procedures.

---

## Author

- **Cristian Puenguenan** ([@cristsr](https://github.com/cristsr))

---

## License

This project is for personal use. Feel free to take ideas and adapt them to your own homelab.
