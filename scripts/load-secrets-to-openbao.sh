#!/bin/bash
# Carga secrets/homelab.env en OpenBao KV. Reemplaza a los antiguos
# ansible/vault-populate.yaml + ansible/load-extra-secrets.yaml: esto es
# ahora un paso 100% manual, ya no corre en CI (ver .github/workflows/deploy.yml
# y docs/DECISIONS.md - se saco a proposito para que la carga de secretos
# reales nunca dependa de un runner de CI).
#
# Requiere: kubectl (apuntando al kubeconfig del cluster), curl, jq.
#
# Uso:
#   cp secrets/homelab.env.example secrets/homelab.env
#   $EDITOR secrets/homelab.env
#   KUBECONFIG=terraform/infra/generated/kubeconfig ./scripts/load-secrets-to-openbao.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/secrets/homelab.env"
NS="secret-management"
BAO_URL="http://127.0.0.1:8200"
PF_PID=""

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/terraform/infra/generated/kubeconfig}"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: no existe $ENV_FILE" >&2
  echo "Copia el ejemplo y completa los valores: cp secrets/homelab.env.example secrets/homelab.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "=== Validando campos obligatorios de infra ==="
for var in ARGOCD_GITHUB_PAT ARGOCD_REPO_URL ARGOCD_WEBHOOK_SECRET CLOUDFLARE_API_TOKEN CLOUDFLARED_TOKEN; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var esta vacia en $ENV_FILE" >&2
    exit 1
  fi
done

cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Esperando endpoint del Service openbao ==="
for i in $(seq 1 60); do
  eps=$(kubectl get endpoints openbao -n "$NS" -o jsonpath='{.subsets[*].addresses}' 2>/dev/null || true)
  [ -n "$eps" ] && break
  sleep 10
done
[ -n "${eps:-}" ] || { echo "ERROR: el Service openbao nunca tuvo endpoints listos" >&2; exit 1; }

echo "=== Esperando el Job openbao-init ==="
for i in $(seq 1 30); do
  kubectl get job openbao-init -n "$NS" >/dev/null 2>&1 && break
  sleep 10
done
kubectl wait --for=condition=complete job/openbao-init -n "$NS" --timeout=300s

echo "=== Leyendo root token ==="
BAO_TOKEN=$(kubectl get secret openbao-root-token -n "$NS" -o jsonpath='{.data.token}' | base64 -d)
[ -n "$BAO_TOKEN" ] || { echo "ERROR: root token vacio" >&2; exit 1; }

echo "=== Iniciando port-forward hacia openbao ==="
kubectl port-forward svc/openbao 8200:8200 -n "$NS" >/tmp/openbao-pf.log 2>&1 &
PF_PID=$!

for i in $(seq 1 15); do
  curl -sf -o /dev/null "$BAO_URL/v1/sys/health" && break
  sleep 1
done
curl -sf -o /dev/null "$BAO_URL/v1/sys/health" || { echo "ERROR: openbao no respondio en $BAO_URL" >&2; exit 1; }

write_secret() {
  local path="$1"
  shift
  # Recibe pares clave=valor; ignora los que vengan vacios (app no usada).
  local body="{}"
  for kv in "$@"; do
    local key="${kv%%=*}"
    local value="${kv#*=}"
    [ -n "$value" ] || continue
    body=$(echo "$body" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
  done
  if [ "$body" = "{}" ]; then
    echo "  - $path: sin valores, se omite"
    return
  fi
  curl -sf -X POST \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -d "$(jq -n --argjson data "$body" '{data: $data}')" \
    "$BAO_URL/v1/secret/data/$path" >/dev/null
  echo "  - $path: ok"
}

echo "=== Escribiendo secretos en OpenBao KV ==="
write_secret "argocd" \
  "github_pat=$ARGOCD_GITHUB_PAT" \
  "username=x-access-token" \
  "url=$ARGOCD_REPO_URL" \
  "webhook_secret=$ARGOCD_WEBHOOK_SECRET"
write_secret "infra/cloudflare" "api_token=$CLOUDFLARE_API_TOKEN"
write_secret "infra/cloudflared" "token=$CLOUDFLARED_TOKEN"
write_secret "databases/redis" "redis-password=${REDIS_PASSWORD:-}"
write_secret "databases/qdrant" "api_key=${QDRANT_API_KEY:-}"
write_secret "databases/postgresql-app" \
  "username=${POSTGRESQL_APP_USERNAME:-}" \
  "password=${POSTGRESQL_APP_PASSWORD:-}"
write_secret "databases/mongodb-app" "password=${MONGODB_APP_PASSWORD:-}"
write_secret "monitoring/grafana" \
  "username=${GRAFANA_ADMIN_USERNAME:-admin}" \
  "password=${GRAFANA_ADMIN_PASSWORD:-}"
write_secret "sonarqube/db-credentials" \
  "username=${SONARQUBE_DB_USERNAME:-sonarqube}" \
  "password=${SONARQUBE_DB_PASSWORD:-}"
write_secret "sonarqube/monitoring" "passcode=${SONARQUBE_MONITORING_PASSCODE:-}"
write_secret "devtools/openmemory" "OPENAI_API_KEY=${OPENMEMORY_OPENAI_API_KEY:-}"
write_secret "apps/flow" \
  "database-url=${FLOW_DATABASE_URL:-}" \
  "mongodb-url=${FLOW_MONGODB_URL:-}" \
  "redis-url=${FLOW_REDIS_URL:-}"

if kubectl get deployment cloudflared -n networking >/dev/null 2>&1; then
  echo "=== Esperando que el ExternalSecret sincronice el token nuevo de cloudflared ==="
  for i in $(seq 1 20); do
    synced=$(kubectl get secret cloudflared-token -n networking -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ "$synced" = "$CLOUDFLARED_TOKEN" ] && break
    sleep 5
  done
  echo "=== Reiniciando cloudflared para tomar el token nuevo ==="
  kubectl rollout restart deployment/cloudflared -n networking
fi

echo "=== Listo ==="
