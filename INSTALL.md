# Guía de Instalación

Punto de partida: k0s instalado y listo. El cluster debe estar en estado `Ready`.

---

## 1. Preparar k0s

Verificar nodo listo:

```bash
kubectl get nodes
```

Copiar kubeconfig:

```bash
mkdir -p ~/.kube
sudo cp /etc/k0s/k0s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
```

---

## 2. Clonar repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar bootstrap secrets

Crear el secret de bootstrap directamente (no commitear):

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

Agent Gateway Admin Key:

```bash
openssl rand -hex 32
```

Editar `platform/ingress/agentgateway/values.yaml` (este sí se puede commitear).

---

## 4. Crear namespaces

```bash
kubectl apply -f bootstrap/namespaces.yaml
```

---

## 5. Instalar Cilium

```bash
helm repo add cilium https://helm.cilium.io
helm repo update

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.18.4 \
  -f bootstrap/cilium/values.yaml
```

Esperar (2-3 min):

```bash
kubectl -n kube-system rollout status daemonset/cilium
kubectl get nodes
```

---

## 6. Instalar Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.0 \
  -f bootstrap/argocd/values.yaml
```

Obtener contraseña admin:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 7. Activar GitOps

### 7.1 Cluster secret

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

### 7.2 Aplicar root-app

```bash
kubectl apply -f gitops/root-app.yaml
```

### 7.3 Sync order

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

## 8. Verificar

```bash
kubectl -n argocd get applications
kubectl get pods -n argocd ingress networking databases monitoring vault
```

---

## 9. Acceder

| URL | Servicio | Credenciales |
|-----|---------|--------------|
| `argocd.*` | Argo CD | admin / (paso 6) |
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

## 10. DNS

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