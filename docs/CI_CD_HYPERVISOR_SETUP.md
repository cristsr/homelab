# Setup del hipervisor para CI/CD (Proxmox VE)

> Runbook de lo que hay que aplicar en el hipervisor Proxmox y en GitHub para
> que el pipeline de CI/CD pueda aprovisionar/administrar el nodo Talos
> remotamente. Reemplaza el runbook anterior (Fedora + libvirt + SELinux),
> que ya no aplica: Proxmox no usa libvirt, y Talos no tiene SSH ni SELinux.
>
> A diferencia del runbook viejo, acá **no hace falta ninguna llave SSH**:
> Terraform habla con la API REST de Proxmox (token) y con la API de Talos
> (mTLS), y Ansible corre en `localhost` (el runner) usando el kubeconfig que
> Terraform ya dejó en disco.

## 1. Tailscale en el hipervisor + ruta de subred

El runner de GitHub Actions es hosted (no tiene acceso directo a la LAN del
homelab). Para que llegue tanto a la API de Proxmox (`:8006`) como a la IP
que le toque a la VM Talos, el nodo Tailscale del hipervisor debe advertir
la subred LAN completa:

```bash
sudo tailscale set --advertise-routes=192.168.80.0/24 --accept-routes
```

Y aprobar la ruta en el admin console de Tailscale (**Machines → homelab →
Edit route settings → habilitar la subred anunciada**). Sin este paso manual
la ruta queda advertida pero no enrutada.

Verificación desde cualquier maquina de la tailnet:

```bash
tailscale ping 192.168.80.20   # IP LAN del hipervisor
```

## 2. API token de Proxmox para Terraform

En la UI de Proxmox: **Datacenter → Permissions → API Tokens → Add**.
Usuario `terraform@pve` (o el que corresponda) con un token dedicado
(`ci` por ejemplo), **sin** "Privilege Separation" si el token necesita los
mismos permisos que el usuario, o con un rol acotado si se prefiere
principio de mínimo privilegio (necesita al menos permisos para crear/editar
VMs y descargar archivos al datastore).

El token completo tiene el formato `usuario@realm!tokenid=uuid` - ese string
completo es el valor de `TF_VAR_proxmox_api_token` / el secret
`PROXMOX_API_TOKEN` en GitHub.

## 3. Variables y secrets de GitHub

**Secrets** (Settings → Environments → `prod` → Secrets):
- `PROXMOX_API_TOKEN` - el token generado en el paso 2.
- `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` - backend remoto (sin cambios).
- `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` - OAuth client de Tailscale (sin cambios).
- `ANSIBLE_VAULT_PASSWORD` - sin cambios.

**Variables** (Settings → Environments → `prod` → Variables):
- `PROXMOX_ENDPOINT` - ej. `https://192.168.80.20:8006/`.
- `TALOS_SCHEMATIC_ID` - el ID generado en https://factory.talos.dev (ver `terraform/variables.tf` para el valor actual, que también sirve de default).
- `VM_STATIC_IP` - IP LAN elegida para el nodo Talos (ej. `192.168.80.30`).
- `VM_GATEWAY` - gateway de la LAN (ej. `192.168.80.1`).

## 4. Qué ya NO hace falta

- Llave SSH dedicada al hipervisor (`homeserver_ci_ed25519`) - Terraform ya no se conecta por SSH.
- Módulos SELinux / sudoers custom - Proxmox es Debian sin SELinux, y no hay nada que ejecutar por SSH.
- `ansible/host-network.yaml` (port-forward de firewalld) - con `vmbr0` bridged, la VM tiene IP LAN directa.

## 5. Primer `terraform apply` contra el state viejo

El `terraform.tfstate` remoto (R2) puede seguir teniendo referencias a los
recursos `libvirt_*`/`tls_private_key` de la arquitectura anterior (Fedora +
libvirt), que ya no existe físicamente. Antes del primer `apply` con este
código, hay que reconciliar ese state - la opción más simple es resetear el
objeto de state en R2 (bucket `homelab-tfstate`, key `terraform.tfstate`) ya
que la infraestructura que describía fue destruida junto con el hipervisor
Fedora. Alternativamente, `terraform state rm` cada recurso viejo uno por
uno si se prefiere no perder el historial de state.
