# Hypervisor Setup for CI/CD (Proxmox VE)

> Runbook of what needs to be applied on the Proxmox hypervisor and on GitHub
> so the CI/CD pipeline can provision/manage the Talos node
> remotely. Replaces the old runbook (Fedora + libvirt + SELinux),
> which no longer applies: Proxmox doesn't use libvirt, and Talos has neither SSH nor SELinux.
>
> Unlike the old runbook, Terraform **doesn't need any SSH key**:
> it talks to the Proxmox REST API (token) and the Talos API (mTLS). What
> does need SSH is Ansible when provisioning the data engines on
> the LXCs (`ansible/bootstrap-lxc-ssh.yaml` + `ansible/data-services.yaml`,
> see section 5) — unlike Talos (no SSH or shell), the Proxmox
> LXCs do have both.

## 1. Tailscale on the hypervisor + subnet route (scoped, not the full /24)

The GitHub Actions runner is hosted (it has no direct access to the
homelab LAN). For it to reach the Proxmox API (`:8006`), the Talos VM, and
(since `ansible/data-services.yaml` runs in CI) the data LXCs
via direct SSH, the hypervisor's Tailscale node has to advertise those
hosts - **not the full `/24` subnet**: advertising the entire `192.168.80.0/24`
causes any machine on the tailnet with "accept routes" (including the
operator's) to route ALL of that range through the tunnel, breaking
direct LAN access to the other devices on the local network.

> If `ansible-playbook data-services.yaml` fails in CI with `Connection
> timed out` against `10.10.20.31-35`, this is why - the runner doesn't have
> a route advertised/approved to those IPs yet.

The Talos VM has a fixed MAC (`var.vm_mac_address` in
`terraform/infra/variables.tf`, default `02:00:00:00:00:30`) precisely
so `var.vm_static_ip` can be reserved for it via DHCP on the router - that way the boot
in maintenance mode (before Talos applies its static network config)
already lands on that known IP, instead of a random IP from the DHCP pool. Without that
reservation, scoping the Tailscale route to specific hosts breaks
`talos_machine_configuration_apply` (there's no way to know in advance which
IP it will get in maintenance mode).

Steps:

1. On the router: reserve `var.vm_static_ip` (e.g. `192.168.80.30`) to the MAC
   `var.vm_mac_address` (e.g. `02:00:00:00:00:30`).
2. On the hypervisor:
   ```bash
   tailscale set --advertise-routes=192.168.80.20/32,192.168.80.30/32,192.168.80.240/32,192.168.80.253/32,10.10.20.0/24 --accept-routes
   ```
   (adjust the IPs if `PROXMOX_ENDPOINT`/`VM_STATIC_IP` are different; the
   `10.10.20.0/24` is the isolated data VNet holding the data LXCs, `terraform/infra/sdn.tf`).
3. In the Tailscale admin console (**Machines → homelab → Edit route
   settings**): disable the old `192.168.80.0/24` route if it was
   approved, and enable the six new `/32` routes. Without this manual step
   the routes remain advertised but not routed - `tailscale status
   --json` will keep showing only the old routes in `PrimaryRoutes`
   until they're approved here.

Verification from any machine on the tailnet:

```bash
tailscale ping 192.168.80.20   # LAN IP of the hypervisor
tailscale ping 192.168.80.30   # LAN IP of the Talos VM
tailscale ping 10.10.20.31      # data VNet IP of the PostgreSQL LXC (same for 32/33/34/35)
```

## 2. Proxmox API token for Terraform

In the Proxmox UI: **Datacenter → Permissions → API Tokens → Add**.
User `terraform@pve` (or whichever applies) with a dedicated token
(e.g. `ci`), **without** "Privilege Separation" if the token needs the
same permissions as the user, or with a scoped role if you prefer the
principle of least privilege (needs at least permissions to create/edit
VMs and download files to the datastore).

The full token has the format `user@realm!tokenid=uuid` - that full
string is the value of `TF_VAR_proxmox_api_token` / the secret
`PROXMOX_API_TOKEN` in GitHub.

## 3. GitHub variables and secrets

**Secrets** (Settings → Environments → `prod` → Secrets):
- `PROXMOX_API_TOKEN` - the token generated in step 2.
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` - remote backend (unchanged).
- `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` - Tailscale OAuth client (unchanged).
- `ARGOCD_GITHUB_PAT` - GitHub PAT used by ArgoCD to sync this repo (consumed by Terraform, validated by the preflight).

CI does **not** need `CLOUDFLARE_API_TOKEN`, `CLOUDFLARED_TOKEN`, `ARGOCD_WEBHOOK_SECRET`, or any 1Password token as GitHub secrets - the application's actual secrets live in the "Homelab" vault in 1Password and are read by ExternalSecrets directly from the cluster via the Service Account token (`onepassword-service-account-token`, namespace `secret-management`), never from CI.

**Variables** (Settings → Environments → `prod` → Variables):
- `PROXMOX_ENDPOINT` - e.g. `https://192.168.80.20:8006/`.
- `TALOS_SCHEMATIC_ID` - the ID generated at https://factory.talos.dev (see `terraform/variables.tf` for the current value, which also serves as the default).
- `VM_STATIC_IP` - LAN IP chosen for the Talos node (e.g. `192.168.80.30`).
- `VM_GATEWAY` - LAN gateway (e.g. `192.168.80.1`).
- `ARGOCD_REPO_URL` - optional, normally `https://github.com/cristsr/homelab` (the preflight already defaults to that value if you don't set it).

## 4. What's no longer needed

- Custom SELinux / sudoers modules - Proxmox is Debian without SELinux.
- `ansible/host-network.yaml` (firewalld port-forward) - with `vmbr0` bridged, the VM has a direct LAN IP.

## 5. CI SSH key for the data LXCs (`data_lxcs`)

`ansible/bootstrap-lxc-ssh.yaml` and `ansible/data-services.yaml` do need
SSH: the first connects to the Proxmox host and uses `pct exec` to seed the
CI pubkey into each LXC; the second connects directly to each LXC
(`10.10.20.31-35`) to install Podman and bring up the engine via Quadlet.

Steps:

1. Generate a key pair dedicated to CI (never reuse the operator's
   personal one) - `~/.ssh/cristian/homeserver_ci_ed25519` already exists for that
   purpose, comment `gh-actions-ci`.
2. Add the public key to `/root/.ssh/authorized_keys` on the Proxmox host - the
   hypervisor's LAN, Tailscale isn't needed for this manual step.
3. Upload the private key as secret `PROXMOX_SSH_PRIVATE_KEY` in
   **Settings → Environments → `prod` → Secrets**.
4. Also upload the credentials that `ansible/data-services.yaml` requires
   (same names as in `secrets/homelab.env`): `POSTGRESQL_APP_USERNAME`,
   `POSTGRESQL_APP_PASSWORD`, `MONGODB_APP_PASSWORD`, `REDIS_PASSWORD`,
   `QDRANT_API_KEY`, `SONARQUBE_DB_USERNAME`, `SONARQUBE_DB_PASSWORD`.

## 6. First `terraform apply` against the old state

The remote `terraform.tfstate` (R2) may still have references to the
`libvirt_*`/`tls_private_key` resources from the previous architecture (Fedora +
libvirt), which no longer physically exists. Before the first `apply` with this
code, that state needs to be reconciled - the simplest option is to reset the
state object in R2 (bucket `homelab-tfstate`, key `terraform.tfstate`) since
the infrastructure it described was destroyed along with the Fedora
hypervisor. Alternatively, `terraform state rm` each old resource one by
one if you'd prefer not to lose the state history.
