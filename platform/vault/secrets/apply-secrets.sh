#!/bin/bash
set -e

# Configuration
BAO_ADDR="${BAO_ADDR:-http://openbao.vault.svc.cluster.local:8200}"
SECRETS_DIR="$(dirname "$0")"

echo "=== OpenBao Bootstrap Secrets ==="
echo "Address: $BAO_ADDR"
echo "Secrets dir: $SECRETS_DIR"
echo ""

# Check if OpenBao is available
if ! curl -s "$BAO_ADDR/v1/sys/health" >/dev/null 2>&1; then
  echo "Error: OpenBao not available at $BAO_ADDR"
  exit 1
fi

# Check if initialized
STATUS=$(curl -s "$BAO_ADDR/v1/sys/health" | jq -r '.initialized')
if [ "$STATUS" != "true" ]; then
  echo "Error: OpenBao not initialized"
  exit 1
fi

# Get token (from env or file)
if [ -n "$BAO_TOKEN" ]; then
  export BAO_TOKEN
elif [ -f /tmp/bao-init-token ]; then
  export BAO_TOKEN=$(cat /tmp/bao-init-token)
else
  echo "Error: BAO_TOKEN not set and no token file found"
  exit 1
fi

# Map YAML filename to KV path
get_kv_path() {
  local filename=$(basename "$1" .yaml)
  
  case "$filename" in
    argocd) echo "secret/argocd" ;;
    dockerhub) echo "secret/dockerhub" ;;
    infra) echo "secret/infra" ;;
    databases) echo "secret/databases" ;;
    apps) echo "secret/apps" ;;
    dev-tools) echo "secret/dev-tools" ;;
    monitoring) echo "secret/monitoring" ;;
    *) echo "secret/$filename" ;;
  esac
}

# Map key to field name
get_field_name() {
  local key=$1
  
  # Handle special cases
  case "$key" in
    cloudflare_api_token) echo "api_token" ;;
    cloudflared_token) echo "token" ;;
    postgresql_username) echo "username" ;;
    postgresql_password) echo "password" ;;
    redis_username) echo "username" ;;
    redis_password) echo "redis_password" ;;
    mongodb_username) echo "username" ;;
    mongodb_password) echo "password" ;;
    qdrant_api_key) echo "api_key" ;;
    dockerhub_password) echo "password" ;;
    *) echo "$key" ;;
  esac
}

# Map filename to subpath
get_subpath() {
  local filename=$(basename "$1" .yaml)
  
  case "$filename" in
    infra) echo "cloudflare,cloudflared" ;;
    databases) echo "postgresql-app,redis,mongodb-app,qdrant" ;;
    *) echo "$filename" ;;
  esac
}

echo "Processing secret files..."
echo ""

# Process each YAML file
for yaml_file in "$SECRETS_DIR"/*.yaml; do
  [ -f "$yaml_file" ] || continue
  
  filename=$(basename "$yaml_file" .yaml)
  echo "Processing: $filename.yaml"
  
  # Extract keys and values from stringData
  keys=$(grep "stringData:" -A 100 "$yaml_file" | grep -E "^\s+[a-zA-Z_]+:" | sed 's/:.*//' | tr -d ' ')
  
  for key in $keys; do
    # Get value (look for "DUMMY_" to skip or use actual value)
    value=$(grep "$key:" "$yaml_file" | head -1 | sed 's/.*: *//' | tr -d '"' | tr -d "'")
    
    # Skip if value contains DUMMY or is empty
    if [[ "$value" == DUMMY_* ]] || [ -z "$value" ]; then
      continue
    fi
    
    field=$(get_field_name "$key")
    
    # Determine KV path based on filename
    case "$filename" in
      argocd)
        kv_path="secret/argocd"
        ;;
      dockerhub)
        kv_path="secret/dockerhub"
        ;;
      infra)
        case "$key" in
          cloudflare*) kv_path="secret/infra/cloudflare" ;;
          cloudflared*) kv_path="secret/infra/cloudflared" ;;
        esac
        ;;
      databases)
        case "$key" in
          postgresql_*) kv_path="secret/databases/postgresql-app" ;;
          redis_*) kv_path="secret/databases/redis" ;;
          mongodb_*) kv_path="secret/databases/mongodb-app" ;;
          qdrant_*) kv_path="secret/databases/qdrant" ;;
        esac
        ;;
      *)
        kv_path="secret/$filename"
        ;;
    esac
    
    if [ -n "$kv_path" ]; then
      echo "  Writing: $kv_path -> $field"
      bao kv put "$kv_path" "$field=$value" >/dev/null 2>&1 || true
    fi
  done
done

echo ""
echo "=== Done ==="
echo "Secrets imported to OpenBao"