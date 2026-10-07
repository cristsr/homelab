#!/bin/bash
# Turns a namespace's Deployments and StatefulSets off (replicas 0) and back on,
# remembering each one's replica count in the homelab/replicas annotation.
# PVCs and every other resource stay, so data survives.
#
# ArgoCD ignores spec.replicas (bootstrap/argocd/values.yaml), so selfHeal doesn't
# scale them back up.
#
# Usage: ./scripts/workload.sh <down|up|status> <namespace>
set -euo pipefail

ACTION="${1:?Usage: $0 <down|up|status> <namespace>}"
NS="${2:?Usage: $0 <down|up|status> <namespace>}"

kinds="deployment,statefulset"

case "$ACTION" in
  status)
    kubectl -n "$NS" get "$kinds"
    ;;
  down)
    kubectl -n "$NS" get "$kinds" -o name | while read -r obj; do
      replicas=$(kubectl -n "$NS" get "$obj" -o jsonpath='{.spec.replicas}')
      [ "$replicas" -gt 0 ] || continue
      kubectl -n "$NS" annotate "$obj" "homelab/replicas=$replicas" --overwrite
      kubectl -n "$NS" scale "$obj" --replicas=0
    done
    ;;
  up)
    kubectl -n "$NS" get "$kinds" -o name | while read -r obj; do
      current=$(kubectl -n "$NS" get "$obj" -o jsonpath='{.spec.replicas}')
      [ "$current" -eq 0 ] || continue
      saved=$(kubectl -n "$NS" get "$obj" -o jsonpath='{.metadata.annotations.homelab/replicas}' 2>/dev/null || true)
      kubectl -n "$NS" scale "$obj" --replicas="${saved:-1}"
      kubectl -n "$NS" annotate "$obj" homelab/replicas- >/dev/null
    done
    ;;
  *)
    echo "Usage: $0 <down|up|status> <namespace>" >&2
    exit 1
    ;;
esac
