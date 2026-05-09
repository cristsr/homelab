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
ansible-playbook site.yaml
```

El playbook instala k0s (nodo único), escribe `~/.kube/config`, instala `helm` y `helmfile`, y crea el secret `github-repo-creds` en el namespace `argocd` para que ArgoCD pueda acceder al repositorio privado.

Verificar que el cluster está listo:

```bash
kubectl get nodes
```

---

## 3. Configurar variables de entorno

Crear el secret con todas las variables necesarias:

```bash
kubectl create secret generic vault-bootstrap-secrets \
  -n vault \
  --from-literal=argocd_github_pat='TU_GITHUB_PAT' \
  --from-literal=argocd_repo_url='https://github.com/cristsr/homelab' \
  --from-literal=dockerhub_password='TU_DOCKERHUB_PASSWORD' \
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
  --from-literal=grafana_password='TU_GRAFANA_PASSWORD'
```

---

## 4. Bootstrap (namespaces + Cilium + Argo CD)

```bash
cd bootstrap
helmfile sync
```

El helmfile aplica los namespaces, instala Cilium (espera a que esté listo) e instala Argo CD en ese orden.

Verificar Cilium:

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl get nodes
```

Obtener contraseña admin de Argo CD:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

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
| `argocd.*` | Argo CD | admin / (paso 4) |
| `grafana.*` | Grafana | admin / (bootstrap.yaml) |
| `agentgateway.*` | Agent Gateway | admin / admin |
| `headlamp.*` | Headlamp | `--token` |
| `hubble.*` | Hubble | Sin auth |
| `sonarqube.*` | SonarQube | admin / (bootstrap.yaml) |
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