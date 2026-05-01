# OpenBao + External Secrets Operator Setup

## Overview
Centralized secret management using OpenBao (Vault fork) and External Secrets Operator (ESO).

## Components Deployed

### 1. OpenBao (vault namespace)
- StatefulSet in dev mode (single node, in-memory)
- Accessible at `http://openbao.vault.svc.cluster.local:8200`
- KV v2 secrets engine at `secret/`

### 2. External Secrets Operator (external-secrets namespace)
- Manages synchronization from OpenBao to Kubernetes Secrets
- Uses ClusterSecretStore to connect to OpenBao

### 3. ClusterSecretStore (openbao)
- Authenticates with OpenBao using token auth
- Token stored in `openbao-token` secret (external-secrets namespace)

## Secret Structure in OpenBao

```
secret/data/databases/postgresql-app     -> username, password
secret/data/databases/redis             -> redis-password
secret/data/databases/mongodb-app        -> password
secret/data/apps/flow                  -> database-url, mongodb-url, redis-url
secret/data/infra/cloudflare          -> api-token
secret/data/dev-tools/openmemory        -> OPENAI_API_KEY
secret/data/dev-tools/sonarqube        -> password
```

## How to Add New Secrets

### 1. Add secret to OpenBao
```bash
microk8s kubectl -n vault exec openbao-0 -- /bin/bao kv put secret/<path> \
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
microk8s kubectl apply -f my-externalsecret.yaml
```

## Token Management

The ESO uses a token with `external-secrets` policy. To renew/rotate:
```bash
# Generate new token
NEW_TOKEN=$(microk8s kubectl -n vault exec openbao-0 -- /bin/bao token create \
  -policy=external-secrets -ttl=24h | grep "^token " | awk '{print $2}')

# Update secret
microk8s kubectl -n external-secrets patch secret openbao-token \
  --type='merge' -p "{\"data\":{\"token\":\"$(echo -n $NEW_TOKEN | base64)\"}}"
```

## Troubleshooting

### Check ClusterSecretStore status
```bash
microk8s kubectl get clustersecretstore openbao -o yaml
```

### Check ExternalSecret sync
```bash
microk8s kubectl get externalsecret -A
microk8s kubectl describe externalsecret <name> -n <namespace>
```

### Check ESO logs
```bash
microk8s kubectl -n external-secrets logs deployment/external-secrets --tail=50
```

### Test OpenBao access
```bash
microk8s kubectl -n vault exec openbao-0 -- /bin/bao status
microk8s kubectl -n vault exec openbao-0 -- /bin/bao kv list secret/
```
