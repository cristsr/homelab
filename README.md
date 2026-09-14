# Homelab Kubernetes

Infraestructura de homelab personal basada en Kubernetes, orquestada con GitOps. El nodo corre como una VM Talos Linux sobre Proxmox VE, aprovisionada con Terraform.

---

## Que es este proyecto

Este repositorio contiene la configuracion completa para levantar un cluster Kubernetes de un solo nodo usando **Talos Linux** (inmutable, sin SSH), con un stack moderno de plataforma que incluye:

- **GitOps**: ArgoCD gestiona todo el ciclo de vida de las aplicaciones desde Git.
- **Networking**: Cilium como CNI con reemplazo completo de kube-proxy via eBPF.
- **Ingress**: Cilium Gateway API para el trafico generico, Agent Gateway retenido solo para servidores MCP (ver ADR-010).
- **Secretos**: OpenBao como backend de secretos, sincronizado con Kubernetes via External Secrets Operator.
- **Almacenamiento**: OpenEBS ZFS LocalPV como storage local (ver ADR-013 y ADR-014).
- **Monitoreo**: Prometheus, Grafana y Headlamp.
- **Bases de datos**: PostgreSQL, MongoDB, Redis y Qdrant en LXC de Proxmox, fuera del cluster (ver ADR-016).
- **Herramientas**: SonarQube, OpenMemory.
- **Acceso externo**: Cloudflare Tunnel para exponer servicios sin abrir puertos.

La VM se crea con **Terraform** (provider `bpg/proxmox` + `siderolabs/talos`) en dos etapas: `terraform/infra` (VM, Talos, discos) y `terraform/cluster` (namespaces, Cilium, ArgoCD, secrets iniciales). **Ansible** se usa solo para validaciones de preflight y para poblar OpenBao — Talos no tiene SSH ni shell, asi que ya no aprovisiona el sistema operativo del nodo.

---

## Stack Tecnologico

| Capa | Tecnologia | Version |
|------|-----------|---------|
| VM / Hipervisor | Terraform + Proxmox VE (`bpg/proxmox`) | - |
| Kubernetes | Talos Linux (`siderolabs/talos`) | v1.14.0 |
| CNI | Cilium | 1.20.1 |
| GitOps | Argo CD | 9.5.13 |
| Ingress (generico) | Cilium Gateway API | 1.20.1 |
| Ingress (MCP) | Agent Gateway | 1.1.0 |
| Storage | OpenEBS ZFS LocalPV | 2.11.1 |
| Secrets | OpenBao | 2.5.3 |
| Secret Sync | External Secrets Operator | - |
| Monitoreo | kube-prometheus-stack / Grafana Operator | - |
| Ingress TLS | cert-manager + Let's Encrypt + Cloudflare DNS-01 | - |
| Tunel WAN | Cloudflare Tunnel (cloudflared) | - |
| Runtime security | Tetragon | - |
| Bases de datos | PostgreSQL 17, MongoDB 8.0, Qdrant, Redis 8 (LXC de Proxmox) | - |

---

## Estructura del Repositorio

```
homelab/
├── terraform/
│   ├── infra/                   # VM Talos + LXC de datos en Proxmox: disco, red, bootstrap de Talos
│   │   ├── proxmox.tf           # VM, discos (instalacion + dedicado a ZFS), ISO de Talos
│   │   ├── lxc.tf               # Cuatro LXC de datos: PostgreSQL, MongoDB, Qdrant, Redis
│   │   ├── talos.tf             # machine config, bootstrap, kubeconfig/talosconfig generados
│   │   └── generated/           # kubeconfig/talosconfig (gitignored)
│   └── cluster/                 # Bootstrap de Kubernetes sobre el cluster ya arrancado
│       ├── bootstrap.tf         # helm_release: Cilium, ArgoCD
│       ├── namespaces.tf        # Namespaces base
│       ├── secrets.tf           # Secrets iniciales (repo-creds, in-cluster, unseal key)
│       └── storage.tf           # Job que crea el zpool de OpenEBS ZFS LocalPV
│
├── ansible/                     # Preflight de credenciales (ya no aprovisiona SO ni puebla OpenBao)
│   ├── preflight.yaml           # Valida credenciales antes de correr Terraform (falla rapido en CI)
│   ├── ansible.cfg              # Configuracion de Ansible
│   └── tasks/                   # Tareas individuales
│
├── secrets/
│   └── homelab.env.example      # Plantilla de todas las credenciales (infra + apps)
│
├── scripts/
│   └── load-secrets-to-openbao.sh  # Carga secrets/homelab.env en OpenBao KV - manual, no corre en CI
│
├── bootstrap/                   # Values/scripts que consume terraform/cluster/bootstrap.tf
│   ├── cilium/values.yaml       # Configuracion de Cilium (incluye ajustes especificos de Talos)
│   ├── argocd/values.yaml       # Configuracion de ArgoCD
│   └── adopt-cilium-gateway-secrets.sh  # Hook de idempotencia para el chart de Cilium
│
├── gitops/                      # Aplicaciones de ArgoCD (App of Apps)
│   ├── root-app.yaml            # Aplicacion raiz
│   └── apps/
│       ├── platform/            # ArgoCD Applications de infraestructura
│       └── workloads/           # ArgoCD Applications de apps de usuario
│
├── platform/                    # Manifiestos y valores Helm de infraestructura
│   ├── networking/
│   ├── storage/
│   ├── devtools/
│   ├── observability/
│   ├── secret-management/
│   └── security/
│
├── workloads/                   # Aplicaciones de usuario/negocio
│   ├── flow/                    # Flow API
│   ├── portfolio/                # Sitio personal
│   └── sonarqube/                # SonarQube + MCP server
│
└── docs/                        # Documentacion del proyecto
    ├── ARCHITECTURE.md          # Arquitectura completa
    ├── INSTALL.md                # Guia de instalacion paso a paso
    ├── OPERATIONS.md             # Manual operativo y troubleshooting
    ├── DECISIONS.md              # Registro de decisiones (ADR)
    └── CI_CD_HYPERVISOR_SETUP.md # Runbook de setup manual del hipervisor
```

---

## Documentacion

Toda la documentacion se encuentra en la carpeta [`docs/`](./docs/):

- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)**: Descripcion detallada de la arquitectura, componentes, networking, seguridad y flujo de datos.
- **[docs/INSTALL.md](./docs/INSTALL.md)**: Requisitos previos, configuracion de Terraform y de `secrets/homelab.env`, instalacion del cluster y activacion de GitOps.
- **[docs/OPERATIONS.md](./docs/OPERATIONS.md)**: Operaciones diarias, gestion de secretos, backups, actualizaciones, troubleshooting y procedimientos de emergencia.
- **[docs/DECISIONS.md](./docs/DECISIONS.md)**: Registro de decisiones de arquitectura (ADR): Talos, Proxmox, Agent Gateway, Cilium, OpenEBS, Ansible y CI/CD.
- **[docs/CI_CD_HYPERVISOR_SETUP.md](./docs/CI_CD_HYPERVISOR_SETUP.md)**: Runbook de setup manual del hipervisor (Tailscale, SSH, sudoers) para que CI/CD funcione.

---

## Instalacion Rapida

> Requiere Proxmox VE corriendo en el hipervisor y acceso a su API.

```bash
# 1. Clonar repo
git clone git@github.com:cristsr/homelab.git && cd homelab

# 2. Configurar secretos (infra + apps, un solo archivo, nunca se commitea)
cp secrets/homelab.env.example secrets/homelab.env
# editar secrets/homelab.env con los valores reales

# 3. Validar credenciales antes de aprovisionar (falla rapido si falta algo)
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
cd ..

# 4. Instalar cluster infra (VM Talos en Proxmox)
cd terraform/infra
terraform init -backend-config=backend.hcl
terraform apply

# 5. Bootstrap K8s (Cilium, ArgoCD, ZFS) y configuraciones base
cd ../cluster
terraform init -backend-config=backend.hcl
terraform apply

# 6. Activar GitOps
cd ../../
kubectl apply -f gitops/root-app.yaml

# 7. Poblar OpenBao (infraestructura + secrets de apps) - siempre manual, no corre en CI
./scripts/load-secrets-to-openbao.sh
```

Para una guia detallada, consulta [docs/INSTALL.md](./docs/INSTALL.md).

---

## CI/CD

Terraform y Ansible **no** corren en el homeserver: cada push a `master` dispara [`.github/workflows/deploy.yml`](./.github/workflows/deploy.yml) en un runner hosted de GitHub Actions, que se conecta al hipervisor por Tailscale y aplica el cambio (`ansible-playbook preflight.yaml`, `terraform apply` en `infra` y `cluster`, y `kubectl apply -f gitops/root-app.yaml`), detras de un gate de aprobacion manual (Environment `prod`). La carga de secretos en OpenBao **no** corre en CI a proposito — es siempre manual (`./scripts/load-secrets-to-openbao.sh`, ver seccion Seguridad). Cada PR que toque `terraform/**` dispara [`terraform-plan.yml`](./.github/workflows/terraform-plan.yml), que comenta el plan antes de mergear. Detalle completo de la arquitectura en [ADR-009](./docs/DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2).

---

## Acceso a Servicios

| Servicio | URL | Notas |
|----------|-----|-------|
| ArgoCD | `https://argocd.cristianpuenguenan.online` | Admin / contrasena inicial del secret `argocd-initial-admin-secret` |
| Grafana | `https://grafana.cristianpuenguenan.online` | Credenciales en OpenBao |
| Headlamp | `https://headlamp.cristianpuenguenan.online` | Requiere token de servicio |
| SonarQube | `https://sonarqube.cristianpuenguenan.online` | Credenciales en OpenBao |
| Agent Gateway | `https://agentgateway.cristianpuenguenan.online` | Admin / admin |
| Hubble | `https://hubble.cristianpuenguenan.online` | Sin autenticacion |

---

## Seguridad

- Todas las credenciales (infra + apps) viven en `secrets/homelab.env`, plano y **nunca versionado** (esta en `.gitignore`). Se cargan a OpenBao a mano con `./scripts/load-secrets-to-openbao.sh` — este paso nunca corre en CI, a proposito.
- Los secretos del cluster se gestionan mediante **OpenBao** (KV v2) y se sincronizan con Kubernetes via **External Secrets Operator**.
- En CI, el preflight de credenciales usa GitHub Actions secrets/vars (ver [CI_CD_HYPERVISOR_SETUP.md](./docs/CI_CD_HYPERVISOR_SETUP.md)) — nunca un archivo del repo.
- El acceso externo se realiza a traves de **Cloudflare Tunnel**, sin necesidad de abrir puertos en el router.
- **Tetragon** monitorea a nivel de kernel escalamiento de privilegios, acceso a archivos sensibles y syscalls sospechosas.

---

## Mantenimiento y Operaciones

Consulta [docs/OPERATIONS.md](./docs/OPERATIONS.md) para:

- Verificar salud del cluster.
- Gestionar secretos y ExternalSecrets.
- Realizar backups de bases de datos.
- Actualizar versiones de componentes.
- Troubleshooting por componente.
- Procedimientos de emergencia.

---

## Autor

- **Cristian Puenguenan** ([@cristsr](https://github.com/cristsr))

---

## Licencia

Este proyecto es de uso personal. Puedes tomar ideas y adaptarlas a tu propio homelab.
