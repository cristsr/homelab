# Arquitectura del Homelab Kubernetes

## Indice

1. [Vision General](#1-vision-general)
2. [Infraestructura Base](#2-infraestructura-base)
3. [Componentes de Plataforma](#3-componentes-de-plataforma)
4. [Aplicaciones y Herramientas](#4-aplicaciones-y-herramientas)
5. [Bases de Datos](#5-bases-de-datos)
6. [Monitoreo](#6-monitoreo)
7. [Networking y Acceso](#7-networking-y-acceso)
8. [Seguridad y Secretos](#8-seguridad-y-secretos)
9. [GitOps y Orden de Despliegue](#9-gitops-y-orden-de-despliegue)
10. [Almacenamiento y Recursos](#10-almacenamiento-y-recursos)
11. [Flujo de Instalacion Inicial](#11-flujo-de-instalacion-inicial)

---

## 1. Vision General

Homelab de un solo nodo construido sobre Talos Linux (VM en Proxmox VE) con GitOps completo. ArgoCD gestiona todas las aplicaciones desde este repositorio. El ingress esta dividido entre dos Gateway API implementations: **Cilium Gateway API** para el trafico HTTP generico y **Agent Gateway** retenido solo para las rutas de servidores MCP (ver [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-para-ingress-genérico-agent-gateway-solo-para-mcp)). Cloudflare Tunnel expone servicios seleccionados a Internet sin abrir puertos en el router. Ver [ADR-014](DECISIONS.md#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv) para el contexto completo de la migración desde k0s/libvirt/Fedora.

### Stack tecnologico

| Capa | Tecnologia |
|------|-----------|
| Hipervisor | Proxmox VE (provider Terraform `bpg/proxmox`) |
| Kubernetes | Talos Linux v1.14.0 (inmutable, sin SSH) |
| CNI / NetworkPolicy | Cilium 1.20.1 (eBPF, kube-proxy replacement) |
| Ingress / Gateway (generico) | Cilium Gateway API |
| Ingress / Gateway (MCP) | Agent Gateway 1.1.0 |
| GitOps | Argo CD 9.5.13 |
| Certificados TLS | cert-manager: Let's Encrypt (publico y privado, DNS-01 via Cloudflare) |
| Storage | OpenEBS ZFS LocalPV 2.11.1 |
| Tunel Internet | Cloudflare Tunnel (cloudflared) |
| Monitoreo | kube-prometheus-stack + Grafana Operator |
| Secrets | OpenBao 2.5.3 + External Secrets Operator |
| Runtime security | Tetragon |
| Operador PostgreSQL | CloudNative-PG |
| Operador MongoDB | Percona PSMDB Operator |

### Estructura del repositorio

```
homelab/
├── terraform/
│   ├── infra/                   # VM Talos en Proxmox (provider bpg/proxmox + siderolabs/talos)
│   │   ├── proxmox.tf            # VM, discos (instalacion + dedicado a ZFS), ISO de Talos
│   │   ├── talos.tf              # machine config, bootstrap, kubeconfig/talosconfig generados
│   │   ├── variables.tf          # Sizing, red, schematic de Talos
│   │   ├── outputs.tf            # vm_static_ip, kubeconfig_path, talosconfig_path
│   │   └── generated/            # kubeconfig/talosconfig (gitignored)
│   └── cluster/                  # Bootstrap de Kubernetes (una vez el cluster ya arranco)
│       ├── bootstrap.tf          # helm_release: Cilium, ArgoCD
│       ├── namespaces.tf         # Namespaces base
│       ├── secrets.tf            # Secrets iniciales (repo-creds, in-cluster, unseal key)
│       ├── storage.tf            # Job que crea el zpool de OpenEBS ZFS LocalPV
│       └── variables.tf          # kubeconfig_path, credenciales de ArgoCD/OpenBao
│
├── ansible/                    # Preflight de secrets y poblado de OpenBao (Talos no tiene SSH)
│   ├── tasks/
│   │   ├── preflight-secrets.yaml        # Valida que las credenciales no esten vacias
│   │   ├── preflight-remote-checks.yaml  # Chequeos de conectividad remota
│   │   └── openbao-kv-write.yaml         # Port-forward + write generico a OpenBao KV
│   ├── ansible.cfg             # Configuracion de Ansible
│   ├── inventory.yaml          # localhost - Talos no expone SSH/shell al nodo
│   └── preflight.yaml          # Corre antes de `terraform apply` en CI (falla rapido)
│
├── secrets/
│   └── homelab.env.example     # Plantilla de credenciales (infra + apps), gitignored el real
│
├── scripts/
│   └── load-secrets-to-openbao.sh  # Poblar OpenBao (manual, no corre en CI)
│
├── bootstrap/                   # Values/scripts que consume terraform/cluster/bootstrap.tf
│   ├── cilium/values.yaml       # Valores de Cilium (incluye ajustes especificos de Talos)
│   ├── argocd/values.yaml       # Valores de ArgoCD (GitOps)
│   └── adopt-cilium-gateway-secrets.sh  # Hook de idempotencia para el chart de Cilium
│
├── gitops/                     # Aplicaciones de ArgoCD (App of Apps)
│   ├── root-app.yaml           # Aplicacion raiz que apunta a gitops/apps/
│   └── apps/
│       ├── platform/           # ArgoCD Applications de infraestructura
│       │   ├── argocd/         # Configuracion adicional de ArgoCD
│       │   ├── networking/     # cert-manager, cloudflared, agentgateway, cilium-gateway
│       │   ├── storage/        # OpenEBS Local PV LVM
│       │   ├── data-platform/  # PostgreSQL, MongoDB, Redis, Qdrant
│       │   ├── devtools/       # OpenMemory
│       │   ├── observability/  # Prometheus, Grafana, Headlamp
│       │   ├── secret-management/ # OpenBao, External Secrets
│       │   └── security/       # Tetragon
│       └── workloads/          # ArgoCD Applications de apps de usuario
│           ├── flow.yaml
│           ├── portfolio.yaml
│           └── sonarqube/
│
├── platform/                   # Manifiestos y valores Helm de infraestructura
│   ├── argocd/
│   ├── networking/
│   ├── storage/
│   ├── data-platform/
│   ├── devtools/
│   ├── observability/
│   └── secret-management/
│
├── workloads/                  # Aplicaciones de usuario/negocio
│   ├── flow/                   # Flow API (Deployment, ExternalSecret, HTTPRoute)
│   ├── portfolio/              # Sitio personal (Deployment, ConfigMap, HTTPRoute)
│   └── sonarqube/              # SonarQube + DB + MCP server
│
└── docs/                       # Documentacion del proyecto
    ├── ARCHITECTURE.md
    ├── INSTALL.md
    ├── OPERATIONS.md
    ├── DECISIONS.md
    └── CI_CD_HYPERVISOR_SETUP.md
```

---

## 2. Infraestructura Base

### 2.1 Talos Linux (Kubernetes)

**Version**: `v1.14.0` — **Modo**: Single node (controlplane, sin workers separados)

- Corre en una VM sobre Proxmox VE, provisionada por Terraform (`terraform/infra/`, ver [ADR-014](DECISIONS.md#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv)).
- Talos es inmutable y no tiene SSH ni shell: la configuracion es 100% declarativa via machine config, aplicada por el provider Terraform `siderolabs/talos` (`terraform/infra/talos.tf`). Ya no hay Ansible aprovisionando el sistema operativo del nodo.
- El ISO se genera con el [Image Factory](https://factory.talos.dev) a partir de un schematic con las extensiones `qemu-guest-agent`, `tailscale` y `zfs` (`talos_schematic_id` en `terraform/infra/variables.tf`).
- kube-proxy esta deshabilitado (`cluster.proxy.disabled = true`, reemplazado por Cilium eBPF); el CNI tambien queda deshabilitado a nivel de Talos (`cluster.network.cni.name = "none"`) para que lo instale Cilium.
- El control-plane corre workloads (cluster de un solo nodo): varios charts (ArgoCD, el Job de OpenEBS ZFS) necesitan `tolerations` explicitas para el taint `node-role.kubernetes.io/control-plane:NoSchedule`.

| Parametro | Valor |
|-----------|-------|
| `vm_static_ip` (nodo) | `192.168.80.x` (LAN real, bridge `vmbr0` de Proxmox) |
| Pod CIDR (Cilium `ipam.operator.clusterPoolIPv4PodCIDRList`) | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` (default de Talos) |
| Disco de instalacion | `/dev/vda` (`virtio0`) |
| Disco dedicado a ZFS | `/dev/vdb` (`virtio1`, particionado declarativamente con `RawVolumeConfig`, label `r-openebs-zfs`) |

### 2.2 Cilium (CNI)

**Chart**: `cilium/cilium` — **Namespace**: `kube-system` — **Version**: `1.20.1`

Reemplaza completamente kube-proxy con eBPF. Provee conectividad de pods, NetworkPolicies y observabilidad via Hubble.

| Parametro | Valor |
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
| Daemon run path | `/var/run/cilium` |
| `cgroup.autoMount.enabled` | `false` (Talos ya monta cgroupv2/bpffs) |
| `securityContext.capabilities` | Ajustado sin `SYS_MODULE` — Talos no permite a los workloads cargar modulos de kernel |

### 2.3 Argo CD (GitOps)

**Chart**: `argo/argo-cd` — **Namespace**: `argocd` — **Version**: `9.5.13`

Controla el ciclo de vida de todas las aplicaciones del cluster. La `root-app` apunta a `gitops/apps/` y crea las sub-aplicaciones que despliegan cada componente.

| Parametro | Valor |
|-----------|-------|
| `server.ingress.enabled` | `false` (gestionado por HTTPRoute contra el Gateway de Cilium) |
| `server.insecure` | `true` (TLS terminado en el Gateway `main` con Let's Encrypt — el backend siempre habla HTTP plano, ver §3.1 TLS) |
| Timeout de reconciliacion | `600s` (fallback de seguridad — el sync real lo dispara un webhook de GitHub en segundos, ver `docs/TODO.md`) |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.internal.cristianpuenguenan.online` |
| Tolerations | `node-role.kubernetes.io/control-plane:NoSchedule` (cluster de un solo nodo, ver §2.1) |

### 2.4 Namespaces

Creados por `terraform/cluster/namespaces.tf` (`kubernetes_namespace_v1.namespaces`, `for_each` sobre una lista fija) o con `syncOptions: CreateNamespace=true` en la Application de ArgoCD correspondiente:

| Namespace | Contenido |
|-----------|-----------|
| `argocd` | Argo CD |
| `apps` | Flow API, Portfolio |
| `data-platform` | Operadores: CloudNative-PG, Percona PSMDB |
| `infra` | PostgreSQL, MongoDB, Redis, Qdrant (instancias, no operadores) |
| `devtools` | OpenMemory |
| `openebs` | OpenEBS ZFS LocalPV |
| `networking` | Cilium Gateway, Agent Gateway (MCP), cloudflared, cert-manager, private-dns |
| `observability` | Prometheus, Grafana, Alertmanager, Headlamp |
| `secret-management` | OpenBao, External Secrets, Reloader |
| `tetragon` | Tetragon |
| `sonarqube` | SonarQube, SonarQube DB, MCP server |

---

## 3. Componentes de Plataforma

### 3.1 Ingress: tres Gateway API, uno por audiencia

Ver [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-para-ingress-genérico-agent-gateway-solo-para-mcp), ADR-011 y ADR-012 en [DECISIONS.md](DECISIONS.md). Los tres `Gateway` viven en el namespace `networking`. `main` termina TLS en HTTPS:443 con un certificado real de Let's Encrypt (ver TLS abajo); su puerto 80 solo hace redirect a HTTPS. `agentgateway-mcp` sirve HTTP:80 plano puertas adentro (su controller no soporta listeners HTTPS, ADR-012) pero no tiene IP externa propia: sus 3 rutas entran igual por HTTPS, vía `main` haciendo de proxy TLS hacia su Service. `public` escucha HTTP:80 plano — el TLS de cara a Internet lo termina Cloudflare en el borde del tunel. La separacion entre `public` y `main` no es por tipo de trafico sino por **audiencia**: `public` es el unico Gateway al que apunta el wildcard de Cloudflare — lo que es publico queda decidido por que `HTTPRoute` vive ahi, no por una lista aparte.

#### 3.1.a Cilium Gateway API — público (`public`)

**`Gateway`**: `public` (`platform/networking/cilium-gateway/gateway-public.yaml`) — **Service generado**: `cilium-gateway-public` — sin IP LAN fija (solo lo consume `cloudflared`, via `ClusterIP`)

Único Gateway alcanzable desde Internet — las únicas dos rutas que deben serlo:

| Subdominio | Backend | Namespace |
|-----------|---------|-----------|
| `api.cristianpuenguenan.online` | flow:80 (`/flow`, `/webhooks`) | apps |
| `portfolio.cristianpuenguenan.online` | portfolio:80 | apps |

#### 3.1.b Cilium Gateway API — privado (`main`)

**`GatewayClass`**: `cilium` (creada automaticamente por Cilium al habilitar `gatewayAPI.enabled: true`) — **`Gateway`**: `main` (`platform/networking/cilium-gateway/gateway.yaml`) — **Service generado**: `cilium-gateway-main` — IP LAN fija `192.168.80.240` (Cilium L2 Announcements, ver §7) — listeners: `https` (443, TLS terminate con `wildcard-internal-online-tls`) y `http` (80, solo redirect)

Herramientas de administracion/observabilidad — solo alcanzables por LAN/Tailscale, nunca por el wildcard de Cloudflare:

| Subdominio | Backend | Namespace |
|-----------|---------|-----------|
| `argocd.internal.cristianpuenguenan.online` | argocd-server:80 | argocd |
| `grafana.internal.cristianpuenguenan.online` | prometheus-grafana:80 | observability |
| `headlamp.internal.cristianpuenguenan.online` | headlamp:80 | observability |
| `hubble.internal.cristianpuenguenan.online` | hubble-ui:80 | kube-system |
| `openbao.internal.cristianpuenguenan.online` | openbao:8200 | secret-management |
| `openmemory.internal.cristianpuenguenan.online` | openmemory-ui:3000 | devtools |
| `sonarqube.internal.cristianpuenguenan.online` | sonarqube-sonarqube:9000 | sonarqube |

#### 3.1.c Agent Gateway (solo servidores MCP)

**Chart**: `oci://cr.agentgateway.dev/charts/agentgateway` — **`GatewayClass`**: `agentgateway` — **`Gateway`**: `agentgateway-mcp` (`platform/networking/agentgateway/gateway.yaml`) — listener unico `http` (80, HTTP plano — el controller v1.1.0 no soporta listeners HTTPS, ver ADR-012) — **Service generado**: `agentgateway-mcp`, `ClusterIP` (sin IP LAN fija: el unico que lo alcanza es el proxy interno de `main`, ver TLS abajo)

Retenido unicamente para las rutas que aprovechan features reales de protocolo MCP (multiplexing, virtual MCP) que Cilium no ofrece; sigue haciendo su propio ruteo/rewrite/multiplexing con estas `HTTPRoute` (sin cambios):

| Subdominio | Backend | Namespace |
|-----------|---------|-----------|
| `agentgateway.internal.cristianpuenguenan.online` | agentgateway admin UI | networking |
| `openmemory-api.internal.cristianpuenguenan.online` | openmemory:8765 (MCP server) | devtools |
| `mcp.internal.cristianpuenguenan.online` | mcp-sonarqube:3000 (`/sonarqube`) | sonarqube |

#### TLS

Dos planos separados, ambos con certificados reales de Let's Encrypt — ya no hay CA propia (ver ADR-012, actualizacion):

- **Privado (`*.internal.cristianpuenguenan.online`)**: subdominio de un dominio que ya es nuestro, certificado por el mismo `ClusterIssuer` (`letsencrypt-prod-cloudflare-dns01`, DNS-01 via Cloudflare) que emite el wildcard publico — `wildcard-internal-online-tls`, referenciado por el listener HTTPS de `main`. El desafio DNS-01 no exige que el subdominio resuelva a una IP real: no hay ningun registro A/AAAA para `internal.cristianpuenguenan.online`, asi que sigue sin ser alcanzable fuera del tailnet (aunque el wildcard *publico* `*.cristianpuenguenan.online` sí matchea por DNS estas rutas al ser subdominios de el — la conexion real falla igual en el borde de Cloudflare, que rechaza el TLS de cualquier hostname sin un Hostname/certificado propio configurado ahi, ver ADR-012 actualizacion). El puerto 80 de `main` solo responde 301 → HTTPS. Las 3 rutas de `agentgateway-mcp` tambien quedan HTTPS de cara al cliente: su controller sigue sin soportar listeners HTTPS (ADR-012), asi que `main` termina el TLS y reenvia en HTTP plano, puertas adentro del cluster, al Service `agentgateway-mcp` (`platform/networking/cilium-gateway/httproute-agentgateway-proxy.yaml`).
- **Publico (`*.cristianpuenguenan.online`)**: el TLS de cara a Internet lo termina Cloudflare en el borde del tunel; cloudflared habla HTTP al `Gateway public`. El wildcard `wildcard-home-tls` emitido por cert-manager sigue sin estar referenciado por ningun listener del cluster — se mantiene emitido para uso futuro, no es necesario para el flujo actual.

### 3.2 cert-manager

**Chart**: `jetstack/cert-manager` — **Namespace**: `networking`

Automatiza la emision y renovacion de certificados TLS.

| Recurso | Detalle |
|---------|---------|
| ClusterIssuer | `letsencrypt-prod-cloudflare-dns01` (unico, usado por los dos wildcards) |
| Metodo de validacion | DNS-01 via Cloudflare API |
| Certificado publico | Wildcard `*.cristianpuenguenan.online` + apex → `wildcard-home-tls` |
| Certificado privado | Wildcard `*.internal.cristianpuenguenan.online` + apex → `wildcard-internal-online-tls`, usado por `main` |
| Secret del token | `cloudflare-api-token` en namespace `networking` (via ExternalSecret) |

### 3.3 OpenEBS Local PV LVM (Storage)

**Chart**: `zfs-localpv` (`https://openebs.github.io/zfs-localpv`, version `2.11.1`) — **Namespace**: `openebs`

Ver [ADR-013](DECISIONS.md#adr-013-reemplazo-de-longhorn-por-openebs-local-pv-lvm) y [ADR-014](DECISIONS.md#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv) en [DECISIONS.md](DECISIONS.md) (reemplaza a Longhorn/ADR-004, y al motor LVM de ADR-013). PVCs provisionados como datasets ZFS dentro de un zpool (`zfspv-pool`) sobre un disco dedicado de la VM (`vdb`/`virtio1`, ver `terraform/infra/proxmox.tf`). El zpool lo crea un `Job` de Kubernetes (`kubernetes_job_v1.openebs_zpool_create`, `terraform/cluster/storage.tf`) — Talos no expone shell para correr herramientas de ZFS en el host. Sin replicacion (copia unica, local al nodo) — igual trade-off que ya aceptaba Longhorn con `replicaCount: 1`.

| Parametro | Valor |
|-----------|-------|
| `zfsNode.kubeletDir` | Default del chart (`/var/lib/kubelet/`) — Talos usa el path estandar, a diferencia de k0s |
| `analytics.enabled` | `false` |
| StorageClass por defecto | `openebs-zfs` |
| Pool ZFS | `zfspv-pool` (`compression=zstd`, `ashift=12`, `atime=off`) |

#### StorageClasses

| Nombre | ReclaimPolicy | Uso |
|--------|--------------|-----|
| `openebs-zfs` | Delete | Por defecto |
| `openebs-zfs-retain` | Retain | Bases de datos |

### 3.4 Cloudflared (Tunel Internet)

**Imagen**: `cloudflare/cloudflared` — **Namespace**: `networking`

Establece un tunel cifrado saliente hacia Cloudflare sin necesidad de abrir puertos en el router.

Secret: `cloudflared-token` (via ExternalSecret desde OpenBao en `secret/infra/cloudflared`).

### 3.5 Headlamp (UI Kubernetes)

**Chart**: `headlamphq/headlamp` — **Namespace**: `observability`

Dashboard web para inspeccionar el estado del cluster.

| Parametro | Valor |
|-----------|-------|
| Service | ClusterIP:80 |
| Acceso | `headlamp.internal.cristianpuenguenan.online` via Cilium Gateway API |

### 3.6 OpenBao (Secrets Backend)

**Imagen**: `ghcr.io/openbao/openbao:2.5.3` — **Namespace**: `secret-management`

KV v2 secrets engine como backend central de todos los secrets del cluster.

| Parametro | Valor |
|-----------|-------|
| Modo | Production (standalone) |
| Autenticacion | Kubernetes auth |
| KV mount | `secret` (v2) |
| Storage | PVC (`openebs-zfs`, default del cluster) |
| UI | habilitada en `:8200` |

**Init jobs** (`platform/secret-management/openbao/init.yaml`):
- Inicializa OpenBao, habilita Kubernetes auth, crea policies y roles.

> Tras cada restart del pod, OpenBao queda sellado. Requiere unseal manual o configuracion de auto-unseal.

### 3.7 External Secrets Operator

**Chart**: `external-secrets/external-secrets` — **Namespace**: `secret-management`

Sincroniza secrets desde OpenBao hacia Kubernetes.

| Recurso | Detalle |
|---------|---------|
| ClusterSecretStore | `openbao` — apunta a `http://openbao.secret-management.svc.cluster.local:8200` |
| KV version | v2 |
| Auth | Kubernetes (ServiceAccount) |

### 3.8 Reloader

**Chart**: `stakater/reloader` — Namespace segun configuracion en gitops

Reinicia Deployments/StatefulSets automaticamente cuando cambia un Secret o ConfigMap referenciado.

---

## 4. Aplicaciones y Herramientas

### 4.1 Flow API

**Namespace**: `apps`

Aplicacion principal del homelab.

```
Replicas: 1
Port:     80
Secrets:  flow-secrets via ExternalSecret
```

### 4.2 OpenMemory (MCP + Vector Memory)

**Namespace**: `devtools` — **Imagen**: `mem0/openmemory-mcp:latest`

Agente de memoria vectorial para LLMs. Almacena embeddings en Qdrant.

```
Replicas: 1
Port:     8080
Env:      QDRANT_HOST=qdrant.data-platform.svc.cluster.local
Secrets:  openmemory-secrets (OPENAI_API_KEY) via ExternalSecret
```

### 4.3 SonarQube Community

**Chart**: `SonarSource/sonarqube` — **Namespace**: `sonarqube`

Analisis estatico de calidad de codigo.

```
Edition:  Community
Port:     9000
DB:       PostgreSQL en data-platform
```

---

## 5. Bases de Datos

Los operadores viven en `data-platform`; las instancias de bases de datos que administran viven en `infra`.

### 5.1 PostgreSQL — CloudNative-PG

**Operador**: `cloudnative-pg` (namespace `data-platform`) — **CRD**: `kind: Cluster` (namespace `infra`)

| Parametro | Valor |
|-----------|-------|
| Imagen | `ghcr.io/cloudnative-pg/postgresql:17-standard` |
| Storage | `openebs-zfs-retain` |

Servicios generados: `-rw`, `-r`, `-ro`.

### 5.2 MongoDB — Percona Operator

**Operador**: `percona/psmdb-operator` (namespace `data-platform`) — **CRD**: `kind: PerconaServerMongoDB` (namespace `infra`)

| Parametro | Valor |
|-----------|-------|
| Replica set | `rs0` (1 miembro en nodo unico) |
| Storage | `openebs-zfs-retain` |

### 5.3 Redis

**Imagen**: `redis:8-alpine` — **Namespace**: `infra`

| Parametro | Valor |
|-----------|-------|
| Puerto | 6379 |
| Auth | via Secret |
| Storage | `openebs-zfs-retain` |

### 5.4 Qdrant (Vector DB)

**Chart**: `qdrant/qdrant` — **Namespace**: `infra`

| Parametro | Valor |
|-----------|-------|
| Puerto REST | 6333 |
| Puerto gRPC | 6334 |
| Storage | `openebs-zfs-retain` |

---

## 6. Monitoreo

**Namespace**: `observability`

### Componentes

| Componente | Descripcion |
|-----------|-------------|
| Prometheus | Retencion configurable, scrape via ServiceMonitor |
| Grafana | Dashboards, datasource Prometheus |
| Alertmanager | Alertas |
| node-exporter | Metricas del host |
| kube-state-metrics | Estado de objetos Kubernetes |
| Headlamp | UI de gestion del cluster |

---

## 7. Networking y Acceso

### Acceso segmentado: publico (Cloudflare) vs privado (LAN + Tailscale)

Ver ADR-011 en [DECISIONS.md](DECISIONS.md). Solo 2 de las 12 rutas son publicas de verdad (`portfolio`, `api` `/webhooks`) — el resto (ArgoCD, Grafana, Headlamp, Hubble, OpenBao, SonarQube UI, admin UI de Agent Gateway, OpenMemory UI/API, SonarQube MCP) son herramientas de administracion, accesibles solo desde la LAN de casa o el tailnet del usuario. OpenEBS (reemplazo de Longhorn, ver ADR-013) no expone UI web — no hay ruta equivalente que administrar.

Cada Gateway tiene una IP LAN fija, asignada via Cilium L2 Announcements (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy` en `platform/networking/cilium-gateway/`, `spec.addresses` en cada `Gateway`):

| Gateway / Servicio | IP fija |
|---------|---------|
| `cilium-gateway-main` (rutas genericas, incluidas las 3 de Agent Gateway via proxy) | `192.168.80.240` |
| `private-dns` (CoreDNS, resuelve `internal.cristianpuenguenan.online` para LAN/Tailscale) | `192.168.80.253` |

`agentgateway-mcp` ya no tiene IP LAN fija — es `ClusterIP`, solo alcanzable por el proxy interno de `main` (ver TLS en §3.1).

Con la VM en el bridge real de Proxmox (`vmbr0`, ver [ADR-014](DECISIONS.md#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv)), las IPs de los Gateway son direcciones LAN reales — cualquier dispositivo de la LAN las alcanza directo, sin el port-forward de firewalld que exigia la NAT de libvirt (`ansible/host-network.yaml`, eliminado).

```
Internet (solo portfolio + api /webhooks)
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egreso desde cloudflared, dentro del cluster)
              └── cilium-gateway-public:80 ──► Backend ClusterIP (portfolio/flow-api, por HTTPRoute)

LAN fisica del homelab — acceso directo, sin forward-port
  ├── 192.168.80.240:443 TLS / :80 redirect (cilium-gateway-main,
  │   incluidas las 3 rutas de agentgateway-mcp, reenviadas puertas
  │   adentro en HTTP plano hacia su Service ClusterIP)
  └── 192.168.80.253:53 (private-dns)

Tailscale (dispositivos fuera de la LAN fisica, y el runner de CI)
  └── Nodo Tailscale del hipervisor, rutas /32 acotadas a Proxmox y a la VM
      (ver docs/CI_CD_HYPERVISOR_SETUP.md — NO se anuncia el /24 completo,
      para no forzar todo el trafico LAN del operador por el tunel)
        ├── 192.168.80.240 (cilium-gateway-main)
        └── 192.168.80.253 (private-dns, via Tailscale Split DNS)
```

Que hostname resuelve contra que Gateway lo decide, para el trafico publico, la configuracion del tunel de Cloudflare (Zero Trust → Public Hostnames, gestionada fuera de Git); para LAN/Tailscale, `private-dns` (CoreDNS, `platform/networking/private-dns/`) resuelve `internal.cristianpuenguenan.online` a la IP fija correspondiente — ver `docs/OPERATIONS.md` para configurar Tailscale Split DNS.

### Puertos expuestos

| Puerto | Protocolo | Descripcion |
|--------|-----------|-------------|
| 80/443 | TCP | 80 = redirect a HTTPS, 443 = TLS de `cilium-gateway-main` (IP LAN directa); incluye las 3 rutas de `agentgateway-mcp`, reenviadas puertas adentro |
| 53 | UDP/TCP | DNS de `private-dns` (IP LAN directa) |

### DNS y subdominios

`portfolio`/`api` resuelven via Cloudflare Tunnel (WAN). El resto de las rutas no tiene DNS publico util — resuelven via `private-dns` con Tailscale Split DNS restringido a `internal.cristianpuenguenan.online` (ver §11 en `docs/OPERATIONS.md`). El wildcard publico `*.cristianpuenguenan.online` técnicamente también matchea estos subdominios por DNS, pero la conexion TLS falla en el borde de Cloudflare (ningun Hostname configurado ahi) — no hay forma real de llegar a estas rutas desde fuera del tailnet.

---

## 8. Seguridad y Secretos

### Archivo local de secretos

Todas las credenciales (infra + apps) viven en `secrets/homelab.env`, plano y **nunca commiteado** (`.gitignore`). No hay cifrado en reposo en git — la carga a OpenBao es siempre manual, nunca corre en CI (ver [ADR-009](DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2)). En CI, el preflight de credenciales usa GitHub Actions secrets/vars en su lugar (ver `docs/CI_CD_HYPERVISOR_SETUP.md`).

| Variable (`secrets/homelab.env`) | Descripcion |
|----------|-------------|
| `ARGOCD_GITHUB_PAT` | PAT de GitHub para ArgoCD |
| `ARGOCD_WEBHOOK_SECRET` | Secret del webhook de GitHub que dispara el sync de ArgoCD |
| `CLOUDFLARE_API_TOKEN` | Token API Cloudflare (DNS-01) |
| `CLOUDFLARED_TOKEN` | Token del tunel Cloudflare |
| `OPENBAO_STATIC_SEAL_KEY` | Clave AES-256 para Static Seal de OpenBao |

### Gestion de Secretos en el Cluster

1. **Terraform** (`terraform/cluster/secrets.tf`) crea el secret `openbao-static-unseal-key` en `secret-management`.
2. **GitOps** despliega OpenBao, que usa la static seal key.
3. **`./scripts/load-secrets-to-openbao.sh`** (manual) escribe los secrets de infraestructura y de apps en OpenBao KV, leyendo `secrets/homelab.env`.
4. **External Secrets Operator** sincroniza desde OpenBao hacia Kubernetes Secrets.

#### Estructura de secretos en OpenBao

```
secret/argocd               -> github_pat, username, url, webhook_secret
secret/infra/cloudflare     -> api_token
secret/infra/cloudflared    -> token
secret/databases/*          -> credenciales de Redis/Qdrant/PostgreSQL/MongoDB
secret/monitoring/grafana   -> username, password
secret/sonarqube/*          -> db-credentials, monitoring (passcode)
secret/devtools/openmemory  -> OPENAI_API_KEY
secret/apps/flow            -> database-url, mongodb-url, redis-url
```

---

## 9. GitOps y Orden de Despliegue

Orden real por `argocd.argoproj.io/sync-wave` (verificado en `gitops/apps/**`, no un valor estimado):

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── Wave -1: homelab-project (AppProject)
        ├── platform/
        │     ├── Wave 1: openebs, cert-manager, cloudnative-pg (operador), percona-mongodb (operador), reloader
        │     ├── Wave 2: openebs-config, agentgateway-crds, gateway-api-crds, cert-manager-config,
        │     │           external-secrets(-config), openbao(-init)
        │     ├── Wave 3: agentgateway, cilium-service-mesh, cilium-hubble-pki, openbao-config
        │     ├── Wave 4: argocd-config, observability/secrets, agentgateway-config, tetragon,
        │     │           cilium-gateway, private-dns
        │     ├── Wave 5: prometheus, cloudflared, headlamp(-config), hubble-config
        │     ├── Wave 6: redis, qdrant, postgresql, mongodb (instancias en `infra`), grafana-config,
        │     │           service-monitors
        │     ├── Wave 7: hubble-dashboards
        │     └── Wave 8: openmemory, openmemory-ui
        └── workloads/
              ├── Wave 7: sonarqube-db
              ├── Wave 8: sonarqube, sonarqube-config, sonarqube-mcp
              └── Wave 9: flow, portfolio
```

### Dependencias implicitas

```
OpenEBS ───────────────────────► Todas las bases de datos y PVCs

cert-manager (letsencrypt-prod-cloudflare-dns01) ──► wildcard-internal-online-tls ──► listener HTTPS de main
                                                └──► wildcard-home-tls (emitido, no referenciado — ver §3.1 TLS)

OpenBao ──► openbao-init ──► ExternalSecrets sync ──► todos los secrets

PostgreSQL ────────────────────► SonarQube, Flow API

Qdrant ────────────────────────► OpenMemory
```

---

## 10. Almacenamiento y Recursos

### Volumenes persistentes (estimado)

| Componente | Tamanio | StorageClass |
|-----------|---------|-------------|
| PostgreSQL | 10Gi | openebs-zfs-retain |
| MongoDB | 10Gi | openebs-zfs-retain |
| Redis | 5Gi | openebs-zfs-retain |
| Qdrant | 10Gi | openebs-zfs-retain |
| OpenBao | 1Gi | openebs-zfs |
| Prometheus | 20Gi | openebs-zfs |
| Grafana | 5Gi | openebs-zfs |
| Alertmanager | 1Gi | openebs-zfs |
| SonarQube | 10Gi | openebs-zfs |
| **Total** | **~72Gi** | |

### Requerimiento minimo de la VM

- **CPU**: 4 cores (default de este repo: 8 vCPU, `var.vcpu`)
- **RAM**: 8 GB (default: 16 GB, `var.memory_mib`)
- **Disco**: 2 discos — instalacion de Talos (default: 120 GB, `var.disk_size_gb`, `virtio0`) + dedicado al zpool de OpenEBS ZFS (default: 100 GB, `var.zfs_disk_size_gb`, `virtio1`, sin formatear)
- **OS**: Talos Linux (ISO generado por el Image Factory, descargado por `proxmox_download_file.talos_iso`)

El **host** (Proxmox VE) necesita margen adicional sobre estos numeros para el hipervisor + overhead de la VM.

---

## 11. Flujo de Instalacion Inicial

### Fase 0 — Preflight (Ansible)

Valida que las credenciales en `secrets/homelab.env` no esten vacias/invalidas antes de gastar tiempo aprovisionando infraestructura.

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

### Fase 1 — VM Talos en Proxmox (`terraform/infra`)

Terraform descarga el ISO de Talos (Image Factory), crea la VM en Proxmox con dos discos, aplica la machine config (incluye el particionado declarativo del disco de ZFS), bootstrapea el cluster y genera `terraform/infra/generated/{kubeconfig,talosconfig}`.

```bash
cd terraform/infra
terraform init -backend-config=backend.hcl
terraform apply
kubectl --kubeconfig generated/kubeconfig get nodes
```

### Fase 2 — Bootstrap de Kubernetes (`terraform/cluster`)

Crea los namespaces, instala Cilium y ArgoCD (`helm_release`) y el Job que crea el zpool de OpenEBS ZFS, en orden via `depends_on`.

```bash
cd ../cluster
terraform init -backend-config=backend.hcl
terraform apply
```

### Fase 3 — Activar GitOps

```bash
kubectl apply -f gitops/root-app.yaml
```

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

### Fase 4 — Poblar OpenBao (manual, no corre en CI)

Una vez que OpenBao este inicializado:

```bash
cp secrets/homelab.env.example secrets/homelab.env   # completar valores
./scripts/load-secrets-to-openbao.sh
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
kubectl exec -n secret-management openbao-0 -- bao operator unseal <UNSEAL_KEY>
```

**Volumen OpenEBS no provisiona (Pending):**
```bash
kubectl get zfsnode -n openebs
kubectl -n openebs logs -l app=openebs-zfs-controller -c openebs-zfs-plugin

# Talos no tiene shell ni herramientas de ZFS en el host: se inspecciona
# desde un pod privilegiado con /dev montado (mismo patron que
# kubernetes_job_v1.openebs_zpool_create en terraform/cluster/storage.tf) -
# las syscalls/ioctls de ZFS son a nivel de kernel, compartidas por todos
# los containers del nodo, sin necesidad de chroot al host.
kubectl debug node/talos -it --image=alpine:3.20 -- \
  sh -c "apk add --no-cache zfs >/dev/null && zpool status zfspv-pool"
```
