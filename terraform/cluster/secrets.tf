data "kubernetes_config_map_v1" "kube_root_ca" {
  metadata {
    name      = "kube-root-ca.crt"
    namespace = "kube-system"
  }
}

resource "kubernetes_secret_v1" "github_repo_creds" {
  metadata {
    name      = "github-repo-creds"
    namespace = kubernetes_namespace_v1.namespaces["argocd"].metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  # El provider base64-codifica los valores de `data` automaticamente
  # (equivalente a `stringData` en un manifest crudo).
  data = {
    type     = "git"
    url      = "https://github.com/${var.argocd_github_username}"
    username = "git"
    password = var.argocd_github_pat
  }
}

resource "kubernetes_secret_v1" "argocd_in_cluster" {
  metadata {
    name      = "in-cluster-secret"
    namespace = kubernetes_namespace_v1.namespaces["argocd"].metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  type = "Opaque"

  data = {
    server = "https://kubernetes.default.svc"
    name   = "in-cluster"
    config = jsonencode({
      tlsClientConfig = {
        insecure = false
        caData   = base64encode(data.kubernetes_config_map_v1.kube_root_ca.data["ca.crt"])
      }
    })
  }
}

resource "kubernetes_secret_v1" "openbao_static_unseal_key" {
  metadata {
    name      = "openbao-static-unseal-key"
    namespace = kubernetes_namespace_v1.namespaces["secret-management"].metadata[0].name
  }

  data = {
    key = var.openbao_static_seal_key
  }
}
