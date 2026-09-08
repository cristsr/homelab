# Setup del hipervisor para CI/CD

> Runbook de todo lo que hay que aplicar **en el servidor físico (Fedora)** para que
> GitHub Actions pueda provisionar/administrar la VM remotamente (ver
> [ADR-009](DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2)).
> No cubre la configuración de cuenta (Tailscale ACL/OAuth client, Cloudflare R2,
> GitHub Secrets/Vars) — eso ya está hecho; ver el checklist de la Fase 0 si hay
> que rehacerlo desde cero.
>
> Todo lo de acá es idempotente: correrlo de nuevo sobre un servidor ya
> configurado no rompe nada.

## 1. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --advertise-tags=tag:ci-target
tailscale ip -4   # anotar -> variable HYPERVISOR_TAILSCALE_IP en GitHub
```

**Importante:** desactivar el SSH propio de Tailscale inmediatamente después.
`--ssh` activa un servidor SSH que intercepta el puerto 22 y autoriza por
identidad de tailnet (política `ssh` del ACL), no por `authorized_keys` — con
la política ACL actual, un nodo taggeado (`tag:ci-target`) deja de ser "self"
de nadie y queda bloqueado para todos. Este proyecto usa clave SSH dedicada +
sshd clásico, no Tailscale SSH:

```bash
sudo tailscale set --ssh=false
```

## 2. Clave SSH dedicada para CI

En tu propia máquina (no en el servidor):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homeserver_ci_ed25519 -N "" -C "gh-actions-ci"
cat ~/.ssh/homeserver_ci_ed25519.pub
```

En el servidor, agregar esa pública (con tu acceso SSH normal):

```bash
echo '<PEGAR_LA_PUBLICA>' >> ~/.ssh/authorized_keys
groups | grep -o libvirt || sudo usermod -aG libvirt "$USER"   # relogin si hizo falta
```

Probar el salto completo:

```bash
ssh -i ~/.ssh/homeserver_ci_ed25519 <usuario>@<ip_tailscale> "id && virsh -c qemu:///system list"
```

## 3. SELinux — permitir que sshd haga de proxy hacia libvirt y hacia la VM

Fedora trae SELinux enforcing por default. `sshd_session_t` (el dominio de
una sesión SSH) no tiene permiso, de fábrica, para:

1. Abrir (`write`) el socket de libvirt (`virtqemud_var_run_t`) — necesario
   para que `qemu+ssh://` de Terraform llegue a libvirt.
2. Conectarse (`connectto`) al `unix_stream_socket` del dominio `virtqemud_t`
   que atiende ese socket.
3. Abrir una conexión TCP saliente (`name_connect` sobre `ssh_port_t`) hacia
   el puerto 22 — necesario para el `ProxyCommand -W %h:%p` que usa Ansible
   para saltar del hipervisor a la VM (red NAT interna 192.168.122.0/24).

El booleano clásico `sshd_can_network_connect` **no existe** en esta versión
de la política (el dominio `sshd_session_t` es más nuevo que ese booleano).
La solución es un módulo de política custom, generado una sola vez a partir
de los AVC ya conocidos — no hace falta re-disparar los errores a mano:

```bash
sudo dnf install -y policycoreutils-python-utils checkpolicy

cat <<'EOF' | audit2allow -M libvirt_ssh_ci
type=AVC msg=audit(0:0): avc:  denied  { write } for  pid=0 comm="sshd-session" name="virtqemud-sock" dev="tmpfs" ino=0 scontext=system_u:system_r:sshd_session_t:s0-s0:c0.c1023 tcontext=system_u:object_r:virtqemud_var_run_t:s0 tclass=sock_file permissive=0
type=AVC msg=audit(0:0): avc:  denied  { connectto } for  pid=0 comm="sshd-session" path="/run/libvirt/virtqemud-sock" scontext=system_u:system_r:sshd_session_t:s0-s0:c0.c1023 tcontext=system_u:system_r:virtqemud_t:s0 tclass=unix_stream_socket permissive=0
type=AVC msg=audit(0:0): avc:  denied  { name_connect } for  pid=0 comm="sshd-session" dest=22 scontext=system_u:system_r:sshd_session_t:s0-s0:c0.c1023 tcontext=system_u:object_r:ssh_port_t:s0 tclass=tcp_socket permissive=0
EOF

sudo semodule -i libvirt_ssh_ci.pp
```

Verificación (no debería aparecer ningún AVC nuevo con `sshd_session_t` como
`scontext` después de correr el pipeline):

```bash
sudo ausearch -m avc -ts recent | grep sshd_session_t
```

Si en el futuro aparece un AVC *nuevo* con este mismo patrón (otro `tclass`),
el flujo de diagnóstico es:

```bash
sudo ausearch -m avc -ts recent | grep sshd_session_t | audit2allow -M <nombre-nuevo>
sudo semodule -i <nombre-nuevo>.pp
```

## 3.5. SELinux — etiquetar el pool de libvirt en `/home`

`/var/lib/libvirt/images` ya viene etiquetado por la política default con el
contexto `virt_image_t`, que es el que necesita libvirtd/qemu para leer y
escribir los discos de la VM. El pool de este módulo (`terraform/variables.tf`
`pool_path`) vive en `/home/libvirt/images/homelab` en vez de la ruta default
porque la partición raíz de este hipervisor tiene solo ~50GB — insuficiente
para el disco raíz de la VM (120GB) más el disco dedicado de OpenEBS (100GB).
`/home` no tiene ese contexto por defecto, así que sin este paso `terraform
apply` falla (o libvirtd rechaza leer/escribir los volúmenes) con un AVC
`denied` sobre `virt_image_t`/`home_root_t` — mismo patrón que los AVC de
`sshd_session_t` de arriba, pero en el dominio `virtqemud_t`/`svirt_t`.

```bash
sudo mkdir -p /home/libvirt/images
sudo semanage fcontext -a -t virt_image_t '/home/libvirt(/.*)?'
sudo restorecon -R -v /home/libvirt
```

**Ojo con el patrón del `fcontext`**: tiene que cubrir `/home/libvirt` completo, no
solo `/home/libvirt/images`. SELinux exige permiso `search` en *cada* directorio
intermedio del path — si solo se etiqueta `images/`, `/home/libvirt` (el
directorio padre) se queda con la equivalencia default de `/home/<algo>`
(`user_home_dir_t`, pensada para el home personal de un usuario), y
`virtqemud_t`/`svirt_t` no tienen permiso de `search` ahí. Confirmado
empíricamente en este host (2026-09-08): con solo `images/` etiquetado,
`ls -laZ /home/libvirt` seguía mostrando `user_home_dir_t` en el padre.

Verificación (después del primer `terraform apply`, no debería aparecer
ningún AVC nuevo sobre este path):

```bash
sudo ausearch -m avc -ts recent | grep -i 'home/libvirt'
```

## 4. sudo para Ansible (`host-network.yaml`)

Ansible ejecuta sus módulos (incluido `ansible.builtin.command`) copiando un
wrapper Python a un path temporal aleatorio y corriéndolo vía `sudo` — por
eso **no es posible** restringir el sudoers a un solo binario (ej.
`firewall-cmd`): sudo nunca ve ese binario directamente, ve el intérprete
Python del wrapper. La única opción funcional es NOPASSWD sin restricción de
comando para el usuario de CI:

```bash
echo 'cpuenguenan ALL=(root) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/ci-firewall-cmd
sudo chmod 440 /etc/sudoers.d/ci-firewall-cmd
sudo visudo -c
```

Aceptado como trade-off razonable: este mismo usuario ya está en el grupo
`libvirt`, que de por sí es un camino directo a root (se le puede adjuntar a
una VM el filesystem del host como disco). Restringir sudo a un comando no
cierra ese vector de todos modos.

Verificación:

```bash
sudo -n whoami   # debe imprimir "root" sin pedir password
```

## 5. Qué NO hace falta tocar a mano

- **firewalld**: viene activo por default en Fedora Server/Workstation; el
  playbook `host-network.yaml` configura el `masquerade` y el forward-port
  (80/443 → VM) solo, no requiere setup previo más allá del punto 4.
- **libvirt / daemons modulares**: Fedora ya trae `virtqemud.socket` activo
  por default; no hace falta habilitar nada extra ahí. Ver
  [ADR-009 / memoria del proyecto] si algún día el socket real cambia de
  path — el que usa `terraform/provider.tf` hoy es
  `/run/libvirt/virtqemud-sock`.
