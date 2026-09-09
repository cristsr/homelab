variable "kubeconfig_path" {
  description = "Path al kubeconfig generado por terraform/infra"
  type        = string
}

variable "argocd_github_username" {
  description = "Usuario de GitHub del repo que sincroniza ArgoCD"
  type        = string
  default     = "cristsr"
}

variable "argocd_github_pat" {
  description = "Personal Access Token de GitHub con acceso al repo de ArgoCD"
  type        = string
  sensitive   = true
}

variable "openbao_static_seal_key" {
  description = "Clave de sellado estatico de OpenBao"
  type        = string
  sensitive   = true
}
