locals {
  namespaces = toset([
    "argocd",
    "apps",
    "data-platform",
    "devtools",
    "openebs",
    "networking",
    "observability",
    "secret-management"
  ])
}

resource "kubernetes_namespace_v1" "namespaces" {
  for_each = local.namespaces

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/part-of" = "homelab"
    }
  }
}

# Los 8 namespaces ya existen en el cluster real (creados fuera de Terraform
# por el bootstrap anterior via Ansible/helmfile) pero el state remoto nunca
# los trackeo bajo esta direccion for_each - la reconciliacion declarativa
# evita el "namespaces X already exists" sin necesitar acceso interactivo al
# cluster desde fuera de CI. Una vez que el proximo apply los importe, este
# bloque queda como no-op y se puede borrar en una limpieza futura.
import {
  for_each = local.namespaces
  to       = kubernetes_namespace_v1.namespaces[each.key]
  id       = each.key
}
