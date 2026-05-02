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

Homelab de un solo nodo construido sobre k0s con GitOps completo. ArgoCD gestiona todas las aplicaciones desde este repositorio. APISIX actúa como único punto de entrada (ingress). Cloudflare Tunnel expone servicios seleccionados a Internet sin abrir puertos en el router.

### Stack tecnológico

| Capa | Tecnología |
|------|-----------|
| Kubernetes | k0s 1.31.x |
| CNI / NetworkPolicy | Cilium 1.16.x (eBPF, kubeProxy replacement) |
| Ingress / Gateway | APISIX 2.9.x (hostPort directo 80/443) |
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
│       ├── infra/           # cert-manager, headlamp, longhorn, cloudflared, operators
│       ├── ingress/         # APISIX (gateway, etcd, config)
│       ├── databases/
│       ├── dev-tools/
│       ├── apps/
│       └── monitoring/
├── platform/                # Valores Helm y manifiestos de cada servicio
│   ├── infra/               # cert-manager, headlamp, longhorn, cloudflared, operators
│   ├── ingress/             # APISIX (apisix/, apisix-etcd/)
│   ├── databases/
│   ├── apps/
│   ├── dev-tools/
│   └── monitoring/
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
| `server.ingress.enabled` | `false` (gestionado por APISIX) |
| `server.insecure` | `true` (TLS termina en APISIX) |
| Timeout de reconciliación | 180s |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.cristianpuenguenan.online` |

### 2.3 Namespaces

Declarados en `bootstrap/namespaces.yaml`:

| Namespace | Contenido |
|-----------|-----------|
| `infra` | Headlamp, CloudNativePG operator |
| `ingress` | APISIX (gateway + IC + dashboard + etcd) |
| `argocd` | Argo CD |
| `networking` | cloudflared, cert-manager |
| `databases` | PostgreSQL, MongoDB, Redis, Qdrant, Percona operator |
| `devtools` | SonarQube, OpenMemory |
| `apps` | Flow API |
| `monitoring` | Prometheus, Grafana, Alertmanager |
| `vault` | OpenBao, External Secrets |

---

## 3. Componentes de Plataforma

### 3.1 APISIX (Ingress + Gateway)

**Chart**: `apisix/apisix 2.9.0` — **Namespace**: `ingress`

Punto de entrada único al cluster. Escucha en puertos 80 y 443 via `hostPort` directo en la IP del nodo (`192.168.80.20`). Gestiona TLS, autenticación, rate limiting y routing hacia backends internos.

#### Sub-componentes

| Componente | Puerto | Descripción |
|-----------|--------|-------------|
| APISIX Gateway | 80, 443 (hostPort) | Ingress principal, datos HTTP/HTTPS |
| Admin API | 9180 (ClusterIP) | Configuración, protegido por NetworkPolicy |
| Dashboard | 9000 (ClusterIP) | UI de administración, acceso via APISIX Route |
| etcd | 2379 (ClusterIP) | Almacena config de rutas (PVC 2Gi Longhorn) |
| Ingress Controller | — | Reconcilia CRDs de APISIX → etcd |

#### Recursos APISIX Gateway

```
Requests: CPU 100m / RAM 128Mi
Limits:   CPU 1000m / RAM 512Mi
Capability: NET_BIND_SERVICE
```

#### Rutas configuradas

| Subdominio | Path | Backend | Namespace | Plugin |
|-----------|------|---------|-----------|--------|
| `apisix.cristianpuenguenan.online` | `/*` | apisix-dashboard:9000 | ingress | internal-dashboard |
| `argocd.cristianpuenguenan.online` | `/*` | argocd-server:80 | argocd | internal-dashboard |
| `grafana.cristianpuenguenan.online` | `/*` | kube-prometheus-stack-grafana:80 | monitoring | internal-dashboard |
| `headlamp.cristianpuenguenan.online` | `/*` | headlamp:80 | infra | internal-dashboard |
| `hubble.cristianpuenguenan.online` | `/*` | hubble-ui:80 | kube-system | internal-dashboard |
| `openmemory.cristianpuenguenan.online` | `/*` | openmemory:8080 | dev-tools | internal-dashboard |
| `sonarqube.cristianpuenguenan.online` | `/*` | sonarqube-sonarqube:9000 | dev-tools | internal-dashboard |
| `flow.cristianpuenguenan.online` | `/*` | flow:8000 | apps | internal-dashboard |
| `api.cristianpuenguenan.online` | `/flow/*` | flow:8000 | apps | public-api (JWT) |
| `api.cristianpuenguenan.online` | `/webhooks/*` | flow:8000 | apps | rate-limit 20/s |

#### Plugins globales (`ApisixGlobalRule`)

- **real-ip**: detecta IP real del cliente detrás de Cloudflare Tunnel  
  Trusted addresses: `127.0.0.1`
- **prometheus**: métricas en todas las rutas (`prefer_name: true`)

#### Plugin configs (`ApisixPluginConfig`)

**`internal-dashboard`** — para dashboards y herramientas internas:
- ip-restriction whitelist: LAN `192.168.80.0/24`

**`public-api`** — para endpoints de la API pública:
- jwt-auth
- limit-req: 100 req/s, burst 50, HTTP 429
- cors: `*`, métodos GET/POST/PUT/DELETE/PATCH/OPTIONS

#### TLS (`ApisixTls`)

Certificado wildcard `*.cristianpuenguenan.online` en secret `wildcard-home-tls` (namespace `ingress`).

### 3.2 cert-manager

**Chart**: `jetstack/cert-manager 1.16.2` — **Namespace**: `cert-manager`

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

**Chart**: `longhorn/longhorn 1.7.2` — **Namespace**: `infra`

CSI StorageClass por defecto del cluster. En nodo único, las réplicas se configuran en 1.

| Parámetro | Valor |
|-----------|-------|
| `defaultSettings.defaultReplicaCount` | `1` |
| `defaultSettings.storageMinimalAvailablePercentage` | `10` |
| `csi.kubeletRootDir` | `/var/lib/kubelet` |
| StorageClass por defecto | `longhorn` |

### 3.4 Cloudflared (Túnel Internet)

**Imagen**: `cloudflare/cloudflared:latest` — **Namespace**: `infra`

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
| Acceso | `headlamp.cristianpuenguenan.online` via APISIX |

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

Rutas APISIX:
- `flow.cristianpuenguenan.online/*` → acceso interno (ip-restriction)
- `api.cristianpuenguenan.online/flow/*` → API pública (JWT + rate-limit)
- `api.cristianpuenguenan.online/webhooks/*` → webhooks públicos (rate-limit 20/s)

### 4.2 OpenMemory (MCP + Vector Memory)

**Namespace**: `dev-tools` — **Imagen**: `mem0ai/openmemory-mcp:latest`

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

**Chart**: `SonarSource/sonarqube 10.7.0` — **Namespace**: `dev-tools`

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
| Acceso desde | `apps`, `dev-tools` |
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
| Acceso desde | `apps`, `dev-tools` |

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
| Acceso desde | `apps`, `dev-tools` |

### 5.4 Qdrant (Vector DB)

**Chart**: `qdrant/qdrant 1.13.0`

| Parámetro | Valor |
|-----------|-------|
| Puerto REST | 6333 |
| Puerto gRPC | 6334 |
| Storage | 10Gi (longhorn) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 1Gi |
| Acceso desde | `dev-tools` únicamente |

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
| APISIX | `ingress/apisix` puerto `prometheus` | `/apisix/prometheus/metrics` | 30s |
| Longhorn | `infra/longhorn-manager` puerto `manager` | `/metrics` | 30s |

---

## 7. Networking y Acceso

### Flujo de tráfico externo

```
Internet
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egreso desde cloudflared)
              └── APISIX :443 (hostPort en 192.168.80.20)
                    └── Backend ClusterIP (por ruta)

LAN
  └── APISIX :443 (hostPort en 192.168.80.20)
        └── Backend ClusterIP (por ruta)

Tailscale → SSH al host (mantenimiento del servidor, fuera del cluster)
```

### Puertos expuestos en el nodo

| Puerto | Protocolo | Descripción |
|--------|-----------|-------------|
| 80 | TCP | APISIX HTTP (redirige a HTTPS) |
| 443 | TCP | APISIX HTTPS (TLS wildcard) |

### Puertos internos (ClusterIP)

| Servicio | Puerto | Namespace |
|---------|--------|-----------|
| PostgreSQL | 5432 | databases |
| MongoDB | 27017 | databases |
| Redis | 6379 | databases |
| Qdrant REST | 6333 | databases |
| Qdrant gRPC | 6334 | databases |
| APISIX Admin API | 9180 | ingress |
| etcd (APISIX) | 2379 | ingress |
| Flow API | 8000 | apps |
| OpenMemory | 8080 | dev-tools |
| Prometheus | 9090 | monitoring |

### DNS y subdominios

Todos apuntan a `192.168.80.20` como registro A. Certificado wildcard cubre `*.cristianpuenguenan.online`.

| Subdominio | Servicio |
|-----------|---------|
| `argocd.cristianpuenguenan.online` | Argo CD |
| `apisix.cristianpuenguenan.online` | APISIX Dashboard |
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
| APISIX Admin API | Ingress Controller, Dashboard | 9180 |
| APISIX datos | Cualquier origen (hostPort) | 9080, 9443 |
| PostgreSQL | `apps`, `dev-tools` | 5432 |
| MongoDB | `apps`, `dev-tools` | 27017 |
| Redis | `apps`, `dev-tools` | 6379 |
| Qdrant | `dev-tools` | 6333, 6334 |

### Restricción de IP en dashboards

Plugin `internal-dashboard` en APISIX:
- LAN: `192.168.80.0/24` (ej. `192.168.80.0/24`)

### Secrets que deben crearse manualmente (nunca en git)

| Secret | Namespace | Claves |
|--------|-----------|--------|
| `cloudflare-api-token` | cert-manager | `api-token` |
| `cloudflared-token` | infra | `token` |
| `postgresql-app-secret` | databases | `username`, `password` |
| `mongodb-secret` | databases | Claves de sistema Percona (5 usuarios internos) |
| `mongodb-app-secret` | databases | `password` |
| `redis-secret` | databases | `redis-password` |
| `flow-secrets` | apps | `database-url`, `mongodb-url`, `redis-url` |
| `openmemory-secrets` | dev-tools | `OPENAI_API_KEY` |
| `sonarqube-db-secret` | dev-tools | `password` |

---

## 9. GitOps y Orden de Despliegue

Argo CD despliega las aplicaciones en orden via `sync-wave`. La `root-app` apunta a `gitops/apps/` y descubre todas las sub-aplicaciones.

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── Wave 1:  Longhorn, cert-manager, cloudnative-pg (operador), percona-mongodb-operator
        ├── Wave 2:  cert-manager-config (ClusterIssuer + Certificate)
        ├── Wave 3:  APISIX (Helm)
        ├── Wave 4:  apisix-config (Routes, PluginConfigs, TLS)
        ├── Wave 5:  kube-prometheus-stack, cloudflared, headlamp
        ├── Wave 6:  PostgreSQL (Cluster), MongoDB (PSMDB), Redis, Qdrant, ServiceMonitors
        ├── Wave 7:  NetworkPolicies de bases de datos
        ├── Wave 8:  SonarQube, OpenMemory
        └── Wave 9:  Flow API
```

### Dependencias implícitas entre componentes

```
Longhorn ──────────────────────────► etcd APISIX, PostgreSQL, MongoDB,
                                      Redis, Qdrant, Prometheus, Grafana,
                                      SonarQube

cert-manager ──► certificate ──────► wildcard-home-tls ──► APISIX TLS

APISIX ────────────────────────────► Todas las rutas de acceso externo

PostgreSQL ────────────────────────► SonarQube, Flow API

Qdrant ────────────────────────────► OpenMemory
```

---

## 10. Almacenamiento y Recursos

### Volúmenes persistentes (todos en StorageClass `longhorn`)

| Componente | Tamaño |
|-----------|--------|
| etcd (APISIX) | 2Gi |
| PostgreSQL | 10Gi |
| MongoDB | 10Gi |
| Redis | 5Gi |
| Qdrant | 10Gi |
| Prometheus | 20Gi |
| Grafana | 5Gi |
| SonarQube | 10Gi |
| **Total** | **~72Gi** |

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
helm install cilium cilium/cilium -n kube-system -f bootstrap/cilium/values.yaml

# 4. Instalar Argo CD (bootstrap manual, luego se autogestiona)
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f bootstrap/argocd/values.yaml

# 5. Crear secrets manuales (jamás se commitean)
# PostgreSQL (CloudNativePG)
kubectl create secret generic postgresql-app-secret \
  --from-literal=username=admin --from-literal=password=admin -n databases

# MongoDB (Percona Operator) — usuarios de sistema internos
kubectl create secret generic mongodb-secret \
  --from-literal=MONGODB_BACKUP_USER=backup --from-literal=MONGODB_BACKUP_PASSWORD=admin \
  --from-literal=MONGODB_DATABASE_ADMIN_USER=databaseAdmin --from-literal=MONGODB_DATABASE_ADMIN_PASSWORD=admin \
  --from-literal=MONGODB_CLUSTER_ADMIN_USER=clusterAdmin --from-literal=MONGODB_CLUSTER_ADMIN_PASSWORD=admin \
  --from-literal=MONGODB_CLUSTER_MONITOR_USER=clusterMonitor --from-literal=MONGODB_CLUSTER_MONITOR_PASSWORD=admin \
  --from-literal=MONGODB_USER_ADMIN_USER=userAdmin --from-literal=MONGODB_USER_ADMIN_PASSWORD=admin \
  -n databases

# MongoDB — usuario de aplicación
kubectl create secret generic mongodb-app-secret \
  --from-literal=password=admin -n databases

# Redis
kubectl create secret generic redis-secret \
  --from-literal=redis-password=admin -n databases

# Aplicaciones
kubectl create secret generic flow-secrets \
  --from-literal=database-url="postgresql://admin:admin@postgresql-rw.databases.svc.cluster.local:5432/homelab" \
  --from-literal=mongodb-url="mongodb://admin:admin@mongodb-rs0.databases.svc.cluster.local:27017/homelab?replicaSet=rs0&authSource=homelab" \
  --from-literal=redis-url="redis://:admin@redis-master.databases.svc.cluster.local:6379" \
  -n apps

kubectl create secret generic openmemory-secrets \
  --from-literal=OPENAI_API_KEY=sk-... -n dev-tools

kubectl create secret generic sonarqube-db-secret \
  --from-literal=password=admin -n dev-tools

kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=TU_TOKEN -n cert-manager

kubectl create secret generic cloudflared-token \
  --from-literal=token=TU_TUNNEL_TOKEN -n infra

# 6. Activar GitOps — Argo CD despliega todo en orden automáticamente
kubectl apply -f gitops/root-app.yaml
```

A partir del paso 8, Argo CD sincroniza el estado del cluster con el repositorio Git siguiendo el orden de sync-waves definido.
