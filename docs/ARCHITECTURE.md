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

Homelab de un solo nodo construido sobre k0s con GitOps completo. ArgoCD gestiona todas las aplicaciones desde este repositorio. El ingress esta dividido entre dos Gateway API implementations: **Cilium Gateway API** para el trafico HTTP generico y **Agent Gateway** retenido solo para las rutas de servidores MCP (ver [ADR-010](DECISIONS.md#adr-010-cilium-gateway-api-para-ingress-genérico-agent-gateway-solo-para-mcp)). Cloudflare Tunnel expone servicios seleccionados a Internet sin abrir puertos en el router.

### Stack tecnologico

| Capa | Tecnologia |
|------|-----------|
| Kubernetes | k0s v1.35.3+k0s.0 |
| CNI / NetworkPolicy | Cilium 1.19.3 (eBPF, kube-proxy replacement) |
| Ingress / Gateway (generico) | Cilium Gateway API |
| Ingress / Gateway (MCP) | Agent Gateway 1.1.0 |
| GitOps | Argo CD 9.5.13 |
| Certificados TLS | cert-manager: Let's Encrypt (publico, DNS-01) + CA interna (rutas `.internal`) |
| Storage | OpenEBS Local PV LVM 1.10.0 |
| Tunel Internet | Cloudflare Tunnel (cloudflared) |
| Monitoreo | kube-prometheus-stack + Grafana Operator |
| Secrets | OpenBao 2.5.3 + External Secrets Operator |
| Operador PostgreSQL | CloudNative-PG |
| Operador MongoDB | Percona PSMDB Operator |

### Estructura del repositorio

```
homelab/
├── terraform/                  # Aprovisionamiento de la VM (Terraform + libvirt)
│   ├── versions.tf              # Providers: dmacvicar/libvirt, tls, local
│   ├── provider.tf               # qemu:///system
│   ├── variables.tf               # Imagen base, sizing, red, IP estatica
│   ├── main.tf                     # Pool, volumenes (base + overlay), cloud-init, dominio
│   ├── outputs.tf                   # vm_static_ip, vm_mac, ssh_private_key_path
│   ├── cloud-init/
│   │   ├── user-data.yaml.tpl        # hostname/usuario/ssh-key/growpart (nada de k0s)
│   │   └── network-config.yaml.tpl    # IP estatica (match por MAC + set-name)
│   ├── templates/
│   │   └── inventory.yaml.tftpl        # Genera ansible/inventory.yaml
│   └── generated/                       # Llave SSH generada (gitignored)
│
├── ansible/                    # Aprovisionamiento del nodo (dentro de la VM) y secretos
│   ├── tasks/
│   │   ├── k0s.yaml            # Instalacion y configuracion de k0s
│   │   ├── kubeconfig.yaml     # Export de kubeconfig e instalacion de kubectl
│   │   ├── helm.yaml           # Instalacion de Helm
│   │   ├── openebs-prereqs.yaml  # Prerequisitos de OpenEBS (lvm2 + Volume Group)
│   │   ├── helmfile.yaml       # Instalacion de Helmfile y bootstrap Cilium/ArgoCD
│   │   ├── argocd-secret.yaml  # Secret repo-creds de GitHub para ArgoCD
│   │   └── vault-secrets.yaml  # Namespace secret-management y static unseal key
│   ├── templates/
│   │   └── k0s-config.yaml.j2  # Configuracion de k0s (single node)
│   ├── group_vars/all.yaml     # Variables globales + secrets cifrados (ansible-vault)
│   ├── ansible.cfg             # Configuracion de Ansible
│   ├── inventory.yaml          # Generado por `terraform apply` (grupos k0s + hypervisor)
│   ├── site.yaml               # Playbook principal de instalacion (corre por SSH sobre la VM)
│   ├── host-network.yaml       # Port-forward LAN (firewalld) del host hacia la VM
│   ├── teardown.yaml           # Playbook para destruir el cluster
│   └── vault-populate.yaml     # Playbook para poblar OpenBao KV
│
├── bootstrap/                  # Bootstrap inicial del cluster
│   ├── cilium/values.yaml      # Valores de Cilium (CNI)
│   ├── argocd/values.yaml      # Valores de ArgoCD (GitOps)
│   ├── namespaces.yaml         # Namespaces base
│   └── helmfile.yaml           # Orquesta Cilium + ArgoCD
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
    └── OPERATIONS.md
```

---

## 2. Infraestructura Base

### 2.1 k0s (Kubernetes)

**Version**: `v1.35.3+k0s.0` — **Modo**: Single node controller

- Corre dentro de una VM libvirt provisionada por Terraform (`terraform/`, ver [ADR-008](DECISIONS.md#adr-008-vm-libvirt-provisionada-con-terraform)), no directamente sobre el hardware del host.
- Descarga el binario de k0s y lo registra como servicio systemd (`k0scontroller`) — via Ansible, por SSH a la VM.
- Configuracion en `/etc/k0s/k0s.yaml` generada desde plantilla Jinja2.
- kube-proxy esta deshabilitado (reemplazado por Cilium eBPF).
- CIDRs configurables via variables de Ansible.

| Parametro | Valor por defecto |
|-----------|-------------------|
| `k0s_node_ip` | `192.168.122.10` (IP interna de la VM en la red NAT `default`) |
| `k0s_pod_cidr` | `10.244.0.0/16` |
| `k0s_service_cidr` | `10.96.0.0/12` |

> `192.168.80.20` sigue siendo la IP del host en la LAN — ya no es la IP del nodo, es el destino del port-forward (ver §7).

### 2.2 Cilium (CNI)

**Chart**: `cilium/cilium` — **Namespace**: `kube-system` — **Version**: `1.19.3`

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
| CNI bin path | `/opt/cni/bin` |
| Daemon run path | `/var/run/cilium` |

### 2.3 Argo CD (GitOps)

**Chart**: `argo/argo-cd` — **Namespace**: `argocd` — **Version**: `9.5.13`

Controla el ciclo de vida de todas las aplicaciones del cluster. La `root-app` apunta a `gitops/apps/` y crea las sub-aplicaciones que despliegan cada componente.

| Parametro | Valor |
|-----------|-------|
| `server.ingress.enabled` | `false` (gestionado por HTTPRoute contra el Gateway de Cilium) |
| `server.insecure` | `true` (TLS terminado en el Gateway `main` con Let's Encrypt — el backend siempre habla HTTP plano, ver §3.1 TLS) |
| Timeout de reconciliacion | `180s` |
| RBAC por defecto | `role:readonly` |
| Dominio | `argocd.internal.cristianpuenguenan.online` |

### 2.4 Namespaces

Declarados en `bootstrap/namespaces.yaml` y creados por el hook presync de Cilium en el helmfile:

| Namespace | Contenido |
|-----------|-----------|
| `argocd` | Argo CD |
| `apps` | Flow API, Portfolio |
| `data-platform` | CloudNative-PG, Percona operators |
| `infra` | PostgreSQL, MongoDB, Redis, Qdrant |
| `devtools` | OpenMemory |
| `openebs` | OpenEBS Local PV LVM |
| `networking` | Cilium Gateway, Agent Gateway (MCP), cloudflared, cert-manager |
| `observability` | Prometheus, Grafana, Alertmanager, Headlamp |
| `secret-management` | OpenBao, External Secrets |
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

**`GatewayClass`**: `cilium` (creada automaticamente por Cilium al habilitar `gatewayAPI.enabled: true`) — **`Gateway`**: `main` (`platform/networking/cilium-gateway/gateway.yaml`) — **Service generado**: `cilium-gateway-main` — IP LAN fija `192.168.122.240` (Cilium L2 Announcements, ver §7) — listeners: `https` (443, TLS terminate con `wildcard-internal-online-tls`) y `http` (80, solo redirect)

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

**Chart**: `lvm-localpv` (`https://openebs.github.io/lvm-localpv`) — **Namespace**: `openebs`

Ver ADR-013 en [DECISIONS.md](DECISIONS.md) (reemplaza a Longhorn/ADR-004). PVCs provisionados como
Logical Volumes dentro de un Volume Group LVM (`vg-openebs`) sobre un disco dedicado de la VM
(`vdb`, ver ADR-008/terraform). Sin replicacion (copia unica, local al nodo) — igual trade-off
que ya aceptaba Longhorn con `replicaCount: 1`.

| Parametro | Valor |
|-----------|-------|
| `global.kubeletDir` / `lvmNode.kubeletDir` | `/var/lib/k0s/kubelet/` |
| `lvmNode.serviceMonitor.enabled` | `true` |
| `analytics.enabled` | `false` |
| StorageClass por defecto | `openebs-lvm` |
| Volume Group | `vg-openebs` (creado por Ansible, ver `ansible/tasks/openebs-prereqs.yaml`) |

#### StorageClasses

| Nombre | ReclaimPolicy | Uso |
|--------|--------------|-----|
| `openebs-lvm` | Delete | Por defecto |
| `openebs-lvm-retain` | Retain | Bases de datos |

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
| Storage | PVC (`openebs-lvm`, default del cluster) |
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

Todas en namespace `data-platform`.

### 5.1 PostgreSQL — CloudNative-PG

**Operador**: `cloudnative-pg` — **CRD**: `kind: Cluster`

| Parametro | Valor |
|-----------|-------|
| Imagen | `ghcr.io/cloudnative-pg/postgresql:17-standard` |
| Storage | `openebs-lvm-retain` |

Servicios generados: `-rw`, `-r`, `-ro`.

### 5.2 MongoDB — Percona Operator

**Operador**: `percona/psmdb-operator` — **CRD**: `kind: PerconaServerMongoDB`

| Parametro | Valor |
|-----------|-------|
| Replica set | `rs0` (1 miembro en nodo unico) |
| Storage | `openebs-lvm-retain` |

### 5.3 Redis

**Imagen**: `redis:8-alpine` — **Namespace**: `data-platform`

| Parametro | Valor |
|-----------|-------|
| Puerto | 6379 |
| Auth | via Secret |
| Storage | `openebs-lvm-retain` |

### 5.4 Qdrant (Vector DB)

**Chart**: `qdrant/qdrant` — **Namespace**: `data-platform`

| Parametro | Valor |
|-----------|-------|
| Puerto REST | 6333 |
| Puerto gRPC | 6334 |
| Storage | `openebs-lvm-retain` |

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
| `cilium-gateway-main` (rutas genericas, incluidas las 3 de Agent Gateway via proxy) | `192.168.122.240` |
| `private-dns` (CoreDNS, resuelve `internal.cristianpuenguenan.online` para LAN/Tailscale) | `192.168.122.253` |

`agentgateway-mcp` ya no tiene IP LAN fija — es `ClusterIP`, solo alcanzable por el proxy interno de `main` (ver TLS en §3.1).

```
Internet (solo portfolio + api /webhooks)
  └── Cloudflare (DNS + WAF)
        └── Cloudflare Tunnel (egreso desde cloudflared, dentro del cluster)
              └── cilium-gateway-public:80 ──► Backend ClusterIP (portfolio/flow-api, por HTTPRoute)

LAN fisica (sin Tailscale) — via de acceso NO soportada (ADR-012); los
forward-port siguen existiendo pero el puerto 80 responde solo redirect
hacia IPs internas inalcanzables desde la LAN
  └── Host 192.168.80.20 (firewalld forward-port, ansible/host-network.yaml)
        ├── 80/443   → 192.168.122.240:80/443 (cilium-gateway-main)
        └── 53/udp+tcp → 192.168.122.253:53 (private-dns)

Tailscale (cualquier dispositivo del usuario, desde cualquier lado) — via prioritaria
  └── Subnet router en el hipervisor (`tailscale up --advertise-routes=192.168.122.0/24`)
        ├── 192.168.122.240:443 TLS / :80 redirect (cilium-gateway-main,
        │   incluidas las 3 rutas de agentgateway-mcp, reenviadas puertas
        │   adentro en HTTP plano hacia su Service ClusterIP)
        └── 192.168.122.253:53 (private-dns, via Tailscale Split DNS)
```

Que hostname resuelve contra que Gateway lo decide, para el trafico publico, la configuracion del tunel de Cloudflare (Zero Trust → Public Hostnames, gestionada fuera de Git); para LAN/Tailscale, `private-dns` (CoreDNS, `platform/networking/private-dns/`) resuelve `internal.cristianpuenguenan.online` a la IP fija correspondiente — ver §11 en `docs/OPERATIONS.md` para configurar Tailscale Split DNS.

La VM corre en la red NAT de libvirt (`192.168.122.0/24`) porque el host solo tiene WiFi activa — bridging de una VM sobre WiFi es fragil con la mayoria de drivers/APs (ver ADR-008).

### Puertos expuestos

| Puerto | Protocolo | Descripcion |
|--------|-----------|-------------|
| 80/443 | TCP | 80 = redirect a HTTPS, 443 = TLS de `cilium-gateway-main` (host → IP fija via forward-port); incluye las 3 rutas de `agentgateway-mcp`, reenviadas puertas adentro |
| 53 | UDP/TCP | DNS de `private-dns` (host → IP fija via forward-port) |

### DNS y subdominios

`portfolio`/`api` resuelven via Cloudflare Tunnel (WAN). El resto de las rutas no tiene DNS publico util — resuelven via `private-dns` con Tailscale Split DNS restringido a `internal.cristianpuenguenan.online` (ver §11 en `docs/OPERATIONS.md`). El wildcard publico `*.cristianpuenguenan.online` técnicamente también matchea estos subdominios por DNS, pero la conexion TLS falla en el borde de Cloudflare (ningun Hostname configurado ahi) — no hay forma real de llegar a estas rutas desde fuera del tailnet.

---

## 8. Seguridad y Secretos

### Ansible Vault

Todas las variables sensibles se almacenan cifradas en `ansible/group_vars/all.yaml` usando `ansible-vault`.

| Variable | Descripcion |
|----------|-------------|
| `argocd_github_pat` | PAT de GitHub para ArgoCD |
| `cloudflare_api_token` | Token API Cloudflare (DNS-01) |
| `cloudflared_token` | Token del tunel Cloudflare |
| `openbao_static_seal_key` | Clave AES-256 para Static Seal de OpenBao |

El archivo de contrasena del vault es `ansible/.vault-pass` (referenciado en `ansible.cfg` y excluido de Git via `.gitignore`).

### Gestion de Secretos en el Cluster

1. **Ansible** crea el secret `openbao-static-unseal-key` en `secret-management`.
2. **GitOps** despliega OpenBao, que usa la static seal key.
3. **vault-populate.yaml** escribe secrets de infraestructura en OpenBao KV.
4. **External Secrets Operator** sincroniza desde OpenBao hacia Kubernetes Secrets.

#### Estructura de secretos en OpenBao

```
secret/argocd          -> github_pat, username, url
secret/infra/cloudflare -> api_token
secret/infra/cloudflared -> token
```

---

## 9. GitOps y Orden de Despliegue

```
root-app (gitops/root-app.yaml)
  └── App of Apps (gitops/apps/)
        ├── platform/
        │     ├── Wave 1:  openebs, cert-manager, operators (cloudnative-pg, percona)
        │     ├── Wave 2:  openbao, external-secrets, init jobs, gateway-api-crds
        │     ├── Wave 3:  agentgateway, cilium (con gatewayAPI.enabled)
        │     ├── Wave 4:  agentgateway-config, cilium-gateway, private-dns, argocd-config, cert-manager-config
        │     ├── Wave 5:  monitoring, cloudflared, headlamp
        │     ├── Wave 6:  postgresql, mongodb, redis, qdrant
        │     └── Wave 8:  openmemory
        └── workloads/
              ├── Wave 7:  sonarqube-db
              ├── Wave 8:  sonarqube, sonarqube-config, sonarqube-mcp
              └── Wave 9:  flow, portfolio
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
| PostgreSQL | 10Gi | openebs-lvm-retain |
| MongoDB | 10Gi | openebs-lvm-retain |
| Redis | 5Gi | openebs-lvm-retain |
| Qdrant | 10Gi | openebs-lvm-retain |
| OpenBao | 1Gi | openebs-lvm |
| Prometheus | 20Gi | openebs-lvm |
| Grafana | 5Gi | openebs-lvm |
| Alertmanager | 1Gi | openebs-lvm |
| SonarQube | 10Gi | openebs-lvm |
| **Total** | **~72Gi** | |

### Requerimiento minimo de la VM

- **CPU**: 4 cores (default de este repo: 8 vCPU)
- **RAM**: 8 GB (default: 16 GB)
- **Disco**: 2 discos - raiz (100 GB SSD recomendado, default: 120 GB overlay qcow2) + dedicado para el VG LVM de OpenEBS (default: 100 GB raw, `vdb`)
- **OS**: Fedora Cloud Base (imagen descargada por Terraform)

El **host** (hipervisor) necesita margen adicional sobre estos numeros para SO + libvirt/KVM + overhead de la VM.

---

## 11. Flujo de Instalacion Inicial

### Fase 0 — Aprovisionamiento de la VM (Terraform)

Terraform crea la VM libvirt (disco overlay sobre una plantilla pristina de Fedora Cloud, cloud-init con IP estatica) y regenera `ansible/inventory.yaml` apuntando a ella.

```bash
cd terraform
terraform init
terraform apply
```

### Fase 1 — Aprovisionamiento del nodo (Ansible)

Ansible instala k0s, exporta kubeconfig, instala kubectl, Helm, Helmfile, prerequisitos de OpenEBS (lvm2 + Volume Group), secret de ArgoCD y secret de OpenBao.

```bash
cd ansible
ansible-playbook site.yaml
kubectl get nodes
```

### Fase 2 — Bootstrap del cluster (Helmfile)

Helmfile (ejecutado via Ansible) crea namespaces, instala Cilium y ArgoCD en orden.

```bash
cd ../bootstrap
helmfile sync
```

### Fase 3 — Activar GitOps

```bash
kubectl apply -f gitops/root-app.yaml
```

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

### Fase 4 — Poblar OpenBao

Una vez que OpenBao este inicializado:

```bash
cd ansible
ansible-playbook vault-populate.yaml
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
kubectl get lvmnode -n openebs
kubectl -n openebs logs -l app=openebs-lvm-controller -c openebs-lvm-plugin
# En el nodo: confirmar que el VG existe y tiene espacio libre
vgs vg-openebs
```
