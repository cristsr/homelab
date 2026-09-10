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
