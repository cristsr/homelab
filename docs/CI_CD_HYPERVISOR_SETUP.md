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

## 1. Tailscale en el hipervisor + ruta de subred (acotada, no el /24 completo)

El runner de GitHub Actions es hosted (no tiene acceso directo a la LAN del
homelab). Para que llegue a la API de Proxmox (`:8006`) y a la VM Talos, el
nodo Tailscale del hipervisor tiene que advertir esos hosts - **no la subred
`/24` completa**: anunciar todo `192.168.80.0/24` hace que cualquier
maquina de la tailnet con "accept routes" (incluida la del operador) enrute
TODO ese rango a traves del tunel, rompiendo el acceso directo por LAN a
los demas dispositivos de la red local.

La VM Talos tiene una MAC fija (`var.vm_mac_address` en
`terraform/infra/variables.tf`, default `02:00:00:00:00:30`) precisamente
para poder reservarle `var.vm_static_ip` por DHCP en el router - asi el boot
en modo mantenimiento (antes de que Talos aplique su config de red estatica)
ya cae en esa IP conocida, en vez de una IP random del pool DHCP. Sin esa
reserva, acotar la ruta de Tailscale a hosts puntuales rompe
`talos_machine_configuration_apply` (no hay forma de saber de antemano que
IP le va a tocar en modo mantenimiento).

Pasos:

1. En el router: reservar `var.vm_static_ip` (ej. `192.168.80.30`) a la MAC
   `var.vm_mac_address` (ej. `02:00:00:00:00:30`).
2. En el hipervisor:
   ```bash
   sudo tailscale set --advertise-routes=192.168.80.20/32,192.168.80.30/32 --accept-routes
   ```
   (ajustar las IPs si `PROXMOX_ENDPOINT`/`VM_STATIC_IP` son distintas).
3. En el admin console de Tailscale (**Machines → homelab → Edit route
   settings**): deshabilitar la ruta vieja `192.168.80.0/24` si estaba
   aprobada, y habilitar las dos rutas `/32` nuevas. Sin este paso manual
   las rutas quedan advertidas pero no enrutadas.

Verificación desde cualquier maquina de la tailnet:

```bash
tailscale ping 192.168.80.20   # IP LAN del hipervisor
tailscale ping 192.168.80.30   # IP LAN de la VM Talos
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
