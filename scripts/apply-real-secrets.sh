#!/bin/bash
# Carga valores reales en los SopsSecret/`.env` del repo a partir de un
# archivo de respuestas plano (KEY=value, mismo formato/campos que
# secrets/homelab.env.example - copialo a secrets/homelab.env, completa los
# valores, y pasalo como argumento). Usa `sops set` para parchear un campo
# cifrado a la vez
# sin tocar el resto del archivo, y re-encripta ansible/data-services.env
# completo (es dotenv, no tiene estructura anidada que parchear campo por
# campo). Cualquier KEY ausente o vacia en el archivo de respuestas se
# omite - el valor cifrado existente queda intacto.
#
# Uso: ./scripts/apply-real-secrets.sh <archivo-de-respuestas>
set -euo pipefail

ANSWERS="${1:?Uso: $0 <archivo-de-respuestas>}"
[ -f "$ANSWERS" ] || { echo "No existe: $ANSWERS" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"

get() {
  # Ultima ocurrencia de KEY= en el archivo, todo lo que sigue hasta fin de
  # linea (permite '=' dentro del valor, p.ej. tokens base64).
  grep -E "^$1=" "$ANSWERS" | tail -1 | cut -d= -f2-
}

set_field() {
  local file="$1" path="$2" value="$3"
  if [ -z "$value" ]; then
    echo "skip  $file $path (vacio)"
    return
  fi
  sops set "$file" "$path" "$(printf '%s' "$value" | jq -Rs .)"
  echo "set   $file $path"
}

# --- ansible/data-services.env (dotenv, se re-encripta completo) ---
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
  echo "skip  ansible/data-services.env (nada para cargar)"
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
  echo "skip  platform/devtools/openmemory/secrets.sops.yaml ghcr-pull-secret (GHCR_USERNAME/GHCR_PAT vacios)"
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

# platform/argocd/repo-credentials.sops.yaml se elimino (ver docs/DECISIONS.md
# ADR-020-bis/commit d85afd3): duplicaba github-repo-creds
# (terraform/cluster/secrets.tf, ya con el PAT real) con un `repository`-typed
# secret que, si su `url` llega a coincidir exacto con el repo real mientras
# username/password quedan en un placeholder viejo, ArgoCD lo prefiere sobre
# el que si funciona y rompe TODO el sync del cluster. No recrear este
# archivo - si hace falta un segundo repo-creds, usar Terraform, no SOPS.

# --- workloads/flow/secrets.sops.yaml (opcional, `flow` hoy es un stub sin uso real) ---
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["database-url"]' "$(get FLOW_DATABASE_URL)"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["mongodb-url"]' "$(get FLOW_MONGODB_URL)"
set_field workloads/flow/secrets.sops.yaml \
  '["spec"]["secretTemplates"][0]["stringData"]["redis-url"]' "$(get FLOW_REDIS_URL)"

echo
echo "Listo. Revisa 'git diff --stat' y commitea los archivos que cambiaron."
echo "IMPORTANTE: postgresql y mongodb solo aplican POSTGRES_PASSWORD/MONGO_INITDB_ROOT_PASSWORD"
echo "la primera vez que arrancan sobre un volumen vacio. Si ya corrieron antes con un valor"
echo "distinto, cambiar el secret NO les cambia la password real - hay que hacerlo a mano"
echo "(ALTER USER/ALTER ROLE) o borrar /srv/postgresql y /srv/mongodb en la LXC para reinicializar."
