# Este null_resource ejecuta el script de adopcion de secretos de Cilium
# de manera local antes de cada upgrade/sync del chart, garantizando la idempotencia
# del Helm release cuando Cilium ha modificado anotaciones del GatewayClass y RoleBindings.
resource "null_resource" "adopt_cilium_gateway_secrets" {
  triggers = {
    # El trigger siempre cambia para que se ejecute en cada apply (simulando un hook presync).
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../../bootstrap/adopt-cilium-gateway-secrets.sh"
    environment = {
      KUBECONFIG = var.kubeconfig_path
    }
  }

  depends_on = [
    kubernetes_namespace_v1.namespaces
  ]
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.20.1"
  namespace  = "kube-system"

  values = [
    file("${path.module}/../../bootstrap/cilium/values.yaml")
  ]

  wait    = true
  timeout = 300

  depends_on = [
    null_resource.adopt_cilium_gateway_secrets
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.5.13"
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
