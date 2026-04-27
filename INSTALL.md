# Guía de Instalación

Punto de partida: MicroK8s 1.32 instalado y limpio. El cluster debe estar en estado `Ready` antes de comenzar.

---

## Índice

1. [Preparar MicroK8s](#1-preparar-microk8s)
2. [Clonar el repositorio](#2-clonar-el-repositorio)
3. [Configurar secrets y contraseñas](#3-configurar-secrets-y-contraseñas)
4. [Crear namespaces](#4-crear-namespaces)
5. [Instalar Cilium (CNI)](#5-instalar-cilium-cni)
6. [Instalar Argo CD](#6-instalar-argo-cd)
7. [Crear secrets de aplicaciones](#7-crear-secrets-de-aplicaciones)
8. [Activar GitOps](#8-activar-gitops)
   - [8.1 Registrar repositorio privado en ArgoCD](#81-registrar-repositorio-privado-en-argocd)
   - [8.2 Aplicar la root-app](#82-aplicar-la-root-app)
   - [8.3 Desbloquear el sync inicial de Longhorn](#83-desbloquear-el-sync-inicial-de-longhorn)
9. [Verificar el despliegue](#9-verificar-el-despliegue)
10. [Acceder a los servicios](#10-acceder-a-los-servicios)
11. [Configurar DNS y certificados](#11-configurar-dns-y-certificados)

---

## 1. Preparar MicroK8s

Deshabilitar los addons que entran en conflicto con Cilium y APISIX:

```bash
microk8s disable dns
microk8s disable ingress
microk8s disable ha-cluster
```

> `dns` se deshabilita para evitar conflictos durante la inicialización del CNI. Se vuelve a habilitar en el paso 5 después de instalar Cilium.

Verificar que el nodo está listo:

```bash
microk8s kubectl get nodes
# NAME   STATUS   ROLES    AGE   VERSION
# ...    Ready    <none>   ...   v1.32.x
```

Agregar alias para comodidad (opcional):

```bash
alias kubectl='microk8s kubectl'
alias helm='microk8s helm'
```

---

## 2. Clonar el repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar secrets y contraseñas

Antes de activar GitOps hay que reemplazar los valores `REEMPLAZAR_CON_*` en los archivos de values. Estos valores quedan commiteados en el repo — **usar contraseñas reales, no las de ejemplo**.

### 3.1 APISIX Admin Key

Generar una clave aleatoria:

```bash
openssl rand -hex 32
```

Editar `platform/infra/apisix/values.yaml` y reemplazar:

```yaml
adminKey: "REEMPLAZAR_CON_ADMIN_KEY"
# por:
adminKey: "tu-clave-generada"
```

### 3.2 Grafana

`platform/monitoring/values.yaml`:
```yaml
grafana:
  adminPassword: "tu-password-grafana"
```

### 3.3 Commitear los cambios

```bash
git add platform/infra/apisix/values.yaml platform/monitoring/values.yaml
git commit -m "chore: set passwords and secrets"
git push
```

> Las contraseñas de bases de datos (PostgreSQL, MongoDB, Redis) **no se commitean** — se crean como Kubernetes Secrets en el paso 7.

---

## 4. Crear namespaces

```bash
microk8s kubectl apply -f bootstrap/namespaces.yaml
```

Verificar:

```bash
microk8s kubectl get namespaces | grep -E 'infra|cert-manager|databases|dev-tools|apps|monitoring'
```

---

## 5. Instalar Cilium (CNI)

Cilium reemplaza el CNI por defecto de MicroK8s. Debe instalarse **antes** que cualquier otra cosa.

```bash
microk8s helm repo add cilium https://helm.cilium.io
microk8s helm repo update

microk8s helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.6 \
  -f bootstrap/cilium/values.yaml
```

Esperar a que los pods estén listos (puede tardar 2-3 minutos):

```bash
microk8s kubectl -n kube-system rollout status daemonset/cilium
microk8s kubectl -n kube-system get pods -l k8s-app=cilium
```

Verificar que el nodo sigue en estado `Ready`:

```bash
microk8s kubectl get nodes
```

> Si el nodo queda en `NotReady` después de instalar Cilium, reiniciar MicroK8s:
> `sudo snap restart microk8s`

Volver a habilitar CoreDNS (se deshabilitó en el paso 1 para evitar conflictos durante la instalación del CNI):

```bash
microk8s enable dns
microk8s kubectl -n kube-system rollout status deployment/coredns
```

---

## 6. Instalar Argo CD

Argo CD se instala manualmente una sola vez. A partir de aquí gestiona todo lo demás.

```bash
microk8s helm repo add argo https://argoproj.github.io/argo-helm
microk8s helm repo update

microk8s helm upgrade --install argocd argo/argo-cd \
  --namespace infra \
  --version 7.8.0 \
  -f bootstrap/argocd/values.yaml
```

Esperar a que todos los pods estén listos:

```bash
microk8s kubectl -n infra rollout status deployment/argocd-server
microk8s kubectl -n infra get pods -l app.kubernetes.io/name=argocd-server
```

Obtener la contraseña inicial del admin:

```bash
microk8s kubectl -n infra get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

> Guardar esta contraseña. Se puede cambiar después desde la UI de ArgoCD en `User Info → Update Password`.

---

## 7. Crear secrets de aplicaciones

Estos secrets **nunca se commitean** al repositorio. Se crean directamente en el cluster.

Los comandos son idempotentes: crean el secret si no existe o lo actualizan si ya existe.

```bash
# PostgreSQL
microk8s kubectl create secret generic postgresql-secret \
  --from-literal=postgres-password=TU_PASSWORD_POSTGRES \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# MongoDB
microk8s kubectl create secret generic mongodb-secret \
  --from-literal=root-password=TU_PASSWORD_MONGO \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# Redis
microk8s kubectl create secret generic redis-secret \
  --from-literal=redis-password=TU_PASSWORD_REDIS \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

```bash
# Flow API
microk8s kubectl create secret generic flow-secrets \
  --from-literal=database-url="postgresql://postgres:TU_PASSWORD@postgresql.databases.svc.cluster.local:5432/homelab" \
  --from-literal=redis-url="redis://:TU_PASSWORD_REDIS@redis-master.databases.svc.cluster.local:6379" \
  -n apps \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# OpenMemory
microk8s kubectl create secret generic openmemory-secrets \
  --from-literal=OPENAI_API_KEY=sk-... \
  -n dev-tools \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# SonarQube (password de PostgreSQL)
microk8s kubectl create secret generic sonarqube-db-secret \
  --from-literal=password=TU_PASSWORD_POSTGRES \
  -n dev-tools \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 7.4 Cloudflare — cert-manager (DNS01 challenge)

Crear el token en Cloudflare → My Profile → API Tokens.  
Permisos necesarios: `Zone:DNS:Edit` para el dominio `cristianpuenguenan.online`.

```bash
microk8s kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=TU_CLOUDFLARE_API_TOKEN \
  -n cert-manager \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 7.5 Cloudflare — cloudflared (Tunnel)

Crear el túnel en Cloudflare → Zero Trust → Networks → Tunnels → Create Tunnel.  
Copiar el token que aparece al crearlo.

```bash
microk8s kubectl create secret generic cloudflared-token \
  --from-literal=token=TU_CLOUDFLARE_TUNNEL_TOKEN \
  -n infra \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

> Estos dos secrets deben existir **antes** de aplicar la root-app. ArgoCD no los gestiona (están excluidos del sync) — son responsabilidad del operador.

---

## 8. Activar GitOps

### 8.1 Registrar repositorio privado en ArgoCD

Como el repositorio es privado, ArgoCD necesita credenciales para clonar el código. Crear un [Personal Access Token (PAT)](https://github.com/settings/tokens) en GitHub con scope `repo` (solo lectura es suficiente).

```bash
microk8s kubectl -n infra create secret generic homelab-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cristsr/homelab \
  --from-literal=username=cristsr \
  --from-literal=password=TU_GITHUB_PAT \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

microk8s kubectl -n infra label secret homelab-repo \
  argocd.argoproj.io/secret-type=repository \
  --overwrite
```

Verificar que ArgoCD reconoció el repositorio:

```bash
microk8s kubectl -n infra get secrets -l argocd.argoproj.io/secret-type=repository
```

### 8.2 Aplicar la root-app

Con ArgoCD corriendo, los secrets de aplicaciones en su lugar y el repositorio registrado, aplicar la root-app. A partir de aquí ArgoCD despliega todo el stack automáticamente siguiendo los sync-waves.

```bash
microk8s kubectl apply -f gitops/root-app.yaml
```

> La advertencia `metadata.finalizers: prefer a domain-qualified finalizer name` es un falso positivo de kubectl — no afecta el funcionamiento.

ArgoCD comenzará a sincronizar en este orden:

| Wave | Componentes |
|------|-------------|
| 1 | Longhorn, cert-manager |
| 2 | cert-manager-config (ClusterIssuer + Certificate wildcard) |
| 3 | APISIX |
| 4 | apisix-config (Routes, PluginConfigs, TLS) |
| 5 | kube-prometheus-stack, cloudflared, headlamp |
| 6 | PostgreSQL, MongoDB, Redis, Qdrant, ServiceMonitors |
| 7 | NetworkPolicies de bases de datos |
| 8 | SonarQube, OpenMemory |
| 9 | Flow API |

Seguir el progreso en tiempo real:

```bash
microk8s kubectl -n infra get applications -w
```

Si la root-app queda en `Unknown` o hay que forzar un re-sync (por ejemplo tras corregir un secret o cambiar configuración):

```bash
microk8s kubectl -n infra patch application root --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

### 8.3 Desbloquear el sync inicial de Longhorn

El chart de Longhorn incluye un hook de pre-upgrade que necesita `longhorn-service-account` para crear su pod, pero esa ServiceAccount la crea el propio chart durante el sync principal. En una instalación nueva esto genera un círculo vicioso: el hook falla → el sync nunca avanza → la ServiceAccount nunca se crea.

Romper el bloqueo manualmente:

```bash
microk8s kubectl create serviceaccount longhorn-service-account -n infra

microk8s kubectl create clusterrolebinding longhorn-pre-upgrade-temp \
  --clusterrole=cluster-admin \
  --serviceaccount=infra:longhorn-service-account

microk8s kubectl delete job -n infra longhorn-pre-upgrade 2>/dev/null || true
```

> El ClusterRoleBinding temporal `longhorn-pre-upgrade-temp` queda huérfano tras el sync — ArgoCD crea el definitivo (`longhorn-bind`). Se puede borrar después con `microk8s kubectl delete clusterrolebinding longhorn-pre-upgrade-temp`.

Esperar a que Longhorn sincronice antes de continuar (puede tardar 2-3 minutos):

```bash
microk8s kubectl get pods -n infra -l app=longhorn-manager -w
```

---

## 9. Verificar el despliegue

Comprobar que todas las Applications están en `Synced` / `Healthy`:

```bash
microk8s kubectl -n infra get applications
```

Verificar pods por namespace:

```bash
microk8s kubectl get pods -n infra
microk8s kubectl get pods -n cert-manager
microk8s kubectl get pods -n databases
microk8s kubectl get pods -n monitoring
microk8s kubectl get pods -n dev-tools
microk8s kubectl get pods -n apps
```

> cloudflared estará `Degraded` hasta que se configuren los registros DNS en el paso 11. El resto del stack debe estar `Healthy`.

---

## 10. Acceder a los servicios

Todos los servicios son accesibles en `https://<subdominio>.cristianpuenguenan.online` desde la LAN.

| URL | Servicio | Credenciales |
|-----|---------|--------------|
| `https://argocd.cristianpuenguenan.online` | Argo CD | `admin` / contraseña del paso 6 |
| `https://grafana.cristianpuenguenan.online` | Grafana | `admin` / contraseña configurada en paso 3.3 |
| `https://apisix.cristianpuenguenan.online` | APISIX Dashboard | `admin` / `admin` (cambiar al entrar) |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Token de ServiceAccount |
| `https://hubble.cristianpuenguenan.online` | Hubble UI (Cilium) | Sin auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | `admin` / `admin` (cambiar al entrar) |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | Sin auth |

### Token para Headlamp

```bash
microk8s kubectl create token headlamp -n infra
```

---

## 11. Configurar DNS y certificados

Los secrets de Cloudflare ya fueron creados en el paso 7. Este paso configura los registros DNS y verifica que el certificado wildcard se haya emitido correctamente.

### 11.1 Configurar DNS

Agregar registros A en Cloudflare apuntando a la IP del nodo (`192.168.80.20`).

| Registro | Tipo | Valor | Proxy |
|---|---|---|---|
| `cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |

> Usar **DNS only** (nube gris) para los subdominios internos. Solo activar proxy para los que se expongan públicamente vía Cloudflare Tunnel.

### 11.2 Verificar el certificado

El certificado wildcard debería emitirse en 5-10 minutos tras configurar el DNS:

```bash
microk8s kubectl get certificate -n infra
# wildcard-home-tls   True   ...
```

Si sigue en `False`, revisar el estado del `CertificateRequest`:

```bash
microk8s kubectl describe certificaterequest -n infra
```

---

## Troubleshooting rápido

**Pods en Pending tras instalar Cilium**
```bash
microk8s kubectl describe pod <pod> -n <ns>
# Buscar eventos relacionados con CNI o scheduling
sudo snap restart microk8s
```

**Certificado en estado `False`**
```bash
microk8s kubectl describe certificaterequest -n infra
# Verificar que el secret cloudflare-api-token existe y tiene el token correcto
microk8s kubectl get secret cloudflare-api-token -n cert-manager
```

**Application de ArgoCD en `Unknown` sync status**
```bash
# Causa más común: repositorio privado sin credenciales registradas.
# Verificar que el secret del repo existe:
microk8s kubectl -n infra get secrets -l argocd.argoproj.io/secret-type=repository
# Si no existe, seguir el paso 8.1.
# Forzar re-sync tras crear las credenciales:
microk8s kubectl -n infra patch application root \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

**Application de ArgoCD en `OutOfSync`**
```bash
microk8s kubectl -n infra get application <nombre> -o yaml
# Forzar sync manual:
# Desde la UI de ArgoCD → Sync → Force
```

**APISIX sin rutas activas**
```bash
microk8s kubectl get apisixroute -n infra
# Si están vacías, verificar que apisix-config está en Synced
```

**Bases de datos en `Unknown` / pods en `ImagePullBackOff`**
```bash
# Diagnóstico del Application:
microk8s kubectl -n infra get application postgresql \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Diagnóstico del pod:
microk8s kubectl describe pod -n databases <pod> | grep -A10 Events

# Hard refresh para forzar re-evaluación:
for app in postgresql mongodb redis; do
  microk8s kubectl -n infra annotate application $app \
    argocd.argoproj.io/refresh=hard --overwrite
done
```

**ArgoCD Application atascada en operación `Running` (hook Job que no existe)**
```bash
# Síntoma: operationState.message = "waiting for completion of hook batch/Job/..."
# pero el Job no existe en el namespace.
microk8s kubectl -n infra get application <nombre> \
  -o jsonpath='{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'

# Solución: eliminar la Application y dejar que root-app la recree limpia.
microk8s kubectl delete application -n infra <nombre>
microk8s kubectl -n infra patch application root --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```
