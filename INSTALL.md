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
7. [Crear secrets manuales en Kubernetes](#7-crear-secrets-manuales-en-kubernetes)
8. [Configurar DNS](#8-configurar-dns)
9. [Activar GitOps](#9-activar-gitops)
10. [Verificar el despliegue](#10-verificar-el-despliegue)
11. [Acceder a los servicios](#11-acceder-a-los-servicios)

---

## 1. Preparar MicroK8s

Deshabilitar los addons que entran en conflicto con Cilium y APISIX:

```bash
microk8s disable dns
microk8s disable ingress
microk8s disable ha-cluster
```

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

### 3.2 Contraseñas de bases de datos

**PostgreSQL** — `platform/databases/postgresql/values.yaml`:
```yaml
auth:
  postgresPassword: "tu-password-postgres"
```

**MongoDB** — `platform/databases/mongodb/values.yaml`:
```yaml
auth:
  rootPassword: "tu-password-root"
  # y el password del usuario si aplica
```

**Redis** — `platform/databases/redis/values.yaml`:
```yaml
auth:
  password: "tu-password-redis"
```

### 3.3 Grafana

`platform/monitoring/values.yaml`:
```yaml
grafana:
  adminPassword: "tu-password-grafana"
```

### 3.4 Commitear los cambios

```bash
git add platform/
git commit -m "chore: set passwords and secrets"
git push
```

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

## 7. Crear secrets manuales en Kubernetes

Estos secrets **nunca se commitean** al repositorio. Se crean directamente en el cluster.

### Cloudflare API Token (para cert-manager)

Crear el token en https://dash.cloudflare.com → My Profile → API Tokens.  
Permisos necesarios: `Zone:DNS:Edit` para el dominio `cristianpuenguenan.online`.

```bash
microk8s kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=TU_CLOUDFLARE_API_TOKEN \
  -n cert-manager
```

### Cloudflare Tunnel Token (para cloudflared)

Crear el túnel en https://one.dash.cloudflare.com → Networks → Tunnels → Create Tunnel.  
Copiar el token que aparece al crear el túnel.

```bash
microk8s kubectl create secret generic cloudflared-token \
  --from-literal=token=TU_CLOUDFLARE_TUNNEL_TOKEN \
  -n infra
```

### Secrets de aplicaciones

```bash
# Flow API
microk8s kubectl create secret generic flow-secrets \
  --from-literal=database-url="postgresql://postgres:TU_PASSWORD@postgresql.databases.svc.cluster.local:5432/homelab" \
  --from-literal=redis-url="redis://:TU_PASSWORD_REDIS@redis-master.databases.svc.cluster.local:6379" \
  -n apps

# OpenMemory
microk8s kubectl create secret generic openmemory-secrets \
  --from-literal=OPENAI_API_KEY=sk-... \
  -n dev-tools

# SonarQube (password de PostgreSQL)
microk8s kubectl create secret generic sonarqube-db-secret \
  --from-literal=password=TU_PASSWORD_POSTGRES \
  -n dev-tools
```

---

## 8. Configurar DNS

Agregar registros A en Cloudflare apuntando a la IP del nodo (`192.168.80.20`).

| Registro | Tipo | Valor | Proxy |
|----------|------|-------|-------|
| `cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |

> Usar **DNS only** (nube gris) para los subdominios internos. Solo activar proxy de Cloudflare para los que se expongan públicamente vía Cloudflare Tunnel.

---

## 9. Activar GitOps

Con Argo CD corriendo y los secrets en su lugar, aplicar la root-app. A partir de aquí Argo CD despliega todo el stack automáticamente siguiendo los sync-waves.

```bash
microk8s kubectl apply -f gitops/root-app.yaml
```

Argo CD comenzará a sincronizar en este orden:

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

---

## 10. Verificar el despliegue

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

Verificar que el certificado wildcard fue emitido correctamente:

```bash
microk8s kubectl get certificate -n infra
# wildcard-home-tls   True   ...
```

> El certificado puede tardar 5-10 minutos en emitirse la primera vez (desafío DNS-01 con Cloudflare).

---

## 11. Acceder a los servicios

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
