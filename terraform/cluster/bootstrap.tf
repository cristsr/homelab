resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.20.2"
  namespace  = "kube-system"

  values = [
    file("${path.module}/../../bootstrap/cilium/values.yaml")
  ]

  wait    = true
  timeout = 300

  depends_on = [
    kubernetes_namespace_v1.namespaces
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.10.0"
  namespace        = "argocd"
  create_namespace = true

  values = [
    file("${path.module}/../../bootstrap/argocd/values.yaml")
  ]

  wait = true
  # ArgoCD image pull on a residential connection can be slow, keeping the 900s timeout.
  timeout = 900

  depends_on = [
    helm_release.cilium,
    kubernetes_namespace_v1.namespaces
  ]
}
