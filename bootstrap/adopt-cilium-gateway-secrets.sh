#!/bin/bash
# Presync hook de `helmfile sync` (bootstrap/helmfile.yaml, release cilium).
#
# Con gatewayAPI.enabled=true (bootstrap/cilium/values.yaml), el chart de
# Cilium templa 4 recursos RBAC en el namespace `cilium-secrets` para que
# el agent y el operator puedan sincronizar ahi los Secrets TLS
# referenciados por certificateRefs de cualquier Gateway (ver
# docs/DECISIONS.md ADR-012, wildcard-internal-tls en el Gateway `main`):
# `templates/cilium-agent/{role,rolebinding}.yaml` (Role/RoleBinding
# `cilium-gateway-secrets`) y `templates/cilium-operator/{role,rolebinding}.yaml`
# (Role/RoleBinding `cilium-operator-gateway-secrets`). El agent y el
# operator (cada uno corriendo ya, reconciliando por su cuenta) terminan
# re-escribiendo estos objetos por fuera de Helm y les borran las
# anotaciones de ownership - confirmado en la practica: se fueron rompiendo
# de a uno por corrida de CI (primero el Role del agent, despues el del
# operator). El siguiente `helm upgrade` (via helmfile sync, en cada
# deploy) ve un recurso ajeno y aborta con
# "cannot be imported into the current release".
#
# Reponer las anotaciones/labels de Helm antes de cada sync es idempotente:
# si nadie lo toco desde la ultima vez, no cambia nada; si ya lo
# reconciliaron, deja a Helm actualizarlo en paz. Sin `set -e` a proposito
# - en el primerisimo bootstrap (namespace/recursos todavia no existen)
# estos comandos fallan con "not found" y no debe abortar el resto del
# sync.

NS=cilium-secrets

adopt() {
  local kind="$1" name="$2"
  kubectl -n "$NS" annotate "$kind" "$name" \
    meta.helm.sh/release-name=cilium \
    meta.helm.sh/release-namespace=kube-system \
    --overwrite >/dev/null 2>&1
  kubectl -n "$NS" label "$kind" "$name" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite >/dev/null 2>&1
}

adopt role cilium-gateway-secrets
adopt rolebinding cilium-gateway-secrets
adopt role cilium-operator-gateway-secrets
adopt rolebinding cilium-operator-gateway-secrets

exit 0
