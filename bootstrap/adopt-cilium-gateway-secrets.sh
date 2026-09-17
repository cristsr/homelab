#!/bin/bash
# Runs before every Cilium Helm upgrade. With Gateway API enabled, the
# agent/operator reconcile some of the same resources the chart templates
# (GatewayClass status, TLS-secret-sync Role/RoleBinding) and strip their
# Helm ownership annotations, so the next `helm upgrade` aborts with
# "cannot be imported into the current release". Re-adopting them here
# keeps every upgrade idempotent. No `set -e`: on the very first bootstrap
# these resources don't exist yet, and that must not abort the script.

RELEASE_ANNOTATIONS=(
  meta.helm.sh/release-name=cilium
  meta.helm.sh/release-namespace=kube-system
)

adopt() {
  local kind="$1" name="$2" ns_flag=()
  [ -n "${3:-}" ] && ns_flag=(-n "$3")

  kubectl "${ns_flag[@]}" annotate "$kind" "$name" \
    "${RELEASE_ANNOTATIONS[@]}" --overwrite >/dev/null 2>&1
  kubectl "${ns_flag[@]}" label "$kind" "$name" \
    app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1
}

# Namespaced: TLS-secret-sync RBAC (agent + operator)
adopt role cilium-gateway-secrets cilium-secrets
adopt rolebinding cilium-gateway-secrets cilium-secrets
adopt role cilium-operator-gateway-secrets cilium-secrets
adopt rolebinding cilium-operator-gateway-secrets cilium-secrets

# Cluster-scoped
adopt gatewayclass cilium
adopt validatingadmissionpolicy gateway.cilium.io
adopt validatingadmissionpolicybinding gateway.cilium.io

exit 0
