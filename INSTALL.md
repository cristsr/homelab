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

### 2.2 Cifrar las variables sensibles con ansible-vault

El playbook gestiona automáticamente todos los secrets del cluster. Todas las variables marcadas como `CHANGEME` en `group_vars/all.yaml` deben cifrarse antes de ejecutar el playbook.

**Formato:** ejecuta el siguiente comando por cada variable, copia el bloque `!vault |` generado y reemplaza el `CHANGEME` correspondiente en `group_vars/all.yaml`.

```bash
cd ansible
ansible-vault encrypt_string 'EL_VALOR' --name 'NOMBRE_VARIABLE'
```

**Variables a cifrar** — solo secrets de infraestructura, los de aplicaciones se gestionan directamente en OpenBao:

| Variable | Descripción |
|---|---|
| `github_token` | PAT de GitHub para que Ansible clone el repo durante el bootstrap |
| `openbao_static_seal_key` | Clave AES-256 para Static Seal — generar con `openssl rand -base64 32` |
| `argocd_github_pat` | PAT de GitHub para que ArgoCD acceda al repo GitOps |
| `cloudflare_api_token` | Token de API de Cloudflare (cert-manager DNS-01) |
| `cloudflared_token` | Token del túnel Cloudflare |

Ejemplo para la clave de OpenBao:

```bash
ansible-vault encrypt_string "$(openssl rand -base64 32)" --name 'openbao_static_seal_key'
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
- Crea el secret `openbao-static-unseal-key` en el namespace `vault` (Static Seal)
- Crea el secret `vault-bootstrap-secrets` en el namespace `vault` con todas las credenciales de aplicaciones

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

> El playbook de Ansible (paso 2.4) crea automáticamente los secrets `openbao-static-unseal-key` y `vault-bootstrap-secrets` en el namespace `vault` usando las variables cifradas en `group_vars/all.yaml`.  
> **No es necesario crear nada manualmente.** Si necesitas actualizar un valor, edita `group_vars/all.yaml` y vuelve a ejecutar el playbook.

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

## 6. Post-init: poblar OpenBao y guardar la recovery key

> **Cuándo hacerlo:** Después de que GitOps active el cluster (paso 5) y el job `openbao-init` termine.  
> Este paso escribe todos los secrets directamente en OpenBao KV desde Ansible y guarda la recovery key de forma segura.

### 6.1 Poblar OpenBao KV

```bash
cd ansible
ansible-playbook vault-populate.yaml
```

El playbook escribe los secrets de infraestructura en OpenBao KV y limpia el root token temporal:

| Path KV | Contenido |
|---|---|
| `secret/argocd` | PAT y URL del repo GitOps |
| `secret/infra/cloudflare` | Token de API de Cloudflare |
| `secret/infra/cloudflared` | Token del túnel Cloudflare |

Los secrets de aplicaciones (bases de datos, servicios) se gestionan directamente en OpenBao al desplegar cada servicio.

### 6.2 Leer y guardar la recovery key

La recovery key permite regenerar un root token en caso de emergencia. Sin ella, perder el acceso admin a OpenBao es **irreversible**.

```bash
kubectl get secret openbao-recovery-key -n secret-management \
  -o jsonpath='{.data.key}' | base64 -d && echo
```

Cifrar y añadir a `group_vars/all.yaml`:

```bash
cd ansible
ansible-vault encrypt_string 'LA_KEY_DEL_PASO_ANTERIOR' --name 'openbao_recovery_key'
```

```yaml
openbao_recovery_key: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  38613330623564376561373361333864...
```

### 6.3 Eliminar la recovery key del cluster

```bash
kubectl delete secret openbao-recovery-key -n secret-management
```

---

## 7. Verificar

```bash
kubectl -n argocd get applications
kubectl get pods -n argocd ingress networking databases monitoring secret-management
```

---

## 8. Acceder

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

## 9. DNS

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
