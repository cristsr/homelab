#!/bin/bash
# Migrates every secret under secret/ from the in-cluster OpenBao instance to
# the external one on the secrets LXC. Standalone, run manually - never in CI
# (same convention as load-secrets-to-openbao.sh, see docs/DECISIONS.md ADR-015).
#
# Walks the source KV tree instead of a fixed list of paths, so anything
# written by hand later (e.g. via the manual `bao kv put` in docs/OPERATIONS.md)
# gets migrated too.
#
# Requires: bao, kubectl (pointed at the source cluster's kubeconfig), jq.
#
# Usage:
#   export BAO_SRC_ADDR=http://127.0.0.1:8200   # reached via the port-forward below
#   export BAO_SRC_TOKEN=<root or read-capable token for the in-cluster instance>
#   export BAO_DST_ADDR=http://192.168.80.35:8200
#   export BAO_DST_TOKEN=<root or write-capable token for the external instance>
#   ./scripts/migrate-openbao-secrets.sh

set -euo pipefail

NS="secret-management"
KV_ROOT="secret/"
PF_PID=""
TMP_FILE=""

for bin in bao kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing binary '$bin' in PATH" >&2; exit 1; }
done

echo "=== Validating connection variables ==="
for var in BAO_SRC_ADDR BAO_SRC_TOKEN BAO_DST_ADDR BAO_DST_TOKEN; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not set" >&2
    exit 1
  fi
done

cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
  fi
  [ -n "$TMP_FILE" ] && rm -f "$TMP_FILE"
}
trap cleanup EXIT

TMP_FILE="$(mktemp)"

echo "=== Starting port-forward to the in-cluster OpenBao ==="
kubectl port-forward svc/openbao 8200:8200 -n "$NS" >/tmp/migrate-openbao-pf.log 2>&1 &
PF_PID=$!

for i in $(seq 1 15); do
  BAO_ADDR="$BAO_SRC_ADDR" BAO_TOKEN="$BAO_SRC_TOKEN" bao status >/dev/null 2>&1 && break
  sleep 1
done
BAO_ADDR="$BAO_SRC_ADDR" BAO_TOKEN="$BAO_SRC_TOKEN" bao status >/dev/null 2>&1 || {
  echo "ERROR: could not reach $BAO_SRC_ADDR" >&2
  exit 1
}

MIGRATED_COUNT=0

# Never writes against the source: only `kv list` and `kv get`.
migrate_leaf() {
  local path="$1"

  BAO_ADDR="$BAO_SRC_ADDR" BAO_TOKEN="$BAO_SRC_TOKEN" \
    bao kv get -format=json "$path" | jq -c '.data.data' > "$TMP_FILE"

  BAO_ADDR="$BAO_DST_ADDR" BAO_TOKEN="$BAO_DST_TOKEN" \
    bao kv put "$path" "@$TMP_FILE" >/dev/null

  echo "  - $path: migrated"
  MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
}

walk() {
  local path="$1"
  local entries
  entries=$(BAO_ADDR="$BAO_SRC_ADDR" BAO_TOKEN="$BAO_SRC_TOKEN" bao kv list -format=json "$path" 2>/dev/null || echo '[]')

  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    local child="${path}${entry}"
    if [[ "$entry" == */ ]]; then
      walk "$child"
    else
      migrate_leaf "$child"
    fi
  done < <(jq -r '.[]' <<<"$entries")
}

echo "=== Migrating the secrets tree from $BAO_SRC_ADDR to $BAO_DST_ADDR ==="
walk "$KV_ROOT"

echo "$MIGRATED_COUNT paths migrated"
