# Manual Operativo

Guia de operacion, mantenimiento, troubleshooting y buenas practicas para el homelab.

---

## Indice

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

## Contacto y Referencias

- Repositorio: `https://github.com/cristsr/homelab`
- Documentacion k0s: https://docs.k0sproject.io
- Documentacion Cilium: https://docs.cilium.io
- Documentacion ArgoCD: https://argo-cd.readthedocs.io
- Documentacion OpenBao: https://openbao.org/docs/
