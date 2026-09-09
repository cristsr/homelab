resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace_v1" "secret_management" {
  metadata {
    name = "secret-management"
  }
}
