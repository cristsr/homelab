# Arquitectura del Homelab Kubernetes

## Índice

1. [Visión General](#1-visión-general)
2. [Infraestructura Base](#2-infraestructura-base)
3. [Componentes de Plataforma](#3-componentes-de-plataforma)
4. [Aplicaciones y Herramientas](#4-aplicaciones-y-herramientas)
5. [Bases de Datos](#5-bases-de-datos)
6. [Monitoreo](#6-monitoreo)
7. [Networking y Acceso](#7-networking-y-acceso)
8. [Seguridad](#8-seguridad)
9. [GitOps y Orden de Despliegue](#9-gitops-y-orden-de-despliegue)
10. [Almacenamiento y Recursos](#10-almacenamiento-y-recursos)
11. [Flujo de Instalación Inicial](#11-flujo-de-instalación-inicial)

---

## 1. Visión General

Homelab de un solo nodo construido sobre k0s con GitOps completo. ArgoCD gestiona todas las aplicaciones desde este repositorio. Agent Gateway actúa como único punto de entrada (ingress). Cloudflare Tunnel expone servicios seleccionados a Internet sin abrir puertos en el router.

### Stack tecnológico

| Capa | Tecnología |
|------|-----------|
| Kubernetes | k0s 1.31.x |
| CNI / NetworkPolicy | Cilium 1.18.4 (eBPF, kubeProxy replacement) |
| Ingress / Gateway | Agent Gateway 1.1.0 (API7) |
| GitOps | Argo CD 7.x |
| Certificados TLS | cert-manager 1.16.2 + Let's Encrypt + Cloudflare DNS-01 |
| Storage | Longhorn 1.7.2 |
| Túnel Internet | Cloudflare Tunnel (cloudflared) |
| Monitoreo | kube-prometheus-stack 67.9.0 (Prometheus + Grafana) |
| Operador PostgreSQL | CloudNativePG 0.22.x (CNCF) |
| Operador MongoDB | Percona Server for MongoDB Operator 1.17.x |

### Estructura del repositorio

```
homelab/
├── bootstrap/               # Instalación manual previa a GitOps
│   ├── cilium/values.yaml
│   ├── argocd/values.yaml
│   └── namespaces.yaml
├── gitops/                  # Applications de Argo CD
│   ├── root-app.yaml
│   └── apps/
│       ├── infra/           # reloader
│       ├── argocd/         # argocd-config
│       ├── networking/     # cert-manager, cloudflared
│       ├── ingress/        # Agent Gateway
│       ├── storage/        # Longhorn
│       ├── databases/      # PostgreSQL, MongoDB, Redis, Qdrant, operators
│       ├── devtools/       # SonarQube, OpenMemory
│       ├── apps/           # Flow API
│       ├── monitoring/     # Prometheus, Grafana, monitors, headlamp
│       └── vault/          # OpenBao, External Secrets, vault-sync-operator
├── platform/                # Valores Helm y manifiestos de cada servicio
│   ├── argocd/            # cluster secret
│   ├── networking/         # cert-manager, cloudflared
│   ├── ingress/            # Agent Gateway
│   ├── storage/            # Longhorn
│   ├── databases/          # PostgreSQL, MongoDB, Redis, Qdrant, operators
│   ├── devtools/           # SonarQube, OpenMemory
│   ├── apps/               # Flow API
│   ├── monitoring/         # Prometheus, Grafana, headlamp
│   └── vault/              # OpenBao, External Secrets, vault-sync-operator
```

---

## 2. Infraestructura Base

### 2.1 Cilium (CNI)

**Chart**: `cilium/cilium` — **Namespace**: `kube-system`

Reemplaza completamente kube-proxy con eBPF. Provee conectividad de pods, NetworkPolicies y observabilidad via Hubble.

| Parámetro | Valor |
|-----------|-------|
| `kubeProxyReplacement` | `true` |
| `k8sServiceHost` | `127.0.0.1` |
| `k8sServicePort` | `6443` (k0s) |
| `hubble.relay.enabled` | `true` |
| `hubble.ui.enabled` | `true` |
| CNI bin path | `/opt/cni/bin` |
| Daemon run path | `/var/run/cilium` |

### 2.2 Argo CD (GitOps)

**Chart**: `argo/argo-cd` — **Namespace**: `argocd`

Controla el ciclo de vida de todas las aplicaciones del cluster. La `root-app` apunta a `gitops/apps/` y crea las sub-aplicaciones que despliegan cada componente.

| Parámetro | Valor |
|-----------|-------|
| `server.ingress.enabled` | `false` (gestionado por Agent Gateway) |
| `server.insecure` | `true` (TLS termina en Agent Gateway) |
| Timeout de reconciliación | 180s |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.cristianpuenguenan.online` |

### 2.3 Namespaces

Declarados en `bootstrap/namespaces.yaml`:

| Namespace | Contenido |
|-----------|-----------|
| `infra` | Reloader |
| `ingress` | Agent Gateway |
| `argocd` | Argo CD |
| `networking` | cloudflared, cert-manager |
| `databases` | PostgreSQL, MongoDB, Redis, Qdrant, CloudNativePG, Percona operators |
| `devtools` | SonarQube, OpenMemory |
| `apps` | Flow API |
| `monitoring` | Prometheus, Grafana, Alertmanager, Headlamp |
| `vault` | OpenBao, External Secrets, vault-sync-operator |
| `longhorn-system` | Longhorn |

---

## 3. Componentes de Plataforma

### 3.1 Agent Gateway (Ingress + Gateway API7)

**Chart**: `oci://cr.agentgateway.dev/charts/agentgateway 1.1.0` — **Namespace**: `ingress`

Punto de entrada único al cluster. Escucha en puertos 80 y 443 via `hostPort` directo en la IP del nodo (`192.168.80.20`).

#### Sub-componentes

| Componente | Puerto | Descripción |
|-----------|--------|-------------|
| Agent Gateway | 80, 443 (hostPort) | Ingress principal, datos HTTP/HTTPS |
| Dashboard | 9000 (ClusterIP) | UI de administración, acceso via Agent Gateway Route |

#### Recursos Agent Gateway

```
Requests: CPU 100m / RAM 128Mi
Limits:   CPU 1000m / RAM 512Mi
Capability: NET_BIND_SERVICE
```

#### Rutas configuradas

| Subdominio | Path | Backend | Namespace | Plugin |
|-----------|------|---------|-----------|--------|
| `agentgateway.cristianpuenguenan.online` | `/*` | agent-gateway:9000 | ingress | internal-dashboard |
| `argocd.cristianpuenguenan.online` | `/*` | argocd-server:80 | argocd | internal-dashboard |
| `grafana.cristianpuenguenan.online` | `/*` | kube-prometheus-stack-grafana:80 | monitoring | internal-dashboard |
| `headlamp.cristianpuenguenan.online` | `/*` | headlamp:80 | infra | internal-dashboard |
| `hubble.cristianpuenguenan.online` | `/*` | hubble-ui:80 | kube-system | internal-dashboard |
| `openmemory.cristianpuenguenan.online` | `/*` | openmemory:8080 | devtools | internal-dashboard |
| `sonarqube.cristianpuenguenan.online` | `/*` | sonarqube-sonarqube:9000 | devtools | internal-dashboard |
| `flow.cristianpuenguenan.online` | `/*` | flow:8000 | apps | internal-dashboard |
| `api.cristianpuenguenan.online` | `/flow/*` | flow:8000 | apps | public-api (JWT) |
| `api.cristianpuenguenan.online` | `/webhooks/*` | flow:8000 | apps | rate-limit 20/s |

#### Plugins globales

- **real-ip**: detecta IP real del cliente detrás de Cloudflare Tunnel  
  Trusted addresses: `127.0.0.1`
- **prometheus**: métricas en todas las rutas (`prefer_name: true`)

#### Plugin configs

**`internal-dashboard`** — para dashboards y herramientas internas:
- ip-restriction whitelist: LAN `192.168.80.0/24`

**`public-api`** — para endpoints de la API pública:
- jwt-auth
- limit-req: 100 req/s, burst 50, HTTP 429
- cors: `*`, métodos GET/POST/PUT/DELETE/PATCH/OPTIONS

#### TLS

Certificado wildcard `*.cristianpuenguenan.online` en secret `wildcard-home-tls` (namespace `ingress`).

### 3.2 cert-manager

**Chart**: `jetstack/cert-manager 1.16.2` — **Namespace**: `networking`

Automatiza la emisión y renovación de certificados TLS.

| Recurso | Detalle |
|---------|---------|
| ClusterIssuer | `letsencrypt-prod-cloudflare-dns01` |
| Método de validación | DNS-01 via Cloudflare API |
| Certificado | Wildcard `*.cristianpuenguenan.online` + apex `cristianpuenguenan.online` |
| Duración | 2160h (90 días), renueva 360h antes |
| Secret del token | `cloudflare-api-token` en namespace `cert-manager` (manual) |
| Secret del certificado | `wildcard-home-tls` en namespace `ingress` |

### 3.3 Longhorn (Storage)

**Chart**: `longhorn/longhorn 1.7.2` — **Namespace**: `longhorn-system`

CSI StorageClass por defecto del cluster. En nodo único, las réplicas se configuran en 1.

| Parámetro | Valor |
|-----------|-------|
| `defaultSettings.defaultReplicaCount` | `1` |
| `defaultSettings.storageMinimalAvailablePercentage` | `10` |
| `csi.kubeletRootDir` | `/var/lib/kubelet` |
| StorageClass por defecto | `longhorn` |

### 3.4 Cloudflared (Túnel Internet)

**Imagen**: `cloudflare/cloudflared:latest` — **Namespace**: `networking`

Establece un túnel cifrado saliente hacia Cloudflare sin necesidad de abrir puertos en el router. Los dominios que se exponen públicamente se configuran en el dashboard de Cloudflare Tunnel.

```
Requests: CPU 50m / RAM 64Mi
Limits:   CPU 200m / RAM 128Mi
Secret:   cloudflared-token (token del túnel, manual)
```

### 3.5 Headlamp (UI Kubernetes)

**Chart**: `headlamp-k8s/headlamp 0.26.0` — **Namespace**: `infra`

Dashboard web de solo lectura para inspeccionar el estado del cluster.

| Parámetro | Valor |
|-----------|-------|
| `inCluster` | `true` |
| Service | ClusterIP:80 |
| Acceso | `headlamp.cristianpuenguenan.online` via Agent Gateway |

---

## 4. Aplicaciones y Herramientas

### 4.1 Flow API

**Namespace**: `apps` — **Imagen**: `ghcr.io/cristsr/flow:latest`

Aplicación principal del homelab. Expone una API REST en el puerto 8000.

```
Replicas: 1
Port:     8000
Requests: CPU 100m / RAM 256Mi
Limits:   CPU 500m / RAM 512Mi
Secrets:  flow-secrets (DATABASE_URL, REDIS_URL)
```

Rutas Agent Gateway:
- `flow.cristianpuenguenan.online/*` → acceso interno (ip-restriction)
- `api.cristianpuenguenan.online/flow/*` → API pública (JWT + rate-limit)
- `api.cristianpuenguenan.online/webhooks/*` → webhooks públicos (rate-limit 20/s)

### 4.2 OpenMemory (MCP + Vector Memory)

**Namespace**: `devtools` — **Imagen**: `mem0ai/openmemory-mcp:latest`

Agente de memoria vectorial para LLMs. Almacena embeddings en Qdrant.

```
Replicas: 1
Port:     8080
Requests: CPU 50m / RAM 128Mi
Limits:   CPU 500m / RAM 512Mi
Env:      QDRANT_HOST=qdrant.databases.svc.cluster.local
          QDRANT_PORT=6333
Secrets:  openmemory-secrets (OPENAI_API_KEY)
```

### 4.3 SonarQube Community

**Chart**: `SonarSource/sonarqube 10.7.0` — **Namespace**: `devtools`

Análisis estático de calidad de código.

```
Edition:  Community
Port:     9000
Requests: CPU 200m / RAM 1Gi
Limits:   CPU 1000m / RAM 2Gi
Storage:  10Gi (longhorn)
DB:       postgresql-rw.databases.svc.cluster.local:5432/sonarqube
Usuario:  sonarqube (gestionado por CloudNativePG managed.roles)
Secret:   sonarqube-db-secret (clave: password)
```

---

## 5. Bases de Datos

Todas en namespace `databases`. Acceso restringido por CiliumNetworkPolicy.  
PostgreSQL y MongoDB son gestionados por operadores Kubernetes que proveen backup, PITR y gestión declarativa de usuarios.

### 5.1 PostgreSQL — CloudNativePG

**Operador**: `cloudnative-pg/cloudnative-pg 0.22.0` — **CRD**: `kind: Cluster`

El operador gestiona el ciclo de vida completo: bootstrapping, backups, upgrades y roles de base de datos.

| Parámetro | Valor |
|-----------|-------|
| Imagen | `ghcr.io/cloudnative-pg/postgresql:17` |
| Database | homelab |
| Usuario propietario | admin |
| Puerto | 5432 |
| Storage | 10Gi (longhorn) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 512Mi |
| Acceso desde | `apps`, `devtools` |
| Métricas | PodMonitor integrado |

#### Servicios generados por el operador

| Servicio | Descripción |
|---------|-------------|
| `postgresql-rw.databases` | Primario — lectura/escritura |
| `postgresql-r.databases` | Cualquier instancia (round-robin) |
| `postgresql-ro.databases` | Réplicas de solo lectura |

#### Bases de datos y roles

| DB | Owner | Notas |
|----|-------|-------|
| `homelab` | `admin` | DB principal de aplicaciones |
| `sonarqube` | `sonarqube` | Creada en bootstrap via postInitSQL |

El rol `sonarqube` es gestionado por `managed.roles` — el operador reconcilia su contraseña desde `sonarqube-db-secret`.

### 5.2 MongoDB — Percona Operator

**Operador**: `percona/psmdb-operator 1.17.0` — **CRD**: `kind: PerconaServerMongoDB`

Equivalente open source al MongoDB Enterprise Operator. Provee replica sets, backups a S3, PITR y gestión declarativa de usuarios.

| Parámetro | Valor |
|-----------|-------|
| Imagen | `percona/percona-server-mongodb:8.0` |
| Replica set | rs0 (1 miembro, ampliable a 3 sin migración) |
| Database | homelab |
| Usuario de aplicación | admin |
| Puerto | 27017 |
| Storage | 10Gi (longhorn) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 512Mi |
| Acceso desde | `apps`, `devtools` |

#### Servicios generados por el operador

| Servicio | Descripción |
|---------|-------------|
| `mongodb-rs0.databases` | Servicio del replica set (puerto 27017) |
| `mongodb-rs0-0.databases` | Pod individual (acceso directo) |

#### Connection string

```
mongodb://admin:admin@mongodb-rs0.databases.svc.cluster.local:27017/homelab?replicaSet=rs0&authSource=homelab
```

### 5.3 Redis

**Chart**: `bitnami/redis 20.6.0`

| Parámetro | Valor |
|-----------|-------|
| Arquitectura | standalone |
| Puerto | 6379 |
| Auth | habilitada |
| Storage | 5Gi (longhorn) |
| Requests | CPU 50m / RAM 128Mi |
| Limits | CPU 200m / RAM 256Mi |
| Acceso desde | `apps`, `devtools` |

### 5.4 Qdrant (Vector DB)

**Chart**: `qdrant/qdrant 1.13.0`

| Parámetro | Valor |
|-----------|-------|
| Puerto REST | 6333 |
| Puerto gRPC | 6334 |
| Storage | 10Gi (longhorn) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 1Gi |
| Acceso desde | `devtools` únicamente |

---

## 6. Monitoreo

**Chart**: `prometheus-community/kube-prometheus-stack 67.9.0` — **Namespace**: `monitoring`

### Componentes

| Componente | Descripción |
|-----------|-------------|
| Prometheus | Recolección de métricas, retención 15 días, 20Gi |
| Grafana | Dashboards, 5Gi, `grafana.cristianpuenguenan.online` |
| Alertmanager | Gestión de alertas |
| node-exporter | Métricas del host |
| kube-state-metrics | Estado de objetos Kubernetes |

Prometheus descubre ServiceMonitors de **todos los namespaces** (`serviceMonitorNamespaceSelector: {}`).

### ServiceMonitors adicionales

| Monitor | Target | Path | Intervalo |
|---------|--------|------|-----------|
| Longhorn | `longhorn-system/longhorn-manager` puerto `manager` | `/metrics` | 30s |

---

## 7. Networking y Acceso

### Flujo de tráfico externo

```
Internet
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egreso desde cloudflared)
              └── Agent Gateway :443 (hostPort en 192.168.80.20)
                    └── Backend ClusterIP (por ruta)

LAN
  └── Agent Gateway :443 (hostPort en 192.168.80.20)
        └── Backend ClusterIP (por ruta)

Tailscale → SSH al host (mantenimiento del servidor, fuera del cluster)
```

### Puertos expuestos en el nodo

| Puerto | Protocolo | Descripción |
|--------|-----------|-------------|
| 80 | TCP | Agent Gateway HTTP (redirige a HTTPS) |
| 443 | TCP | Agent Gateway HTTPS (TLS wildcard) |

### Puertos internos (ClusterIP)

| Servicio | Puerto | Namespace |
|---------|--------|-----------|
| PostgreSQL | 5432 | databases |
| MongoDB | 27017 | databases |
| Redis | 6379 | databases |
| Qdrant REST | 6333 | databases |
| Qdrant gRPC | 6334 | databases |
| Flow API | 8000 | apps |
| OpenMemory | 8080 | devtools |
| Prometheus | 9090 | monitoring |

### DNS y subdominios

Todos apuntan a `192.168.80.20` como registro A. Certificado wildcard cubre `*.cristianpuenguenan.online`.

| Subdominio | Servicio |
|-----------|---------|
| `argocd.cristianpuenguenan.online` | Argo CD |
| `agentgateway.cristianpuenguenan.online` | Agent Gateway Dashboard |
| `grafana.cristianpuenguenan.online` | Grafana |
| `headlamp.cristianpuenguenan.online` | Headlamp |
| `hubble.cristianpuenguenan.online` | Hubble UI (Cilium) |
| `openmemory.cristianpuenguenan.online` | OpenMemory |
| `sonarqube.cristianpuenguenan.online` | SonarQube |
| `flow.cristianpuenguenan.online` | Flow (acceso interno) |
| `api.cristianpuenguenan.online` | Flow API pública + webhooks |

---

## 8. Seguridad

### NetworkPolicies (Cilium)

Estrategia: **default deny implícito** con listas blancas explícitas por namespace.

| Recurso | Ingress permitido | Puerto |
|---------|------------------|--------|
| Agent Gateway datos | Cualquier origen (hostPort) | 80, 443 |
| PostgreSQL | `apps`, `devtools` | 5432 |
| MongoDB | `apps`, `devtools` | 27017 |
| Redis | `apps`, `devtools` | 6379 |
| Qdrant | `devtools` | 6333, 6334 |

### Restricción de IP en dashboards

Plugin `internal-dashboard` en Agent Gateway:
- LAN: `192.168.80.0/24` (ej. `192.168.80.0/24`)

### Secrets que deben crearse manualmente (nunca en git)

| Secret | Namespace | Claves |
|--------|-----------|--------|
| `cloudflare-api-token` | networking | `api-token` |
| `cloudflared-token` | networking | `token` |
| `postgresql-app-secret` | databases | `username`, `password` |
| `mongodb-secret` | databases | Claves de sistema Percona (5 usuarios internos) |
| `mongodb-app-secret` | databases | `password` |
| `redis-secret` | databases | `redis-password` |
| `flow-secrets` | apps | `database-url`, `mongodb-url`, `redis-url` |
| `openmemory-secrets` | devtools | `OPENAI_API_KEY` |
| `sonarqube-db-secret` | devtools | `password` |

---

## 9. GitOps y Orden de Despliegue

Argo CD despliega las aplicaciones en orden via `sync-wave`. La `root-app` apunta a `gitops/apps/` y descubre todas las sub-aplicaciones.

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── Wave 1:  Longhorn, cert-manager, cloudnative-pg, percona-mongodb, reloader
        ├── Wave 2:  OpenBao, External Secrets, vault-sync-operator, cert-manager-config
        ├── Wave 3:  Agent Gateway (Helm)
        ├── Wave 4:  agentgateway-config, argocd-config
        ├── Wave 5:  monitoring (prometheus, grafana), cloudflared, headlamp, argocd-config
        ├── Wave 6:  PostgreSQL, MongoDB, Redis, Qdrant
        ├── Wave 8:  SonarQube, OpenMemory
        └── Wave 9:  Flow API
```

### Dependencias implícitas entre componentes

```
Longhorn (longhorn-system) ─────────► PostgreSQL, MongoDB,
                                      Redis, Qdrant, Prometheus, Grafana,
                                      SonarQube

cert-manager ──► certificate ──────► wildcard-home-tls ──► Agent Gateway TLS

Agent Gateway ────────────────────────────► Todas las rutas de acceso externo

OpenBao ──► External Secrets ──► Secrets en cluster

PostgreSQL ────────────────────────► SonarQube, Flow API

Qdrant ────────────────────────────► OpenMemory
```

---

## 10. Almacenamiento y Recursos

### Volúmenes persistentes (todos en StorageClass `longhorn`)

| Componente | Tamaño |
|-----------|--------|
| PostgreSQL | 10Gi |
| MongoDB | 10Gi |
| Redis | 5Gi |
| Qdrant | 10Gi |
| Prometheus | 20Gi |
| Grafana | 5Gi |
| SonarQube | 10Gi |
| **Total** | **~60Gi** |

### Recursos de CPU y RAM (estimado total)

| | CPU Requests | CPU Limits | RAM Requests | RAM Limits |
|-|-------------|-----------|------------|-----------|
| Infraestructura | ~1.0 core | ~5.0 cores | ~1.5Gi | ~4.0Gi |
| Bases de datos | ~0.35 cores | ~1.7 cores | ~1.0Gi | ~2.3Gi |
| Aplicaciones | ~0.35 cores | ~1.5 cores | ~1.4Gi | ~3.0Gi |
| Sistema (Cilium, kube) | ~0.2 cores | ~2.0 cores | ~0.5Gi | ~2.0Gi |
| **Total estimado** | **~1.9 cores** | **~10.2 cores** | **~4.4Gi** | **~11.3Gi** |

**Requerimiento mínimo del host**: 8GB RAM, 4 CPU cores, 100GB disco.

---

## 11. Flujo de Instalación Inicial

```bash
# 1. Subir el repositorio a Git
git add -A && git commit -m "chore: initial commit" && git push

# 2. Crear namespaces
kubectl apply -f bootstrap/namespaces.yaml

# 3. Instalar Cilium (CNI, antes que cualquier otra cosa)
helm repo add cilium https://helm.cilium.io
helm repo update

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.18.4 \
  -f bootstrap/cilium/values.yaml

# 4. Instalar Argo CD (bootstrap manual, luego se autogestiona)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.0 \
  -f bootstrap/argocd/values.yaml

# 5. Obtener kubeconfig
sudo cp /etc/k0s/k0s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# 6. Crear cluster secret para ArgoCD
CA_DATA=$(kubectl get configmap kube-root-ca.crt \
  -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)

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

# 7. Registrar repositorio privado en ArgoCD
# Crear Personal Access Token en GitHub con scope 'repo'
kubectl -n argocd create secret generic homelab-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cristsr/homelab \
  --from-literal=username=cristsr \
  --from-literal=password=TU_GITHUB_PAT \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret homelab-repo \
  argocd.argoproj.io/secret-type=repository \
  --overwrite

# 8. Aplicar root-app (ArgoCD despliega el resto)
kubectl apply -f gitops/root-app.yaml

# 9. Desbloquear Longhorn (si es necesario)
kubectl create serviceaccount longhorn-service-account -n argocd
kubectl create clusterrolebinding longhorn-pre-upgrade-temp \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd:longhorn-service-account
```

A partir del paso 8, Argo CD sincroniza el estado del cluster con el repositorio Git siguiendo el orden de sync-waves definido.
