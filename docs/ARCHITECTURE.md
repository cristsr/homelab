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

Homelab de un solo nodo construido sobre Talos Linux (VM en Proxmox VE) con GitOps completo. ArgoCD gestiona todas las aplicaciones desde este repositorio. El ingress esta dividido entre dos Gateway API implementations: **Cilium Gateway API** para el trafico HTTP generico y **Agent Gateway** retenido solo para las rutas de servidores MCP (ver [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-para-ingress-genérico-agent-gateway-solo-para-mcp)). Cloudflare Tunnel expone servicios seleccionados a Internet sin abrir puertos en el router. Ver [ADR-014](DECISIONS.md#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv) para el contexto completo de la migración desde k0s/libvirt/Fedora. Los servicios de datos (PostgreSQL, MongoDB, Qdrant, Redis) corren **fuera del cluster**, en LXC de Proxmox (ver [ADR-016](DECISIONS.md) y §5).

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
| Bases de datos | PostgreSQL 17, MongoDB 8.0, Qdrant v1.x, Redis 8 en LXC de Proxmox (ADR-016) |
| Tunel Internet | Cloudflare Tunnel (cloudflared) |
| Monitoreo | kube-prometheus-stack + Grafana Operator |
| Secrets | 1Password + External Secrets Operator |
| Runtime security | Tetragon |

### Estructura del repositorio

```
homelab/
├── terraform/
│   ├── infra/                   # VM Talos + LXC de datos en Proxmox (provider bpg/proxmox + siderolabs/talos)
│   │   ├── proxmox.tf            # VM, discos (instalacion + dedicado a ZFS), ISO de Talos
│   │   ├── lxc.tf                # Cuatro LXC de datos: PostgreSQL, MongoDB, Qdrant, Redis
│   │   ├── talos.tf              # machine config, bootstrap, kubeconfig/talosconfig generados
│   │   ├── variables.tf          # Sizing, red, schematic de Talos
│   │   ├── outputs.tf            # vm_static_ip, kubeconfig_path, talosconfig_path
│   │   └── generated/            # kubeconfig/talosconfig (gitignored)
│   └── cluster/                  # Bootstrap de Kubernetes (una vez el cluster ya arranco)
│       ├── bootstrap.tf          # helm_release: Cilium, ArgoCD
│       ├── namespaces.tf         # Namespaces base
│       ├── secrets.tf            # Secrets iniciales (repo-creds, in-cluster)
│       ├── storage.tf            # Job que crea el zpool de OpenEBS ZFS LocalPV
│       └── variables.tf          # kubeconfig_path, credenciales de ArgoCD
│
├── ansible/                    # Preflight + aprovisionamiento de las LXC de datos (Talos no tiene SSH)
│   ├── tasks/
│   │   ├── preflight-secrets.yaml        # Valida que las credenciales no esten vacias
│   │   ├── preflight-remote-checks.yaml  # Chequeos de conectividad remota
│   │   └── install-podman.yaml           # Instalacion compartida de Podman + auto-update
│   ├── data-services.yaml      # Levanta postgresql/mongodb/qdrant/redis via Podman Quadlet
│   ├── bootstrap-lxc-ssh.yaml   # Siembra la pubkey de SSH en las LXC via pct exec
│   ├── ansible.cfg             # Configuracion de Ansible
│   ├── inventory.yaml          # localhost + las LXC de datos (Talos no expone SSH/shell al nodo)
│   └── preflight.yaml          # Corre antes de `terraform apply` en CI (falla rapido)
│
├── secrets/
│   └── homelab.env.example     # Plantilla de credenciales de infra y de las LXC de datos, gitignored el real
│
├── scripts/
│   └── apply-real-secrets.sh    # Carga secrets/homelab.env en los SopsSecret/env cifrados del repo (manual, no corre en CI)
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
│       │   ├── storage/        # OpenEBS ZFS LocalPV
│       │   ├── devtools/       # OpenMemory
│       │   ├── observability/  # Prometheus, Grafana, Headlamp
│       │   ├── secret-management/ # ClusterSecretStore de 1Password, External Secrets
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
│   ├── devtools/
│   ├── observability/
│   ├── secret-management/
│   └── security/
│
├── workloads/                  # Aplicaciones de usuario/negocio
│   ├── flow/                   # Flow API (Deployment, ExternalSecret, HTTPRoute)
│   ├── portfolio/              # Sitio personal (Deployment, ConfigMap, HTTPRoute)
│   └── sonarqube/              # SonarQube + MCP server (DB externa, ver §5)
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
| Timeout de reconciliacion | `180s` (unico mecanismo de sync desde ADR-019 — el webhook de GitHub se retiro, ver `docs/DECISIONS.md`) |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.internal.cristianpuenguenan.online` |
| Tolerations | `node-role.kubernetes.io/control-plane:NoSchedule` (cluster de un solo nodo, ver §2.1) |

### 2.4 Namespaces

Creados por `terraform/cluster/namespaces.tf` (`kubernetes_namespace_v1.namespaces`, `for_each` sobre una lista fija) o con `syncOptions: CreateNamespace=true` en la Application de ArgoCD correspondiente:

| Namespace | Contenido |
|-----------|-----------|
| `argocd` | Argo CD |
| `apps` | Flow API, Portfolio |
| `devtools` | OpenMemory |
| `openebs` | OpenEBS ZFS LocalPV |
| `networking` | Cilium Gateway, Agent Gateway (MCP), cloudflared, cert-manager, private-dns |
| `observability` | Prometheus, Grafana, Alertmanager, Headlamp |
| `secret-management` | ClusterSecretStore de 1Password, External Secrets, Reloader |
| `tetragon` | Tetragon |
| `sonarqube` | SonarQube, MCP server |

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

Secret: `cloudflared-token` (via ExternalSecret desde el item `infra/cloudflared` en 1Password).

### 3.5 Headlamp (UI Kubernetes)

**Chart**: `headlamphq/headlamp` — **Namespace**: `observability`

Dashboard web para inspeccionar el estado del cluster.

| Parametro | Valor |
|-----------|-------|
| Service | ClusterIP:80 |
| Acceso | `headlamp.internal.cristianpuenguenan.online` via Cilium Gateway API |

### 3.6 1Password (Secrets Backend)

Backend de secretos gestionado — vault dedicado **"Homelab"**, sin infraestructura propia que correr en el cluster ni en ninguna LXC (ver ADR-017).

| Parametro | Valor |
|-----------|-------|
| Vault | `Homelab` |
| Autenticacion | Service Account token (solo lectura, acotado a ese vault) |
| Token | Secret de Kubernetes `onepassword-service-account-token`, namespace `secret-management` |
| Modelo de items | Un item por `remoteRef.key` de los ExternalSecret, un campo por `remoteRef.property` |

No hay proceso propio que inicializar, sellar/desellar, ni policies/roles que mantener — eso es justamente lo que reemplazó a OpenBao (ver ADR-017 para el detalle de por qué).

### 3.7 External Secrets Operator

**Chart**: `external-secrets/external-secrets` — **Namespace**: `secret-management`

Sincroniza secrets desde 1Password hacia Kubernetes.

| Recurso | Detalle |
|---------|---------|
| ClusterSecretStore | `onepassword` — provider `onepasswordSDK`, vault `Homelab` |
| Auth | Service Account token (`onepassword-service-account-token`) |

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
Env:      QDRANT_HOST=qdrant.internal.cristianpuenguenan.online (LXC externo, §5)
Secrets:  openmemory-secrets (OPENAI_API_KEY) via ExternalSecret
```

### 4.3 SonarQube Community

**Chart**: `SonarSource/sonarqube` — **Namespace**: `sonarqube`

Analisis estatico de calidad de codigo.

```
Edition:  Community
Port:     9000
DB:       PostgreSQL en el LXC externo (§5): jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube
```

---

## 5. Bases de Datos

Los servicios de datos **no corren en el cluster**: viven en cuatro LXC de Proxmox VE, creados por Terraform (`terraform/infra/lxc.tf`) como Debian 13 base — bridge `vmbr0`, datastore `local-lvm`, IP estatica en la LAN. Ver [ADR-016](DECISIONS.md) para la decision y sus trade-offs. La instalacion de los motores dentro de los LXC esta pendiente (aprovisionamiento posterior); los consumidores ya apuntan a los hostnames que `private-dns` (§7) resuelve, igual que las rutas privadas HTTP.

### 5.1 Los cuatro LXC

| LXC | vmid | IP | Hostname (`private-dns`) | Motor |
|-----|------|----|--------------------------|-------|
| `postgresql` | 121 | `192.168.80.31` | `postgres.internal.cristianpuenguenan.online` | PostgreSQL 17 — bases `homelab` y `sonarqube` |
| `mongodb` | 122 | `192.168.80.32` | `mongodb.internal.cristianpuenguenan.online` | MongoDB 8.0 |
| `qdrant` | 123 | `192.168.80.33` | `qdrant.internal.cristianpuenguenan.online` | Qdrant v1.x (REST 6333, gRPC 6334) |
| `redis` | 124 | `192.168.80.34` | `redis.internal.cristianpuenguenan.online` | Redis 8 (puerto 6379) |

Un unico PostgreSQL multi-base (`homelab` + `sonarqube`) reemplaza las dos instancias separadas que corrian en el cluster. Ya no hay operadores ni CRDs de bases de datos dentro de Kubernetes — el ciclo de vida de los LXC es responsabilidad de Terraform, y su SO se actualiza como cualquier Debian, independiente del cluster. Los motores de la tabla son el estado objetivo: los contenedores se crean base y la instalacion de cada motor queda pendiente de un aprovisionamiento posterior (ver ADR-016).

### 5.2 Endpoints de los consumidores

| Consumidor | Endpoint |
|------------|----------|
| SonarQube | `jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube` (`SONAR_JDBC_URL`, credenciales via ExternalSecret) |
| OpenMemory | `qdrant.internal.cristianpuenguenan.online:6333` (`QDRANT_HOST`/`QDRANT_PORT`) |
| Flow API | URLs de PostgreSQL/MongoDB/Redis en 1Password (item `apps/flow`), como valores planos |

Los backups y tareas operativas sobre las bases se documentan en `docs/OPERATIONS.md` §3.

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

Ver ADR-011 en [DECISIONS.md](DECISIONS.md). Solo 2 de las 12 rutas son publicas de verdad (`portfolio`, `api` `/webhooks`) — el resto (ArgoCD, Grafana, Headlamp, Hubble, SonarQube UI, admin UI de Agent Gateway, OpenMemory UI/API, SonarQube MCP) son herramientas de administracion, accesibles solo desde la LAN de casa o el tailnet del usuario. OpenEBS (reemplazo de Longhorn, ver ADR-013) no expone UI web — no hay ruta equivalente que administrar.

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

Que hostname resuelve contra que Gateway lo decide, para el trafico publico, la configuracion del tunel de Cloudflare (Zero Trust → Public Hostnames, gestionada fuera de Git); para LAN/Tailscale, `private-dns` (CoreDNS, `platform/networking/private-dns/`) resuelve `internal.cristianpuenguenan.online` a la IP fija correspondiente, y los hostnames de los LXC de datos (§5) a sus IPs en la LAN — ver `docs/OPERATIONS.md` para configurar Tailscale Split DNS.

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

Las credenciales de las LXC de datos vivian antes en `secrets/homelab.env` (plano, gitignored); desde ADR-018 viven cifradas en `ansible/data-services.env` (SOPS + age), consumido por CI via `sops exec-env` antes de correr `ansible/data-services.yaml`. En CI, el preflight de credenciales usa GitHub Actions secrets/vars para lo que Terraform consume (ver `docs/CI_CD_HYPERVISOR_SETUP.md`).

### Gestion de Secretos en el Cluster (SOPS + age, ver ADR-018 y ADR-019)

1. **SOPS + age** es la unica fuente de verdad de los secretos de la aplicacion (dentro y fuera del cluster) — cada valor se cifra con la clave publica de `age` y se commitea cifrado al repo. No hay backend externo, no hay rate limit.
2. **Terraform** (`terraform/cluster/secrets.tf`) crea los secrets iniciales de ArgoCD (`github-repo-creds`, `in-cluster-secret`).
3. **`sops-secrets-operator`** (namespace `sops`) corre en el cluster con la clave privada de `age` montada, y traduce cada `SopsSecret` (CRD, cifrado) a un `Secret` de Kubernetes real. ArgoCD aplica el `SopsSecret` tal cual, cifrado — nunca necesita saber de SOPS.
4. La **clave privada de `age`** es la unica pieza sensible fuera del repo: vive en el `Secret` que monta el operador, y su unico backup es un documento manual en 1Password (`sops-age-homelab-key`, vault "Homelab") — lectura unica para recuperacion de desastre, no una integracion activa. Desde ADR-019, 1Password no tiene ninguna otra integracion en el cluster ni en CI.

#### Inventario de `SopsSecret` (`*.sops.yaml` en el repo)

```
platform/argocd/repo-credentials.sops.yaml          -> PAT de GitHub para ArgoCD
platform/networking/cert-manager/cloudflare-api-token.sops.yaml -> token API Cloudflare (DNS-01)
platform/networking/cloudflared/token.sops.yaml     -> token del tunel Cloudflare
platform/observability/secrets/grafana-admin.sops.yaml -> admin de Grafana
platform/devtools/openmemory/secrets.sops.yaml       -> OPENAI_API_KEY, QDRANT_API_KEY, ghcr-pull-secret
workloads/flow/secrets.sops.yaml                     -> database-url, mongodb-url, redis-url
workloads/sonarqube/secrets.sops.yaml                -> credenciales de DB, passcode de monitoring
ansible/data-services.env (dotenv, no CRD)           -> credenciales de Postgres/Mongo/Redis/Qdrant, solo CI
```

---

## 9. GitOps y Orden de Despliegue

Orden real por `argocd.argoproj.io/sync-wave` (verificado en `gitops/apps/**`, no un valor estimado):

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── Wave -1: homelab-project (AppProject)
        ├── platform/
        │     ├── Wave 1: openebs, cert-manager, reloader
        │     ├── Wave 2: openebs-config, agentgateway-crds, gateway-api-crds, cert-manager-config,
        │     │           external-secrets(-config)
        │     ├── Wave 3: agentgateway, cilium-service-mesh, cilium-hubble-pki
        │     ├── Wave 4: argocd-config, observability/secrets, agentgateway-config, tetragon,
        │     │           cilium-gateway, private-dns
        │     ├── Wave 5: prometheus, cloudflared, headlamp(-config), hubble-config
        │     ├── Wave 6: grafana-config, service-monitors
        │     ├── Wave 7: hubble-dashboards
        │     ├── Wave 8: openmemory
        │     └── Wave 9: openmemory-ui
        └── workloads/
              ├── Wave 8: sonarqube, sonarqube-config, sonarqube-mcp
              └── Wave 9: flow, portfolio
```

### Dependencias implicitas

```
OpenEBS ───────────────────────► PVCs del cluster (Prometheus, Grafana, SonarQube, Alertmanager)

cert-manager (letsencrypt-prod-cloudflare-dns01) ──► wildcard-internal-online-tls ──► listener HTTPS de main
                                                └──► wildcard-home-tls (emitido, no referenciado — ver §3.1 TLS)

1Password (vault Homelab) ──► ExternalSecrets sync ──► todos los secrets

LXC postgresql (externo, §5) ──► SonarQube (base sonarqube), Flow API (base homelab)
LXC qdrant (externo, §5) ──────► OpenMemory
LXC mongodb / redis (externos) ─► Flow API (URLs desde 1Password, item apps/flow)

private-dns ──► los hostnames *.internal de los LXC resuelven para los consumers del cluster
```

---

## 10. Almacenamiento y Recursos

### Volumenes persistentes (estimado)

Las bases de datos ya no consumen PVCs del cluster — viven en los LXC de Proxmox (§5), con disco en `local-lvm` del host de Proxmox.

| Componente | Tamanio | StorageClass |
|-----------|---------|-------------|
| Prometheus | 20Gi | openebs-zfs |
| Grafana | 5Gi | openebs-zfs |
| Alertmanager | 1Gi | openebs-zfs |
| SonarQube | 10Gi | openebs-zfs |
| **Total** | **~37Gi** | |

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

Terraform descarga el ISO de Talos (Image Factory), crea la VM en Proxmox con dos discos, aplica la machine config (incluye el particionado declarativo del disco de ZFS), bootstrapea el cluster y genera `terraform/infra/generated/{kubeconfig,talosconfig}`. En la misma etapa aprovisiona los cuatro LXC de datos (§5, `terraform/infra/lxc.tf`).

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

### Fase 4 — Cargar los secretos reales (manual, no corre en CI)

```bash
cp secrets/homelab.env.example secrets/homelab.env && $EDITOR secrets/homelab.env
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt
./scripts/apply-real-secrets.sh secrets/homelab.env
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
kubectl get clustersecretstore onepassword -o wide
kubectl describe clustersecretstore onepassword
```
Causas típicas: falta el Secret `onepassword-service-account-token` en `secret-management`, el token expiró, o perdió acceso al vault "Homelab".

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
