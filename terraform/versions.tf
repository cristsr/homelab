terraform {
  # >= 1.10 por use_lockfile en el backend s3 (locking nativo sin DynamoDB)
  required_version = ">= 1.10.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # State remoto en Cloudflare R2 (S3-compatible) — ver ADR-009. Runner de
  # CI efimero, no puede depender de un tfstate local. Un bloque backend no
  # admite variables (se evalua antes de que existan): el endpoint (atado a
  # la cuenta de Cloudflare) se completa por configuracion parcial, con
  # `terraform init -backend-config=backend.hcl` (ver backend.hcl.example).
  # Credenciales via env AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, nunca en
  # este archivo.
  backend "s3" {
    bucket                      = "homelab-tfstate"
    key                         = "terraform.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}
