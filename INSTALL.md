# Guía de Instalación

> El playbook de Ansible se ejecuta **directamente en el servidor** (no desde un host remoto).  
> Todos los comandos de esta guía se ejecutan con sesión SSH abierta en el nodo.

---

## 1. Preparar el servidor

### 1.1 Instalar dependencias

```bash
sudo apt update && sudo apt install -y git pipx
pipx install ansible
pipx ensurepath
source ~/.bashrc
```

Verificar:

```bash
ansible --version
```

### 1.2 Clonar repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 2. Instalar k0s con Ansible

### 2.1 Ajustar inventario y variables

Edita `ansible/inventory.yaml` si tu usuario o IP difieren del predeterminado, y `ansible/group_vars/all.yaml` para ajustar versiones y el username de GitHub:

```yaml
github_username: tu-usuario-github
```

### 2.2 Cifrar el GitHub token con ansible-vault

```bash
cd ansible
ansible-vault encrypt_string 'ghp_tutoken' --name 'github_token'
```

Copia el bloque `!vault |` que genera y reemplaza el placeholder en `group_vars/all.yaml`:

```yaml
github_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  38613330623564376561373361333864...
```

### 2.3 Configurar contraseña del vault

```bash
echo "tu-contrasena-vault" > ansible/.vault-pass
echo "ansible/.vault-pass" >> .gitignore
```

### 2.4 Ejecutar el playbook

```bash
cd ansible
ansible-playbook site.yaml -K
```

El playbook realiza todo automaticamente:
- Instala k0s (nodo único), escribe `~/.kube/config` e instala `kubectl` standalone (no requiere sudo)
- Instala `helm`, `helmfile` y hace bootstrap de Cilium + ArgoCD via helmfile
- Crea el secret `github-repo-creds` en el namespace `argocd`

Verificar que el cluster está listo:

```bash
kubectl get nodes
```

---

## 3. Bootstrap (namespaces + Cilium + ArgoCD)

> **Nota:** El playbook de Ansible (paso 2.4) ya ejecuta `helmfile sync` automaticamente.  
> Solo necesitas ejecutarlo manualmente si quieres repetir el bootstrap.

```bash
cd bootstrap
helmfile sync
```

Verificar Cilium:

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl get nodes
```

Obtener contraseña admin de ArgoCD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 4. Configurar variables de entorno

> **Cuándo hacerlo:** Después del bootstrap (paso 2 o 3) y **antes** de activar GitOps (paso 5).  
> El namespace `vault` ya existe (lo creó Ansible en el paso 2, o el bootstrap manual en el paso 3).  
> El job `openbao-import-secrets` lee este secret al iniciar OpenBao y lo importa al KV store.

Crear el secret con las variables necesarias (es idempotente, puedes re-ejecutarlo para actualizar valores):

```bash
kubectl create secret generic vault-bootstrap-secrets \
  -n vault \
  --from-literal=cloudflare_api_token='TU_CLOUDFLARE_API_TOKEN' \
  --from-literal=cloudflared_token='TU_CLOUDFLARE_TUNNEL_TOKEN' \
  --from-literal=postgresql_username='appuser' \
  --from-literal=postgresql_password='TU_POSTGRES_PASSWORD' \
  --from-literal=redis_username='default' \
  --from-literal=redis_password='TU_REDIS_PASSWORD' \
  --from-literal=mongodb_username='appuser' \
  --from-literal=mongodb_password='TU_MONGODB_PASSWORD' \
  --from-literal=qdrant_api_key='TU_QDRANT_API_KEY' \
  --from-literal=openmemory_openai_api_key='TU_OPENAI_KEY' \
  --from-literal=sonarqube_password='TU_SONARQUBE_PASSWORD' \
  --from-literal=grafana_username='admin' \
  --from-literal=grafana_password='TU_GRAFANA_PASSWORD' \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Valores críticos:** `cloudflare_api_token` y `cloudflared_token` son necesarios para el túnel Cloudflare.  
> El token de GitHub para ArgoCD lo configura Ansible automáticamente (secret `github-repo-creds`).  
> Los demás (`*_password`) puedes dejarlos como `DUMMY_...` para que el import job los salte, y configurarlos después directamente en OpenBao.

---

## 5. Activar GitOps

### 5.1 Cluster secret

Si las aplicaciones quedan en `Unknown`:

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

### 5.2 Aplicar root-app

```bash
kubectl apply -f gitops/root-app.yaml
```

### 5.3 Sync order

| Wave | Componentes |
|------|-------------|
| 1 | Longhorn, cert-manager, cloudnative-pg, percona-mongodb, reloader |
| 2 | OpenBao, External Secrets, vault-sync-operator |
| 3 | Agent Gateway |
| 4 | agentgateway-config, argocd-config |
| 5 | monitoring, cloudflared, headlamp |
| 6 | PostgreSQL, MongoDB, Redis, Qdrant |
| 8 | SonarQube, OpenMemory |
| 9 | Flow API |

Seguir progreso:

```bash
kubectl -n argocd get applications -w
```

Si queda en Unknown:

```bash
kubectl -n argocd patch application root --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```

---

## 6. Verificar

```bash
kubectl -n argocd get applications
kubectl get pods -n argocd ingress networking databases monitoring vault
```

---

## 7. Acceder

| URL | Servicio | Credenciales |
|-----|---------|--------------|
| `argocd.*` | Argo CD | admin / (paso 3) |
| `grafana.*` | Grafana | admin / (ver paso 4) |
| `agentgateway.*` | Agent Gateway | admin / admin |
| `headlamp.*` | Headlamp | `--token` |
| `hubble.*` | Hubble | Sin auth |
| `sonarqube.*` | SonarQube | admin / (ver paso 4) |
| `openmemory.*` | OpenMemory | Sin auth |

Token Headlamp:

```bash
kubectl create token headlamp -n monitoring
```

---

## 8. DNS

Registros en Cloudflare:

| Registro | Tipo | Valor |
|----------|------|-------|
| `cristianpuenguenan.online` | A | `192.168.80.20` |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` |

Verificar certificado:

```bash
kubectl get certificate -n networking
```

---

## Troubleshooting

**Apps en Unknown:**
```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
kubectl delete pod -n argocd argocd-application-controller-0
```

**ClusterSecretStore False:**
```bash
kubectl get clustersecretstore openbao -o wide
kubectl describe clustersecretstore openbao
```

**Longhorn stuck:**
```bash
kubectl create serviceaccount longhorn-sa -n argocd
kubectl create clusterrolebinding longhorn-temp --clusterrole=cluster-admin --serviceaccount=argocd:longhorn-sa
```
