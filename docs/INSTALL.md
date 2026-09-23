# Installation Guide

> The Talos Linux node runs as a VM on Proxmox VE, provisioned with Terraform in two stages (`terraform/infra`, `terraform/cluster`).
> Neither Terraform nor Ansible run on the hypervisor (see [ADR-009](DECISIONS.md#adr-009-cicd-with-github-actions-hosted--tailscale--cloudflare-r2)): they talk to the Proxmox REST API and the Talos API (mTLS) remotely — from your control machine or, automatically, from GitHub Actions via Tailscale. This guide documents the **manual** flow; for the automatic one see [`.github/workflows/`](../.github/workflows/), ADR-009, and [CI_CD_HYPERVISOR_SETUP.md](CI_CD_HYPERVISOR_SETUP.md).

---

## Table of Contents

0. [Credentials preflight](#0-credentials-preflight)
1. [Prerequisites](#1-prerequisites)
2. [Prepare the Control Machine](#2-prepare-the-control-machine)
3. [Configure Secrets](#3-configure-secrets)
4. [Provision the Talos VM (`terraform/infra`)](#4-provision-the-talos-vm-terraforminfra)
5. [Kubernetes Bootstrap (`terraform/cluster`)](#5-kubernetes-bootstrap-terraformcluster)
6. [Activate GitOps](#6-activate-gitops)
7. [Load the real secrets (SOPS + age)](#7-load-the-real-secrets-sops--age)
8. [Verify and Access](#8-verify-and-access)
9. [DNS](#9-dns)
10. [Troubleshooting](#10-troubleshooting)

---

## 0. Credentials preflight

Before touching Terraform, validate that the credentials exist and aren't empty — fail in seconds instead of halfway through provisioning. Credentials are exported from `secrets/homelab.env` (see section 3):

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

---

## 1. Prerequisites

### Minimum VM hardware (defined in `terraform/infra/variables.tf`)

| Resource | Minimum | This repo's default |
|---------|--------|-----------------------|
| CPU | 4 cores | 8 vCPU (`var.vcpu`) |
| RAM | 8 GB | 16 GB (`var.memory_mib`) |
| Installation disk | 100 GB | 120 GB (`var.disk_size_gb`) |
| Dedicated ZFS disk | - | 100 GB (`var.zfs_disk_size_gb`) |
| Network | Static IP on the LAN | `var.vm_static_ip`, bridge `vmbr0` |

### Software

- **Hypervisor**: Proxmox VE, with the API reachable (`:8006`) and a dedicated API token (see [CI_CD_HYPERVISOR_SETUP.md §2](CI_CD_HYPERVISOR_SETUP.md)).
- **Control machine**: Terraform (`>= 1.10.0`) and Ansible. Neither is installed on the hypervisor or on the VM.
- The VM needs no manual preparation: Talos is immutable, Terraform applies the full configuration via API.

### Required external accounts and tokens

Before starting, make sure you have the following values on hand:

| Token/Account | Description | How to get it |
|--------------|-------------|----------------|
| **Proxmox API Token** | `user@realm!tokenid=uuid` so Terraform can create the VM | Proxmox UI → Datacenter → Permissions → API Tokens (see CI_CD_HYPERVISOR_SETUP.md §2) |
| **Talos Schematic ID** | ID generated at https://factory.talos.dev with the `qemu-guest-agent`, `zfs` extensions | Image Factory — see the default in `terraform/infra/variables.tf` |
| **GitHub PAT** | Personal Access Token with `repo` permissions so ArgoCD can access the private repository | GitHub Settings → Developer settings → Personal access tokens |
| **Cloudflare API Token** | Token with `Zone:Edit` and `Zone:Read` permissions for the domain (cert-manager DNS-01) | Cloudflare Dashboard → My Profile → API Tokens |
| **Cloudflared Tunnel Token** | Cloudflare tunnel token | `cloudflared tunnel create <name>` or from the Zero Trust Dashboard |

---

## 2. Prepare the Control Machine

### 2.1 Install dependencies

```bash
# Terraform (official HashiCorp repo)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform git pipx curl
pipx install --include-deps ansible && pipx ensurepath
source ~/.bashrc
```

Verify installation:

```bash
terraform version
ansible --version
```

### 2.2 Clone the repository

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab

# Install the git hooks (once per clone, idempotent)
./scripts/install-git-hooks.sh
```

`core.hooksPath` lives in `.git/config`, which is not cloned, so the installer has to be run on each machine. Without it the `commit-msg` hook never runs and commit messages are not validated.

---

## 3. Configure Secrets

All credentials (infra + apps) live in a single plaintext file, **never committed** (`secrets/homelab.env` is in `.gitignore`):

```bash
cp secrets/homelab.env.example secrets/homelab.env
$EDITOR secrets/homelab.env
```

Fill in at least the fields in the `# --- Infra (required) ---` section (`ARGOCD_GITHUB_PAT`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARED_TUNNEL_TOKEN`, `GHCR_PAT`) and `# --- Databases ---`. The rest of the fields (Monitoring, SonarQube, DevTools) also live in this same file, but are applied to the repo (encrypted) in section 7 — they're not used directly from here.

> This file is now only consumed by `ansible/preflight.yaml` (Infra fields) and `ansible/data-services.yaml` (Databases fields, when bringing up the engines on their LXCs). The Gateway/internal DNS fixed IP is no longer configured via variable — it's edited directly in `platform/networking/cilium-gateway/gateway.yaml` and `platform/networking/private-dns/` if it needs to change.

### 3.1 Run the preflight

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

---

## 4. Provision the Talos VM (`terraform/infra`)

### 4.1 Configure variables

```bash
cd terraform/infra
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edit `terraform.tfvars`: `proxmox_endpoint`, `proxmox_api_token`, `talos_schematic_id`, `vm_static_ip`, `vm_gateway`. Adjust memory/vcpu/disks if needed (defaults: 16GB RAM, 8 vCPU, 120GB + 100GB disk).

Edit `backend.hcl` with your Cloudflare account's Account ID (R2 bucket `homelab-tfstate` that holds the remote state — see ADR-009).

### 4.2 Apply

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

This:
- Downloads the Talos ISO generated by the Image Factory (`talos_schematic_id`), once.
- Creates the VM in Proxmox with two disks (installation + dedicated to ZFS) and a static IP on the real LAN (bridge `vmbr0`).
- Applies the Talos machine config (partitions the ZFS disk, configures the network) and bootstraps the cluster.
- Generates `terraform/infra/generated/kubeconfig` and `generated/talosconfig`.

Verify the node is ready:

```bash
export KUBECONFIG=terraform/infra/generated/kubeconfig
kubectl get nodes
```

---

## 5. Kubernetes Bootstrap (`terraform/cluster`)

### 5.1 Configure variables

```bash
cd ../cluster
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edit `terraform.tfvars`: `kubeconfig_path` (points to `../infra/generated/kubeconfig`), `argocd_github_pat`.

### 5.2 Apply

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

This creates, in order (via `depends_on`):
- **Base namespaces** (`terraform/cluster/namespaces.tf`).
- **Cilium** (`helm_release`).
- **ArgoCD** (`helm_release`).
- **Initial secrets**: `github-repo-creds`, `in-cluster-secret` (`terraform/cluster/secrets.tf`).
- **OpenEBS ZFS Job**: creates the `zfspv-pool` zpool on the dedicated disk (`terraform/cluster/storage.tf`).

Verify:

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl -n argocd get pods
```

Get ArgoCD's initial password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 6. Activate GitOps

```bash
kubectl apply -f gitops/root-app.yaml
```

From here on ArgoCD syncs the cluster with the Git repository following the sync-wave order (see `docs/ARCHITECTURE.md` §9).

Follow progress:

```bash
kubectl -n argocd get applications -w
```

---

## 7. Load the real secrets (SOPS + age)

> **When to do this**: After GitOps activates the cluster. **This step is always manual** — it deliberately doesn't run in CI (same rationale as ADR-015). Until you do it, the Applications that depend on these secrets (cloudflared, the databases, SonarQube, OpenMemory) will be stuck with unusable `admin` placeholders (`Progressing`/`Degraded`/`CrashLoopBackOff`/`ImagePullBackOff` depending on the case). This is expected, not a pipeline failure.

The real secrets live encrypted in the repo (`*.sops.yaml` + `ansible/data-services.env`, see ADR-018/019 in [DECISIONS.md](DECISIONS.md)) — there's no external backend, only the `age` private key mounted in `sops-secrets-operator` (namespace `sops`).

### 7.1 Fill in the values

1. Copy `secrets/homelab.env.example` to `secrets/homelab.env` (gitignored, never committed).
2. Fill in each value (Cloudflare tokens, GHCR PAT, database passwords, etc. — each field in the file documents what it's used for).

### 7.2 Apply the values to the encrypted files

```bash
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt   # or wherever you keep the age private key
./scripts/apply-real-secrets.sh secrets/homelab.env
```

The script uses `sops set` to patch each encrypted field in its `*.sops.yaml` (without touching the rest of the file) and re-encrypts the entire `ansible/data-services.env`. Any empty field in `secrets/homelab.env` is skipped — the existing encrypted value stays intact. Review `git diff --stat`, and commit/push the files that changed so ArgoCD (the `SopsSecret`s) and CI (`data-services.env`, via `sops exec-env`) pick up the new values.

You can re-run the script whenever you want to rotate a value — it's idempotent.

---

## 8. Verify and Access

### 8.1 Verify cluster status

```bash
kubectl -n argocd get applications
kubectl get pods -A
```

### 8.2 Access endpoints

| URL | Service | Credentials |
|-----|----------|--------------|
| `https://argocd.cristianpuenguenan.online` | Argo CD | admin / (initial password from step 5.2) |
| `https://grafana.cristianpuenguenan.online` | Grafana | admin / (configured in secrets/homelab.env, see §7) |
| `https://agentgateway.cristianpuenguenan.online` | Agent Gateway | admin / admin |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Service token |
| `https://hubble.cristianpuenguenan.online` | Hubble | No auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | admin / (configured in secrets/homelab.env, see §7) |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | No auth |

Token for Headlamp:

```bash
kubectl create token headlamp -n observability
```

### 8.3 LAN and Tailscale access

The VM has a real IP on the LAN (Proxmox bridge `vmbr0`) — the Gateways (`envoy-main` at `192.168.80.240`, `private-dns` at `192.168.80.253`) are reachable directly from any device on the LAN, no port-forward needed. To access from outside the physical LAN, use Tailscale: the hypervisor advertises `/32` routes scoped to those IPs (see [CI_CD_HYPERVISOR_SETUP.md §1](CI_CD_HYPERVISOR_SETUP.md)), not the full `/24`.

```bash
curl -kI https://192.168.80.240 -H "Host: argocd.internal.cristianpuenguenan.online"
```

Cloudflare Tunnel (WAN access, public routes) doesn't depend on the LAN or Tailscale — it's an outbound connection from inside the cluster.

---

## 9. DNS

**Public** routes (`portfolio`, `api`) don't require manual A records: they're configured as *Public Hostnames* in the Cloudflare Zero Trust dashboard, pointing to the `cloudflared` tunnel — managed outside Git.

**Private** routes (`*.internal.cristianpuenguenan.online`) resolve via `private-dns` (in-cluster CoreDNS, fixed IP `192.168.80.253`), not via Cloudflare. For your machine to resolve them automatically, configure Tailscale Split DNS (Admin console → DNS → Nameservers → Split DNS) pointing the `internal.cristianpuenguenan.online` domain to `192.168.80.253`.

Verify the certificate (both wildcards, public and private, are issued by the same DNS-01 `ClusterIssuer`):

```bash
kubectl get certificate -n networking
```

---

## 10. Troubleshooting

### Apps in Unknown state

Terraform already creates the `in-cluster-secret` for ArgoCD automatically (`terraform/cluster/secrets.tf`). If for some reason applications end up in `Unknown` state, verify the secret exists and restart the controller:

```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
kubectl delete pod -n argocd argocd-application-controller-0
```

If the secret doesn't exist, recreate it manually:

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

### SopsSecret not syncing

```bash
kubectl get sopssecrets -A
kubectl describe sopssecret <name> -n <namespace>
kubectl -n sops logs deployment/sops-secrets-operator --tail=50
```

Typical causes: the `age` private key mounted in the operator doesn't match the one that encrypted the file (`age1...` in `.sops.yaml` vs the real key), or the destination `Secret` already existed owned by another controller without `spec.enforceOwnership: true` on the `SopsSecret` (`Child secret is not owned by controller` error).

### OpenEBS volume not provisioning

Talos has no shell: there's no `vgs`/`lvs` to run over SSH. Inspect it from a privileged pod (see `docs/ARCHITECTURE.md`, Troubleshooting):

```bash
kubectl get zfsnode -n openebs
kubectl -n openebs logs -l app=openebs-zfs-controller -c openebs-zfs-plugin
kubectl debug node/talos -it --image=alpine:3.20 -- \
  sh -c "apk add --no-cache zfs >/dev/null && zpool status zfspv-pool"
```

### Updating Talos

Talos is updated by replacing the node's entire image, not with a package manager:

```bash
talosctl --talosconfig terraform/infra/generated/talosconfig upgrade \
  --nodes <vm_static_ip> --image factory.talos.dev/installer/<schematic_id>:<version>
```

Since this is a single-node cluster, the upgrade reboots the node and the entire cluster goes down during the process — do it in a chosen maintenance window.

### Reinstalling from scratch

To destroy and recreate only the Kubernetes bootstrap (keeping the VM):

```bash
cd terraform/cluster
terraform destroy
terraform apply
```

To also destroy the VM and recreate it from scratch:

```bash
cd terraform/infra
terraform destroy
terraform apply
```

---

## Command summary

```bash
# 0. Clone repo, prepare the control machine
git clone git@github.com:cristsr/homelab.git && cd homelab
sudo dnf install -y dnf-plugins-core git pipx curl
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
pipx install --include-deps ansible && pipx ensurepath

# 1. Configure secrets and preflight
cp secrets/homelab.env.example secrets/homelab.env
# (edit secrets/homelab.env with the infra values)
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
cd ..

# 2. Provision the Talos VM on Proxmox
cd ../terraform/infra
cp terraform.tfvars.example terraform.tfvars   # fill in proxmox_*/talos_schematic_id/vm_*
terraform init -backend-config=backend.hcl && terraform apply

# 3. Kubernetes bootstrap (Cilium, ArgoCD, ZFS)
cd ../cluster
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl && terraform apply

# 4. Activate GitOps
cd ../..
kubectl apply -f gitops/root-app.yaml

# 5. Load the real secrets (always manual - see section 7 above)
cp secrets/homelab.env.example secrets/homelab.env && $EDITOR secrets/homelab.env
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt
./scripts/apply-real-secrets.sh secrets/homelab.env

# 6. Verify
kubectl -n argocd get applications
kubectl get pods -A
```
