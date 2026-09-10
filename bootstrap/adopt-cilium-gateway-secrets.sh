#!/bin/bash
# Invocado por null_resource.adopt_cilium_gateway_secrets
# (terraform/cluster/bootstrap.tf) antes de cada apply/upgrade del
# helm_release "cilium".
#
# Con gatewayAPI.enabled=true (bootstrap/cilium/values.yaml), varios de los
# recursos que el chart de Cilium templa para Gateway API terminan siendo
# reconciliados en vivo por el agent y el operator (que ya estan corriendo)
# - por ejemplo el GatewayClass necesita su `status.conditions: Accepted`
# actualizado, y las Role/RoleBinding de sync de Secrets TLS se re-crean
# cuando cambia algun certificateRef (ver docs/DECISIONS.md ADR-012,
# wildcard-internal-tls en el Gateway `main`). Esa reconciliacion pisa el
# objeto entero por fuera de Helm y le borra las anotaciones de ownership -
# confirmado en la practica, se fueron rompiendo de a uno por corrida de CI
# (Role del agent, despues el del operator, despues el GatewayClass). El
# siguiente `helm upgrade` (via terraform apply, en cada deploy) ve un
# recurso ajeno y aborta con "cannot be imported into the current release".
#
# Recursos identificados leyendo el chart cilium/cilium 1.20.1 real
# (templates/cilium-agent/, cilium-operator/, cilium-gateway-api-*.yaml)
# que dependen de gatewayAPI.enabled - se reponen todos antes de cada sync,
# no solo el que fallo la ultima vez. Idempotente: si nadie lo toco desde
# la ultima vez no cambia nada; sin `set -e` a proposito, en el
# primerisimo bootstrap (recursos todavia no existen) los comandos fallan
# con "not found" y no debe abortar el resto del sync.

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

# Namespaced: sync de Secrets TLS (agent + operator), namespace cilium-secrets
adopt role cilium-gateway-secrets cilium-secrets
adopt rolebinding cilium-gateway-secrets cilium-secrets
adopt role cilium-operator-gateway-secrets cilium-secrets
adopt rolebinding cilium-operator-gateway-secrets cilium-secrets

# Cluster-scoped
adopt gatewayclass cilium
adopt validatingadmissionpolicy gateway.cilium.io
adopt validatingadmissionpolicybinding gateway.cilium.io

exit 0
