# Tareas Pendientes del Homelab

Este documento lista las tareas planificadas para mejorar la automatizacion y el mantenimiento del cluster.

---

## 1. Integrar Renovate para Actualizaciones Automaticas

**Motivacion:** Actualmente las versiones de charts Helm e imagenes Docker estan fijadas manualmente. Cuando sale una nueva version (ej. SonarQube), hay que detectarlo y actualizar el `targetRevision` a mano.

**Tareas:**

- [ ] Instalar/configurar Renovate (GitHub App o self-hosted) para escanear el repositorio.
- [ ] Crear `renovate.json` en la raiz del repo con reglas para:
  - Detectar nuevas versiones de charts de Helm (ej. `sonarqube`, `argocd`, etc.).
  - Detectar nuevas versiones de imagenes Docker definidas en values de Helm.
  - Agrupar updates de tipo `patch` y `minor` para reducir ruido.
  - Separar updates `major` en PRs individuales por riesgo.
- [ ] Verificar que Renovate detecte correctamente las imagenes actuales (ej. `sonarqube:26.3.0.120487-community`).
- [ ] Documentar en `docs/OPERATIONS.md` como aprobar/rechazar PRs de Renovate.

**Archivos afectados:**
- `renovate.json` (nuevo)
- `docs/OPERATIONS.md`

---

## 2. Formalizar y Documentar Conventional Commits

**Motivacion:** El repositorio ya usa Conventional Commits de facto (`feat(sonarqube):`, `fix(networking):`, `refactor(observability):`), pero no esta documentado ni hay validacion automatica.

**Tareas:**

- [ ] Documentar la convencion de commits en `docs/CONTRIBUTING.md` o similar:
  - Tipos permitidos: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `test`, `perf`.
  - Formato: `tipo(alcance): descripcion`.
  - Alcances comunes: `sonarqube`, `networking`, `storage`, `observability`, `ansible`, `bootstrap`, `security`.
- [ ] (Opcional) Agregar validacion de mensajes de commit en CI (pre-commit hook o GitHub Action) con herramientas como `commitlint`.
- [ ] Revisar el historial reciente para identificar inconsistencias y corregir si es necesario.

**Archivos afectados:**
- `docs/CONTRIBUTING.md` (nuevo)
- `.github/workflows/commitlint.yaml` (opcional)

---

## 3. Migrar ArgoCD de polling a webhook de GitHub — RESUELTO (con matiz)

**Motivacion:** El polling original tenia un intervalo de 180s. Un webhook de GitHub entrega notificaciones en segundos tras cada push, eliminando la latencia innecesaria.

**Estado real:** El webhook esta implementado y funcionando (`webhook_secret` cargado en el item `argocd` del vault 1Password, `platform/argocd/webhook-externalsecret.yaml` lo sincroniza a `argocd-secret`; originalmente se cargaba con `scripts/load-secrets-to-openbao.sh` contra OpenBao, retirado en ADR-017). Sin embargo `timeout.reconciliation` **no** quedo en `0s`: se dejo en `600s` a proposito, como fallback de seguridad. El 2026-05-13 el webhook se rompio silenciosamente y el cluster estuvo sin sincronizar hasta el 2026-09-07 sin que nadie lo notara (con polling en `0s` no hay red de seguridad si el webhook falla). Ver el comentario en `bootstrap/argocd/values.yaml` y `docs/DECISIONS.md` para el detalle del incidente.

**Archivos afectados (implementados):**
- Item `argocd`, campo `webhook_secret`, en el vault "Homelab" de 1Password (ver `ARGOCD_WEBHOOK_SECRET` en `secrets/homelab.env.example` para el nombre original)
- `platform/argocd/webhook-externalsecret.yaml` — ExternalSecret con `creationPolicy: Merge` sobre `argocd-secret`
- `bootstrap/argocd/values.yaml` — `timeout.reconciliation: 600s` (fallback intencional, no bug)

---

## Notas

- Prioridad alta: Renovate, ya que reduce el trabajo manual de mantenimiento.
- Prioridad media: Documentar Conventional Commits, para estandarizar contribuciones.
- Prioridad media: Migrar ArgoCD a webhook para sync inmediato tras push.
- Fecha de creacion: 2026-05-11
