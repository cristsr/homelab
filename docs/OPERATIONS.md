# Manual Operativo

Guia de operacion, mantenimiento, troubleshooting y buenas practicas para el homelab.

---

## Indice

0. [Acceso SSH a la VM](#0-acceso-ssh-a-la-vm)
1. [Operaciones Diarias](#1-operaciones-diarias)
2. [Gestion de Secretos](#2-gestion-de-secretos)
3. [Backups](#3-backups)
4. [Actualizaciones](#4-actualizaciones)
5. [Escalado y Recursos](#5-escalado-y-recursos)
6. [Troubleshooting por Componente](#6-troubleshooting-por-componente)
7. [Procedimientos de Emergencia](#7-procedimientos-de-emergencia)
8. [Monitoreo y Alertas](#8-monitoreo-y-alertas)
9. [Mantenimiento del Nodo](#9-mantenimiento-del-nodo)
10. [Checklist Mensual](#10-checklist-mensual)
11. [Acceso Privado: LAN + Tailscale](#11-acceso-privado-lan--tailscale)

---

## 0. Acceso SSH a la VM

Toda esta guia asume que ya tenes `kubectl` funcionando contra el cluster. El nodo vive en una VM dentro de la red NAT interna de libvirt (`192.168.122.0/24`), no es alcanzable directo desde tu equipo ni desde la LAN — hay que saltar por el hipervisor fisico.

### 0.1 Topologia

```
[tu equipo] --SSH--> [hipervisor: 192.168.80.20 en LAN / IP Tailscale fuera de la LAN] --SSH (ProxyCommand)--> [VM: 192.168.122.10]
```

### 0.2 Claves necesarias

| Salto | Usuario | Clave |
|-------|---------|-------|
| Equipo de control -> Hipervisor | `cpuenguenan` (`hypervisor_ssh_user` en `terraform.tfvars`) | La clave dedicada del operador para ese hipervisor (la misma que usa CI via el secret `HOMESERVER_SSH_PRIVATE_KEY`) |
| Hipervisor -> VM | `fedora` | `terraform/generated/id_ed25519` (generada por Terraform, ver 0.4 si no la tenes local) |

> Si el hipervisor cambio de sistema operativo (p. ej. Ubuntu -> Fedora), su fingerprint SSH cambia por completo. Es esperado, no un MITM — confirmalo antes de aceptar el nuevo fingerprint (`ssh-keygen -R <ip>` para limpiar la entrada vieja de `known_hosts`).

### 0.3 Comando de conexion (ad-hoc)

Estando en la misma LAN que el hipervisor:

```bash
ssh -i <clave-hipervisor> \
  -o ProxyCommand="ssh -i <clave-hipervisor> -W %h:%p cpuenguenan@192.168.80.20" \
  -i terraform/generated/id_ed25519 \
  fedora@192.168.122.10
```

Fuera de la LAN, reemplaza `192.168.80.20` por la IP Tailscale del hipervisor.

### 0.3.1 Alias permanente (recomendado)

Mas comodo que repetir el comando cada vez — agregar a `~/.ssh/config`:

```
Host homelab-hipervisor
  HostName 192.168.80.20
  User cpuenguenan
  IdentityFile ~/.ssh/<clave-hipervisor>

Host homelab-vm
  HostName 192.168.122.10
  User fedora
  IdentityFile <ruta-al-repo>/terraform/generated/id_ed25519
  ProxyJump homelab-hipervisor
```

Y despues simplemente `ssh homelab-vm`.

### 0.4 Si no tenes `terraform/generated/id_ed25519` localmente

Terraform genera esta clave (`tls_private_key.vm` en `terraform/main.tf`) y solo queda en el filesystem de donde corrio el `apply`. Si el unico `apply` real fue via CI (GitHub Actions), el archivo nunca existio en tu equipo — el runner que lo genero ya no existe.

Se puede recuperar del Terraform state remoto (Cloudflare R2) sin tocar la infraestructura, es una operacion de solo lectura:

```bash
cd terraform
cp backend.hcl.example backend.hcl   # completar <ACCOUNT_ID>

export AWS_ACCESS_KEY_ID=<R2_ACCESS_KEY_ID>
export AWS_SECRET_ACCESS_KEY=<R2_SECRET_ACCESS_KEY>
terraform init -backend-config=backend.hcl

mkdir -p generated
jq -r '.resources[] | select(.type=="tls_private_key" and .name=="vm") | .instances[0].attributes.private_key_openssh' terraform.tfstate > generated/id_ed25519
jq -r '.resources[] | select(.type=="tls_private_key" and .name=="vm") | .instances[0].attributes.public_key_openssh' terraform.tfstate > generated/id_ed25519.pub
chmod 600 generated/id_ed25519
```

> **Windows / Git Bash**: el archivo puede quedar con terminadores CRLF, lo que rompe el parser de OpenSSH (`Load key ...: error in libcrypto`). Si pasa, corregir con:
> ```bash
> sed -i 's/\r$//' generated/id_ed25519
> ```
> Validar antes de usarla: `ssh-keygen -y -f generated/id_ed25519` (si tira error, la clave sigue corrupta).

Alternativa mas invasiva (sin necesitar el state remoto, requiere apagar la VM unos segundos): usar `virt-customize --ssh-inject fedora:file:<tu-clave>.pub` desde el hipervisor para inyectar una clave propia directo en el disco.

### 0.5 Ansible en Windows

`ansible-core` no corre nativo en Windows (falla con `AttributeError: module 'os' has no attribute 'get_blocking'`). Usar WSL:

```bash
wsl.exe -- bash -lc "cd /mnt/d/ruta/al/repo/ansible && ansible-playbook ..."
```

Los archivos montados desde NTFS (`/mnt/c`, `/mnt/d`) heredan permisos world-writable/world-executable, lo que hace que `ansible-vault` rechace `.vault-pass` con `Exec format error` (lo interpreta como script en vez de texto plano). Copialo a un path nativo de WSL antes de usarlo:

```bash
cp /mnt/d/.../.vault-pass /tmp/vault-pass && chmod 600 /tmp/vault-pass
ansible-vault encrypt_string '...' --name 'mi_var' --vault-password-file /tmp/vault-pass
```

Lo mismo aplica a cualquier clave SSH que uses desde WSL apuntando a un path bajo `/mnt/`: copiala a `/tmp/` y aplicale `chmod 600` antes de pasarsela a `ssh`/`ansible`.

---

## 1. Operaciones Diarias

### Verificar salud del cluster

```bash
# Estado general
kubectl get nodes
kubectl get pods -A

# Aplicaciones de ArgoCD
kubectl -n argocd get applications

# Eventos recientes
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

### Acceso rapido a servicios

| Servicio | Comando util |
|----------|-------------|
| ArgoCD | `kubectl -n argocd port-forward svc/argocd-server 8080:80` |
| OpenBao | `kubectl -n secret-management port-forward svc/openbao 8200:8200` |
| Grafana | `kubectl -n observability port-forward svc/grafana 3000:3000` |

### Reiniciar un deployment

```bash
kubectl rollout restart deployment/<nombre> -n <namespace>
```

### Ver logs de un pod

```bash
kubectl logs -f deployment/<nombre> -n <namespace> --tail=100
```

---

## 2. Gestion de Secretos

### Verificar sincronizacion de ExternalSecrets

```bash
# Listar todos los ExternalSecrets
kubectl get externalsecret -A

# Ver detalle de uno
kubectl describe externalsecret <nombre> -n <namespace>

# Logs del operador
kubectl -n secret-management logs deployment/external-secrets --tail=50
```

### Escribir un nuevo secret en OpenBao

```bash
# Port-forward a OpenBao
kubectl -n secret-management port-forward svc/openbao 8200:8200 &

# Login (necesitas root token o usar kubernetes auth)
export VAULT_ADDR=http://127.0.0.1:8200
bao login

# Escribir secret
bao kv put secret/mi-app/config \
  username="usuario" \
  password="contrasena"
```

### Crear un nuevo ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mi-app-secret
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: mi-app-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: mi-app/config
        property: username
    - secretKey: password
      remoteRef:
        key: mi-app/config
        property: password
```

Aplicar:

```bash
kubectl apply -f mi-externalsecret.yaml
```

---

## 3. Backups

### Backup de PostgreSQL (CloudNative-PG)

CloudNative-PG soporta backups continuos a S3. Verificar configuracion en:
`platform/data-platform/operators/cloudnative-pg/`

Backup manual:

```bash
kubectl -n data-platform exec -it postgresql-1 -- pg_dump -U admin homelab > backup.sql
```

### Backup de MongoDB

```bash
kubectl -n data-platform exec -it mongodb-rs0-0 -- mongodump --out /tmp/backup
```

### Backup de PersistentVolumes (Longhorn)

Longhorn soporta snapshots. Desde la UI de Longhorn o via kubectl:

```bash
kubectl -n longhorn-system get volumes
```

### Backup de configuracion de Ansible

El estado critico esta en:

```bash
# Variables cifradas
ansible/group_vars/all.yaml

# Contrasena del vault (NO versionar)
ansible/.vault-pass
```

> Guarda una copia de `all.yaml` y la contrasena del vault en un gestor de contrasenas seguro.

---

## 4. Actualizaciones

### Actualizar versiones de k0s/helm

Editar `ansible/group_vars/all.yaml`:

```yaml
k0s_version: v1.NEXT+k0s.0
helm_version: X.Y.Z
helmfile_version: X.Y.Z
```

Luego ejecutar:

```bash
cd ansible
ansible-playbook site.yaml --tags k0s,helm,helmfile
```

### Actualizar charts via ArgoCD

Las versiones de charts se definen en los manifiestos de `gitops/apps/` y `platform/`.

Para forzar una sincronizacion:

```bash
kubectl -n argocd patch application <nombre> --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

O desde la UI de ArgoCD: Applications > Sync.

### Actualizar imagenes de aplicaciones

Cambiar el tag en el manifiesto correspondiente en `gitops/apps/` o `platform/`.
ArgoCD sincronizara automaticamente si `selfHeal: true` esta activado.

---

## 5. Escalado y Recursos

### Ver uso de recursos

```bash
# Top de pods
kubectl top pods -A

# Top de nodos
kubectl top nodes

# Descripcion detallada del nodo
kubectl describe node
```

### Ajustar recursos de un deployment

Editar el manifiesto en `platform/` o `gitops/apps/` y aplicar cambios.

Ejemplo:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

---

## 6. Troubleshooting por Componente

### Cilium

```bash
# Estado de Cilium
kubectl -n kube-system get pods -l k8s-app=cilium

# Verificar conectividad
kubectl -n kube-system exec ds/cilium -- cilium status

# Politicas de red activas
kubectl get ciliumnetworkpolicy -A
```

### ArgoCD

```bash
# Logs del application controller
kubectl -n argocd logs deployment/argocd-application-controller --tail=100

# Forzar reconciliacion
kubectl -n argocd patch application <app> --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

# Resetear contrasena admin
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"admin.password": "nueva-contrasena", "admin.passwordMtime": "'$(date +%FT%T%Z)'"}}'
```

### cert-manager

```bash
# Estado de certificados
kubectl get certificate -A
kubectl get certificaterequest -A
kubectl get challenge -A

# Logs
kubectl -n networking logs deployment/cert-manager --tail=100

# Forzar renovacion
kubectl -n networking annotate certificate wildcard-home-tls cert-manager.io/force-renew="true"
```

### Longhorn

```bash
# Volumenes
kubectl -n longhorn-system get volumes

# Nodos de almacenamiento
kubectl -n longhorn-system get nodes

# UI de Longhorn
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

### OpenBao

```bash
# Estado
kubectl -n secret-management exec openbao-0 -- bao status

# Unseal manual
kubectl -n secret-management exec -it openbao-0 -- bao operator unseal <UNSEAL_KEY>

# Listar secrets
kubectl -n secret-management exec openbao-0 -- bao kv list secret/
```

### External Secrets Operator

```bash
# Estado del ClusterSecretStore
kubectl get clustersecretstore openbao -o yaml

# Estado de ExternalSecrets
kubectl get externalsecret -A
kubectl describe externalsecret <nombre> -n <namespace>

# Logs
kubectl -n secret-management logs deployment/external-secrets --tail=100
```

---

## 7. Procedimientos de Emergencia

### Perdida del nodo

1. Reinstalar el sistema operativo.
2. Restaurar las dependencias base (git, pipx, ansible).
3. Clonar el repositorio.
4. Restaurar `ansible/group_vars/all.yaml` (debe tener backup seguro).
5. Recrear `ansible/.vault-pass` con la contrasena del vault.
6. Ejecutar `ansible-playbook site.yaml`.
7. Restaurar backups de bases de datos si es necesario.

### OpenBao sellado y sin acceso

Si no tienes la `openbao_static_seal_key`, el contenido del vault es irrecuperable.

Con la key:

```bash
kubectl -n secret-management exec -it openbao-0 -- bao operator unseal <KEY>
```

### Recrear el cluster desde cero

```bash
cd ansible
ansible-playbook teardown.yaml  # Confirma con 'yes'
ansible-playbook site.yaml
kubectl apply -f ../gitops/root-app.yaml
ansible-playbook vault-populate.yaml
```

> **ADVERTENCIA**: Todos los datos persistentes en Longhorn con `Delete` reclaim policy se perderan.

---

## 8. Monitoreo y Alertas

### Metricas clave a observar

| Metrica | Umbral de alerta | Comando |
|---------|-----------------|---------|
| Uso de disco nodo | > 80% | `df -h` |
| Uso de RAM nodo | > 85% | `free -h` |
| Pods en estado Error/CrashLoopBackOff | > 0 | `kubectl get pods -A | grep -v Running` |
| Certificados proximos a expirar | < 7 dias | `kubectl get certificate -A` |
| Volumenes Longhorn degradados | > 0 | `kubectl -n longhorn-system get volumes` |

### Dashboards de Grafana

Accede a `https://grafana.cristianpuenguenan.online` y revisa:
- **Node Exporter Full**: Metricas del host.
- **Kubernetes / Compute Resources / Cluster**: Uso de recursos del cluster.
- **Longhorn**: Estado de volumenes.

---

## 9. Mantenimiento del Nodo

### Reinicio del servidor fisico

Los pods se reiniciaran automaticamente. Componentes criticos como k0s y Cilium arrancan como servicios systemd.

**Verificacion post-reinicio**:

```bash
kubectl get nodes
kubectl -n kube-system get pods
kubectl -n argocd get applications
```

> Recuerda que OpenBao puede quedar sellado tras un reinicio. Ejecuta unseal si es necesario.

### Limpieza de imagenes Docker/containerd

k0s usa containerd internamente. Para limpiar imagenes no usadas:

```bash
sudo k0s ctr images prune
```

### Limpieza de logs

```bash
# Logs de systemd
sudo journalctl --vacuum-time=7d

# Logs de pods (si persisten en disco)
sudo find /var/log/pods -type f -mtime +7 -delete
```

---

## 10. Checklist Mensual

- [ ] Revisar estado de todas las aplicaciones en ArgoCD.
- [ ] Verificar certificados TLS no esten proximos a expirar.
- [ ] Revisar uso de disco en el nodo (`df -h`).
- [ ] Verificar backups de bases de datos esten actualizados.
- [ ] Revisar logs de External Secrets Operator.
- [ ] Confirmar que OpenBao este operativo (no sellado).
- [ ] Verificar metricas en Grafana.
- [ ] Revisar actualizaciones de seguridad del sistema operativo.
- [ ] Revisar actualizaciones de k0s, Cilium y charts criticos.
- [ ] Confirmar que `.vault-pass` y backups de `group_vars/all.yaml` esten seguros.

---

## 11. Acceso Privado: LAN + Tailscale

Ver [ADR-011](DECISIONS.md). Las rutas de administración (todas menos `portfolio` y `api` `/webhooks`) no son públicas — se accede por IP fija de cada Gateway (`192.168.122.240` Cilium, `192.168.122.250` Agent Gateway), desde la LAN física o desde Tailscale.

### 11.1 Configurar el subnet router de Tailscale (una sola vez)

En el hipervisor:

```bash
sudo tailscale up --ssh --advertise-routes=192.168.122.0/24 --accept-routes
```

Luego aprobar la ruta en [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines) → `homelab` → Edit route settings → habilitar `192.168.122.0/24`. Sin este paso manual, Tailscale acepta el anuncio pero no rutea tráfico por él.

Verificar desde cualquier dispositivo en tu tailnet (podés estar en cualquier lado, no hace falta estar en la LAN de casa):

```bash
curl -H "Host: argocd.cristianpuenguenan.online" http://192.168.122.240/
```

### 11.2 Acceso desde la LAN física (sin Tailscale)

Ya resuelto por `ansible/host-network.yaml` — `80/443` del host (`192.168.80.20`) reenvía a `192.168.122.240` (Cilium), `8080/8443` a `192.168.122.250` (Agent Gateway).

### 11.3 Resolver los hostnames sin Split DNS

No hay DNS interno configurado todavía — agregá el hostname a tu `hosts` file local (`/etc/hosts` o `C:\Windows\System32\drivers\etc\hosts`) apuntando a la IP correspondiente, por ejemplo:

```
192.168.122.240 argocd.cristianpuenguenan.online grafana.cristianpuenguenan.online longhorn.cristianpuenguenan.online
192.168.122.250 agentgateway.cristianpuenguenan.online mcp.cristianpuenguenan.online openmemory-api.cristianpuenguenan.online
```

### 11.4 Qué es público y qué no (sin lista que mantener)

Cloudflare no tiene una entrada por ruta — hay un único wildcard (`*.cristianpuenguenan.online`) apuntando a `cilium-gateway-public.networking.svc.cluster.local:80`. Lo que es público lo decide **dónde vive el `HTTPRoute`** en el código, no una lista en el dashboard:

- `HTTPRoute` con `parentRefs: [{name: public}]` → alcanzable desde Internet.
- `HTTPRoute` con `parentRefs: [{name: main}]` o `[{name: agentgateway-mcp}]` → nunca alcanzado por el wildcard, solo por LAN/Tailscale (§11.1-11.3).

Para hacer pública una ruta nueva: agregar su `HTTPRoute` con `parentRefs: [{name: public, namespace: networking}]` (ver `workloads/portfolio/httproute.yaml` como ejemplo) — no hace falta tocar nada en Cloudflare. Para hacer privada una que hoy es pública: cambiar su `parentRefs` a `main` (o `agentgateway-mcp` si depende de MCP).

En [dash.cloudflare.com](https://dash.cloudflare.com) → Zero Trust → Networks → Tunnels → túnel del homelab → Public Hostnames, la única entrada a mantener es el wildcard apuntando a `cilium-gateway-public` — no se toca al agregar o quitar rutas privadas.

---

## Contacto y Referencias

- Repositorio: `https://github.com/cristsr/homelab`
- Documentacion k0s: https://docs.k0sproject.io
- Documentacion Cilium: https://docs.cilium.io
- Documentacion ArgoCD: https://argo-cd.readthedocs.io
- Documentacion OpenBao: https://openbao.org/docs/
