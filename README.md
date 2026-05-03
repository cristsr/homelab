# Homelab Kubernetes

Homelab de un solo nodo impulsado por k0s con GitOps completo vía ArgoCD.

## Stack

| Capa | Tecnología |
|------|-----------|
| Kubernetes | k0s 1.31.x |
| CNI | Cilium 1.18 (eBPF,kube-proxy replacement) |
| Ingress | Agent Gateway 1.1.0 (hostPort 80/443) |
| GitOps | Argo CD 7.x |
| TLS | cert-manager + Let's Encrypt + Cloudflare DNS-01 |
| Storage | Longhorn 1.7.x |
| Database | CloudNativePG (PostgreSQL), Percona MongoDB, Redis, Qdrant |
| Secrets | OpenBao + External Secrets Operator |
| Monitoring | kube-prometheus-stack + Grafana + Headlamp |

## Acceso

- **LAN**: `https://<servicio>.cristianpuenguenan.online`
- **Internet**: via Cloudflare Tunnel (cloudflared)

## Estructura

```
homelab/
├── bootstrap/      # Cilium, ArgoCD, namespaces
├── gitops/apps/   # ArgoCD Applications
├── platform/     # Helm values y manifiestos
```

## Quick Start

```bash
# 1. namespaces
kubectl apply -f bootstrap/namespaces.yaml

# 2. Cilium
helm upgrade --install cilium cilium/cilium -n kube-system -f bootstrap/cilium/values.yaml

# 3. ArgoCD
helm upgrade --install argocd argo/argo-cd -n argocd -f bootstrap/argocd/values.yaml

# 4. GitOps
kubectl apply -f gitops/root-app.yaml
```

## Documentación

- [Arquitectura](ARCHITECTURE.md)
- [Instalación](INSTALL.md)