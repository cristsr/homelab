# Guia de Instalacion

> El nodo Talos Linux corre como una VM sobre Proxmox VE, provisionada con Terraform en dos etapas (`terraform/infra`, `terraform/cluster`).
> Ni Terraform ni Ansible corren en el hipervisor (ver [ADR-009](DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2)): hablan con la API REST de Proxmox y la API de Talos (mTLS) en remoto — desde tu equipo de control o, de forma automatica, desde GitHub Actions via Tailscale. Esta guia documenta el flujo **manual**; para el automatico ver [`.github/workflows/`](../.github/workflows/), ADR-009 y [CI_CD_HYPERVISOR_SETUP.md](CI_CD_HYPERVISOR_SETUP.md).

---

## Tabla de Contenidos

0. [Preflight de credenciales](#0-preflight-de-credenciales)
1. [Requisitos Previos](#1-requisitos-previos)
2. [Preparar el Equipo de Control](#2-preparar-el-equipo-de-control)
3. [Configurar Secretos](#3-configurar-secretos)
4. [Aprovisionar la VM Talos (`terraform/infra`)](#4-aprovisionar-la-vm-talos-terraforminfra)
5. [Bootstrap de Kubernetes (`terraform/cluster`)](#5-bootstrap-de-kubernetes-terraformcluster)
6. [Activar GitOps](#6-activar-gitops)
7. [Cargar los secretos reales (SOPS + age)](#7-cargar-los-secretos-reales-sops--age)
8. [Verificar y Acceder](#8-verificar-y-acceder)
9. [DNS](#9-dns)
10. [Troubleshooting](#10-troubleshooting)

---

## 0. Preflight de credenciales

Antes de tocar Terraform, valida que las credenciales existen y no estan vacias — falla en segundos en vez de a mitad del aprovisionamiento. Las credenciales se exportan desde `secrets/homelab.env` (ver seccion 3):

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

---

## 1. Requisitos Previos

### Hardware minimo de la VM (definido en `terraform/infra/variables.tf`)

| Recurso | Minimo | Default de este repo |
|---------|--------|-----------------------|
| CPU | 4 cores | 8 vCPU (`var.vcpu`) |
| RAM | 8 GB | 16 GB (`var.memory_mib`) |
| Disco instalacion | 100 GB | 120 GB (`var.disk_size_gb`) |
| Disco ZFS dedicado | - | 100 GB (`var.zfs_disk_size_gb`) |
| Red | IP estatica en la LAN | `var.vm_static_ip`, bridge `vmbr0` |

### Software

- **Hipervisor**: Proxmox VE, con la API accesible (`:8006`) y un API token dedicado (ver [CI_CD_HYPERVISOR_SETUP.md §2](CI_CD_HYPERVISOR_SETUP.md)).
- **Equipo de control**: Terraform (`>= 1.10.0`) y Ansible. Ninguno de los dos se instala en el hipervisor ni en la VM.
- La VM no requiere preparacion manual: Talos es inmutable, la configuracion completa la aplica Terraform via API.

### Cuentas y tokens externos necesarios

Antes de comenzar, asegurate de tener a mano los siguientes valores:

| Token/Cuenta | Descripcion | Como obtenerlo |
|--------------|-------------|----------------|
| **API Token de Proxmox** | `usuario@realm!tokenid=uuid` para que Terraform cree la VM | Proxmox UI → Datacenter → Permissions → API Tokens (ver CI_CD_HYPERVISOR_SETUP.md §2) |
| **Schematic ID de Talos** | ID generado en https://factory.talos.dev con las extensiones `qemu-guest-agent`, `tailscale`, `zfs` | Image Factory — ver default en `terraform/infra/variables.tf` |
| **GitHub PAT** | Personal Access Token con permisos `repo` para que ArgoCD acceda al repositorio privado | GitHub Settings → Developer settings → Personal access tokens |
| **Cloudflare API Token** | Token con permisos `Zone:Edit` y `Zone:Read` para el dominio (cert-manager DNS-01) | Cloudflare Dashboard → My Profile → API Tokens |
| **Cloudflared Tunnel Token** | Token del tunel de Cloudflare | `cloudflared tunnel create <nombre>` o desde Zero Trust Dashboard |

---

## 2. Preparar el Equipo de Control

### 2.1 Instalar dependencias

```bash
# Terraform (repo oficial de HashiCorp)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform git pipx curl
pipx install --include-deps ansible && pipx ensurepath
source ~/.bashrc
```

Verificar instalacion:

```bash
terraform version
ansible --version
```

### 2.2 Clonar repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar Secretos

Todas las credenciales (infra + apps) viven en un unico archivo plano, **nunca commiteado** (`secrets/homelab.env` esta en `.gitignore`):

```bash
cp secrets/homelab.env.example secrets/homelab.env
$EDITOR secrets/homelab.env
```

Completa al menos los campos de la seccion `# --- Infra (obligatorios) ---` (`ARGOCD_GITHUB_PAT`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARED_TUNNEL_TOKEN`, `GHCR_PAT`) y `# --- Databases ---`. El resto de los campos (Monitoring, SonarQube, DevTools) tambien viven en este mismo archivo, pero se aplican al repo (cifrados) en la seccion 7, no se usan directo de aca.

> Este archivo ya solo lo consumen `ansible/preflight.yaml` (campos de Infra) y `ansible/data-services.yaml` (campos de Databases, al levantar los motores en sus LXC). La IP fija del Gateway/DNS interno ya no se configura por variable — se edita directo en `platform/networking/cilium-gateway/gateway.yaml` y `platform/networking/private-dns/` si hace falta cambiarla.

### 3.1 Correr el preflight

```bash
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
```

---

## 4. Aprovisionar la VM Talos (`terraform/infra`)

### 4.1 Configurar variables

```bash
cd terraform/infra
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edita `terraform.tfvars`: `proxmox_endpoint`, `proxmox_api_token`, `talos_schematic_id`, `vm_static_ip`, `vm_gateway`. Ajusta memoria/vcpu/discos si hace falta (defaults: 16GB RAM, 8 vCPU, 120GB + 100GB disco).

Edita `backend.hcl` con el Account ID de tu cuenta Cloudflare (bucket R2 `homelab-tfstate` que guarda el state remoto — ver ADR-009).

### 4.2 Aplicar

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Esto:
- Descarga el ISO de Talos generado por el Image Factory (`talos_schematic_id`), una sola vez.
- Crea la VM en Proxmox con dos discos (instalacion + dedicado a ZFS) e IP estatica en la LAN real (bridge `vmbr0`).
- Aplica la machine config de Talos (particiona el disco de ZFS, configura la red) y bootstrapea el cluster.
- Genera `terraform/infra/generated/kubeconfig` y `generated/talosconfig`.

Verificar que el nodo esta listo:

```bash
export KUBECONFIG=terraform/infra/generated/kubeconfig
kubectl get nodes
```

---

## 5. Bootstrap de Kubernetes (`terraform/cluster`)

### 5.1 Configurar variables

```bash
cd ../cluster
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edita `terraform.tfvars`: `kubeconfig_path` (apunta a `../infra/generated/kubeconfig`), `argocd_github_pat`.

### 5.2 Aplicar

```bash
terraform init -backend-config=backend.hcl
terraform apply
```

Esto crea, en orden (via `depends_on`):
- **Namespaces base** (`terraform/cluster/namespaces.tf`).
- **Cilium** (`helm_release`, con el hook de idempotencia `bootstrap/adopt-cilium-gateway-secrets.sh`).
- **ArgoCD** (`helm_release`).
- **Secrets iniciales**: `github-repo-creds`, `in-cluster-secret` (`terraform/cluster/secrets.tf`).
- **Job de OpenEBS ZFS**: crea el zpool `zfspv-pool` sobre el disco dedicado (`terraform/cluster/storage.tf`).

Verificar:

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl -n argocd get pods
```

Obtener contrasena inicial de ArgoCD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 6. Activar GitOps

```bash
kubectl apply -f gitops/root-app.yaml
```

A partir de aqui ArgoCD sincroniza el cluster con el repositorio Git siguiendo el orden de sync-waves (ver `docs/ARCHITECTURE.md` §9).

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

---

## 7. Cargar los secretos reales (SOPS + age)

> **Cuando hacerlo**: Despues de que GitOps active el cluster. **Este paso es siempre manual** — no corre en CI a proposito (mismo criterio que ADR-015). Hasta que lo hagas, las Applications que dependen de estos secretos (cloudflared, las bases de datos, SonarQube, OpenMemory) van a quedar con placeholders `admin` inservibles (`Progressing`/`Degraded`/`CrashLoopBackOff`/`ImagePullBackOff` segun el caso). Es esperado, no un fallo del pipeline.

Los secretos reales viven cifrados en el repo (`*.sops.yaml` + `ansible/data-services.env`, ver ADR-018/019 en [DECISIONS.md](DECISIONS.md)) — no hay backend externo, solo la clave privada de `age` montada en `sops-secrets-operator` (namespace `sops`).

### 7.1 Completar los valores

1. Copiá `secrets/homelab.env.example` a `secrets/homelab.env` (gitignored, nunca se commitea).
2. Completá cada valor (tokens de Cloudflare, PAT de GHCR, passwords de las bases de datos, etc. — cada campo del archivo documenta para qué se usa).

### 7.2 Aplicar los valores a los archivos cifrados

```bash
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt   # o donde tengas la clave privada de age
./scripts/apply-real-secrets.sh secrets/homelab.env
```

El script usa `sops set` para parchear cada campo cifrado en su `*.sops.yaml` (sin tocar el resto del archivo) y re-encripta `ansible/data-services.env` completo. Cualquier campo vacío en `secrets/homelab.env` se omite — el valor cifrado existente queda intacto. Revisá `git diff --stat`, y commiteá/empujá los archivos que cambiaron para que ArgoCD (los `SopsSecret`) y CI (`data-services.env`, vía `sops exec-env`) recojan los valores nuevos.

Podés volver a correr el script cuando quieras rotar un valor — es idempotente.

---

## 8. Verificar y Acceder

### 8.1 Verificar estado del cluster

```bash
kubectl -n argocd get applications
kubectl get pods -A
```

### 8.2 Endpoints de acceso

| URL | Servicio | Credenciales |
|-----|----------|--------------|
| `https://argocd.cristianpuenguenan.online` | Argo CD | admin / (contrasena inicial del paso 5.2) |
| `https://grafana.cristianpuenguenan.online` | Grafana | admin / (configurada en secrets/homelab.env, ver §7) |
| `https://agentgateway.cristianpuenguenan.online` | Agent Gateway | admin / admin |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Token de servicio |
| `https://hubble.cristianpuenguenan.online` | Hubble | Sin auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | admin / (configurada en secrets/homelab.env, ver §7) |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | Sin auth |

Token para Headlamp:

```bash
kubectl create token headlamp -n observability
```

### 8.3 Acceso LAN y Tailscale

La VM tiene IP real en la LAN (bridge `vmbr0` de Proxmox) — los Gateway (`cilium-gateway-main` en `192.168.80.240`, `private-dns` en `192.168.80.253`) son alcanzables directo desde cualquier dispositivo de la LAN, sin ningun port-forward. Para acceder desde fuera de la LAN fisica, usa Tailscale: el hipervisor advierte rutas `/32` acotadas a esas IPs (ver [CI_CD_HYPERVISOR_SETUP.md §1](CI_CD_HYPERVISOR_SETUP.md)), no el `/24` completo.

```bash
curl -kI https://192.168.80.240 -H "Host: argocd.internal.cristianpuenguenan.online"
```

Cloudflare Tunnel (acceso WAN, rutas públicas) no depende de la LAN ni de Tailscale — es una conexión saliente desde dentro del cluster.

---

## 9. DNS

Las rutas **públicas** (`portfolio`, `api`) no requieren registros A manuales: se configuran como *Public Hostnames* en el dashboard de Cloudflare Zero Trust, apuntando al tunel de `cloudflared` — gestionado fuera de Git.

Las rutas **privadas** (`*.internal.cristianpuenguenan.online`) resuelven vía `private-dns` (CoreDNS in-cluster, IP fija `192.168.80.253`), no vía Cloudflare. Para que tu equipo las resuelva automáticamente, configura Tailscale Split DNS (Admin console → DNS → Nameservers → Split DNS) apuntando el dominio `internal.cristianpuenguenan.online` a `192.168.80.253`.

Verificar certificado (ambos wildcards, público y privado, los emite el mismo `ClusterIssuer` DNS-01):

```bash
kubectl get certificate -n networking
```

---

## 10. Troubleshooting

### Apps en estado Unknown

Terraform ya crea automaticamente el `in-cluster-secret` para ArgoCD (`terraform/cluster/secrets.tf`). Si por algun motivo las aplicaciones quedan en estado `Unknown`, verifica que el secret existe y reinicia el controller:

```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
kubectl delete pod -n argocd argocd-application-controller-0
```

Si el secret no existe, recrealo manualmente:

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

### SopsSecret no sincroniza

```bash
kubectl get sopssecrets -A
kubectl describe sopssecret <nombre> -n <namespace>
kubectl -n sops logs deployment/sops-secrets-operator --tail=50
```

Causas típicas: la clave privada de `age` montada en el operador no coincide con la que cifró el archivo (`age1...` en `.sops.yaml` vs la clave real), o el `Secret` destino ya existía owneado por otro controlador sin `spec.enforceOwnership: true` en el `SopsSecret` (error `Child secret is not owned by controller`).

### Volumen OpenEBS no provisiona

Talos no tiene shell: no hay `vgs`/`lvs` que correr por SSH. Se inspecciona desde un pod privilegiado (ver `docs/ARCHITECTURE.md`, Troubleshooting):

```bash
kubectl get zfsnode -n openebs
kubectl -n openebs logs -l app=openebs-zfs-controller -c openebs-zfs-plugin
kubectl debug node/talos -it --image=alpine:3.20 -- \
  sh -c "apk add --no-cache zfs >/dev/null && zpool status zfspv-pool"
```

### Actualizar Talos

Talos se actualiza reemplazando la imagen completa del nodo, no con un gestor de paquetes:

```bash
talosctl --talosconfig terraform/infra/generated/talosconfig upgrade \
  --nodes <vm_static_ip> --image factory.talos.dev/installer/<schematic_id>:<version>
```

Como es un cluster de un solo nodo, el upgrade reinicia el nodo y el cluster completo queda caido durante el proceso — hacelo en una ventana de mantenimiento elegida.

### Reinstalar desde cero

Para destruir y recrear solo el bootstrap de Kubernetes (mantener la VM):

```bash
cd terraform/cluster
terraform destroy
terraform apply
```

Para destruir también la VM y recrearla desde cero:

```bash
cd terraform/infra
terraform destroy
terraform apply
```

---

## Resumen de comandos

```bash
# 0. Clonar repo, preparar equipo de control
git clone git@github.com:cristsr/homelab.git && cd homelab
sudo dnf install -y dnf-plugins-core git pipx curl
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
pipx install --include-deps ansible && pipx ensurepath

# 1. Configurar secretos y preflight
cp secrets/homelab.env.example secrets/homelab.env
# (editar secrets/homelab.env con los valores de infra)
set -a; source secrets/homelab.env; set +a
cd ansible
ansible-playbook preflight.yaml
cd ..

# 2. Aprovisionar la VM Talos en Proxmox
cd ../terraform/infra
cp terraform.tfvars.example terraform.tfvars   # completar proxmox_*/talos_schematic_id/vm_*
terraform init -backend-config=backend.hcl && terraform apply

# 3. Bootstrap de Kubernetes (Cilium, ArgoCD, ZFS)
cd ../cluster
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl && terraform apply

# 4. Activar GitOps
cd ../..
kubectl apply -f gitops/root-app.yaml

# 5. Cargar los secretos reales (manual siempre - ver seccion 7 arriba)
cp secrets/homelab.env.example secrets/homelab.env && $EDITOR secrets/homelab.env
export SOPS_AGE_KEY_FILE=~/.sops-keys/homelab.key.txt
./scripts/apply-real-secrets.sh secrets/homelab.env

# 6. Verificar
kubectl -n argocd get applications
kubectl get pods -A
```
