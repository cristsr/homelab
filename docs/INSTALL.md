# Guia de Instalacion

> El playbook de Ansible se ejecuta **directamente en el servidor** (no desde un host remoto).
> Todos los comandos de esta guia se ejecutan con sesion SSH abierta en el nodo.

---

## Tabla de Contenidos

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

## 1. Requisitos Previos

### Hardware minimo del nodo

| Recurso | Minimo | Recomendado |
|---------|--------|-------------|
| CPU | 4 cores | 6+ cores |
| RAM | 8 GB | 16 GB |
| Disco | 100 GB SSD | 200+ GB SSD |
| Red | Acceso a Internet | IP estatica preferible |

### Software base en el nodo

- Ubuntu 22.04 LTS (o Debian compatible)
- Acceso SSH
- Usuario con privilegios `sudo` sin contrasena (recomendado para Ansible)
- Conexion a Internet estable

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

## 2. Preparar el Servidor

### 2.1 Instalar dependencias del sistema

```bash
sudo apt update && sudo apt install -y git pipx curl
pipx install ansible
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

Edita `ansible/inventory.yaml` si tu usuario o IP difieren:

```yaml
all:
  children:
    k0s:
      hosts:
        homelab:
          ansible_host: 192.168.80.20
          ansible_user: abzu
          ansible_connection: local
```

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

### Reinstalar desde cero

Si necesitas destruir todo y empezar de nuevo:

```bash
cd ansible
ansible-playbook teardown.yaml
```

> **ADVERTENCIA**: `teardown.yaml` elimina el cluster k0s, certificados, etcd y unidades systemd. Los datos de Longhorn pueden perderse dependiendo de la politica de reclaim.

---

## Resumen de comandos

```bash
# 1. Preparar servidor e instalar ansible
sudo apt update && sudo apt install -y git pipx curl
pipx install ansible && pipx ensurepath

# 2. Clonar repo
git clone git@github.com:cristsr/homelab.git && cd homelab

# 3. Configurar vault y secrets
cd ansible
echo "tu-contrasena" > .vault-pass
chmod 600 .vault-pass
# (editar group_vars/all.yaml con valores cifrados)

# 4. Instalar cluster
ansible-playbook site.yaml

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
