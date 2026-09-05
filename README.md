# Homelab Kubernetes

Infraestructura de homelab personal basada en Kubernetes, orquestada con GitOps. El nodo corre dentro de una VM libvirt provisionada con Terraform, configurada con Ansible.

---

## Que es este proyecto

Este repositorio contiene la configuracion completa para levantar un cluster Kubernetes de un solo nodo usando **k0s**, con un stack moderno de plataforma que incluye:

- **GitOps**: ArgoCD gestiona todo el ciclo de vida de las aplicaciones desde Git.
- **Networking**: Cilium como CNI con reemplazo completo de kube-proxy via eBPF.
- **Ingress**: Agent Gateway como punto de entrada unico.
- **Secretos**: OpenBao como backend de secretos, sincronizado con Kubernetes via External Secrets Operator.
- **Almacenamiento**: Longhorn como storage distribuido.
- **Monitoreo**: Prometheus, Grafana y Headlamp.
- **Bases de datos**: PostgreSQL (CloudNative-PG), MongoDB (Percona), Redis y Qdrant.
- **Herramientas**: SonarQube, OpenMemory.
- **Acceso externo**: Cloudflare Tunnel para exponer servicios sin abrir puertos.

La VM se crea con **Terraform** (libvirt/KVM); el aprovisionamiento del nodo y la gestion inicial de secretos se realiza con **Ansible**.

---

## Stack Tecnologico

| Capa | Tecnologia | Version |
|------|-----------|---------|
| VM / Hipervisor | Terraform + libvirt (KVM), Fedora Cloud Base | - |
| Kubernetes | k0s | v1.35.3+k0s.0 |
| CNI | Cilium | 1.19.3 |
| GitOps | Argo CD | 9.5.13 |
| Ingress | Agent Gateway | 1.1.0 |
| Storage | Longhorn | 1.11.2 |
| Secrets | OpenBao | 2.5.3 |
| Secret Sync | External Secrets Operator | 2.4.1 |
| Monitoreo | kube-prometheus-stack / Grafana Operator | - |
| Ingress TLS | cert-manager + Let's Encrypt + Cloudflare DNS-01 | - |
| Tunel WAN | Cloudflare Tunnel (cloudflared) | - |
| Bases de datos | CloudNative-PG, Percona MongoDB, Redis, Qdrant | - |

---

## Estructura del Repositorio

```
homelab/
├── terraform/                   # Aprovisionamiento de la VM (Terraform + libvirt)
│   ├── main.tf                  # Pool, volumenes, cloud-init, dominio
│   └── cloud-init/              # user-data / network-config
│
├── ansible/                    # Aprovisionamiento del nodo (dentro de la VM) y secretos
│   ├── site.yaml               # Playbook principal de instalacion
│   ├── host-network.yaml       # Port-forward LAN (firewalld) del host hacia la VM
│   ├── teardown.yaml           # Playbook para destruir el cluster
│   ├── vault-populate.yaml     # Playbook para poblar OpenBao KV
│   ├── group_vars/all.yaml     # Variables + secrets cifrados (ansible-vault)
│   ├── inventory.yaml          # Generado por `terraform apply`
│   ├── ansible.cfg             # Configuracion de Ansible
│   ├── tasks/                  # Tareas individuales
│   └── templates/              # Plantillas Jinja2
│
├── bootstrap/                  # Bootstrap inicial del cluster
│   ├── helmfile.yaml           # Orquesta Cilium + ArgoCD
│   ├── namespaces.yaml         # Namespaces base
│   ├── cilium/values.yaml      # Configuracion de Cilium
│   └── argocd/values.yaml      # Configuracion de ArgoCD
│
├── gitops/                     # Aplicaciones de ArgoCD (App of Apps)
│   ├── root-app.yaml           # Aplicacion raiz
│   └── apps/
│       ├── platform/           # ArgoCD Applications de infraestructura
│       └── workloads/          # ArgoCD Applications de apps de usuario
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
│   ├── flow/                   # Flow API
│   ├── portfolio/              # Sitio personal
│   └── sonarqube/              # SonarQube + MCP server
│
└── docs/                       # Documentacion del proyecto
    ├── ARCHITECTURE.md         # Arquitectura completa
    ├── INSTALL.md              # Guia de instalacion paso a paso
    └── OPERATIONS.md           # Manual operativo y troubleshooting
```

---

## Documentacion

Toda la documentacion se encuentra en la carpeta [`docs/`](./docs/):

- **[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)**: Descripcion detallada de la arquitectura, componentes, networking, seguridad y flujo de datos.
- **[docs/INSTALL.md](./docs/INSTALL.md)**: Requisitos previos, preparacion del servidor, configuracion de Ansible Vault, instalacion del cluster y activacion de GitOps.
- **[docs/OPERATIONS.md](./docs/OPERATIONS.md)**: Operaciones diarias, gestion de secretos, backups, actualizaciones, troubleshooting y procedimientos de emergencia.
- **[docs/DECISIONS.md](./docs/DECISIONS.md)**: Registro de decisiones de arquitectura (ADR): k0s, Agent Gateway, Cilium, Longhorn, Ansible, Terraform/libvirt y CI/CD.
- **[docs/CI_CD_HYPERVISOR_SETUP.md](./docs/CI_CD_HYPERVISOR_SETUP.md)**: Runbook de setup manual del hipervisor (Tailscale, SSH, SELinux, sudo) para que CI/CD funcione.

---

## Instalacion Rapida

> Requiere un nodo con Ubuntu/Debian, 4 cores, 8GB RAM y 100GB disco.

```bash
# 1. Preparar servidor
sudo apt update && sudo apt install -y git pipx curl
pipx install ansible && pipx ensurepath

# 2. Clonar repo
git clone git@github.com:cristsr/homelab.git && cd homelab

# 3. Configurar secrets en ansible/group_vars/all.yaml y crear .vault-pass

# 4. Instalar cluster
cd ansible
ansible-playbook site.yaml

# 5. Activar GitOps
cd ..
kubectl apply -f gitops/root-app.yaml

# 6. Poblar OpenBao
cd ansible
ansible-playbook vault-populate.yaml
```

Para una guia detallada, consulta [docs/INSTALL.md](./docs/INSTALL.md).

---

## CI/CD

Terraform y Ansible **no** corren en el homeserver: cada push a `master` dispara [`.github/workflows/deploy.yml`](./.github/workflows/deploy.yml) en un runner hosted de GitHub Actions, que se conecta al hipervisor por Tailscale y aplica el cambio (`terraform apply` + `ansible-playbook site.yaml`/`host-network.yaml`), detras de un gate de aprobacion manual (Environment `prod`). Cada PR que toque `terraform/**` dispara [`terraform-plan.yml`](./.github/workflows/terraform-plan.yml), que comenta el plan antes de mergear. Detalle completo de la arquitectura en [ADR-009](./docs/DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2).

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

- Los secretos de infraestructura se almacenan cifrados con **Ansible Vault** en `ansible/group_vars/all.yaml`.
- Los secretos del cluster se gestionan mediante **OpenBao** (KV v2) y se sincronizan con Kubernetes via **External Secrets Operator**.
- El archivo `ansible/.vault-pass` contiene la contrasena del vault y **nunca debe versionarse** (esta en `.gitignore`).
- El acceso externo se realiza a traves de **Cloudflare Tunnel**, sin necesidad de abrir puertos en el router.

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
