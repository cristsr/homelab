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
| Kubernetes | k0s 1.31.5 |
| CNI / NetworkPolicy | Cilium 1.19.3 (eBPF, kubeProxy replacement) |
| Ingress / Gateway | Agent Gateway 1.1.0 |
| GitOps | Argo CD 7.8.28 |
| Certificados TLS | cert-manager v1.20.2 + Let's Encrypt + Cloudflare DNS-01 |
| Storage | Longhorn 1.11.2 |
| Túnel Internet | Cloudflare Tunnel (cloudflared 2026.3.0) |
| Monitoreo | kube-prometheus-stack 83.3.0 + Grafana Operator 5.22.2 |
| Secrets | OpenBao 2.5.3 + External Secrets Operator 2.4.1 |
| Operador PostgreSQL | CloudNative-PG 0.28.0 (chart) |
| Operador MongoDB | Percona PSMDB Operator 1.22.0 |

### Estructura del repositorio

```
homelab/
├── ansible/                 # Provisioning del nodo (k0s, helm, helmfile, argocd secret)
│   ├── tasks/
│   │   ├── k0s.yaml         # Instalación y configuración de k0s
│   │   ├── kubeconfig.yaml  # Export de kubeconfig y wrapper kubectl
│   │   ├── helm.yaml        # Instalación de Helm
│   │   ├── helmfile.yaml    # Instalación de Helmfile
│   │   └── argocd-secret.yaml # Secret repo-creds de GitHub para ArgoCD
│   ├── templates/
│   │   └── k0s-config.yaml.j2
│   ├── group_vars/all.yaml  # Variables globales + github_token (ansible-vault)
│   ├── ansible.cfg
│   ├── inventory.yaml
│   └── site.yaml
├── bootstrap/               # Bootstrap del cluster (namespaces, Cilium, ArgoCD)
│   ├── cilium/values.yaml
│   ├── argocd/values.yaml
│   ├── namespaces.yaml
│   └── helmfile.yaml        # Despliega Cilium y ArgoCD en orden
├── gitops/                  # Applications de Argo CD
│   ├── root-app.yaml
│   └── apps/
│       ├── infra/           # reloader
│       ├── argocd/          # argocd-config
│       ├── networking/      # cert-manager, cloudflared
│       ├── ingress/         # Agent Gateway
│       ├── storage/         # Longhorn
│       ├── databases/       # PostgreSQL, MongoDB, Redis, Qdrant, operators
│       ├── devtools/        # SonarQube, OpenMemory
│       ├── apps/            # Flow API
│       ├── monitoring/      # Prometheus, Grafana, monitors, headlamp
│       └── vault/           # OpenBao, External Secrets, vault-sync-operator
├── platform/                # Valores Helm y manifiestos de cada servicio
│   ├── argocd/              # repo credentials (ExternalSecret)
│   ├── networking/          # cert-manager, cloudflared
│   ├── ingress/             # Agent Gateway routes
│   ├── storage/             # Longhorn StorageClasses
│   ├── databases/           # PostgreSQL, MongoDB, Redis, Qdrant, operators
│   ├── devtools/            # SonarQube, OpenMemory
│   ├── apps/                # Flow API
│   ├── monitoring/          # Prometheus, Grafana, Alertmanager, Headlamp
│   └── vault/               # OpenBao, External Secrets, init jobs
```

---

## 2. Infraestructura Base

### 2.1 Cilium (CNI)

**Chart**: `cilium/cilium` — **Namespace**: `kube-system` — **Versión**: `1.19.3`

Reemplaza completamente kube-proxy con eBPF. Provee conectividad de pods, NetworkPolicies y observabilidad via Hubble.

| Parámetro | Valor |
|-----------|-------|
| `kubeProxyReplacement` | `true` |
| `k8sServiceHost` | `127.0.0.1` |
| `k8sServicePort` | `6443` |
| `ipam.mode` | `cluster-pool` |
| Pod CIDR | `10.244.0.0/16` |
| `routingMode` | `native` |
| `bpf.masquerade` | `true` |
| `hubble.relay.enabled` | `true` |
| `hubble.ui.enabled` | `true` |
| CNI bin path | `/opt/cni/bin` |
| Daemon run path | `/var/run/cilium` |

### 2.2 Argo CD (GitOps)

**Chart**: `argo/argo-cd` — **Namespace**: `argocd` — **Versión**: `7.8.28`

Controla el ciclo de vida de todas las aplicaciones del cluster. La `root-app` apunta a `gitops/apps/` y crea las sub-aplicaciones que despliegan cada componente.

| Parámetro | Valor |
|-----------|-------|
| `server.ingress.enabled` | `false` (gestionado por Agent Gateway) |
| `server.insecure` | `true` (TLS termina en Agent Gateway) |
| Timeout de reconciliación | `180s` |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.cristianpuenguenan.online` |

### 2.3 Namespaces

Declarados en `bootstrap/namespaces.yaml` y creados por el hook presync de Cilium en el helmfile:

| Namespace | Contenido |
|-----------|-----------|
| `infra` | Reloader |
| `ingress` | Agent Gateway |
| `argocd` | Argo CD |
| `networking` | cloudflared, cert-manager |
| `databases` | PostgreSQL, MongoDB, Redis, Qdrant, CloudNative-PG, Percona operators |
| `devtools` | SonarQube, OpenMemory |
| `apps` | Flow API |
| `monitoring` | Prometheus, Grafana, Alertmanager, Headlamp |
| `vault` | OpenBao, External Secrets, vault-sync-operator |
| `longhorn-system` | Longhorn |

---

## 3. Componentes de Plataforma

### 3.1 Agent Gateway (Ingress)

**Chart**: `oci://cr.agentgateway.dev/charts/agentgateway 1.1.0` — **Namespace**: `ingress`

Punto de entrada único al cluster. Expone los servicios internos vía HTTPRoute (Gateway API).

#### Rutas configuradas

| Subdominio | Backend | Namespace |
|-----------|---------|-----------|
| `agentgateway.cristianpuenguenan.online` | agentgateway dashboard | ingress |
| `argocd.cristianpuenguenan.online` | argocd-server:80 | argocd |
| `grafana.cristianpuenguenan.online` | grafana:3000 | monitoring |
| `headlamp.cristianpuenguenan.online` | headlamp:80 | monitoring |
| `hubble.cristianpuenguenan.online` | hubble-ui:80 | kube-system |
| `openmemory.cristianpuenguenan.online` | openmemory:8080 | devtools |
| `sonarqube.cristianpuenguenan.online` | sonarqube-sonarqube:9000 | devtools |
| `flow.cristianpuenguenan.online` | flow:80 | apps |

#### TLS

Certificado wildcard `*.cristianpuenguenan.online` en secret `wildcard-home-tls` (namespace `ingress`).

```
Requests: CPU 100m / RAM 128Mi
Limits:   CPU 500m / RAM 256Mi
```

### 3.2 cert-manager

**Chart**: `jetstack/cert-manager v1.20.2` — **Namespace**: `networking`

Automatiza la emisión y renovación de certificados TLS.

| Recurso | Detalle |
|---------|---------|
| ClusterIssuer | `letsencrypt-prod-cloudflare-dns01` |
| Método de validación | DNS-01 via Cloudflare API |
| Certificado | Wildcard `*.cristianpuenguenan.online` + apex `cristianpuenguenan.online` |
| Duración | 2160h (90 días), renueva 360h antes |
| Secret del token | `cloudflare-api-token` en namespace `networking` (via ExternalSecret) |
| Secret del certificado | `wildcard-home-tls` en namespace `ingress` |

### 3.3 Longhorn (Storage)

**Chart**: `longhorn/longhorn 1.11.2` — **Namespace**: `longhorn-system`

CSI StorageClass por defecto del cluster. En nodo único, las réplicas se configuran en 1.

| Parámetro | Valor |
|-----------|-------|
| `defaultSettings.defaultReplicaCount` | `1` |
| `defaultSettings.storageMinimalAvailablePercentage` | `50` |
| `csi.kubeletRootDir` | `/var/lib/kubelet` |
| StorageClass por defecto | `longhorn` |

#### StorageClasses

| Nombre | ReclaimPolicy | Réplicas | Uso |
|--------|--------------|----------|-----|
| `longhorn` | Delete | 1 | Por defecto (Grafana, Prometheus) |
| `longhorn-retain` | Retain | 1 | Bases de datos (PostgreSQL, MongoDB, Redis, Qdrant) |

### 3.4 Cloudflared (Túnel Internet)

**Imagen**: `cloudflare/cloudflared:2026.3.0` — **Namespace**: `networking`

Establece un túnel cifrado saliente hacia Cloudflare sin necesidad de abrir puertos en el router.

```
Requests: CPU 50m / RAM 64Mi
Limits:   CPU 200m / RAM 128Mi
Secret:   cloudflared-token (via ExternalSecret ← OpenBao secret/infra/cloudflared)
```

### 3.5 Headlamp (UI Kubernetes)

**Chart**: `headlamp-k8s/headlamp 0.42.0` — **Namespace**: `monitoring`

Dashboard web para inspeccionar el estado del cluster.

| Parámetro | Valor |
|-----------|-------|
| `inCluster` | `true` |
| Service | ClusterIP:80 |
| Acceso | `headlamp.cristianpuenguenan.online` via Agent Gateway |

### 3.6 OpenBao (Secrets Backend)

**Chart**: `hashicorp/vault 0.32.0` (imagen `ghcr.io/openbao/openbao:2.5.3`) — **Namespace**: `vault`

> Pendiente migrar al chart oficial `openbao/openbao-helm`.

KV v2 secrets engine como backend central de todos los secrets del cluster.

| Parámetro | Valor |
|-----------|-------|
| Modo | Production (standalone) |
| Autenticación | Kubernetes auth |
| KV mount | `secret` (v2) |
| Storage | PVC 1Gi (Longhorn default) |
| UI | habilitada en `:8200` |

**Init jobs** (`platform/vault/init/`):
- `openbao-init` — inicializa OpenBao, habilita Kubernetes auth, crea policies y roles
- `openbao-import-secrets` — importa `vault-bootstrap-secrets` al KV de OpenBao

> Tras cada restart del pod, OpenBao queda sellado. Unseal manual requerido.

### 3.7 External Secrets Operator

**Chart**: `external-secrets/external-secrets 2.4.1` — **Namespace**: `secret-management`

Sincroniza secrets desde OpenBao hacia Kubernetes. Todos los recursos usan `apiVersion: external-secrets.io/v1`.

| Recurso | Detalle |
|---------|---------|
| ClusterSecretStore | `openbao` — apunta a `http://openbao.secret-management.svc.cluster.local:8200` |
| KV version | v2 |
| Auth | Kubernetes (ServiceAccount `external-secrets-sa`) |
| Paths de KV | Sin prefijo `secret/data/` en `remoteRef.key` (ESO lo añade automáticamente) |

### 3.8 Reloader

**Chart**: `stakater/reloader 1.4.16` — **Namespace**: `infra`

Reinicia Deployments/StatefulSets automáticamente cuando cambia un Secret o ConfigMap referenciado. Activado con la anotación `reloader.stakater.com/auto: "true"`.

---

## 4. Aplicaciones y Herramientas

### 4.1 Flow API

**Namespace**: `apps`

> Actualmente usa imagen placeholder `traefik/whoami:latest`. Reemplazar con la imagen real de la aplicación.

```
Replicas: 1
Port:     80
Requests: CPU 10m / RAM 16Mi
Limits:   CPU 100m / RAM 32Mi
Secrets:  flow-secrets (database-url, mongodb-url, redis-url) via ExternalSecret
```

### 4.2 OpenMemory (MCP + Vector Memory)

**Namespace**: `devtools` — **Imagen**: `mem0/openmemory-mcp:latest`

Agente de memoria vectorial para LLMs. Almacena embeddings en Qdrant.

```
Replicas: 1
Port:     8080
Requests: CPU 50m / RAM 128Mi
Limits:   CPU 500m / RAM 512Mi
Env:      QDRANT_HOST=qdrant.databases.svc.cluster.local
          QDRANT_PORT=6333
Secrets:  openmemory-secrets (OPENAI_API_KEY) via ExternalSecret
```

### 4.3 SonarQube Community

**Chart**: `SonarSource/sonarqube 2026.2.1` — **Namespace**: `devtools`

Análisis estático de calidad de código.

```
Edition:  Community
Port:     9000
Requests: CPU 200m / RAM 1Gi
Limits:   CPU 1000m / RAM 2Gi
Storage:  10Gi (longhorn)
DB:       postgresql-rw.databases.svc.cluster.local:5432/sonarqube
Usuario:  sonarqube (gestionado por CloudNative-PG managed.roles)
Secret:   sonarqube-db-secret (via ExternalSecret ← OpenBao secret/devtools/sonarqube)
```

---

## 5. Bases de Datos

Todas en namespace `databases`. Acceso restringido por CiliumNetworkPolicy.

### 5.1 PostgreSQL — CloudNative-PG

**Operador**: `cloudnative-pg/cloudnative-pg 0.28.0` — **CRD**: `kind: Cluster`

| Parámetro | Valor |
|-----------|-------|
| Imagen | `ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm` |
| Database | `homelab` |
| Usuario propietario | `admin` |
| Puerto | 5432 |
| Storage | 10Gi (`longhorn-retain`) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 512Mi |
| Métricas | PodMonitor integrado (`enablePodMonitor: true`) |

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
| `sonarqube` | `sonarqube` | Creada via `postInitSQL`; rol gestionado por `managed.roles` |

### 5.2 MongoDB — Percona Operator

**Operador**: `percona/psmdb-operator 1.22.0` — **CRD**: `kind: PerconaServerMongoDB`

| Parámetro | Valor |
|-----------|-------|
| Imagen | `percona/percona-server-mongodb:8.0.20-8` |
| `crVersion` | `1.22.0` |
| Replica set | `rs0` (1 miembro) |
| Database | `homelab` |
| Puerto | 27017 |
| Storage | 10Gi (`longhorn-retain`) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 512Mi |

#### Servicios generados por el operador

| Servicio | Descripción |
|---------|-------------|
| `mongodb-rs0.databases` | Servicio del replica set |
| `mongodb-rs0-0.databases` | Pod individual |

#### Connection string

```
mongodb://admin:<pass>@mongodb-rs0.databases.svc.cluster.local:27017/homelab?replicaSet=rs0&authSource=homelab
```

### 5.3 Redis

**Tipo**: StatefulSet manual — **Imagen**: `redis:8-alpine` — **Namespace**: `databases`

| Parámetro | Valor |
|-----------|-------|
| Puerto | 6379 |
| Auth | `requirepass` via Secret |
| Storage | 5Gi (`longhorn-retain`) |
| Requests | CPU 50m / RAM 128Mi |
| Limits | CPU 200m / RAM 256Mi |
| Servicios | `redis-master` (ClusterIP), `redis-headless` (headless) |

### 5.4 Qdrant (Vector DB)

**Chart**: `qdrant/qdrant 1.17.1` — **Namespace**: `databases`

| Parámetro | Valor |
|-----------|-------|
| Puerto REST | 6333 |
| Puerto gRPC | 6334 |
| Storage | 10Gi (`longhorn-retain`) |
| Requests | CPU 100m / RAM 256Mi |
| Limits | CPU 500m / RAM 1Gi |
| API Key | via ExternalSecret (`qdrant-api-key`) |

---

## 6. Monitoreo

**Namespace**: `monitoring`

### Componentes

| Componente | Chart / Versión | Descripción |
|-----------|----------------|-------------|
| Prometheus Operator | `kube-prometheus-stack 83.3.0` | Solo operator + node-exporter + kube-state-metrics (Prometheus/Grafana/AM como CRs) |
| Prometheus | CR `monitoring.coreos.com/v1` | Retención 15d, 20Gi, scrape vía ServiceMonitor label `prometheus: monitor` |
| Grafana | Grafana Operator `5.22.2` | CR `grafana.integreatly.org/v1beta1`, 5Gi storage |
| Alertmanager | CR `monitoring.coreos.com/v1` | 1Gi storage |
| node-exporter | incluido en kube-prometheus-stack | Métricas del host |
| kube-state-metrics | incluido en kube-prometheus-stack | Estado de objetos Kubernetes |
| Headlamp | `headlamp-k8s/headlamp 0.42.0` | UI de gestión del cluster |

### ServiceMonitors adicionales

| Monitor | Target | Intervalo |
|---------|--------|-----------|
| Longhorn | `longhorn-system/longhorn-manager` puerto `manager` | 30s |
| External Secrets | metrics port | via chart |
| CloudNative-PG | PodMonitor integrado | via operador |

---

## 7. Networking y Acceso

### Flujo de tráfico externo

```
Internet
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egreso desde cloudflared)
              └── Agent Gateway :443 (hostPort en 192.168.80.20)
                    └── Backend ClusterIP (por HTTPRoute)

LAN
  └── Agent Gateway :443 (hostPort en 192.168.80.20)
        └── Backend ClusterIP (por HTTPRoute)
```

### Puertos expuestos en el nodo

| Puerto | Protocolo | Descripción |
|--------|-----------|-------------|
| 80 | TCP | Agent Gateway HTTP |
| 443 | TCP | Agent Gateway HTTPS (TLS wildcard) |

### DNS y subdominios

Todos apuntan a `192.168.80.20` como registro A. Certificado wildcard `*.cristianpuenguenan.online`.

| Subdominio | Servicio |
|-----------|---------|
| `argocd.*` | Argo CD |
| `agentgateway.*` | Agent Gateway Dashboard |
| `grafana.*` | Grafana |
| `headlamp.*` | Headlamp |
| `hubble.*` | Hubble UI (Cilium) |
| `openmemory.*` | OpenMemory |
| `sonarqube.*` | SonarQube |
| `flow.*` | Flow API |

---

## 8. Seguridad

### NetworkPolicies (Cilium)

Estrategia: **default deny implícito** con listas blancas explícitas por namespace.

| Recurso | Ingress permitido | Puerto |
|---------|------------------|--------|
| PostgreSQL | `apps`, `devtools` | 5432 |
| MongoDB | `apps`, `devtools` | 27017 |
| Redis | `apps`, `devtools` | 6379 |
| Qdrant | `devtools` | 6333, 6334 |

### Gestión de Secrets

Todos los secrets se almacenan en OpenBao (KV v2, mount `secret`) y se sincronizan al cluster via External Secrets Operator usando `apiVersion: external-secrets.io/v1`.

Los `remoteRef.key` en los ExternalSecrets son paths relativos al mount, sin incluir `secret/data/`:

```yaml
remoteRef:
  key: databases/postgresql-app   # ESO construye /v1/secret/data/databases/postgresql-app
  property: password
```

### Variables de entorno requeridas (vault-bootstrap-secrets)

| Variable | Descripción |
|----------|-------------|
| `argocd_github_pat` | PAT de GitHub para acceso al repo privado |
| `argocd_repo_url` | URL del repositorio |
| `cloudflare_api_token` | Token API Cloudflare (DNS-01) |
| `cloudflared_token` | Token Cloudflare Tunnel |
| `postgresql_username` | Usuario app PostgreSQL |
| `postgresql_password` | Password PostgreSQL |
| `redis_username` | Usuario Redis (`default`) |
| `redis_password` | Password Redis |
| `mongodb_username` | Usuario MongoDB |
| `mongodb_password` | Password MongoDB |
| `qdrant_api_key` | API Key Qdrant |
| `openmemory_openai_api_key` | OpenAI API Key |
| `sonarqube_password` | Password SonarQube |
| `grafana_username` | Usuario Grafana (`admin`) |
| `grafana_password` | Password Grafana |

---

## 9. GitOps y Orden de Despliegue

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/ — recurse: true)
        ├── Wave 1:  longhorn, cert-manager, cloudnative-pg, percona-mongodb-operator, reloader
        ├── Wave 2:  openbao, external-secrets, vault-sync-operator, openbao-init, longhorn-config
        ├── Wave 3:  agentgateway
        ├── Wave 4:  agentgateway-config, argocd-config, cert-manager-config
        ├── Wave 5:  prometheus, grafana-operator, monitoring-stack, cloudflared, headlamp
        ├── Wave 6:  postgresql, mongodb, redis, qdrant, cloudnative-pg cluster, monitors
        ├── Wave 8:  sonarqube, openmemory
        └── Wave 9:  flow
```

### Dependencias implícitas

```
Longhorn ──────────────────────► PostgreSQL, MongoDB, Redis, Qdrant, Prometheus, Grafana, SonarQube

cert-manager ──► Certificate ──► wildcard-home-tls ──► Agent Gateway TLS

OpenBao ──► openbao-init ──► ExternalSecrets sync ──► todos los secrets en cluster

PostgreSQL ────────────────────► SonarQube, Flow API

Qdrant ────────────────────────► OpenMemory
```

---

## 10. Almacenamiento y Recursos

### Volúmenes persistentes

| Componente | Tamaño | StorageClass |
|-----------|--------|-------------|
| PostgreSQL | 10Gi | longhorn-retain |
| MongoDB | 10Gi | longhorn-retain |
| Redis | 5Gi | longhorn-retain |
| Qdrant | 10Gi | longhorn-retain |
| OpenBao | 1Gi | longhorn (default) |
| Prometheus | 20Gi | longhorn (default) |
| Grafana | 5Gi | longhorn (default) |
| Alertmanager | 1Gi | longhorn (default) |
| SonarQube | 10Gi | longhorn (default) |
| **Total** | **~72Gi** | |

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

### Fase 1 — Provisioning del nodo (Ansible)

Ansible instala k0s, exporta el kubeconfig, instala Helm y Helmfile, y crea el secret de GitHub para ArgoCD.

```bash
cd ansible
ansible-playbook site.yaml
kubectl get nodes
```

### Fase 2 — Bootstrap del cluster (Helmfile)

Helmfile crea los namespaces (hook presync), instala Cilium y ArgoCD en orden.

```bash
cd bootstrap
helmfile apply
```

Verificar Cilium:

```bash
kubectl -n kube-system rollout status daemonset/cilium
```

Obtener contraseña admin de Argo CD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Fase 3 — Secrets de Vault

Crear el secret de bootstrap **antes** de activar GitOps:

```bash
kubectl create secret generic vault-bootstrap-secrets \
  -n secret-management \
  --from-literal=argocd_github_pat='...' \
  --from-literal=argocd_repo_url='https://github.com/cristsr/homelab' \
  --from-literal=cloudflare_api_token='...' \
  --from-literal=cloudflared_token='...' \
  --from-literal=postgresql_username='appuser' \
  --from-literal=postgresql_password='...' \
  --from-literal=redis_username='default' \
  --from-literal=redis_password='...' \
  --from-literal=mongodb_username='appuser' \
  --from-literal=mongodb_password='...' \
  --from-literal=qdrant_api_key='...' \
  --from-literal=openmemory_openai_api_key='sk-...' \
  --from-literal=sonarqube_password='...' \
  --from-literal=grafana_username='admin' \
  --from-literal=grafana_password='...'
```

### Fase 4 — Activar GitOps (ArgoCD)

```bash
kubectl apply -f gitops/root-app.yaml
```

A partir de aquí ArgoCD sincroniza el cluster con el repositorio Git siguiendo el orden de sync-waves.

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

### Resumen del flujo

```
cd ansible && ansible-playbook site.yaml   # k0s + kubeconfig + helm + helmfile + argocd secret
cd bootstrap && helmfile apply             # namespaces + cilium + argocd
kubectl create secret generic vault-bootstrap-secrets -n secret-management ...
kubectl apply -f gitops/root-app.yaml      # GitOps activo → ArgoCD despliega el resto
```

---

## Troubleshooting

**Apps en Unknown — cluster secret:**
```bash
CA_DATA=$(kubectl get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)
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
```

**ClusterSecretStore False:**
```bash
kubectl get clustersecretstore openbao -o wide
kubectl describe clustersecretstore openbao
```

**OpenBao sellado tras restart:**
```bash
# Obtener unseal key (guardada manualmente tras el primer init)
kubectl exec -n secret-management openbao-0 -- bao operator unseal <UNSEAL_KEY>
```

**Longhorn stuck:**
```bash
kubectl create serviceaccount longhorn-sa -n argocd
kubectl create clusterrolebinding longhorn-temp --clusterrole=cluster-admin --serviceaccount=argocd:longhorn-sa
```
