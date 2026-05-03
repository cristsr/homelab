# Guía de Instalación

Punto de partida: k0s instalado y limpio. El cluster debe estar en estado `Ready` antes de comenzar.

---

## Índice

1. [Preparar k0s](#1-preparar-k0s)
2. [Clonar el repositorio](#2-clonar-el-repositorio)
3. [Configurar secrets y contraseñas](#3-configurar-secrets-y-contraseñas)
4. [Crear namespaces](#4-crear-namespaces)
5. [Instalar Cilium (CNI)](#5-instalar-cilium-cni)
6. [Instalar Argo CD](#6-instalar-argo-cd)
   - [6.1 Crear el cluster secret](#61-crear-el-cluster-secret)
7. [Instalar OpenBao (Gestión de Secretos)](#7-instalar-openbao-gestión-de-secretos)
   - [7.1 Inicializar y configurar OpenBao](#71-inicializar-y-configurar-openbao)
   - [7.2 Crear secrets en OpenBao](#72-crear-secrets-en-openbao)
8. [Instalar External Secrets Operator](#8-instalar-external-secrets-operator)
9. [Activar GitOps](#9-activar-gitops)
   - [9.1 Registrar repositorio privado en ArgoCD](#91-registrar-repositorio-privado-en-argocd)
   - [9.2 Aplicar la root-app](#92-aplicar-la-root-app)
   - [9.3 Desbloquear el sync inicial de Longhorn](#93-desbloquear-el-sync-inicial-de-longhorn)
10. [Verificar el despliegue](#10-verificar-el-despliegue)
11. [Acceder a los servicios](#11-acceder-a-los-servicios)
12. [Configurar DNS y certificados](#12-configurar-dns-y-certificados)

---

## 1. Preparar k0s

Verificar que el nodo está listo:

```bash
kubectl get nodes
# NAME   STATUS   ROLES    AGE   VERSION
# ...    Ready    <none>   ...   v1.31.x
```

El kubeconfig está en `/etc/k0s/k0s.yaml`:

```bash
mkdir -p ~/.kube
sudo cp /etc/k0s/k0s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
```

> Para usar kubectl desde otro equipo, copiar el kubeconfig del nodo.

---

## 2. Clonar el repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar secrets y contraseñas

Antes de activar GitOps hay que reemplazar los valores `REEMPLAZAR_CON_*` en los archivos de values.

### 3.1 APISIX Admin Key

Generar una clave aleatoria:

```bash
openssl rand -hex 32
```

Editar `platform/ingress/values.yaml` y reemplazar:

```yaml
adminKey: "REEMPLAZAR_CON_ADMIN_KEY"
# por:
adminKey: "tu-clave-generada"
```

### 3.2 Grafana

`platform/monitoring/values.yaml`:
```yaml
grafana:
  adminPassword: "tu-password-grafana"
```

### 3.3 Commitear los cambios

```bash
git add platform/ingress/values.yaml platform/monitoring/values.yaml
git commit -m "chore: set passwords and secrets"
git push
```

---

## 4. Crear namespaces

```bash
kubectl apply -f bootstrap/namespaces.yaml
```

Verificar:

```bash
kubectl get namespaces
```

---

## 5. Instalar Cilium (CNI)

Cilium reemplaza el CNI por defecto de k0s. Debe instalarse **antes** que cualquier otra cosa.

```bash
helm repo add cilium https://helm.cilium.io
helm repo update

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.18.4 \
  -f bootstrap/cilium/values.yaml
```

Esperar a que los pods estén listos (puede tardar 2-3 minutos):

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl -n kube-system get pods -l k8s-app=cilium
```

Verificar que el nodo sigue en estado `Ready`:

```bash
kubectl get nodes
```

> Si el nodo queda en `NotReady` después de instalar Cilium, reiniciar el nodo o revisar los logs:
> `kubectl -n kube-system logs daemonset/cilium`

---

## 6. Instalar Argo CD

Argo CD se instala manualmente una sola vez. A partir de aquí gestiona todo lo demás.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.0 \
  -f bootstrap/argocd/values.yaml
```

Esperar a que todos los pods estén listos:

```bash
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server
```

Obtener la contraseña inicial del admin:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

> Guardar esta contraseña. Se puede cambiar después desde la UI de ArgoCD en `User Info → Update Password`.

### 6.1 Crear el cluster secret

ArgoCD necesita un secret con las credenciales de conexión al cluster.

```bash
CA_DATA=$(kubectl get configmap kube-root-ca.crt \
  -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)

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

Verificar que ArgoCD reconoce el cluster:

```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
```

> Si ArgoCD ya estaba instalado y las aplicaciones están en `Unknown`, crear el secret y reiniciar el controller:
> `kubectl delete pod -n argocd argocd-application-controller-0`

---

## 7. Instalar OpenBao (Gestión de Secretos)

OpenBao actúa como vault central. Se despliega vía Argo CD en el namespace `vault`.

Aplicar la aplicación de Argo CD:

```bash
kubectl apply -f gitops/apps/infra/openbao.yaml
```

Esperar a que el pod esté listo:

```bash
kubectl -n vault rollout status statefulset/openbao
```

### 7.1 Inicializar y configurar OpenBao

OpenBao se despliega en modo `-dev` para simplificar el homelab (single node, sin High Availability).

Ejecutar el script de configuración:

```bash
kubectl cp platform/vault/auth-setup.sh vault/openbao-0:/tmp/auth-setup.sh
kubectl exec -n vault openbao-0 -- bash /tmp/auth-setup.sh
```

O manualmente con port-forward:

```bash
kubectl port-forward -n vault svc/openbao 8200 &
export VAULT_ADDR="http://localhost:8200"

# Inicializar (guardar las keys y root token)
bao operator init -key-shares=1 -key-threshold=1 -format=json

# Desbloquear (unseal)
bao operator unseal <unseal_key>

# Login
bao login token=<root_token>

# Habilitar KV v2
bao secrets enable -path=secret kv-v2

# Habilitar auth de Kubernetes
bao auth enable kubernetes

# Configurar Kubernetes auth
bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$(kubectl get secret -n vault vault-token-xxxxx -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    token_reviewer_jwt="$(kubectl get secret -n vault vault-token-xxxxx -o jsonpath='{.data.token}' | base64 -d)"

# Crear política para external-secrets
bao policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF

# Crear role para external-secrets
bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets-sa \
    bound_service_account_namespaces=vault \
    policies=external-secrets \
    ttl=24h
```

> **Importante**: Guardar el root token y unseal key en un lugar seguro.

### 7.2 Crear secrets en OpenBao

Una vez configurado OpenBao, crear los secretos de las aplicaciones:

```bash
# PostgreSQL app secret
bao kv put secret/databases/postgresql-app \
    username="admin" \
    password="TU_PASSWORD_SEGURA"

# MongoDB app secret
bao kv put secret/databases/mongodb-app \
    password="TU_PASSWORD_SEGURA"

# Redis secret
bao kv put secret/databases/redis \
    redis-password="TU_PASSWORD_SEGURA"

# Flow app secrets
bao kv put secret/apps/flow \
    database-url="postgresql://admin:PASSWORD@postgresql-rw.databases.svc.cluster.local:5432/homelab" \
    mongodb-url="mongodb://admin:PASSWORD@mongodb-rs0.databases.svc.cluster.local:27017/homelab?replicaSet=rs0&authSource=homelab" \
    redis-url="redis://:PASSWORD@redis-master.databases.svc.cluster.local:6379"

# Cloudflare API token
bao kv put secret/infra/cloudflare \
    api-token="TU_CLOUDFLARE_API_TOKEN"

# OpenMemory
bao kv put secret/devtools/openmemory \
    OPENAI_API_KEY="sk-..."

# SonarQube
bao kv put secret/devtools/sonarqube \
    password="TU_PASSWORD_SEGURA"
```

---

## 8. Instalar External Secrets Operator

External Secrets Operator (ESO) sincroniza secretos desde OpenBao hacia Kubernetes Secrets.

Aplicar la aplicación de Argo CD:

```bash
kubectl apply -f gitops/apps/infra/external-secrets.yaml
```

Esperar a que ESO esté listo:

```bash
kubectl -n vault rollout status deployment external-secrets
```

> External Secrets está ahora en el namespace `vault`.

Verificar que el ClusterSecretStore esté listo:

```bash
kubectl get clustersecretstore openbao
# NAME      AGE   STATUS   READY
# openbao   10s           True
```

---

## 9. Activar GitOps

### 9.1 Registrar repositorio privado en ArgoCD

Como el repositorio es privado, ArgoCD necesita credenciales. Crear un [Personal Access Token (PAT)](https://github.com/settings/tokens) en GitHub con scope `repo`.

```bash
kubectl -n argocd create secret generic homelab-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cristsr/homelab \
  --from-literal=username=cristsr \
  --from-literal=password=TU_GITHUB_PAT \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret homelab-repo \
  argocd.argoproj.io/secret-type=repository \
  --overwrite
```

Verificar que ArgoCD reconoció el repositorio:

```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
```

### 9.2 Aplicar la root-app

```bash
kubectl apply -f gitops/root-app.yaml
```

ArgoCD comenzará a sincronizar en este orden:

| Wave | Componentes |
|------|-------------|
| 1 | Longhorn, cert-manager, cloudnative-pg, percona-mongodb-operator |
| 2 | OpenBao (vault) |
| 3 | External Secrets Operator |
| 4 | cert-manager-config (ClusterIssuer + Certificate) |
| 5 | APISIX |
| 6 | apisix-config (Routes, PluginConfigs, TLS) |
| 7 | kube-prometheus-stack, cloudflared, headlamp |
| 8 | PostgreSQL, MongoDB, Redis, Qdrant, ServiceMonitors |
| 9 | NetworkPolicies |
| 10 | SonarQube, OpenMemory |
| 11 | Flow API |

Seguir el progreso:

```bash
kubectl -n argocd get applications -w
```

Si la root-app queda en `Unknown`:

```bash
kubectl -n argocd patch application root --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

### 9.3 Desbloquear el sync inicial de Longhorn

```bash
kubectl create serviceaccount longhorn-service-account -n argocd

kubectl create clusterrolebinding longhorn-pre-upgrade-temp \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd:longhorn-service-account

kubectl delete job -n networking longhorn-pre-upgrade 2>/dev/null || true
```

> El ClusterRoleBinding temporal queda huérfano tras el sync. Se puede borrar después.

Esperar a que Longhorn sincronice:

```bash
kubectl get pods -n networking -l app=longhorn-manager -w
```

---

## 10. Verificar el despliegue

```bash
kubectl -n argocd get applications
```

Verificar pods por namespace:

```bash
kubectl get pods -n argocd
kubectl get pods -n ingress
kubectl get pods -n networking
kubectl get pods -n databases
kubectl get pods -n monitoring
kubectl get pods -n devtools
kubectl get pods -n apps
kubectl get pods -n vault
```

---

## 11. Acceder a los servicios

Todos los servicios son accesibles en `https://<subdominio>.cristianpuenguenan.online` desde la LAN.

| URL | Servicio | Credenciales |
|-----|---------|--------------|
| `https://argocd.cristianpuenguenan.online` | Argo CD | `admin` / contraseña del paso 6 |
| `https://grafana.cristianpuenguenan.online` | Grafana | `admin` / contraseña configurada en paso 3.3 |
| `https://apisix.cristianpuenguenan.online` | APISIX Dashboard | `admin` / `admin` (cambiar al entrar) |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Token de ServiceAccount |
| `https://hubble.cristianpuenguenan.online` | Hubble UI | Sin auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | `admin` / `admin` |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | Sin auth |

Token para Headlamp:

```bash
kubectl create token headlamp -n networking
```

---

## 12. Configurar DNS y certificados

Agregar registros A en Cloudflare apuntando a la IP del nodo.

| Registro | Tipo | Valor | Proxy |
|---|---|---|---|
| `cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |

Verificar el certificado:

```bash
kubectl get certificate -n ingress
```

---

## Troubleshooting

**Todas las aplicaciones en `Unknown` sync status**
```bash
# Falta el cluster secret
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
# Si no existe, seguir paso 6.1
kubectl delete pod -n argocd argocd-application-controller-0
```

**Pods en Pending tras instalar Cilium**
```bash
kubectl describe pod <pod> -n <ns>
# Revisar eventos de CNI o scheduling
```

**Certificado en estado `False`**
```bash
kubectl describe certificaterequest -n ingress
kubectl get secret cloudflare-api-token -n networking
```

**Application en `Unknown` sync status (repositorio privado)**
```bash
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
# Forzar re-sync:
kubectl -n argocd patch application root --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

**OpenBao en Pending o CrashLoopBackOff**
```bash
# Verificar que Longhorn esté listo
kubectl get storageclass
# Ver logs
kubectl logs -n vault openbao-0
```

**ClusterSecretStore en estado `False`**
```bash
kubectl get clustersecretstore openbao
kubectl describe clustersecretstore openbao
# Verificar: OpenBao corriendo, Kubernetes auth habilitado, role existe
```