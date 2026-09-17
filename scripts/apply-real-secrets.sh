#!/bin/bash
# Loads real values into the repo's SopsSecret/.env files from a KEY=value
# answers file. A missing or empty KEY is skipped, leaving the existing
# encrypted value untouched.
#
# Usage: ./scripts/apply-real-secrets.sh <answers-file>
set -euo pipefail

ANSWERS="${1:?Usage: $0 <answers-file>}"
[ -f "$ANSWERS" ] || { echo "Not found: $ANSWERS" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

get() {
  grep -E "^$1=" "$ANSWERS" | tail -1 | cut -d= -f2-
}

set_field() {
  local file="$1" path="$2" value="$3"
  if [ -z "$value" ]; then
    echo "skip  $file $path (empty)"
    return
  fi
  sops set "$file" "$path" "$(printf '%s' "$value" | jq -Rs .)"
  echo "set   $file $path"
}

# --- ansible/data-services.env (dotenv, fully re-encrypted) ---
PG_USER="$(get POSTGRESQL_APP_USERNAME)"
PG_PASS="$(get POSTGRESQL_APP_PASSWORD)"
MONGO_PASS="$(get MONGODB_APP_PASSWORD)"
REDIS_PASS="$(get REDIS_PASSWORD)"
QDRANT_KEY="$(get QDRANT_API_KEY)"
SQ_DB_USER="$(get SONARQUBE_DB_USERNAME)"
SQ_DB_PASS="$(get SONARQUBE_DB_PASSWORD)"

if [ -n "$PG_USER$PG_PASS$MONGO_PASS$REDIS_PASS$QDRANT_KEY$SQ_DB_USER$SQ_DB_PASS" ]; then
  cat > ansible/data-services.env <<EOF
POSTGRESQL_APP_USERNAME=$PG_USER
POSTGRESQL_APP_PASSWORD=$PG_PASS
MONGODB_APP_PASSWORD=$MONGO_PASS
REDIS_PASSWORD=$REDIS_PASS
QDRANT_API_KEY=$QDRANT_KEY
SONARQUBE_DB_USERNAME=$SQ_DB_USER
SONARQUBE_DB_PASSWORD=$SQ_DB_PASS
EOF
  sops encrypt -i ansible/data-services.env
  echo "set   ansible/data-services.env (7 keys)"
else
  echo "skip  ansible/data-services.env (nothing to load)"
fi

# --- workloads/sonarqube/secrets.sops.yaml ---
set_field workloads/sonarqube/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["username"]' "$SQ_DB_USER"
set_field workloads/sonarqube/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["password"]' "$SQ_DB_PASS"
set_field workloads/sonarqube/secrets.sops.yaml \
  '["spec"]["secretTemplates"][1]["stringData"]["passcode"]' "$(get SONARQUBE_MONITORING_PASSCODE)"

# --- platform/devtools/openmemory/secrets.sops.yaml ---
set_field platform/devtools/openmemory/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["OPENAI_API_KEY"]' "$(get OPENMEMORY_OPENAI_API_KEY)"
set_field platform/devtools/openmemory/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["QDRANT_API_KEY"]' "$QDRANT_KEY"

GHCR_USER="$(get GHCR_USERNAME)"
GHCR_PAT="$(get GHCR_PAT)"
if [ -n "$GHCR_USER" ] && [ -n "$GHCR_PAT" ]; then
  DOCKERCFG=$(jq -n --arg auth "$(printf '%s:%s' "$GHCR_USER" "$GHCR_PAT" | base64 -w0)" \
    '{auths:{"ghcr.io":{auth:$auth}}}')
  set_field platform/devtools/openmemory/secrets.sops.yaml \
    '["spec"]["secretTemplates"][1]["stringData"][".dockerconfigjson"]' "$DOCKERCFG"
else
  echo "skip  platform/devtools/openmemory/secrets.sops.yaml ghcr-pull-secret (GHCR_USERNAME/GHCR_PAT empty)"
fi

# --- platform/networking/cloudflared/token.sops.yaml ---
set_field platform/networking/cloudflared/token.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["token"]' "$(get CLOUDFLARED_TUNNEL_TOKEN)"

# --- platform/networking/cert-manager/cloudflare-api-token.sops.yaml ---
set_field platform/networking/cert-manager/cloudflare-api-token.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["api-token"]' "$(get CLOUDFLARE_API_TOKEN)"

# --- platform/observability/secrets/grafana-admin.sops.yaml ---
set_field platform/observability/secrets/grafana-admin.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["GF_SECURITY_ADMIN_USER"]' "$(get GRAFANA_ADMIN_USERNAME)"
set_field platform/observability/secrets/grafana-admin.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["GF_SECURITY_ADMIN_PASSWORD"]' "$(get GRAFANA_ADMIN_PASSWORD)"

# platform/argocd/repo-credentials.sops.yaml was removed: it broke ArgoCD's
# sync by overriding github-repo-creds with placeholders. Do not recreate it -
# a second repo-creds secret belongs in Terraform, not SOPS.

# --- workloads/flow/secrets.sops.yaml (optional, `flow` is currently an unused stub) ---
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["database-url"]' "$(get FLOW_DATABASE_URL)"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["mongodb-url"]' "$(get FLOW_MONGODB_URL)"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["redis-url"]' "$(get FLOW_REDIS_URL)"

echo
echo "Done. Review 'git diff --stat' and commit the files that changed."
echo "IMPORTANT: postgresql and mongodb only apply POSTGRES_PASSWORD/MONGO_INITDB_ROOT_PASSWORD"
echo "the first time they start on an empty volume. If they already ran before with a"
echo "different value, changing the secret does NOT change their real password - it has to be"
echo "done by hand (ALTER USER/ALTER ROLE) or by deleting /srv/postgresql and /srv/mongodb on the LXC to reinitialize."
