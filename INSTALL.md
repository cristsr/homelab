# Guía de Instalación

Punto de partida: MicroK8s 1.32 instalado y limpio. El cluster debe estar en estado `Ready` antes de comenzar.

---

## Índice

1. [Preparar MicroK8s](#1-preparar-microk8s)
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
9. [Aplicar ExternalSecrets](#9-aplicar-externalsecrets)
10. [Activar GitOps](#10-activar-gitops)
    - [10.1 Registrar repositorio privado en ArgoCD](#101-registrar-repositorio-privado-en-argocd)
    - [10.2 Aplicar la root-app](#102-aplicar-la-root-app)
    - [10.3 Desbloquear el sync inicial de Longhorn](#103-desbloquear-el-sync-inicial-de-longhorn)
11. [Verificar el despliegue](#11-verificar-el-despliegue)
12. [Acceder a los servicios](#12-acceder-a-los-servicios)
13. [Configurar DNS y certificados](#13-configurar-dns-y-certificados)

---

## 1. Preparar MicroK8s

Deshabilitar los addons que entran en conflicto con Cilium y APISIX:

```bash
microk8s disable dns
microk8s disable ingress
microk8s disable ha-cluster
```

> `dns` se deshabilita para evitar conflictos durante la inicialización del CNI. Se vuelve a habilitar en el paso 5 después de instalar Cilium.

Verificar que el nodo está listo:

```bash
microk8s kubectl get nodes
# NAME   STATUS   ROLES    AGE   VERSION
# ...    Ready    <none>   ...   v1.32.x
```

Exportar el kubeconfig para usar `kubectl` directamente (sin prefijo `microk8s`):

```bash
mkdir -p ~/.kube
microk8s config > ~/.kube/config
chmod 600 ~/.kube/config
```

> Repetir este comando si se regeneran los certificados del cluster. Funciona también con `helm`, `k9s` y otras herramientas sin configuración adicional.

Agregar alias para `helm` (opcional):

```bash
alias helm='microk8s helm'
```

---

## 2. Clonar el repositorio

```bash
git clone git@github.com:cristsr/homelab.git
cd homelab
```

---

## 3. Configurar secrets y contraseñas

Antes de activar GitOps hay que reemplazar los valores `REEMPLAZAR_CON_*` en los archivos de values. Estos valores quedan commiteados en el repo — **usar contraseñas reales, no las de ejemplo**.

### 3.1 APISIX Admin Key

Generar una clave aleatoria:

```bash
openssl rand -hex 32
```

Editar `platform/ingress/apisix/values.yaml` y reemplazar:

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
git add platform/ingress/apisix/values.yaml platform/monitoring/values.yaml
git commit -m "chore: set passwords and secrets"
git push
```

> Las contraseñas de bases de datos (PostgreSQL, MongoDB, Redis) **no se commitean** — se crean como Kubernetes Secrets en el paso 7.

---

## 4. Crear namespaces

```bash
microk8s kubectl apply -f bootstrap/namespaces.yaml
```

Verificar:

```bash
microk8s kubectl get namespaces | grep -E 'infra|ingress|argocd|cert-manager|databases|dev-tools|apps|monitoring'
```

---

## 5. Instalar Cilium (CNI)

Cilium reemplaza el CNI por defecto de MicroK8s. Debe instalarse **antes** que cualquier otra cosa.

```bash
microk8s helm repo add cilium https://helm.cilium.io
microk8s helm repo update

microk8s helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.6 \
  -f bootstrap/cilium/values.yaml
```

Esperar a que los pods estén listos (puede tardar 2-3 minutos):

```bash
microk8s kubectl -n kube-system rollout status daemonset/cilium
microk8s kubectl -n kube-system get pods -l k8s-app=cilium
```

Verificar que el nodo sigue en estado `Ready`:

```bash
microk8s kubectl get nodes
```

> Si el nodo queda en `NotReady` después de instalar Cilium, reiniciar MicroK8s:
> `sudo snap restart microk8s`

Volver a habilitar CoreDNS (se deshabilitó en el paso 1 para evitar conflictos durante la instalación del CNI):

```bash
microk8s enable dns
microk8s kubectl -n kube-system rollout status deployment/coredns
```

---

## 6. Instalar Argo CD

Argo CD se instala manualmente una sola vez. A partir de aquí gestiona todo lo demás.

```bash
microk8s helm repo add argo https://argoproj.github.io/argo-helm
microk8s helm repo update

microk8s helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version 7.8.0 \
  -f bootstrap/argocd/values.yaml
```

Esperar a que todos los pods estén listos:

```bash
microk8s kubectl -n argocd rollout status deployment/argocd-server
microk8s kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server
```

Obtener la contraseña inicial del admin:

```bash
microk8s kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

> Guardar esta contraseña. Se puede cambiar después desde la UI de ArgoCD en `User Info → Update Password`.

### 6.1 Crear el cluster secret

ArgoCD necesita un secret con las credenciales de conexión al cluster para poder sincronizar aplicaciones. Este paso es **obligatorio** — sin él, el `application-controller` no puede comunicarse con el API server y todas las aplicaciones quedan en estado `Unknown` con timeouts.

```bash
CA_DATA=$(microk8s kubectl get configmap kube-root-ca.crt \
  -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)

microk8s kubectl apply -f - <<EOF
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
microk8s kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
```

> Si ArgoCD ya estaba instalado y las aplicaciones están en `Unknown`, crear el secret y reiniciar el controller:
> `microk8s kubectl delete pod -n argocd argocd-application-controller-0`

---

## 7. Instalar OpenBao (Gestión de Secretos)

OpenBao actúa como vault central para gestionar todos los secretos del homelab. Se despliega vía Argo CD en el namespace `vault`.

Primero, aplicar la aplicación de Argo CD para OpenBao:

```bash
microk8s kubectl apply -f gitops/apps/infra/openbao.yaml
```

Esperar a que el pod esté listo:

```bash
microk8s kubectl -n vault rollout status statefulset/openbao
```

### 7.1 Inicializar y configurar OpenBao

OpenBao se despliega en modo `-dev` para simplificar el homelab (single node, sin High Availability). Para producción, usar Raft backend con unseal manual.

Ejecutar el script de configuración:

```bash
# Copiar el script al pod y ejecutarlo, o usar port-forward
microk8s kubectl cp platform/vault/auth-setup.sh vault/openbao-0:/tmp/auth-setup.sh
microk8s kubectl exec -n vault openbao-0 -- bash /tmp/auth-setup.sh
```

O manualmente con port-forward:

```bash
microk8s kubectl port-forward -n vault svc/openbao 8200:8200 &
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
    kubernetes_ca_cert="$(microk8s kubectl get secret -n vault vault-token-xxxxx -o jsonpath='{.data.ca\.crt}' | base64 -d)" \
    token_reviewer_jwt="$(microk8s kubectl get secret -n vault vault-token-xxxxx -o jsonpath='{.data.token}' | base64 -d)"

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
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=24h
```

> **Importante**: Guardar el root token y unseal key en un lugar seguro. Sin ellos no podrás acceder a OpenBao.

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
bao kv put secret/dev-tools/openmemory \
    OPENAI_API_KEY="sk-..."

# SonarQube
bao kv put secret/dev-tools/sonarqube \
    password="TU_PASSWORD_SEGURA"
```

> Estos secretos ahora están centralizados en OpenBao y se sincronizan automáticamente a Kubernetes via External Secrets.

---

## 8. Instalar External Secrets Operator

External Secrets Operator (ESO) sincroniza secretos desde OpenBao hacia Kubernetes Secrets de forma declarativa.

Aplicar la aplicación de Argo CD:

```bash
microk8s kubectl apply -f gitops/apps/infra/external-secrets.yaml
```

Esperar a que ESO esté listo:

```bash
microk8s kubectl -n external-secrets rollout status deployment external-secrets
microk8s kubectl -n external-secrets rollout status deployment external-secrets-webhook
```

Crear el ServiceAccount para que ESO se autentique con OpenBao:

```bash
microk8s kubectl apply -f platform/vault/external-secrets-sa.yaml
```

Aplicar el ClusterSecretStore que apunta a OpenBao:

```bash
microk8s kubectl apply -f platform/vault/cluster-secret-store.yaml
```

Verificar que el ClusterSecretStore esté listo:

```bash
microk8s kubectl get clustersecretstore openbao
# NAME      AGE   STATUS   READY
# openbao   10s           True
```

---

## 9. Aplicar ExternalSecrets

Los ExternalSecrets definen qué secretos sincronizar desde OpenBao hacia cada namespace.

Aplicar los ExternalSecrets para cada aplicación:

```bash
# PostgreSQL
microk8s kubectl apply -f platform/vault/externalsecret-postgresql.yaml

# MongoDB
microk8s kubectl apply -f platform/vault/externalsecret-mongodb.yaml

# Redis
microk8s kubectl apply -f platform/vault/externalsecret-redis.yaml

# Flow API
microk8s kubectl apply -f platform/vault/externalsecret-flow.yaml

# OpenMemory
microk8s kubectl apply -f platform/vault/externalsecret-openmemory.yaml

# Cloudflare (cert-manager)
microk8s kubectl apply -f platform/vault/externalsecret-cloudflare.yaml
```

Verificar que los secrets se hayan creado:

```bash
microk8s kubectl get externalsecret -A
# NAMESPACE    NAME                      STORE    REFRESH INTERVAL   STATUS    READY
# databases    postgresql-app-secret     openbao  1h                 Success   True
# databases    mongodb-app-secret        openbao  1h                 Success   True
# ...

microk8s kubectl get secrets -n databases
microk8s kubectl get secrets -n apps
microk8s kubectl get secrets -n dev-tools
microk8s kubectl get secrets -n cert-manager
```

> Los secrets ahora se gestionan de forma declarativa. Cualquier cambio en OpenBao se sincroniza automáticamente a Kubernetes (cada 1h o al reiniciar el pod).

---

## 10. Crear secrets de aplicaciones

Estos secrets **nunca se commitean** al repositorio. Se crean directamente en el cluster.

Los comandos son idempotentes: crean el secret si no existe o lo actualizan si ya existe.

### 10.1 PostgreSQL (CloudNativePG)

El operador requiere un secret con claves `username` y `password` para el usuario propietario de la base de datos.

```bash
# Usuario propietario de la DB homelab
microk8s kubectl create secret generic postgresql-app-secret \
  --from-literal=username=admin \
  --from-literal=password=admin \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 10.2 MongoDB (Percona Operator)

Percona requiere dos secrets separados: uno para los usuarios internos del operador y otro para el usuario de aplicación.

```bash
# Usuarios de sistema internos del operador Percona
microk8s kubectl create secret generic mongodb-secret \
  --from-literal=MONGODB_BACKUP_USER=backup \
  --from-literal=MONGODB_BACKUP_PASSWORD=admin \
  --from-literal=MONGODB_DATABASE_ADMIN_USER=databaseAdmin \
  --from-literal=MONGODB_DATABASE_ADMIN_PASSWORD=admin \
  --from-literal=MONGODB_CLUSTER_ADMIN_USER=clusterAdmin \
  --from-literal=MONGODB_CLUSTER_ADMIN_PASSWORD=admin \
  --from-literal=MONGODB_CLUSTER_MONITOR_USER=clusterMonitor \
  --from-literal=MONGODB_CLUSTER_MONITOR_PASSWORD=admin \
  --from-literal=MONGODB_USER_ADMIN_USER=userAdmin \
  --from-literal=MONGODB_USER_ADMIN_PASSWORD=admin \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# Usuario de aplicación (definido en spec.users del CRD)
microk8s kubectl create secret generic mongodb-app-secret \
  --from-literal=password=admin \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 10.3 Redis

```bash
microk8s kubectl create secret generic redis-secret \
  --from-literal=redis-password=admin \
  -n databases \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 10.4 Aplicaciones

```bash
# Flow API
# Nota: PostgreSQL usa el servicio postgresql-rw (primario de CloudNativePG)
# Nota: MongoDB incluye replicaSet=rs0 requerido por Percona
microk8s kubectl create secret generic flow-secrets \
  --from-literal=database-url="postgresql://admin:admin@postgresql-rw.databases.svc.cluster.local:5432/homelab" \
  --from-literal=mongodb-url="mongodb://admin:admin@mongodb-rs0.databases.svc.cluster.local:27017/homelab?replicaSet=rs0&authSource=homelab" \
  --from-literal=redis-url="redis://:admin@redis-master.databases.svc.cluster.local:6379" \
  -n apps \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# OpenMemory
microk8s kubectl create secret generic openmemory-secrets \
  --from-literal=OPENAI_API_KEY=sk-... \
  -n dev-tools \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

# SonarQube — contraseña del rol 'sonarqube' gestionado por CloudNativePG managed.roles
microk8s kubectl create secret generic sonarqube-db-secret \
  --from-literal=password=admin \
  -n dev-tools \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 10.5 Cloudflare — cert-manager (DNS01 challenge)

Crear el token en Cloudflare → My Profile → API Tokens.  
Permisos necesarios: `Zone:DNS:Edit` para el dominio `cristianpuenguenan.online`.

```bash
microk8s kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=TU_CLOUDFLARE_API_TOKEN \
  -n cert-manager \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

### 10.6 Cloudflare — cloudflared (Tunnel)

Crear el túnel en Cloudflare → Zero Trust → Networks → Tunnels → Create Tunnel.  
Copiar el token que aparece al crearlo.

```bash
microk8s kubectl create secret generic cloudflared-token \
  --from-literal=token=TU_CLOUDFLARE_TUNNEL_TOKEN \
  -n infra \
  --dry-run=client -o yaml | microk8s kubectl apply -f -
```

> Estos dos secrets deben existir **antes** de aplicar la root-app. ArgoCD no los gestiona (están excluidos del sync) — son responsabilidad del operador.

> **Nota**: Con OpenBao + External Secrets, los secrets de aplicaciones ya no se crean manualmente. Se gestionan desde OpenBao y se sincronizan automáticamente.

---

## 10. Activar GitOps

### 10.1 Registrar repositorio privado en ArgoCD

Como el repositorio es privado, ArgoCD necesita credenciales para clonar el código. Crear un [Personal Access Token (PAT)](https://github.com/settings/tokens) en GitHub con scope `repo` (solo lectura es suficiente).

```bash
microk8s kubectl -n argocd create secret generic homelab-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/cristsr/homelab \
  --from-literal=username=cristsr \
  --from-literal=password=TU_GITHUB_PAT \
  --dry-run=client -o yaml | microk8s kubectl apply -f -

microk8s kubectl -n argocd label secret homelab-repo \
  argocd.argoproj.io/secret-type=repository \
  --overwrite
```

Verificar que ArgoCD reconoció el repositorio:

```bash
microk8s kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
```

### 10.2 Aplicar la root-app

Con ArgoCD corriendo, los secrets de aplicaciones en su lugar y el repositorio registrado, aplicar la root-app. A partir de aquí ArgoCD despliega todo el stack automáticamente siguiendo los sync-waves.

```bash
microk8s kubectl apply -f gitops/root-app.yaml
```

> La advertencia `metadata.finalizers: prefer a domain-qualified finalizer name` es un falso positivo de kubectl — no afecta el funcionamiento.

ArgoCD comenzará a sincronizar en este orden:

| Wave | Componentes |
|------|-------------|
| 1 | Longhorn, cert-manager, cloudnative-pg (operador), percona-mongodb-operator |
| 2 | OpenBao (vault) |
| 3 | External Secrets Operator |
| 4 | cert-manager-config (ClusterIssuer + Certificate wildcard) |
| 5 | APISIX |
| 6 | apisix-config (Routes, PluginConfigs, TLS) |
| 7 | kube-prometheus-stack, cloudflared, headlamp |
| 8 | PostgreSQL (Cluster CRD), MongoDB (PSMDB CRD), Redis, Qdrant, ServiceMonitors |
| 9 | NetworkPolicies de bases de datos |
| 10 | SonarQube, OpenMemory |
| 11 | Flow API |

Seguir el progreso en tiempo real:

```bash
microk8s kubectl -n argocd get applications -w
```

Si la root-app queda en `Unknown` o hay que forzar un re-sync (por ejemplo tras corregir un secret o cambiar configuración):

```bash
microk8s kubectl -n argocd patch application root --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

### 10.3 Desbloquear el sync inicial de Longhorn

El chart de Longhorn incluye un hook de pre-upgrade que necesita `longhorn-service-account` para crear su pod, pero esa ServiceAccount la crea el propio chart durante el sync principal. En una instalación nueva esto genera un círculo vicioso: el hook falla → el sync nunca avanza → la ServiceAccount nunca se crea.

Romper el bloqueo manualmente:

```bash
microk8s kubectl create serviceaccount longhorn-service-account -n argocd

microk8s kubectl create clusterrolebinding longhorn-pre-upgrade-temp \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd:longhorn-service-account

microk8s kubectl delete job -n infra longhorn-pre-upgrade 2>/dev/null || true
```

> El ClusterRoleBinding temporal `longhorn-pre-upgrade-temp` queda huérfano tras el sync — ArgoCD crea el definitivo (`longhorn-bind`). Se puede borrar después con `microk8s kubectl delete clusterrolebinding longhorn-pre-upgrade-temp`.

Esperar a que Longhorn sincronice antes de continuar (puede tardar 2-3 minutos):

```bash
microk8s kubectl get pods -n infra -l app=longhorn-manager -w
```

---

## 11. Verificar el despliegue

Comprobar que todas las Applications están en `Synced` / `Healthy`:

```bash
microk8s kubectl -n argocd get applications
```

Verificar pods por namespace:

```bash
microk8s kubectl get pods -n argocd
microk8s kubectl get pods -n ingress
microk8s kubectl get pods -n infra
microk8s kubectl get pods -n cert-manager
microk8s kubectl get pods -n databases
microk8s kubectl get pods -n monitoring
microk8s kubectl get pods -n dev-tools
microk8s kubectl get pods -n apps
```

> cloudflared estará `Degraded` hasta que se configuren los registros DNS en el paso 11. El resto del stack debe estar `Healthy`.

---

## 12. Acceder a los servicios

Todos los servicios son accesibles en `https://<subdominio>.cristianpuenguenan.online` desde la LAN.

| URL | Servicio | Credenciales |
|-----|---------|--------------|
| `https://argocd.cristianpuenguenan.online` | Argo CD | `admin` / contraseña del paso 6 |
| `https://grafana.cristianpuenguenan.online` | Grafana | `admin` / contraseña configurada en paso 3.3 |
| `https://apisix.cristianpuenguenan.online` | APISIX Dashboard | `admin` / `admin` (cambiar al entrar) |
| `https://headlamp.cristianpuenguenan.online` | Headlamp | Token de ServiceAccount |
| `https://hubble.cristianpuenguenan.online` | Hubble UI (Cilium) | Sin auth |
| `https://sonarqube.cristianpuenguenan.online` | SonarQube | `admin` / `admin` (cambiar al entrar) |
| `https://openmemory.cristianpuenguenan.online` | OpenMemory | Sin auth |

### Token para Headlamp

```bash
microk8s kubectl create token headlamp -n infra
```

---

## 13. Configurar DNS y certificados

Los secrets de Cloudflare ya fueron creados en el paso 7. Este paso configura los registros DNS y verifica que el certificado wildcard se haya emitido correctamente.

### 11.1 Configurar DNS

Agregar registros A en Cloudflare apuntando a la IP del nodo (`192.168.80.20`).

| Registro | Tipo | Valor | Proxy |
|---|---|---|---|
| `cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |
| `*.cristianpuenguenan.online` | A | `192.168.80.20` | DNS only |

> Usar **DNS only** (nube gris) para los subdominios internos. Solo activar proxy para los que se expongan públicamente vía Cloudflare Tunnel.

### 11.2 Verificar el certificado

El certificado wildcard debería emitirse en 5-10 minutos tras configurar el DNS:

```bash
microk8s kubectl get certificate -n ingress
# wildcard-home-tls   True   ...
```

Si sigue en `False`, revisar el estado del `CertificateRequest`:

```bash
microk8s kubectl describe certificaterequest -n ingress
```

---

## Troubleshooting rápido

**Todas las aplicaciones en `Unknown` sync status + timeouts al API server**
```bash
# Causa: falta el cluster secret en el namespace de ArgoCD.
# Verificar:
microk8s kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
# Si no devuelve nada, seguir el paso 6.1 para crearlo.
# Tras crear el secret, reiniciar el application-controller:
microk8s kubectl delete pod -n argocd argocd-application-controller-0
```

**Pods en Pending tras instalar Cilium**
```bash
microk8s kubectl describe pod <pod> -n <ns>
# Buscar eventos relacionados con CNI o scheduling
sudo snap restart microk8s
```

**Certificado en estado `False`**
```bash
microk8s kubectl describe certificaterequest -n ingress
# Verificar que el secret cloudflare-api-token existe y tiene el token correcto
microk8s kubectl get secret cloudflare-api-token -n cert-manager
```

**Application de ArgoCD en `Unknown` sync status**
```bash
# Causa más común: repositorio privado sin credenciales registradas.
# Verificar que el secret del repo existe:
microk8s kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
# Si no existe, seguir el paso 8.1.
# Forzar re-sync tras crear las credenciales:
microk8s kubectl -n argocd patch application root \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```

**Application de ArgoCD en `OutOfSync`**
```bash
microk8s kubectl -n argocd get application <nombre> -o yaml
# Forzar sync manual:
# Desde la UI de ArgoCD → Sync → Force
```

**APISIX sin rutas activas**
```bash
microk8s kubectl get apisixroute -n ingress
# Si están vacías, verificar que apisix-config está en Synced
```

**Bases de datos en `Unknown` / pods en `ImagePullBackOff`**
```bash
# Diagnóstico del Application:
microk8s kubectl -n argocd get application postgresql \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool

# Diagnóstico del pod:
microk8s kubectl describe pod -n databases <pod> | grep -A10 Events

# Hard refresh para forzar re-evaluación:
for app in postgresql mongodb redis; do
  microk8s kubectl -n argocd annotate application $app \
    argocd.argoproj.io/refresh=hard --overwrite
done
```

**OpenBao en Pending o CrashLoopBackOff**
```bash
# Verificar que Longhorn esté listo (OpenBao necesita storage)
microk8s kubectl get storageclass
# Debe mostrar longhorn como default

# Ver logs
microk8s kubectl logs -n vault openbao-0

# Si falla por permissions, verificar que el pod puede escribir a /vault/data
microk8s kubectl exec -n vault openbao-0 -- ls -la /vault/data
```

**ClusterSecretStore en estado `False`**
```bash
microk8s kubectl get clustersecretstore openbao
# Si no está Ready, verificar:
# 1. OpenBao está corriendo y unsealed
# 2. Kubernetes auth está habilitado en OpenBao
# 3. El role 'external-secrets' existe en OpenBao
# 4. El ServiceAccount external-secrets-sa existe

# Ver detalles del error:
microk8s kubectl describe clustersecretstore openbao
```

**ExternalSecret no sincroniza (Ready=False)**
```bash
# Ver el estado del ExternalSecret
microk8s kubectl describe externalsecret -n databases postgresql-app-secret

# Ver logs del controller de ESO
microk8s kubectl logs -n external-secrets deployment/external-secrets

# Verificar que el secreto existe en OpenBao
# (desde dentro del cluster con port-forward)
bao kv get secret/databases/postgresql-app
```

**Secret no se actualiza después de cambiar en OpenBao**
```bash
# ESO sincroniza cada refreshInterval (1h por defecto)
# Forzar re-sync manualmente:
microk8s kubectl annotate externalsecret -n databases postgresql-app-secret \
    force-sync=true --overwrite

# O esperar al próximo sync automático
```

**ArgoCD Application atascada en operación `Running` (hook Job que no existe)**
```bash
# Síntoma: operationState.message = "waiting for completion of hook batch/Job/..."
# pero el Job no existe en el namespace.
microk8s kubectl -n argocd get application <nombre> \
  -o jsonpath='{.status.operationState.phase}{"\n"}{.status.operationState.message}{"\n"}'

# Solución: eliminar la Application y dejar que root-app la recree limpia.
microk8s kubectl delete application -n argocd <nombre>
microk8s kubectl -n argocd patch application root --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
```
