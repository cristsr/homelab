# OpenBao + External Secrets Operator Setup

## Overview
Centralized secret management using OpenBao (Vault fork) and External Secrets Operator (ESO).

## Components Deployed

### 1. OpenBao (vault namespace)
- StatefulSet in dev mode (single node, in-memory)
- Accessible at `http://openbao.vault.svc.cluster.local:8200`
- KV v2 secrets engine at `secret/`

### 2. External Secrets Operator (vault namespace)
- Manages synchronization from OpenBao to Kubernetes Secrets
- Uses ClusterSecretStore to connect to OpenBao

### 3. ClusterSecretStore (openbao)
- Authenticates with OpenBao using Kubernetes auth
- ServiceAccount: `external-secrets-sa` in vault namespace

## Secret Structure in OpenBao

```
secret/data/databases/postgresql-app     -> username, password
secret/data/databases/redis             -> redis-password
secret/data/databases/mongodb-app        -> password
secret/data/apps/flow                  -> database-url, mongodb-url, redis-url
secret/data/infra/cloudflare          -> api-token
secret/data/devtools/openmemory        -> OPENAI_API_KEY
secret/data/devtools/sonarqube        -> password
```

## How to Add New Secrets

### 1. Add secret to OpenBao
```bash
kubectl -n vault exec openbao-0 -- /bin/bao kv put secret/<path> \
  key1='value1' key2='value2'
```

### 2. Create ExternalSecret
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: <target-namespace>
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: my-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: key1
      remoteRef:
        key: secret/data/<path>
        property: key1
```

### 3. Apply
```bash
kubectl apply -f my-externalsecret.yaml
```

## Troubleshooting

### Check ClusterSecretStore status
```bash
kubectl get clustersecretstore openbao -o yaml
```

### Check ExternalSecret sync
```bash
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>
```

### Check ESO logs
```bash
kubectl -n vault logs deployment/external-secrets --tail=50
```

### Test OpenBao access
```bash
kubectl -n vault exec openbao-0 -- /bin/bao status
kubectl -n vault exec openbao-0 -- /bin/bao kv list secret/
```
