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
SQ_DB_USER="$(get SONARQUBE_DB_USERNAME)"
SQ_DB_PASS="$(get SONARQUBE_DB_PASSWORD)"
MYSQL_PASS="$(get MYSQL_APP_PASSWORD)"
KIMAI_DB_USER="$(get KIMAI_DB_USERNAME)"
KIMAI_DB_PASS="$(get KIMAI_DB_PASSWORD)"
FIREFLY_DB_USER="$(get FIREFLY_DB_USERNAME)"
FIREFLY_DB_PASS="$(get FIREFLY_DB_PASSWORD)"
N8N_DB_USER="$(get N8N_DB_USERNAME)"
N8N_DB_PASS="$(get N8N_DB_PASSWORD)"
HINDSIGHT_DB_USER="$(get HINDSIGHT_DB_USERNAME)"
HINDSIGHT_DB_PASS="$(get HINDSIGHT_DB_PASSWORD)"
KANEO_DB_USER="$(get KANEO_DB_USERNAME)"
KANEO_DB_PASS="$(get KANEO_DB_PASSWORD)"

if [ -n "$PG_USER$PG_PASS$MONGO_PASS$REDIS_PASS$SQ_DB_USER$SQ_DB_PASS$MYSQL_PASS$KIMAI_DB_USER$KIMAI_DB_PASS$FIREFLY_DB_USER$FIREFLY_DB_PASS$N8N_DB_USER$N8N_DB_PASS$HINDSIGHT_DB_USER$HINDSIGHT_DB_PASS$KANEO_DB_USER$KANEO_DB_PASS" ]; then
  cat > ansible/data-services.env <<EOF
POSTGRESQL_APP_USERNAME=$PG_USER
POSTGRESQL_APP_PASSWORD=$PG_PASS
MONGODB_APP_PASSWORD=$MONGO_PASS
REDIS_PASSWORD=$REDIS_PASS
SONARQUBE_DB_USERNAME=$SQ_DB_USER
SONARQUBE_DB_PASSWORD=$SQ_DB_PASS
MYSQL_APP_PASSWORD=$MYSQL_PASS
KIMAI_DB_USERNAME=$KIMAI_DB_USER
KIMAI_DB_PASSWORD=$KIMAI_DB_PASS
FIREFLY_DB_USERNAME=$FIREFLY_DB_USER
FIREFLY_DB_PASSWORD=$FIREFLY_DB_PASS
N8N_DB_USERNAME=$N8N_DB_USER
N8N_DB_PASSWORD=$N8N_DB_PASS
HINDSIGHT_DB_USERNAME=$HINDSIGHT_DB_USER
HINDSIGHT_DB_PASSWORD=$HINDSIGHT_DB_PASS
KANEO_DB_USERNAME=$KANEO_DB_USER
KANEO_DB_PASSWORD=$KANEO_DB_PASS
EOF
  sops encrypt -i ansible/data-services.env
  echo "set   ansible/data-services.env (17 keys)"
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

# --- workloads/hindsight/secrets.sops.yaml ---
# The connection URL is rebuilt from the same answers-file values Ansible
# provisions the PostgreSQL role with, so both sides always agree. The host is
# the postgres domain, so a move of the LXC changes DNS only.
if [ -n "$HINDSIGHT_DB_USER" ] && [ -n "$HINDSIGHT_DB_PASS" ]; then
  set_field workloads/hindsight/secrets.sops.yaml \
    '["spec"]["secretTemplates"][0]["stringData"]["HINDSIGHT_API_DATABASE_URL"]' \
    "postgresql://${HINDSIGHT_DB_USER}:${HINDSIGHT_DB_PASS}@postgres.internal.cristianpuenguenan.online:5432/hindsight"
else
  echo "skip  workloads/hindsight/secrets.sops.yaml HINDSIGHT_API_DATABASE_URL (HINDSIGHT_DB_USERNAME/HINDSIGHT_DB_PASSWORD empty)"
fi
set_field workloads/hindsight/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["HINDSIGHT_API_LLM_API_KEY"]' "$(get HINDSIGHT_OPENROUTER_API_KEY)"
set_field workloads/hindsight/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["HINDSIGHT_API_TENANT_API_KEY"]' "$(get HINDSIGHT_API_KEY)"
set_field workloads/hindsight/secrets.sops.yaml \
  '["spec"]["secretTemplates"][1]["stringData"]["HINDSIGHT_CP_ACCESS_KEY"]' "$(get HINDSIGHT_CP_ACCESS_KEY)"

# --- workloads/kaneo/secrets.sops.yaml ---
set_field workloads/kaneo/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-username"]' "$KANEO_DB_USER"
set_field workloads/kaneo/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-password"]' "$KANEO_DB_PASS"
set_field workloads/kaneo/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["auth-secret"]' "$(get KANEO_AUTH_SECRET)"

# --- workloads/media/secrets.sops.yaml (Lingarr) ---
set_field workloads/media/secrets.sops.yaml \
  '["spec"]["secretTemplates"][1]["stringData"]["SONARR_API_KEY"]' "$(get LINGARR_SONARR_API_KEY)"
set_field workloads/media/secrets.sops.yaml \
  '["spec"]["secretTemplates"][1]["stringData"]["RADARR_API_KEY"]' "$(get LINGARR_RADARR_API_KEY)"
set_field workloads/media/secrets.sops.yaml \
  '["spec"]["secretTemplates"][1]["stringData"]["DEEPSEEK_API_KEY"]' "$(get LINGARR_DEEPSEEK_API_KEY)"

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

# --- workloads/finances/secrets.sops.yaml (Kimai) ---
# Kimai takes one connection URL instead of separate user/password keys, so the
# URL is rebuilt here from the same answers-file values Ansible provisions the
# MySQL user with. The host is the mysql domain, so a move of the LXC changes DNS only.
if [ -n "$KIMAI_DB_USER" ] && [ -n "$KIMAI_DB_PASS" ]; then
  set_field workloads/finances/secrets.sops.yaml \
    '["spec"]["secretTemplates"][0]["stringData"]["database-url"]' \
    "mysql://${KIMAI_DB_USER}:${KIMAI_DB_PASS}@mysql.internal.cristianpuenguenan.online:3306/kimai?charset=utf8mb4"
else
  echo "skip  workloads/finances/secrets.sops.yaml database-url (KIMAI_DB_USERNAME/KIMAI_DB_PASSWORD empty)"
fi

# --- workloads/finances/firefly-secrets.sops.yaml ---
set_field workloads/finances/firefly-secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["app-key"]' "$(get FIREFLY_APP_KEY)"
set_field workloads/finances/firefly-secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-username"]' "$FIREFLY_DB_USER"
set_field workloads/finances/firefly-secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-password"]' "$FIREFLY_DB_PASS"

# --- workloads/flow/secrets.sops.yaml (n8n) ---
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["encryption-key"]' "$(get N8N_ENCRYPTION_KEY)"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-username"]' "$N8N_DB_USER"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["db-password"]' "$N8N_DB_PASS"

echo
echo "Done. Review 'git diff --stat' and commit the files that changed."
echo "IMPORTANT: postgresql and mongodb only apply POSTGRES_PASSWORD/MONGO_INITDB_ROOT_PASSWORD"
echo "the first time they start on an empty volume. If they already ran before with a"
echo "different value, changing the secret does NOT change their real password - it has to be"
echo "done by hand (ALTER USER/ALTER ROLE) or by deleting /srv/postgresql and /srv/mongodb on the LXC to reinitialize."
