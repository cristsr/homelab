# Guia de Instalacion

> El nodo k0s corre dentro de una VM libvirt provisionada por Terraform (`terraform/`).
> Ni Terraform ni Ansible se ejecutan en el propio hipervisor (ver [ADR-009](DECISIONS.md#adr-009-cicd-con-github-actions-hosted--tailscale--cloudflare-r2)): ambos corren en remoto — por SSH (`qemu+ssh://`) desde tu equipo de control o, de forma automatica, desde GitHub Actions via Tailscale. Esta guia documenta el flujo **manual**; para el automatico ver [`.github/workflows/`](../.github/workflows/) y ADR-009.

---

## Tabla de Contenidos

0. [Aprovisionar la VM (Terraform)](#0-aprovisionar-la-vm-terraform)
1. [Requisitos Previos](#1-requisitos-previos)
2. [Preparar el Servidor](#2-preparar-el-servidor)
3. [Configurar Ansible y Secrets](#3-configurar-ansible-y-secretos)
4. [Instalar el Cluster con Ansible](#4-instalar-el-cluster-con-ansible)
5. [Bootstrap del Cluster](#5-bootstrap-del-cluster)
6. [Activar GitOps](#6-activar-gitops)
7. [Poblar OpenBao](#7-poblar-openbao)
8. [Verificar y Acceder](#8-verificar-y-acceder)
9. [DNS](#9-dns)
10. [Troubleshooting](#10-troubleshooting)

---

## 0. Aprovisionar la VM (Terraform)

> Ver [ADR-008](DECISIONS.md#adr-008-vm-libvirt-provisionada-con-terraform) para el contexto completo de esta decision.

El nodo ya no se instala sobre el hardware directamente: `terraform/` crea una VM libvirt (KVM) a partir de una imagen pristina de Fedora Cloud Base, con disco overlay copy-on-write (la imagen descargada nunca se escribe) y arranque via cloud-init (usuario, llave SSH, IP estatica).

### 0.1 Prerequisitos del host (hipervisor)

Esto se instala **en el hipervisor fisico**, no en tu equipo de control:

```bash
sudo dnf install -y '@Virtualization' libvirt qemu-kvm
sudo usermod -aG libvirt $USER   # requiere volver a iniciar sesion
sudo systemctl enable --now libvirtd
```

Ademas, el hipervisor necesita estar en tu tailnet (`tailscale up --ssh`) y tener autorizada por SSH la clave dedicada que usaras para conectarte de forma remota (ver ADR-009). Terraform **no** se instala en el hipervisor: corre en tu equipo de control (o en CI).

### 0.1.1 Prerequisitos del equipo de control

```bash
# Terraform (repo oficial de HashiCorp)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
```

### 0.2 Configurar variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

Edita `terraform.tfvars`: la URL del qcow2 vigente desde https://fedoraproject.org/cloud/download (cambia por release; no hay un default fijo a proposito), y `hypervisor_ssh_host`/`hypervisor_ssh_user`/`hypervisor_ssh_keyfile` con los datos de tu hipervisor (IP Tailscale, usuario del grupo `libvirt`, y la clave privada dedicada). Ajusta memoria/vcpu/disco si hace falta (defaults: 16GB RAM, 8 vCPU, 120GB disco).

Edita `backend.hcl` con el Account ID de tu cuenta Cloudflare (para el bucket R2 `homelab-tfstate` que guarda el state remoto — ver ADR-009).

### 0.3 Aplicar

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Esto:
- Descarga la imagen base de Fedora Cloud (una sola vez, se cachea en el pool `homelab`).
- Crea el disco overlay de la VM, una llave SSH dedicada (`terraform/generated/id_ed25519`), y el dominio libvirt con IP estatica en la red NAT `default` (`192.168.122.0/24`).
- Regenera `ansible/inventory.yaml` apuntando a la VM por SSH.

Verificar que la VM arranco bien. La VM esta en la red NAT interna de libvirt (solo alcanzable desde el hipervisor), asi que hay que saltar por el mismo `ProxyCommand` que usa Ansible:

```bash
ssh -i terraform/generated/id_ed25519 \
  -o ProxyCommand="ssh -i <hypervisor_ssh_keyfile> -W %h:%p <hypervisor_ssh_user>@<hypervisor_ssh_host>" \
  fedora@$(terraform -chdir=terraform output -raw vm_static_ip) "cloud-init status --long"
```

Debe mostrar `status: done` sin errores.

---

## 1. Requisitos Previos

### Hardware minimo de la VM (definido en `terraform/variables.tf`)

| Recurso | Minimo (ARCHITECTURE.md) | Default de este repo |
|---------|--------------------------|-----------------------|
| CPU | 4 cores | 8 vCPU |
| RAM | 8 GB | 16 GB |
| Disco | 100 GB SSD | 120 GB (overlay) |
| Red | Acceso a Internet | IP estatica (`192.168.122.10`, NAT libvirt) |

### Software

- Host: Fedora con libvirt/KVM + Terraform (ver [0. Aprovisionar la VM](#0-aprovisionar-la-vm-terraform)).
- Ansible corre desde el **host** (equipo de control), no dentro de la VM.
- La VM (Fedora Cloud Base) no requiere preparacion manual: cloud-init crea el usuario, la llave SSH y el sudo sin contrasena.
- Conexion a Internet estable (para descargar la imagen base y los binarios que instala Ansible).

### Cuentas y tokens externos necesarios

Antes de comenzar, asegurate de tener a mano los siguientes valores:

| Token/Cuenta | Descripcion | Como obtenerlo |
|--------------|-------------|----------------|
| **GitHub PAT** | Personal Access Token con permisos `repo` para acceder al repositorio privado | GitHub Settings > Developer settings > Personal access tokens |
| **Cloudflare API Token** | Token con permisos `Zone:Edit` y `Zone:Read` para el dominio | Cloudflare Dashboard > My Profile > API Tokens |
| **Cloudflared Tunnel Token** | Token del tunel de Cloudflare | `cloudflared tunnel create <nombre>` o desde Zero Trust Dashboard |

### DNS configurado

- Un dominio propio (ej: `cristianpuenguenan.online`) gestionado en Cloudflare.
- Registro A apuntando a la IP del nodo: `192.168.80.20`.
- Registro wildcard `*.cristianpuenguenan.online` apuntando a la misma IP.

---

## 2. Preparar el Equipo de Control

> Estos pasos son en el **host** (el mismo que corre Terraform), no dentro de la VM.

### 2.1 Instalar dependencias del sistema

```bash
sudo dnf install -y git pipx curl
pipx install --include-deps ansible
pipx ensurepath
source ~/.bashrc
```

Verificar instalacion:

```bash
ansible --version
```

### 2.2 Clonar repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar Ansible y Secretos

### 3.1 Revisar inventario y variables

`ansible/inventory.yaml` ya no se edita a mano: lo genera `terraform apply` (ver [0. Aprovisionar la VM](#0-aprovisionar-la-vm-terraform)) con la IP estatica de la VM y la llave SSH dedicada. Si necesitas verlo:

```yaml
all:
  children:
    k0s:
      hosts:
        homelab:
          ansible_host: 192.168.122.10
          ansible_user: fedora
          ansible_connection: ssh
          ansible_ssh_private_key_file: /ruta/a/homelab/terraform/generated/id_ed25519
          ansible_ssh_common_args: '-o ProxyCommand="ssh -i <hypervisor_ssh_keyfile> -W %h:%p ... <hypervisor_ssh_user>@<hypervisor_ssh_host>"'
    hypervisor:
      hosts:
        homelab-host:
          ansible_host: <hypervisor_ssh_host>
          ansible_user: <hypervisor_ssh_user>
          ansible_connection: ssh
          ansible_ssh_private_key_file: <hypervisor_ssh_keyfile>
```

El grupo `hypervisor` apunta al hipervisor fisico por SSH remoto (ya no `ansible_connection: local` — ver ADR-009) — lo usa `ansible/host-network.yaml` (ver [8.3](#83-acceso-lan-directo)) para el port-forward LAN hacia la VM. El grupo `k0s` llega a la VM saltando por el hipervisor (`ProxyCommand`), porque la VM vive en la red NAT interna de libvirt, solo alcanzable desde el propio hipervisor.

Edita `ansible/group_vars/all.yaml` para ajustar versiones y el username de GitHub:

```yaml
argocd_github_username: cristsr
argocd_repo_url: https://github.com/cristsr/homelab
```

### 3.2 Cifrar las variables sensibles con ansible-vault

Todas las variables marcadas con valor plano o placeholder en `group_vars/all.yaml` deben cifrarse antes de ejecutar el playbook.

**Formato**: ejecuta el siguiente comando por cada variable, copia el bloque `!vault |` generado y reemplaza el valor correspondiente en `group_vars/all.yaml`.

```bash
cd ansible
ansible-vault encrypt_string 'EL_VALOR' --name 'NOMBRE_VARIABLE'
```

**Variables obligatorias a cifrar**:

| Variable | Descripcion |
|----------|-------------|
| `argocd_github_pat` | PAT de GitHub para que ArgoCD acceda al repo GitOps |
| `cloudflare_api_token` | Token de API de Cloudflare (cert-manager DNS-01) |
| `cloudflared_token` | Token del tunel Cloudflare |
| `openbao_static_seal_key` | Clave AES-256 para Static Seal de OpenBao |

Ejemplo para la clave de OpenBao:

```bash
ansible-vault encrypt_string "$(openssl rand -base64 32)" --name 'openbao_static_seal_key'
```

> **IMPORTANTE**: Guarda la clave de OpenBao en un lugar seguro (gestor de contrasenas). Se usa para el unseal del vault.

### 3.3 Configurar contrasena del vault

Crea el archivo de contrasena para que Ansible pueda descifrar automaticamente:

```bash
echo "tu-contrasena-vault" > ansible/.vault-pass
chmod 600 ansible/.vault-pass
```

El archivo `ansible/.vault-pass` ya esta en `.gitignore` para evitar subirlo accidentalmente.

---

## 4. Instalar el Cluster con Ansible

### 4.1 Ejecutar el playbook principal

```bash
cd ansible
ansible-playbook site.yaml
```

> El flag `-K` (sudo password) no es necesario si el usuario tiene sudo sin contrasena.

El playbook `site.yaml` realiza automaticamente:

1. **k0s**: Descarga e instala k0s como servicio systemd single-node.
2. **kubeconfig**: Exporta la config de admin y la coloca en `~/.kube/config`.
3. **kubectl**: Descarga el binario standalone de kubectl.
4. **helm**: Descarga e instala Helm.
5. **longhorn-prereqs**: Instala `open-iscsi` y habilita `iscsid`.
6. **helmfile**: Descarga Helmfile y ejecuta `helmfile sync` desde `../bootstrap`.
7. **argocd-secret**: Crea el secret `github-repo-creds` en namespace `argocd` y el `in-cluster-secret` para que ArgoCD gestione el cluster local.
8. **vault-secrets**: Crea el namespace `secret-management` y el secret `openbao-static-unseal-key`.

Verificar que el cluster esta listo:

```bash
kubectl get nodes
kubectl -n kube-system get pods
```

### 4.2 Verificar bootstrap

Comprueba que Cilium y ArgoCD estan corriendo:

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

## 5. Bootstrap del Cluster

> **Nota**: El playbook de Ansible ya ejecuta `helmfile sync` automaticamente.
> Solo necesitas ejecutarlo manualmente si quieres repetir el bootstrap o si fallo.

```bash
cd bootstrap
helmfile sync
```

Esto despliega:
- **Namespaces base** (via hook presync)
- **Cilium** (CNI con eBPF, kube-proxy replacement)
- **ArgoCD** (GitOps controller)

---

## 6. Activar GitOps

### 6.1 Aplicar la aplicacion raiz

```bash
kubectl apply -f gitops/root-app.yaml
```

A partir de aqui ArgoCD sincroniza el cluster con el repositorio Git siguiendo el orden de sync-waves.

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

---

## 7. Poblar OpenBao

> **Cuando hacerlo**: Despues de que GitOps active el cluster y el job `openbao-init` termine.
> Este paso escribe los secrets de infraestructura en OpenBao KV desde Ansible.

### 7.1 Ejecutar vault-populate

```bash
cd ansible
ansible-playbook vault-populate.yaml
```

El playbook escribe los siguientes secrets en OpenBao KV:

| Path KV | Contenido |
|---------|-----------|
| `secret/argocd` | `github_pat`, `username`, `url` |
| `secret/infra/cloudflare` | `api_token` |
| `secret/infra/cloudflared` | `token` |

### 7.2 Leer y guardar la recovery key de OpenBao

La recovery key permite regenerar un root token en caso de emergencia.

```bash
kubectl get secret openbao-recovery-key -n secret-management \
  -o jsonpath='{.data.key}' | base64 -d && echo
```

**Guardala de forma segura** (gestor de contrasenas o vault fisico).

Opcionalmente, puedes cifrarla y guardarla en `group_vars/all.yaml`:

```bash
cd ansible
ansible-vault encrypt_string 'LA_KEY_DEL_PASO_ANTERIOR' --name 'openbao_recovery_key'
```

Y luego eliminar la recovery key del cluster:

```bash
kubectl delete secret openbao-recovery-key -n secret-management
```

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
| `https://argocd.cristianpuenguenan.online` | Argo CD | admin / (contrasena inicial del paso 4.2) |
| `https://grafana.cristianpuenguenan.online` | Grafana | admin / (configurada en OpenBao) |
| `https://agentgateway.cristianpuenguenan.online` | Agent Gateway | admin / admin |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Token de servicio |
| `https://hubble.cristianpuenguenan.online` | Hubble | Sin auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | admin / (configurada en OpenBao) |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | Sin auth |

Token para Headlamp:

```bash
kubectl create token headlamp -n observability
```

### 8.3 Acceso LAN directo

La VM vive en la red NAT de libvirt (`192.168.122.0/24`), no es alcanzable directamente desde la LAN. `ansible/host-network.yaml` configura firewalld en el **host** para reenviar `192.168.80.20:80/443` hacia la VM.

Antes de correrlo, revisa `host_lan_interface` en `ansible/group_vars/all.yaml` — tiene que coincidir con la interfaz de red real del host (`ip -br link` para verla), no es portable entre máquinas.

```bash
cd ansible
ansible-playbook host-network.yaml
```

Verificar desde otro equipo de la LAN:

```bash
curl -I http://192.168.80.20
```

Cloudflare Tunnel (acceso WAN) no necesita este paso — es una conexion saliente desde dentro de la VM, no le afecta el NAT.

---

## 9. DNS

Registros requeridos en Cloudflare:

| Registro | Tipo | Valor |
|----------|------|-------|
| `cristianpuenguenan.online` | A | `192.168.80.20` |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` |

Verificar certificado:

```bash
kubectl get certificate -n networking
```

---

## 10. Troubleshooting

### Apps en estado Unknown

El playbook de Ansible ya crea automaticamente el `in-cluster-secret` para ArgoCD. Si por algun motivo las aplicaciones quedan en estado `Unknown`, verifica que el secret existe y reinicia el controller:

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

### ClusterSecretStore en False

```bash
kubectl get clustersecretstore openbao -o wide
kubectl describe clustersecretstore openbao
kubectl -n secret-management logs deployment/external-secrets --tail=50
```

### OpenBao sellado tras reinicio

```bash
kubectl -n secret-management exec openbao-0 -- bao operator unseal <UNSEAL_KEY>
```

### Longhorn atascado

```bash
kubectl create serviceaccount longhorn-sa -n argocd
kubectl create clusterrolebinding longhorn-temp --clusterrole=cluster-admin --serviceaccount=argocd:longhorn-sa
```

### Actualizar paquetes del SO de la VM

`update-vm-packages.yaml` no corre en `deploy.yml` a proposito: un `dnf upgrade` puede traer un kernel nuevo, y reiniciar el unico nodo del cluster no es algo que deba pasar sin supervision en cada push a master. Se ejecuta manualmente, en una ventana de mantenimiento elegida:

```bash
cd ansible
ansible-playbook update-vm-packages.yaml
```

Si el output indica que se requiere reboot (kernel u otro paquete critico actualizado), el cluster completo queda caido mientras la VM reinicia (single-node). Para aplicar el reboot en el mismo paso:

```bash
ansible-playbook update-vm-packages.yaml -e reboot_if_needed=true
```

### Reinstalar desde cero

Para resetear solo el cluster (mantener la VM):

```bash
cd ansible
ansible-playbook teardown.yaml
```

> **ADVERTENCIA**: `teardown.yaml` elimina el cluster k0s, certificados, etcd y unidades systemd. Los datos de Longhorn pueden perderse dependiendo de la politica de reclaim.

Para destruir tambien la VM y recrearla desde cero:

```bash
cd terraform
terraform destroy
terraform apply
```

---

## Resumen de comandos

```bash
# 0. Clonar repo, preparar host (libvirt + terraform + ansible)
git clone git@github.com:cristsr/homelab.git && cd homelab
sudo dnf install -y '@Virtualization' libvirt qemu-kvm dnf-plugins-core git pipx curl
sudo usermod -aG libvirt $USER   # re-login despues de esto
sudo systemctl enable --now libvirtd
sudo dnf config-manager addrepo --from-repofile=https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
sudo dnf install -y terraform
pipx install --include-deps ansible && pipx ensurepath

# 1. Aprovisionar la VM
cd terraform
cp terraform.tfvars.example terraform.tfvars   # completar fedora_cloud_image_url
terraform init && terraform apply

# 2. Configurar vault y secrets
cd ../ansible
echo "tu-contrasena" > .vault-pass
chmod 600 .vault-pass
# (editar group_vars/all.yaml con valores cifrados)

# 3. Instalar cluster (via SSH a la VM)
ansible-playbook site.yaml

# 4. Port-forward LAN
ansible-playbook host-network.yaml

# 5. Activar GitOps
cd ..
kubectl apply -f gitops/root-app.yaml

# 6. Poblar OpenBao
cd ansible
ansible-playbook vault-populate.yaml

# 7. Verificar
kubectl -n argocd get applications
kubectl get pods -A
```
