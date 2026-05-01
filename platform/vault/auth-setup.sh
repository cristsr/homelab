#!/bin/bash
# OpenBao initialization and auth setup script
# Run this after OpenBao is deployed and unsealed

set -e

BAO_ADDR="http://openbao.vault.svc.cluster.local:8200"
kubectl="kubectl --namespace vault"

echo "=== OpenBao Setup Script ==="

# Check if OpenBao is ready
echo "Waiting for OpenBao to be ready..."
$kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s

# Port-forward to access OpenBao
echo "Setting up port-forward..."
$kubectl port-forward svc/openbao 8200:8200 &
PF_PID=$!
sleep 5

export VAULT_ADDR="http://localhost:8200"

# Check if already initialized
STATUS=$(bao status 2>&1 || true)
if echo "$STATUS" | grep -q "Initialized.*true"; then
    echo "OpenBao already initialized"
else
    echo "Initializing OpenBao..."
    bao operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/bao-init.json
    echo "Save these keys securely!"
    cat /tmp/bao-init.json
fi

# Unseal if needed
if echo "$STATUS" | grep -q "Sealed.*true"; then
    echo "Unsealing OpenBao..."
    UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /tmp/bao-init.json)
    bao operator unseal $UNSEAL_KEY
fi

# Login with root token
ROOT_TOKEN=$(jq -r '.root_token' /tmp/bao-init.json)
bao login token=$ROOT_TOKEN

# Enable KV v2 secrets engine
echo "Enabling KV v2 secrets engine..."
bao secrets enable -path=secret kv-v2 || echo "KV v2 already enabled"

# Enable Kubernetes auth
echo "Enabling Kubernetes auth..."
bao auth enable kubernetes || echo "Kubernetes auth already enabled"

# Configure Kubernetes auth
echo "Configuring Kubernetes auth..."
kubectl config view --raw > /tmp/kubeconfig
BAO_SA_NAME=$(kubectl get sa -n vault vault -o jsonpath='{.secrets[0]}')
BAO_SA_TOKEN=$(kubectl get secret -n vault $BAO_SA_NAME -o jsonpath='{.data.token}' | base64 -d)
BAO_CA_CERT=$(kubectl get secret -n vault $BAO_SA_NAME -o jsonpath='{.data.ca\.crt}')

bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$BAO_CA_CERT" \
    token_reviewer_jwt="$BAO_SA_TOKEN"

# Create policy for external-secrets
echo "Creating external-secrets policy..."
bao policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF

# Create role for external-secrets
echo "Creating external-secrets role..."
bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets-sa \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=24h

# Create example secrets
echo "Creating example secrets..."

# PostgreSQL app secret
bao kv put secret/databases/postgresql-app \
    username="appuser" \
    password="changeme"

# MongoDB app secret
bao kv put secret/databases/mongodb-app \
    password="changeme"

# Redis secret
bao kv put secret/databases/redis \
    redis-password="changeme"

# Flow app secrets
bao kv put secret/apps/flow \
    database-url="postgresql://appuser:changeme@postgresql.databases.svc.cluster.local:5432/flow" \
    mongodb-url="mongodb://appuser:changeme@mongodb.databases.svc.cluster.local:27017/flow" \
    redis-url="redis://:changeme@redis.databases.svc.cluster.local:6379"

# Cloudflare
bao kv put secret/infra/cloudflare \
    api-token="changeme"

# OpenMemory
bao kv put secret/dev-tools/openmemory \
    OPENAI_API_KEY="changeme"

echo "=== Setup Complete ==="
echo "Root token: $ROOT_TOKEN"
echo "Save the root token securely!"

# Kill port-forward
kill $PF_PID 2>/dev/null || true
