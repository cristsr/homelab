#!/bin/bash
# Presync hook de `helmfile sync` (bootstrap/helmfile.yaml, release cilium).
#
# Con gatewayAPI.enabled=true (bootstrap/cilium/values.yaml), el operator de
# Cilium reconcilia por su cuenta el Role `cilium-gateway-secrets`
# (namespace `cilium-secrets`) que le da permiso para sincronizar ahi los
# Secrets TLS referenciados por certificateRefs de cualquier Gateway - lo
# hace desde que existe al menos un listener HTTPS real (ver
# docs/DECISIONS.md ADR-012, wildcard-internal-tls en el Gateway `main`).
# Cada reconciliacion del operator reemplaza el objeto entero por fuera de
# Helm y le borra las anotaciones de ownership - el siguiente
# `helm upgrade` (via helmfile sync) lo ve como un recurso ajeno y aborta
# con "cannot be imported into the current release".
#
# Reponer las anotaciones/labels de Helm antes de cada sync es idempotente:
# si el operator no lo toco desde la ultima vez, no cambia nada; si ya lo
# reconcilio, deja a Helm actualizarlo en paz. Sin `set -e` a proposito -
# en el primerisimo bootstrap (namespace/Role todavia no existen) estos
# comandos fallan con "not found" y no debe abortar el resto del sync.

kubectl -n cilium-secrets annotate role cilium-gateway-secrets \
  meta.helm.sh/release-name=cilium \
  meta.helm.sh/release-namespace=kube-system \
  --overwrite >/dev/null 2>&1

kubectl -n cilium-secrets label role cilium-gateway-secrets \
  app.kubernetes.io/managed-by=Helm \
  --overwrite >/dev/null 2>&1

exit 0
